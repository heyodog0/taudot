//! `taudot login`: an Overleaf session cookie from the user's browser (or pasted), kept in the macOS Keychain.
//!
//! overleaf.com has no password login for programs (SSO, captcha), so taudot borrows the browser's session, as
//! Overleaf Workshop does. The cookie is `overleaf_session2` on overleaf.com and `overleaf.sid` on CE
//! (`docs/protocol.md`, Connecting). It goes to the Keychain under service `taudot`, account = the server's origin,
//! and the engine reads it from there when it has no password or cookie of its own.
//!
//! Chromium browsers (Chrome, Arc, Brave, Edge, Vivaldi) keep cookies in an SQLite file, encrypted with AES-128-CBC
//! under a key derived from a password in the Keychain (`<Browser> Safe Storage`); reading that password makes macOS
//! ask the user once. Safari keeps them in `Cookies.binarycookies`, readable with Full Disk Access.

use anyhow::{anyhow, bail, Context};
use std::path::{Path, PathBuf};

const SERVICE: &str = "taudot";
/// Cookie names that carry an Overleaf session.
pub const SESSION_COOKIES: [&str; 3] = ["overleaf_session2", "overleaf.sid", "sharelatex.sid"];

#[derive(clap::Args)]
pub struct Args {
    /// Overleaf server.
    #[arg(long, default_value = "https://www.overleaf.com")]
    pub url: String,
    /// Where to take the session from: chrome, arc, brave, edge, vivaldi, safari, or paste (read it from stdin).
    /// Default: try the browsers in that order.
    #[arg(long)]
    pub from: Option<String>,
    /// The cookie itself (`name=value`, or just the value).
    #[arg(long, env = "TAUDOT_COOKIE", hide_env_values = true)]
    pub cookie: Option<String>,
    /// Only check the stored session.
    #[arg(long)]
    pub check: bool,
    /// Forget the stored session.
    #[arg(long)]
    pub logout: bool,
    #[arg(long)]
    pub json: bool,
}

/// `https://www.overleaf.com` from any URL on that server.
pub fn origin(url: &str) -> anyhow::Result<String> {
    let u = url::Url::parse(url).with_context(|| format!("not a URL: {url}"))?;
    Ok(u.origin().ascii_serialization())
}

/// The stored session for `origin`: from the Keychain, or from `file` (a JSON object `{origin: cookie}`, for tests;
/// `--sessions`).
pub fn session_get(file: Option<&Path>, origin: &str) -> Option<String> {
    match file {
        Some(f) => read_sessions(f).get(origin).and_then(|v| v.as_str()).map(String::from),
        None => keychain_get(origin),
    }
}

pub fn session_set(file: Option<&Path>, origin: &str, cookie: &str) -> anyhow::Result<()> {
    match file {
        Some(f) => {
            let mut m = read_sessions(f);
            m.insert(origin.to_string(), cookie.into());
            Ok(std::fs::write(f, serde_json::to_string_pretty(&m)?)?)
        }
        None => keychain_set(origin, cookie),
    }
}

/// Forget the session; no error when there was none.
pub fn session_delete(file: Option<&Path>, origin: &str) -> anyhow::Result<()> {
    match file {
        Some(f) => {
            let mut m = read_sessions(f);
            if m.remove(origin).is_some() {
                std::fs::write(f, serde_json::to_string_pretty(&m)?)?;
            }
            Ok(())
        }
        None => {
            if keychain_get(origin).is_none() {
                return Ok(());
            }
            keychain_delete(origin)
        }
    }
}

fn read_sessions(f: &Path) -> serde_json::Map<String, serde_json::Value> {
    std::fs::read_to_string(f).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn keychain_get(origin: &str) -> Option<String> {
    if let Some(s) = keychain_read(SERVICE, origin) {
        return Some(s);
    }
    // Saved before the rename: copy it to the new service (the old item stays).
    let s = keychain_read(crate::compat::OLD_KEYCHAIN_SERVICE, origin)?;
    if let Err(e) = keychain_set(origin, &s) {
        tracing::warn!("copying the session for {origin} to the new Keychain service: {e:#}");
    }
    Some(s)
}

fn keychain_read(service: &str, origin: &str) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        // Through Apple's `security` tool, not the framework: macOS asks before each new build of taudot reads the
        // item (a new code signature), but remembers "Always Allow" for /usr/bin/security, which never changes.
        let out = std::process::Command::new("/usr/bin/security")
            .args(["find-generic-password", "-s", service, "-a", origin, "-w"])
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let s = String::from_utf8(out.stdout).ok()?;
        let s = s.trim_end_matches('\n').to_string();
        (!s.is_empty()).then_some(s)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (service, origin);
        None
    }
}

fn keychain_set(origin: &str, cookie: &str) -> anyhow::Result<()> {
    #[cfg(target_os = "macos")]
    {
        security_framework::passwords::set_generic_password(SERVICE, origin, cookie.as_bytes())
            .map_err(|e| anyhow!("Keychain: {e}"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (origin, cookie);
        bail!("the Keychain is macOS only; pass --cookie to taudot serve instead")
    }
}

fn keychain_delete(origin: &str) -> anyhow::Result<()> {
    #[cfg(target_os = "macos")]
    {
        security_framework::passwords::delete_generic_password(SERVICE, origin).map_err(|e| anyhow!("Keychain: {e}"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = origin;
        Ok(())
    }
}

/// `name=value` from what the user gave: a full cookie header, `name=value`, or a bare value.
pub fn normalise_cookie(raw: &str, origin: &str) -> anyhow::Result<String> {
    let raw = raw.trim().trim_start_matches("Cookie:").trim();
    let pairs: Vec<&str> = raw.split(';').map(str::trim).filter(|p| !p.is_empty()).collect();
    if let Some(p) = pairs.iter().find(|p| SESSION_COOKIES.iter().any(|n| p.starts_with(&format!("{n}=")))) {
        return Ok(p.to_string());
    }
    if pairs.len() == 1 && !pairs[0].contains('=') {
        let name = if origin.contains("overleaf.com") { "overleaf_session2" } else { "overleaf.sid" };
        return Ok(format!("{name}={}", pairs[0]));
    }
    bail!("no Overleaf session cookie ({}) in what was given", SESSION_COOKIES.join(", "))
}

/// Who a session cookie logs in as.
#[derive(Debug, Clone, Default)]
pub struct Who {
    pub user_id: String,
    pub email: String,
    /// `first last` from the settings page's `ol-user`, empty when the server doesn't say.
    pub name: String,
}

/// Who the cookie logs in as, or an error saying it expired. Reads the settings page, whose layout carries
/// `ol-user_id`, `ol-usersEmail` and `ol-csrfToken`, and its own `ol-user` JSON with the name
/// (`services/web/app/views/layout-base.pug`, `user/settings.pug`); falls back to the dashboard page for the ID.
pub async fn whoami(origin: &str, cookie: &str) -> anyhow::Result<Who> {
    let mut http = overleaf::Http::with_cookie(origin, cookie)?;
    whoami_http(&mut http).await
}

pub async fn whoami_http(http: &mut overleaf::Http) -> anyhow::Result<Who> {
    let origin = http.base.origin().ascii_serialization();
    let resp = http.client.get(http.base.join("user/settings")?).send().await?;
    let landed = resp.url().path().to_string();
    let status = resp.status();
    if landed.ends_with("/login") || status.as_u16() == 401 || status.as_u16() == 403 {
        bail!("the session for {origin} has expired or was logged out; log in again");
    }
    if !status.is_success() {
        bail!("GET {origin}/user/settings: {status}");
    }
    let html = resp.text().await?;
    let mut who = Who {
        user_id: meta(&html, "ol-user_id").unwrap_or_default(),
        email: meta(&html, "ol-usersEmail").unwrap_or_default(),
        name: String::new(),
    };
    if let Some(u) = meta(&html, "ol-user").and_then(|j| serde_json::from_str::<serde_json::Value>(&j).ok()) {
        let s = |k: &str| u.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
        who.name = format!("{} {}", s("first_name"), s("last_name")).trim().to_string();
        if who.email.is_empty() {
            who.email = s("email");
        }
    }
    if let Some(t) = meta(&html, "ol-csrfToken") {
        http.csrf = Some(t);
    }
    if who.user_id.is_empty() {
        http.fetch_csrf("project").await?;
        who.user_id = http.user_id.clone().ok_or_else(|| anyhow!("{origin}/project names no user; is the cookie right?"))?;
        if who.email.is_empty() {
            who.email = http.email.clone().unwrap_or_default();
        }
    }
    http.user_id = Some(who.user_id.clone());
    Ok(who)
}

/// The `content` of `<meta name="NAME" content="...">`, HTML entities undone.
fn meta(html: &str, name: &str) -> Option<String> {
    let needle = format!("name=\"{name}\"");
    let at = html.find(&needle)?;
    let start = html[..at].rfind('<')?;
    let end = at + html[at..].find('>')?;
    let tag = &html[start..end];
    let c = tag.find("content=\"")? + "content=\"".len();
    let len = tag[c..].find('"')?;
    let v = &tag[c..c + len];
    Some(v.replace("&quot;", "\"").replace("&#39;", "'").replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&"))
        .filter(|s| !s.is_empty())
}

/// Browsers tried, in order, when none is named.
pub const BROWSERS: [&str; 6] = ["chrome", "arc", "brave", "edge", "vivaldi", "safari"];

/// A working session cookie for `origin` and where it came from: `cookie` as given (source `given`), one browser
/// (`from`), or the first browser in [`BROWSERS`] with a session that `whoami` accepts.
pub async fn find_session(origin: &str, from: Option<&str>, cookie: Option<&str>) -> anyhow::Result<(String, String, Who)> {
    if let Some(c) = cookie {
        let c = normalise_cookie(c, origin)?;
        let who = whoami(origin, &c).await?;
        return Ok((c, "given".into(), who));
    }
    if let Some(b) = from {
        let c = from_browser(b, origin)?;
        let who = whoami(origin, &c).await.with_context(|| format!("the session in {b}"))?;
        return Ok((c, b.into(), who));
    }
    let mut errors = vec![];
    for b in BROWSERS {
        match from_browser(b, origin) {
            Ok(c) => match whoami(origin, &c).await {
                Ok(who) => return Ok((c, b.to_string(), who)),
                Err(e) => errors.push(format!("{b}: {e:#}")),
            },
            Err(e) => errors.push(format!("{b}: {e:#}")),
        }
    }
    bail!("no logged-in Overleaf session found in a browser:\n  {}\nLog in to {origin} in your browser, or paste the session cookie", errors.join("\n  "))
}

pub async fn run(a: Args) -> anyhow::Result<()> {
    let origin = origin(&a.url)?;
    if a.logout {
        session_delete(None, &origin)?;
        println!("forgot the session for {origin}");
        return Ok(());
    }
    if a.check {
        let cookie = session_get(None, &origin).ok_or_else(|| anyhow!("no session stored for {origin}; run `taudot login --url {origin}`"))?;
        let who = whoami(&origin, &cookie).await?;
        report(&a, &origin, &who, "keychain");
        return Ok(());
    }
    let pasted;
    let (cookie, from) = match (&a.cookie, a.from.as_deref()) {
        (Some(c), _) => (Some(c.as_str()), None),
        (None, Some("paste")) => {
            eprintln!("Paste the {} cookie for {origin} (from the browser's dev tools, Application > Cookies), then Enter:",
                if origin.contains("overleaf.com") { "overleaf_session2" } else { "overleaf.sid" });
            let mut line = String::new();
            std::io::stdin().read_line(&mut line)?;
            pasted = line;
            (Some(pasted.as_str()), None)
        }
        (None, b) => (None, b),
    };
    let (cookie, mut source, who) = find_session(&origin, from, cookie).await?;
    if a.from.as_deref() == Some("paste") {
        source = "paste".into();
    }
    session_set(None, &origin, &cookie)?;
    report(&a, &origin, &who, &source);
    Ok(())
}

fn report(a: &Args, origin: &str, who: &Who, source: &str) {
    let (id, email) = (&who.user_id, &who.email);
    if a.json {
        println!("{}", serde_json::json!({"server": origin, "user_id": id, "email": email, "name": who.name, "source": source}));
    } else {
        println!("logged in to {origin} as {email} ({id}); session from {source}, kept in the Keychain");
    }
}

/// Domains a cookie for `host` may be stored under: the host itself and each parent domain, with and without the
/// leading dot.
fn cookie_domains(host: &str) -> Vec<String> {
    let mut out = vec![];
    let parts: Vec<&str> = host.split('.').collect();
    for i in 0..parts.len().saturating_sub(1).max(1) {
        let d = parts[i..].join(".");
        out.push(d.clone());
        out.push(format!(".{d}"));
    }
    out
}

fn from_browser(browser: &str, origin: &str) -> anyhow::Result<String> {
    let host = url::Url::parse(origin)?.host_str().unwrap_or("").to_string();
    if browser == "safari" {
        return safari_cookie(&host);
    }
    let (dir, keychain) = match browser {
        "chrome" => ("Google/Chrome", "Chrome"),
        "arc" => ("Arc/User Data", "Arc"),
        "brave" => ("BraveSoftware/Brave-Browser", "Brave"),
        "edge" => ("Microsoft Edge", "Microsoft Edge"),
        "vivaldi" => ("Vivaldi", "Vivaldi"),
        other => bail!("unknown browser {other}; use chrome, arc, brave, edge, vivaldi, safari or paste"),
    };
    let home = PathBuf::from(std::env::var("HOME")?);
    let root = home.join("Library/Application Support").join(dir);
    if !root.is_dir() {
        bail!("not installed ({} missing)", root.display());
    }
    let mut dbs = vec![];
    for e in std::fs::read_dir(&root)?.flatten() {
        let n = e.file_name().to_string_lossy().to_string();
        if n == "Default" || n.starts_with("Profile ") {
            for f in ["Network/Cookies", "Cookies"] {
                let p = e.path().join(f);
                if p.is_file() {
                    dbs.push(p);
                    break;
                }
            }
        }
    }
    let domains = cookie_domains(&host);
    // Newest session first, across profiles.
    let mut found: Vec<(i64, String, Vec<u8>, String)> = vec![];
    for db in &dbs {
        for row in chromium_rows(db, &domains)? {
            found.push(row);
        }
    }
    if found.is_empty() {
        bail!("no Overleaf session cookie for {host} in {} profile(s)", dbs.len());
    }
    found.sort_by(|a, b| b.0.cmp(&a.0));
    let key = chromium_key(&format!("{keychain} Safe Storage"), keychain)?;
    let (_, name, enc, host_key) = &found[0];
    let value = chromium_decrypt(enc, &key, host_key)?;
    Ok(format!("{name}={value}"))
}

/// `(last_access, name, encrypted_value, host_key)` of session cookies for these domains. Uses the `sqlite3` that
/// ships with macOS on a copy of the file (the browser keeps it locked).
fn chromium_rows(db: &Path, domains: &[String]) -> anyhow::Result<Vec<(i64, String, Vec<u8>, String)>> {
    let tmp = std::env::temp_dir().join(format!("taudot-cookies-{}", std::process::id()));
    std::fs::copy(db, &tmp).with_context(|| format!("copying {}", db.display()))?;
    let q = |s: &str| format!("'{}'", s.replace('\'', "''"));
    let sql = format!(
        "select last_access_utc, name, hex(encrypted_value), host_key from cookies where host_key in ({}) and name in ({});",
        domains.iter().map(|d| q(d)).collect::<Vec<_>>().join(","),
        SESSION_COOKIES.iter().map(|n| q(n)).collect::<Vec<_>>().join(",")
    );
    let out = std::process::Command::new("/usr/bin/sqlite3").arg("-separator").arg("\t").arg(&tmp).arg(sql).output();
    let _ = std::fs::remove_file(&tmp);
    let out = out.context("running sqlite3")?;
    if !out.status.success() {
        bail!("sqlite3 {}: {}", db.display(), String::from_utf8_lossy(&out.stderr).trim());
    }
    let mut rows = vec![];
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() == 4 {
            let enc = (0..f[2].len()).step_by(2).filter_map(|i| u8::from_str_radix(&f[2][i..i + 2], 16).ok()).collect();
            rows.push((f[0].parse().unwrap_or(0), f[1].to_string(), enc, f[3].to_string()));
        }
    }
    Ok(rows)
}

fn chromium_key(service: &str, account: &str) -> anyhow::Result<[u8; 16]> {
    #[cfg(target_os = "macos")]
    {
        let pw = security_framework::passwords::get_generic_password(service, account)
            .map_err(|e| anyhow!("reading \"{service}\" from the Keychain (allow it when macOS asks): {e}"))?;
        Ok(chromium_key_from(&pw))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (service, account);
        bail!("browser cookies are read on macOS only")
    }
}

/// PBKDF2-HMAC-SHA1 of the Safe Storage password, salt `saltysalt`, 1003 rounds, 16 bytes (Chromium's
/// `os_crypt_mac.mm`).
fn chromium_key_from(password: &[u8]) -> [u8; 16] {
    let mut key = [0u8; 16];
    pbkdf2::pbkdf2_hmac::<sha1::Sha1>(password, b"saltysalt", 1003, &mut key);
    key
}

/// `v10` + AES-128-CBC with a 16-space IV and PKCS#7 padding. Since Chromium 130 the plaintext starts with the
/// SHA-256 of the cookie's host_key, which is dropped.
fn chromium_decrypt(enc: &[u8], key: &[u8; 16], host_key: &str) -> anyhow::Result<String> {
    use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};
    let body = enc.strip_prefix(b"v10").ok_or_else(|| anyhow!("cookie is not v10-encrypted"))?;
    let mut buf = body.to_vec();
    let plain = cbc::Decryptor::<aes::Aes128>::new(key.into(), &[b' '; 16].into())
        .decrypt_padded_mut::<Pkcs7>(&mut buf)
        .map_err(|_| anyhow!("could not decrypt the cookie (wrong Safe Storage key?)"))?;
    use sha2::Digest;
    let digest = sha2::Sha256::digest(host_key.as_bytes());
    let plain = if plain.len() >= 32 && plain[..32] == digest[..] { &plain[32..] } else { plain };
    Ok(String::from_utf8(plain.to_vec())?)
}

fn safari_cookie(host: &str) -> anyhow::Result<String> {
    let home = PathBuf::from(std::env::var("HOME")?);
    let candidates = [
        home.join("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
        home.join("Library/Cookies/Cookies.binarycookies"),
    ];
    let path = candidates.iter().find(|p| p.exists()).ok_or_else(|| anyhow!("no Safari cookie file"))?;
    let data = std::fs::read(path).with_context(|| {
        format!("reading {} (give the terminal Full Disk Access in System Settings, or use --from paste)", path.display())
    })?;
    let domains = cookie_domains(host);
    let mut best: Option<(f64, String)> = None;
    for c in parse_binarycookies(&data)? {
        if domains.contains(&c.domain) && SESSION_COOKIES.contains(&c.name.as_str()) && best.as_ref().is_none_or(|b| c.expires > b.0) {
            best = Some((c.expires, format!("{}={}", c.name, c.value)));
        }
    }
    best.map(|b| b.1).ok_or_else(|| anyhow!("no Overleaf session cookie for {host} in Safari"))
}

#[derive(Debug, PartialEq)]
struct BinaryCookie {
    domain: String,
    name: String,
    value: String,
    expires: f64,
}

/// Safari's `Cookies.binarycookies`: `cook`, page count and sizes (big-endian), then pages of little-endian cookie
/// records with offsets to NUL-terminated domain, name, path and value strings.
fn parse_binarycookies(d: &[u8]) -> anyhow::Result<Vec<BinaryCookie>> {
    let be = |i: usize| -> anyhow::Result<u32> { Ok(u32::from_be_bytes(d.get(i..i + 4).ok_or_else(|| anyhow!("truncated"))?.try_into()?)) };
    if d.get(..4) != Some(b"cook") {
        bail!("not a binarycookies file");
    }
    let pages = be(4)? as usize;
    let mut sizes = vec![];
    for i in 0..pages {
        sizes.push(be(8 + 4 * i)? as usize);
    }
    let mut at = 8 + 4 * pages;
    let mut out = vec![];
    for size in sizes {
        let page = d.get(at..at + size).ok_or_else(|| anyhow!("truncated page"))?;
        at += size;
        let le = |b: &[u8], i: usize| -> Option<u32> { Some(u32::from_le_bytes(b.get(i..i + 4)?.try_into().ok()?)) };
        let n = le(page, 4).unwrap_or(0) as usize;
        for k in 0..n {
            let Some(off) = le(page, 8 + 4 * k).map(|o| o as usize) else { continue };
            let Some(rec) = page.get(off..) else { continue };
            let Some(len) = le(rec, 0).map(|l| l as usize) else { continue };
            let Some(rec) = rec.get(..len) else { continue };
            let s = |field: usize| -> String {
                let o = le(rec, field).unwrap_or(0) as usize;
                let bytes = rec.get(o..).unwrap_or(&[]);
                let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
                String::from_utf8_lossy(&bytes[..end]).to_string()
            };
            let expires = rec.get(40..48).map(|b| f64::from_le_bytes(b.try_into().unwrap())).unwrap_or(0.0);
            out.push(BinaryCookie { domain: s(16), name: s(20), value: s(28), expires });
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cookie_forms() {
        let o = "https://www.overleaf.com";
        assert_eq!(normalise_cookie("abc", o).unwrap(), "overleaf_session2=abc");
        assert_eq!(normalise_cookie("Cookie: GCLB=x; overleaf_session2=s%3Aq.r", o).unwrap(), "overleaf_session2=s%3Aq.r");
        assert_eq!(normalise_cookie("xyz", "http://localhost:8800").unwrap(), "overleaf.sid=xyz");
        assert!(normalise_cookie("a=b; c=d", o).is_err());
    }

    #[test]
    fn domains() {
        assert_eq!(cookie_domains("www.overleaf.com"), ["www.overleaf.com", ".www.overleaf.com", "overleaf.com", ".overleaf.com"]);
        assert_eq!(cookie_domains("localhost"), ["localhost", ".localhost"]);
    }

    #[test]
    fn chromium_round_trip() {
        use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
        use sha2::Digest;
        let key = chromium_key_from(b"peanuts");
        for prefix_hash in [false, true] {
            let mut plain = vec![];
            if prefix_hash {
                plain.extend_from_slice(&sha2::Sha256::digest(b".overleaf.com"));
            }
            plain.extend_from_slice(b"s%3Asecret.sig");
            let n = plain.len();
            let mut buf = plain.clone();
            buf.resize(n + 16, 0);
            let enc = cbc::Encryptor::<aes::Aes128>::new(&key.into(), &[b' '; 16].into()).encrypt_padded_mut::<Pkcs7>(&mut buf, n).unwrap().to_vec();
            let mut v = b"v10".to_vec();
            v.extend(enc);
            assert_eq!(chromium_decrypt(&v, &key, ".overleaf.com").unwrap(), "s%3Asecret.sig");
        }
    }

    #[test]
    fn binarycookies() {
        // One page, one cookie, built by hand in Safari's layout.
        let mut rec = vec![0u8; 56];
        let strings: [&[u8]; 4] = [b".overleaf.com\0", b"overleaf_session2\0", b"/\0", b"s%3Aabc\0"];
        let mut offs = vec![];
        for s in strings {
            offs.push(rec.len() as u32);
            rec.extend_from_slice(s);
        }
        let len = rec.len() as u32;
        rec[0..4].copy_from_slice(&len.to_le_bytes());
        for (i, o) in offs.iter().enumerate() {
            let f = [16, 20, 24, 28][i];
            rec[f..f + 4].copy_from_slice(&o.to_le_bytes());
        }
        rec[40..48].copy_from_slice(&1e9f64.to_le_bytes());
        let mut page = vec![0, 0, 1, 0];
        page.extend_from_slice(&1u32.to_le_bytes());
        page.extend_from_slice(&16u32.to_le_bytes());
        page.extend_from_slice(&[0, 0, 0, 0]);
        page.extend_from_slice(&rec);
        let mut file = b"cook".to_vec();
        file.extend_from_slice(&1u32.to_be_bytes());
        file.extend_from_slice(&(page.len() as u32).to_be_bytes());
        file.extend_from_slice(&page);
        let c = parse_binarycookies(&file).unwrap();
        assert_eq!(c, vec![BinaryCookie { domain: ".overleaf.com".into(), name: "overleaf_session2".into(), value: "s%3Aabc".into(), expires: 1e9 }]);
    }
}
