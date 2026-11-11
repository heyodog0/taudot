//! TeX Live files: find them through the tree's ls-R (fetching from the store on a miss), and read TFM, VF, the
//! pdfTeX map and encoding files.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct Texmf {
    pub root: PathBuf,
    files: HashMap<String, PathBuf>,
    pub map: Vec<MapLine>,
    tfms: HashMap<String, Option<Tfm>>,
    vfs: HashMap<String, Option<Vf>>,
}

#[derive(Debug, Clone)]
pub struct MapLine {
    pub tfm: String,
    pub ps: String,
    pub special: String,
    pub enc: Option<String>,
    /// The font program (`.pfb`...), if the line names one.
    pub file: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct Tfm {
    pub design: f64,
    pub bc: u32,
    pub ec: u32,
    /// Width per code, in units of the design size.
    pub width: HashMap<u32, f64>,
    /// (left, right) → ligature char, for plain `=:` ligatures.
    pub ligs: HashMap<(u32, u32), u32>,
    /// (left, right) → kern, in units of the design size.
    pub kerns: HashMap<(u32, u32), f64>,
    /// fontdimens, 1-based (param[1] slant, [2] space, ...).
    pub param: Vec<f64>,
}

#[derive(Debug, Clone, Default)]
pub struct Vf {
    /// Base fonts by local number: tfm name and scale (fix_word relative to the VF's size).
    pub fonts: HashMap<u32, (String, f64)>,
    /// VF char → (base font name, base char) for packets that set exactly one char.
    pub single: HashMap<u32, (String, u32)>,
    /// The scale of the base font each single packet sets from (small caps: lowercase from the base at ~0.8).
    pub single_scale: HashMap<u32, f64>,
}

static MISSES: std::sync::Mutex<Option<std::collections::HashSet<String>>> = std::sync::Mutex::new(None);

impl Texmf {
    pub fn new() -> Texmf {
        let root = std::env::var("PDFSOURCE_TLROOT").map(PathBuf::from).unwrap_or_else(|_| {
            ref_dir().join("texlive-2026/store-root")
        });
        let mut files = HashMap::new();
        for tree in ["texmf-var", "texmf-dist"] {
            let lsr = root.join(tree).join("ls-R");
            let Ok(text) = std::fs::read_to_string(&lsr) else { continue };
            let mut dir = PathBuf::new();
            for line in text.lines() {
                if let Some(d) = line.strip_suffix(':') {
                    dir = root.join(tree).join(d.trim_start_matches("./"));
                } else if !line.is_empty() && !line.starts_with('%') {
                    // The release tree wins over latex-dev (pre-release copies the store may not hold).
                    let p = dir.join(line);
                    let e = files.entry(line.to_string()).or_insert_with(|| p.clone());
                    if e.to_string_lossy().contains("/latex-dev/") && !p.to_string_lossy().contains("/latex-dev/") {
                        *e = p;
                    }
                }
            }
        }
        let mut t = Texmf { root, files, map: vec![], tfms: HashMap::new(), vfs: HashMap::new() };
        if let Some(p) = t.find("pdftex.map") {
            if let Ok(text) = std::fs::read_to_string(p) {
                t.map = text.lines().filter_map(parse_map_line).collect();
            }
        }
        t
    }

    /// Path of a TeX Live file, fetched from the store if the tree doesn't have it yet.
    pub fn find(&self, name: &str) -> Option<PathBuf> {
        let p = self.files.get(name)?;
        if p.exists() {
            return Some(p.clone());
        }
        // A file the store doesn't have for this image stays missing: remembered (in memory and on disk) so a run
        // doesn't pay a fetch process per lookup.
        let image = std::env::var("TEXSTORE_IMAGE").unwrap_or("2026.1@r79468".into());
        let misses = ref_dir().join("pdfsource").join(format!("fetch-misses-{}.txt", image.replace(['/', '@'], "_")));
        let key = p.display().to_string();
        {
            let mut m = MISSES.lock().unwrap();
            if m.is_none() {
                // (a day at most: a miss may be the store being unreachable, not the file being absent)
                let fresh = std::fs::metadata(&misses).and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).is_some_and(|age| age.as_secs() < 86400);
                if !fresh {
                    let _ = std::fs::remove_file(&misses);
                }
                *m = Some(std::fs::read_to_string(&misses).unwrap_or_default().lines().map(String::from).collect());
            }
            if m.as_ref().unwrap().contains(&key) {
                return None;
            }
        }
        let fetch = std::env::var("PDFSOURCE_FETCH").map(PathBuf::from).unwrap_or_else(|_| {
            fetch_tool()
        });
        let ok = Command::new("sh")
            .arg(&fetch)
            .arg(p)
            .env("TEXSTORE_ROOT", &self.root)
            .env("TEXSTORE_IMAGE", std::env::var("TEXSTORE_IMAGE").unwrap_or("2026.1@r79468".into()))
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if ok && p.exists() {
            return Some(p.clone());
        }
        MISSES.lock().unwrap().as_mut().unwrap().insert(key.clone());
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&misses) {
            use std::io::Write;
            let _ = writeln!(f, "{key}");
        }
        None
    }

    pub fn tfm(&mut self, name: &str) -> Option<&Tfm> {
        if !self.tfms.contains_key(name) {
            let t = self.find(&format!("{name}.tfm")).and_then(|p| std::fs::read(p).ok()).and_then(|b| parse_tfm(&b));
            self.tfms.insert(name.to_string(), t);
        }
        self.tfms.get(name).unwrap().as_ref()
    }

    pub fn vf(&mut self, name: &str) -> Option<&Vf> {
        if !self.vfs.contains_key(name) {
            let v = self.find(&format!("{name}.vf")).and_then(|p| std::fs::read(p).ok()).and_then(|b| parse_vf(&b));
            self.vfs.insert(name.to_string(), v);
        }
        self.vfs.get(name).unwrap().as_ref()
    }

    pub fn has(&self, name: &str) -> bool {
        self.files.contains_key(name)
    }

    /// Names of VF fonts that might sit on a raw font: same first four letters (Berry naming), any VF.
    pub fn vf_candidates(&self, raw: &str) -> Vec<String> {
        let pre: String = raw.chars().take(4).collect();
        let mut v: Vec<String> = self
            .files
            .keys()
            .filter(|k| k.starts_with(&pre) && k.ends_with(".vf"))
            .map(|k| k.trim_end_matches(".vf").to_string())
            .collect();
        v.sort();
        v
    }

    pub fn encoding(&self, name: &str) -> Option<Vec<String>> {
        let text = std::fs::read_to_string(self.find(name)?).ok()?;
        let body: String = text.lines().map(|l| l.split('%').next().unwrap_or("")).collect::<Vec<_>>().join(" ");
        let start = body.find('[')?;
        let end = body[start..].find(']')? + start;
        Some(body[start + 1..end].split_whitespace().map(|s| s.trim_start_matches('/').to_string()).collect())
    }
}

fn parse_map_line(l: &str) -> Option<MapLine> {
    if l.starts_with('%') || l.trim().is_empty() {
        return None;
    }
    let mut toks = vec![];
    let mut special = String::new();
    let mut rest = l;
    while !rest.trim().is_empty() {
        rest = rest.trim_start();
        if let Some(r) = rest.strip_prefix('"') {
            let e = r.find('"').unwrap_or(r.len());
            special = r[..e].trim().to_string();
            rest = &r[(e + 1).min(r.len())..];
        } else {
            let e = rest.find(char::is_whitespace).unwrap_or(rest.len());
            toks.push(rest[..e].to_string());
            rest = &rest[e..];
        }
    }
    let enc = toks.iter().find(|t| t.ends_with(".enc")).map(|t| t.trim_start_matches(['<', '[']).to_string());
    let file = toks.iter().find(|t| t.starts_with('<') && !t.ends_with(".enc")).map(|t| t.trim_start_matches('<').to_string());
    let ps = toks.get(1).filter(|t| !t.starts_with('<')).cloned().unwrap_or_else(|| toks[0].clone());
    Some(MapLine { tfm: toks[0].clone(), ps, special, enc, file })
}

fn be(b: &[u8], i: usize, n: usize) -> u32 {
    (0..n).fold(0u32, |a, k| (a << 8) | *b.get(i + k).unwrap_or(&0) as u32)
}

fn fix(b: &[u8], i: usize) -> f64 {
    (be(b, i, 4) as i32) as f64 / (1u32 << 20) as f64
}

pub fn parse_tfm(b: &[u8]) -> Option<Tfm> {
    if b.len() < 24 {
        return None;
    }
    let h = |k: usize| be(b, 2 * k, 2) as usize;
    let (lh, bc, ec, nw, nh, nd, ni, nl, nk, _ne, np) = (h(1), h(2), h(3), h(4), h(5), h(6), h(7), h(8), h(9), h(10), h(11));
    let ci = 24 + 4 * lh;
    let wi = ci + 4 * (ec + 1 - bc).max(0);
    let li = wi + 4 * (nw + nh + nd + ni);
    let ki = li + 4 * nl;
    let ei = ki + 4 * nk;
    let pi = ei + 4 * h(10);
    if pi + 4 * np > b.len() {
        return None;
    }
    let mut t = Tfm { design: fix(b, 24 + 4), bc: bc as u32, ec: ec as u32, ..Default::default() };
    let kern = |k: usize| if ki + 4 * k + 4 <= b.len() { fix(b, ki + 4 * k) } else { 0.0 };
    for c in bc..=ec {
        let o = ci + 4 * (c - bc);
        let wix = b[o] as usize;
        if wix == 0 {
            continue;
        }
        t.width.insert(c as u32, fix(b, wi + 4 * wix));
        let tag = b[o + 2] & 3;
        if tag == 1 && nl > 0 {
            let mut i = b[o + 3] as usize;
            let first = li + 4 * i;
            if b[first] > 128 {
                i = 256 * b[first + 2] as usize + b[first + 3] as usize;
            }
            for _ in 0..nl {
                let s = li + 4 * i;
                if s + 4 > b.len() {
                    break;
                }
                let (skip, next, op, rem) = (b[s], b[s + 1], b[s + 2], b[s + 3]);
                if skip <= 128 && op == 0 {
                    t.ligs.entry((c as u32, next as u32)).or_insert(rem as u32);
                }
                if skip <= 128 && op >= 128 {
                    t.kerns.entry((c as u32, next as u32)).or_insert(kern(256 * (op as usize - 128) + rem as usize));
                }
                if skip >= 128 {
                    break;
                }
                i += skip as usize + 1;
            }
        }
    }
    t.param.push(0.0);
    for k in 0..np {
        t.param.push(fix(b, pi + 4 * k));
    }
    Some(t)
}

pub fn parse_vf(b: &[u8]) -> Option<Vf> {
    if b.first() != Some(&247) {
        return None;
    }
    let k = b[2] as usize;
    let mut i = 3 + k + 8;
    let mut v = Vf::default();
    loop {
        let op = *b.get(i)?;
        if (243..=246).contains(&op) {
            let n = (op - 242) as usize;
            let num = be(b, i + 1, n);
            let s = fix(b, i + 1 + n + 4);
            let a = b[i + 1 + n + 12] as usize;
            let l = b[i + 1 + n + 13] as usize;
            let nm0 = i + 1 + n + 14;
            let name = String::from_utf8_lossy(&b[nm0 + a..nm0 + a + l]).into_owned();
            v.fonts.insert(num, (name, s));
            i = nm0 + a + l;
        } else {
            break;
        }
    }
    let first_font = v.fonts.keys().min().copied().unwrap_or(0);
    loop {
        let op = *b.get(i)?;
        let (cc, dvi) = if op < 242 {
            let pl = op as usize;
            let cc = b[i + 1] as u32;
            let d = &b[i + 5..i + 5 + pl];
            i += 5 + pl;
            (cc, d)
        } else if op == 242 {
            let pl = be(b, i + 1, 4) as usize;
            let cc = be(b, i + 5, 4);
            let d = &b[i + 13..i + 13 + pl];
            i += 13 + pl;
            (cc, d)
        } else {
            break;
        };
        // One set of one char, from whatever font is selected; skip packets with moves, rules or specials.
        let mut font = first_font;
        let mut set: Vec<u32> = vec![];
        let mut ok = true;
        let mut j = 0;
        while j < dvi.len() {
            let o = dvi[j];
            match o {
                0..=127 => {
                    set.push(o as u32);
                    j += 1
                }
                128..=131 => {
                    let n = (o - 127) as usize;
                    set.push(be(dvi, j + 1, n));
                    j += 1 + n
                }
                171..=234 => {
                    font = (o - 171) as u32;
                    j += 1
                }
                235..=238 => {
                    let n = (o - 234) as usize;
                    font = be(dvi, j + 1, n);
                    j += 1 + n
                }
                141 | 142 => j += 1,
                // Horizontal moves around the char (letterspaced small caps): pdfTeX keeps them; the mapping holds.
                147 | 152 => j += 1,
                143..=146 => j += 1 + (o - 142) as usize,
                148..=151 => j += 1 + (o - 147) as usize,
                153..=156 => j += 1 + (o - 152) as usize,
                _ => {
                    ok = false;
                    break;
                }
            }
        }
        if ok && set.len() == 1 {
            if let Some((name, sc)) = v.fonts.get(&font) {
                v.single.insert(cc, (name.clone(), set[0]));
                v.single_scale.insert(cc, *sc);
            }
        }
    }
    Some(v)
}

pub fn exists(p: &Path) -> bool {
    p.exists()
}

/// An NFSS font: encoding, family, series, shape (what `\usefont` takes).
pub type Nfss = (String, String, String, String);

impl Texmf {
    /// The NFSS font whose `.fd` maps to this TFM (at `size_pt`), from the `.fd` files whose family is a prefix of
    /// the TFM's name (`ot1ptm.fd` for `ptmr7t`, `ot1cmr.fd` for `cmr10`; EC fonts look in the CM families).
    pub fn nfss_of(&mut self, tfm: &str, size_pt: f64) -> Option<Nfss> {
        // Latin Modern names carry the encoding: ec-lmr10, ts1-lmr10, rm-lmr10 (family lmr).
        let mut base = tfm.rsplit('-').next().unwrap_or(tfm).to_string();
        for (ec, cm) in [("ecrm", "cmr"), ("ecbx", "cmr"), ("ecti", "cmr"), ("ecsl", "cmr"), ("eccc", "cmr"), ("ecbi", "cmr"),
            ("ectt", "cmtt"), ("ecit", "cmtt"), ("ecss", "cmss"), ("ecsx", "cmss"), ("ecsi", "cmss")]
        {
            if tfm.starts_with(ec) {
                base = cm.to_string();
            }
        }
        let mut fds: Vec<String> = self
            .files
            .keys()
            .filter(|k| k.ends_with(".fd"))
            .filter(|k| {
                let stem = k.trim_end_matches(".fd");
                ["ot1", "t1", "ts1"].iter().any(|e| stem.strip_prefix(e).is_some_and(|fam| fam.len() >= 3 && base.starts_with(fam)))
            })
            .cloned()
            .collect();
        fds.sort_by_key(|k| (std::cmp::Reverse(k.len()), k.clone()));
        for fd in fds.iter().take(8) {
            let Some(text) = self.find(fd).and_then(|p| std::fs::read_to_string(p).ok()) else { continue };
            if let Some(n) = fd_lookup(&text, tfm, size_pt) {
                return Some(n);
            }
        }
        None
    }
}

/// Find `tfm` in an .fd file's `\DeclareFontShape`s.
fn fd_lookup(text: &str, tfm: &str, size_pt: f64) -> Option<Nfss> {
    let body: String = text.lines().map(|l| l.split('%').next().unwrap_or("")).collect::<Vec<_>>().join(" ");
    // t1cmr.fd and friends: \EC@family{enc}{family}{series}{shape}{prefix} declares genb*prefix (ecrm1095 ...).
    for part in body.split("\\EC@family").skip(1) {
        let args: Vec<&str> = part.split('}').take(5).map(|a| a.trim().trim_start_matches('{').trim()).collect();
        if args.len() == 5 {
            if let Some(d) = tfm.strip_prefix(args[4]) {
                if d.len() == 4 && d.chars().all(|c| c.is_ascii_digit()) {
                    return Some((args[0].into(), args[1].into(), args[2].into(), args[3].into()));
                }
            }
        }
    }
    let mut rest = body.as_str();
    while let Some(i) = rest.find("\\DeclareFontShape") {
        rest = &rest[i + 17..];
        let mut args: Vec<String> = vec![];
        let mut r = rest;
        for _ in 0..5 {
            let Some(o) = r.find('{') else { break };
            let mut depth = 0;
            let mut end = None;
            for (j, ch) in r[o..].char_indices() {
                match ch {
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if depth == 0 {
                            end = Some(o + j);
                            break;
                        }
                    }
                    _ => {}
                }
            }
            let Some(e) = end else { break };
            args.push(r[o + 1..e].trim().to_string());
            r = &r[e + 1..];
        }
        if args.len() < 5 {
            continue;
        }
        let spec = &args[4];
        let toks: Vec<&str> = spec.split(|c: char| c.is_whitespace() || c == '<' || c == '>').filter(|t| !t.is_empty()).collect();
        let hit = toks.iter().any(|t| *t == tfm)
            || toks.windows(3).any(|w| (w[0] == "gen" || w[0] == "genb") && w[1] == "*" && {
                let p = w[2];
                tfm.strip_prefix(p).is_some_and(|d| {
                    d.chars().all(|c| c.is_ascii_digit()) && !d.is_empty() && {
                        let v: f64 = d.parse().unwrap_or(0.0);
                        let v = if w[0] == "genb" { v / 100.0 } else { v };
                        (v - size_pt).abs() < 0.6 || w[0] == "gen"
                    }
                })
            });
        if hit && !spec.contains("sub *") {
            return Some((args[0].clone(), args[1].clone(), args[2].clone(), args[3].clone()));
        }
    }
    None
}

/// The reference tree (TeX Live store root, stock engines, formats, corpus): `$TAUDOT_REF`.
pub fn ref_dir() -> PathBuf {
    match std::env::var("TAUDOT_REF") {
        Ok(r) => PathBuf::from(r),
        Err(_) => {
            eprintln!("pdfsource: set TAUDOT_REF to the reference tree (texlive-2026/store-root, universal/bin-static, universal/fmt-2026)");
            std::process::exit(2)
        }
    }
}

/// The repo's TeX Live store client (`tools/texstore/tl-fetch`), relative to this crate.
pub fn fetch_tool() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tools/texstore/tl-fetch")
}

impl Texmf {
    /// The NFSS font of `tfm` in one family's `.fd` for an encoding (e.g. TS1/cmr may map to Latin Modern).
    pub fn nfss_in(&mut self, enc: &str, fam: &str, tfm: &str, size_pt: f64) -> Option<Nfss> {
        let fd = format!("{}{}.fd", enc.to_ascii_lowercase(), fam);
        let text = std::fs::read_to_string(self.find(&fd)?).ok()?;
        fd_lookup(&text, tfm, size_pt)
    }
}
