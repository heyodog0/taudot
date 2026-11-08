//! `account.status`, `account.login`, `account.logout` (docs/api.md, Accounts): the session `taudot login` keeps,
//! for the app's sign-in view. The logic is `login.rs`'s; this only adds the RPC shape and remembers where each
//! session came from (`<home>/accounts.json`, `{origin: {source, user_id, email, name}}`; no secrets in it).
//!
//! Logging out only forgets the stored cookie. It doesn't call Overleaf's `/logout`: the cookie is usually the
//! browser's own session, and that would sign the browser out too.

use crate::login::{self, Who};
use crate::Login;
use anyhow::{anyhow, bail};
use serde_json::{json, Value};
use std::path::Path;

pub const DEFAULT_SERVER: &str = "https://www.overleaf.com";

/// The server origin a call is about: its `url` (any URL on that server), else overleaf.com.
pub fn server(p: &Value) -> anyhow::Result<String> {
    login::origin(p.get("url").and_then(Value::as_str).unwrap_or(DEFAULT_SERVER))
}

/// The login for a server: the engine's own when it is that server, else the session `taudot login` stored for it.
pub fn login_for(login: &Login, url: Option<&str>) -> anyhow::Result<Login> {
    let Some(url) = url.filter(|u| u.starts_with("http")) else { return Ok(login.clone()) };
    let origin = login::origin(url)?;
    if login::origin(&login.url)? == origin {
        return Ok(login.clone());
    }
    Ok(Login { url: origin, env_file: None, user: login.user.clone(), email: None, password: None, cookie: None, sessions: login.sessions.clone() })
}

/// True when the engine was started with its own credentials for `origin` (`--cookie`, `--password`, `--env-file`).
fn engine_has_credentials(login: &Login, origin: &str) -> bool {
    login::origin(&login.url).is_ok_and(|o| o == origin)
        && (login.cookie.is_some() || login.password.is_some() || login.env_file.is_some())
}

fn read_accounts(home: &Path) -> serde_json::Map<String, Value> {
    std::fs::read_to_string(home.join("accounts.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn write_accounts(home: &Path, m: &serde_json::Map<String, Value>) -> anyhow::Result<()> {
    Ok(std::fs::write(home.join("accounts.json"), serde_json::to_string_pretty(m)? + "\n")?)
}

fn who_json(origin: &str, who: &Who, source: &str) -> Value {
    let name = if who.name.is_empty() { who.email.split('@').next().unwrap_or("").to_string() } else { who.name.clone() };
    json!({"logged_in": true, "server": origin, "user_id": who.user_id, "email": who.email, "name": name, "source": source})
}

/// `{logged_in, server, user_id?, email?, name?, source?}`. `source` is where the session came from: a browser
/// (`chrome`, `safari`, ...), `cookie` (pasted), `webview` (signed in inside the app), or `engine` (the engine's own
/// credentials). An expired session gives `logged_in: false, expired: true, error`.
pub async fn status(engine: &Login, home: &Path, p: &Value) -> anyhow::Result<Value> {
    let origin = server(p)?;
    if let Some(cookie) = login::session_get(engine.sessions.as_deref(), &origin) {
        let source = read_accounts(home).get(&origin).and_then(|a| a["source"].as_str()).unwrap_or("keychain").to_string();
        return Ok(match login::whoami(&origin, &cookie).await {
            Ok(who) => who_json(&origin, &who, &source),
            Err(e) => json!({"logged_in": false, "server": origin, "expired": true, "source": source, "error": format!("{e:#}")}),
        });
    }
    if engine_has_credentials(engine, &origin) {
        let mut http = engine.http().await?;
        let who = login::whoami_http(&mut http).await?;
        return Ok(who_json(&origin, &who, "engine"));
    }
    Ok(json!({"logged_in": false, "server": origin}))
}

/// `{url?, from?: "browser"|"cookie", browser?, cookie?}`. `browser` alone tries that browser; `from: "browser"`
/// without one tries them in `login::BROWSERS` order and the result's `source` says which one worked. `from:
/// "cookie"` takes `cookie` (a cookie header, `name=value`, or the bare value). `source` may be given to label the
/// session (the app's sign-in web view says `webview`).
pub async fn login(engine: &Login, home: &Path, p: &Value) -> anyhow::Result<Value> {
    let origin = server(p)?;
    let s = |k: &str| p.get(k).and_then(Value::as_str);
    let from = s("from").unwrap_or(if s("cookie").is_some() { "cookie" } else { "browser" });
    let (cookie, source, who) = match from {
        "cookie" => {
            let c = s("cookie").ok_or_else(|| anyhow!("from: cookie needs a cookie"))?;
            let (c, _, who) = login::find_session(&origin, None, Some(c)).await?;
            (c, s("source").unwrap_or("cookie").to_string(), who)
        }
        "browser" => {
            let browser = s("browser");
            if let Some(b) = browser.filter(|b| !login::BROWSERS.contains(b)) {
                bail!("unknown browser {b}; use one of {}", login::BROWSERS.join(", "));
            }
            // Reading a browser's cookies runs `sqlite3` and may wait on a Keychain prompt: off the async workers.
            let o = origin.clone();
            let b = browser.map(String::from);
            tokio::task::spawn_blocking(move || {
                tokio::runtime::Handle::current().block_on(login::find_session(&o, b.as_deref(), None))
            })
            .await??
        }
        other => bail!("from must be browser or cookie, not {other}"),
    };
    login::session_set(engine.sessions.as_deref(), &origin, &cookie)?;
    let mut accounts = read_accounts(home);
    accounts.insert(origin.clone(), json!({"source": source, "user_id": who.user_id, "email": who.email, "name": who.name}));
    write_accounts(home, &accounts)?;
    Ok(who_json(&origin, &who, &source))
}

/// Forget the stored session for the server. Projects already open keep their connection until it drops.
pub async fn logout(engine: &Login, home: &Path, p: &Value) -> anyhow::Result<Value> {
    let origin = server(p)?;
    login::session_delete(engine.sessions.as_deref(), &origin)?;
    let mut accounts = read_accounts(home);
    if accounts.remove(&origin).is_some() {
        write_accounts(home, &accounts)?;
    }
    Ok(json!({"logged_in": false, "server": origin}))
}
