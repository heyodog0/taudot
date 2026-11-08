//! Completion (`complete.items`): bib keys, labels, commands, environments and file paths from the whole project.
//!
//! A child module of `engine`, like `review`, so it reads the actor's docs directly. The index keeps, per open doc,
//! what a scan of its text found and the `seq` it was scanned at. A call rescans only the docs whose `seq` moved since
//! (usually just the one being typed in), never the disk. Everything else is a pure function of text, tested below.
//!
//! What counts as context is decided from the text before the cursor: `\na` is a command, `\cite{a, b` a citation,
//! `\ref{`, `\input{`, `\begin{` and so on their own kinds. Clients filter and sort by what is typed; the engine
//! returns every item of the kind.

use super::Actor;
use anyhow::anyhow;
use overleaf::Kind;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Item {
    pub label: String,
    pub kind: &'static str,
    pub detail: String,
    pub insert: String,
    /// Byte offset into `insert` where the cursor goes (inside the first `{}`), when not at its end.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<usize>,
}

/// What one doc defines and uses.
#[derive(Debug, Default, Clone)]
pub struct Syms {
    /// `(key, detail)`
    pub labels: Vec<(String, String)>,
    pub bib: Vec<(String, String)>,
    /// `\newcommand` and friends: `(name without backslash, mandatory args, detail)`.
    pub commands: Vec<(String, u8, String)>,
    /// `\newenvironment`, `\newtheorem`: `(name, detail)`.
    pub envs: Vec<(String, String)>,
    /// Every other command used, with how many `{}` groups followed its first use.
    pub used_commands: Vec<(String, u8)>,
    pub used_envs: Vec<String>,
}

#[derive(Default)]
pub struct Index {
    /// doc_id → (seq scanned at, path, what the scan found)
    docs: HashMap<String, (u64, String, Syms)>,
}

impl Index {
    /// Rescan `doc_id` if it changed since the last scan.
    pub fn update(&mut self, doc_id: &str, seq: u64, path: &str, text: &str) {
        if let Some((s, p, _)) = self.docs.get(doc_id) {
            if *s == seq && p == path {
                return;
            }
        }
        self.docs.insert(doc_id.to_string(), (seq, path.to_string(), scan(path, text)));
    }

    pub fn retain(&mut self, keep: impl Fn(&str) -> bool) {
        self.docs.retain(|id, _| keep(id));
    }

    /// Items for the cursor after `before` (the text before it, a line is enough). `upto` is the doc's text up to the
    /// cursor, used to name the environment `\end{` closes. `paths` are the project's docs and files.
    /// Returns where the replaced text starts (bytes back from the cursor), the context's name, and the items.
    pub fn items(&self, before: &str, upto: &str, paths: &[String], current: &str) -> Option<(usize, &'static str, Vec<Item>)> {
        let ctx = context(before.as_bytes())?;
        let back = before.len() - ctx.start;
        let mut docs: Vec<&(u64, String, Syms)> = self.docs.values().collect();
        docs.sort_by(|a, b| a.1.cmp(&b.1));
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        let mut push = |out: &mut Vec<Item>, it: Item| {
            if seen.insert(it.label.clone()) {
                out.push(it);
            }
        };
        let name = match ctx.kind {
            Ctx::Command => {
                for (_, path, s) in &docs {
                    for (n, args, detail) in &s.commands {
                        let _ = path;
                        push(&mut out, command_item(n, *args, detail));
                    }
                }
                for t in BUILTIN_COMMANDS {
                    push(&mut out, template_item(t));
                }
                for (_, _, s) in &docs {
                    for (n, args) in &s.used_commands {
                        push(&mut out, command_item(n, *args, ""));
                    }
                }
                "command"
            }
            Ctx::Env { end } => {
                if end {
                    if let Some(e) = open_env(upto) {
                        push(&mut out, env_item(&e, "open"));
                    }
                }
                for (_, _, s) in &docs {
                    for (n, detail) in &s.envs {
                        push(&mut out, env_item(n, detail));
                    }
                }
                for e in BUILTIN_ENVS {
                    push(&mut out, env_item(e, ""));
                }
                for (_, _, s) in &docs {
                    for e in &s.used_envs {
                        push(&mut out, env_item(e, ""));
                    }
                }
                "env"
            }
            Ctx::Cite => {
                let mut v: Vec<&(String, String)> = docs.iter().flat_map(|d| &d.2.bib).collect();
                v.sort_by(|a, b| a.0.cmp(&b.0));
                for (k, d) in v {
                    push(&mut out, Item { label: k.clone(), kind: "cite", detail: d.clone(), insert: k.clone(), cursor: None });
                }
                "cite"
            }
            Ctx::Ref => {
                let mut v: Vec<&(String, String)> = docs.iter().flat_map(|d| &d.2.labels).collect();
                v.sort_by(|a, b| a.0.cmp(&b.0));
                for (k, d) in v {
                    push(&mut out, Item { label: k.clone(), kind: "ref", detail: d.clone(), insert: k.clone(), cursor: None });
                }
                "ref"
            }
            Ctx::File(f) => {
                for p in paths {
                    if p == current {
                        continue;
                    }
                    let ext = p.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
                    let insert = match f {
                        FileKind::Tex if ext == "tex" => p[..p.len() - 4].to_string(),
                        FileKind::Bib if ext == "bib" => p[..p.len() - 4].to_string(),
                        FileKind::BibFull if ext == "bib" => p.clone(),
                        FileKind::Graphics if GRAPHICS.contains(&ext.as_str()) => p.clone(),
                        FileKind::Pdf if ext == "pdf" => p.clone(),
                        FileKind::Any => p.clone(),
                        _ => continue,
                    };
                    push(&mut out, Item { label: p.clone(), kind: "file", detail: String::new(), insert, cursor: None });
                }
                "file"
            }
        };
        Some((back, name, out))
    }
}

const GRAPHICS: &[&str] = &["pdf", "png", "jpg", "jpeg", "eps", "svg", "gif", "tif", "tiff", "bmp"];

impl Actor {
    /// `complete.items {doc_id, pos, before?}` (`docs/api.md`).
    pub(super) fn complete_cmd(&mut self, p: &Value) -> anyhow::Result<Value> {
        let doc_id = p.get("doc_id").and_then(Value::as_str).ok_or_else(|| anyhow!("missing doc_id"))?;
        let pos = p.get("pos").and_then(Value::as_u64).ok_or_else(|| anyhow!("missing pos"))? as usize;
        for (id, d) in &self.docs {
            self.complete.update(id, d.seq, &d.path, d.client.text());
        }
        let docs = &self.docs;
        self.complete.retain(|id| docs.contains_key(id));
        let d = self.docs.get(doc_id).ok_or_else(|| anyhow!("doc {doc_id} is not open"))?;
        let text = d.client.text();
        let mut at = pos.min(text.len());
        while !text.is_char_boundary(at) {
            at -= 1;
        }
        let upto = &text[..at];
        let before = match p.get("before").and_then(Value::as_str) {
            Some(b) => b,
            None => {
                let mut s = at.saturating_sub(300);
                while !text.is_char_boundary(s) {
                    s += 1;
                }
                &text[s..at]
            }
        };
        let paths: Vec<String> = [Kind::Doc, Kind::File].into_iter().flat_map(|k| self.tree.list(k)).map(|(_, p)| p).collect();
        Ok(match self.complete.items(before, upto, &paths, &d.path) {
            Some((back, ctx, items)) => {
                let from = pos.saturating_sub(back);
                json!({"from": from, "to": pos, "context": ctx, "items": items})
            }
            None => json!({"from": pos, "to": pos, "context": null, "items": []}),
        })
    }
}

// ---- context --------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
enum FileKind {
    Tex,
    Bib,
    BibFull,
    Graphics,
    Pdf,
    Any,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Ctx {
    Command,
    Env { end: bool },
    Cite,
    Ref,
    File(FileKind),
}

#[derive(Debug, PartialEq)]
struct Context {
    kind: Ctx,
    /// Byte offset in `before` where the text the item replaces starts.
    start: usize,
}

fn is_letter(c: u8) -> bool {
    c.is_ascii_alphabetic()
}

/// An odd run of backslashes ends just before `i`: the one at `i - 1` starts a command.
fn escapes(b: &[u8], i: usize) -> bool {
    let mut n = 0;
    while n < i && b[i - 1 - n] == b'\\' {
        n += 1;
    }
    n % 2 == 1
}

fn classify(name: &str) -> Option<Ctx> {
    Some(match name {
        "begin" => Ctx::Env { end: false },
        "end" => Ctx::Env { end: true },
        "input" | "include" | "subfile" | "includeonly" | "InputIfFileExists" => Ctx::File(FileKind::Tex),
        "includegraphics" | "includesvg" => Ctx::File(FileKind::Graphics),
        "bibliography" => Ctx::File(FileKind::Bib),
        "addbibresource" => Ctx::File(FileKind::BibFull),
        "includepdf" => Ctx::File(FileKind::Pdf),
        "lstinputlisting" | "verbatiminput" | "inputminted" => Ctx::File(FileKind::Any),
        "href" | "hyperref" | "url" => return None,
        n if n.to_ascii_lowercase().contains("cite") => Ctx::Cite,
        n if n.ends_with("ref") || n.ends_with("refrange") => Ctx::Ref,
        _ => return None,
    })
}

fn context(b: &[u8]) -> Option<Context> {
    let end = b.len();
    // `\name` being typed (or a lone `\`).
    let mut j = end;
    while j > 0 && is_letter(b[j - 1]) {
        j -= 1;
    }
    if j > 0 && b[j - 1] == b'\\' && escapes(b, j) {
        return Some(Context { kind: Ctx::Command, start: j - 1 });
    }
    // Inside the braces of `\name[opt]{arg, arg`.
    let mut k = end;
    let stop = end.saturating_sub(300);
    while k > stop && !matches!(b[k - 1], b'{' | b'}' | b'\\' | b'%' | b'\n') {
        k -= 1;
    }
    if k == 0 || b[k - 1] != b'{' {
        return None;
    }
    let mut p = k - 1;
    while p > 0 && b[p - 1] == b' ' {
        p -= 1;
    }
    while p > 0 && b[p - 1] == b']' {
        let mut depth = 0;
        let mut q = p;
        loop {
            if q == 0 || p - q > 200 {
                return None;
            }
            q -= 1;
            match b[q] {
                b']' => depth += 1,
                b'[' => {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                _ => {}
            }
        }
        p = q;
        while p > 0 && b[p - 1] == b' ' {
            p -= 1;
        }
    }
    if p > 0 && b[p - 1] == b'*' {
        p -= 1;
    }
    let ne = p;
    while p > 0 && is_letter(b[p - 1]) {
        p -= 1;
    }
    if p == ne || p == 0 || b[p - 1] != b'\\' || !escapes(b, p) {
        return None;
    }
    let kind = classify(std::str::from_utf8(&b[p..ne]).ok()?)?;
    let mut start = k;
    if matches!(kind, Ctx::Cite | Ctx::Ref) {
        if let Some(c) = b[k..end].iter().rposition(|&c| c == b',') {
            start = k + c + 1;
        }
        while start < end && b[start].is_ascii_whitespace() {
            start += 1;
        }
    }
    Some(Context { kind, start })
}

/// The innermost environment begun and not yet ended in `text`.
fn open_env(text: &str) -> Option<String> {
    let b = text.as_bytes();
    let mut stack: Vec<&str> = Vec::new();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' => i = skip_line(b, i),
            b'\\' => {
                let (name, e) = read_name(b, i + 1);
                i = e;
                if name == "begin" || name == "end" {
                    if let Some((arg, e)) = read_arg(text, i) {
                        i = e;
                        if name == "begin" {
                            stack.push(arg);
                        } else if let Some(at) = stack.iter().rposition(|s| *s == arg) {
                            stack.truncate(at);
                        }
                    }
                }
            }
            _ => i += 1,
        }
    }
    stack.pop().map(String::from)
}

// ---- scanning -------------------------------------------------------------------------------------------------------

fn skip_line(b: &[u8], i: usize) -> usize {
    b[i..].iter().position(|&c| c == b'\n').map_or(b.len(), |n| i + n + 1)
}

/// The command name starting at `i` (just after a backslash) and where it ends. A non-letter is a one-character name.
fn read_name(b: &[u8], i: usize) -> (&str, usize) {
    let mut e = i;
    while e < b.len() && (is_letter(b[e]) || b[e] == b'@') {
        e += 1;
    }
    if e == i {
        // `\\`, `\%`, `\{`: skip the escaped character (always ASCII when it matters).
        let e = (i + 1).min(b.len());
        return ("", e);
    }
    (std::str::from_utf8(&b[i..e]).unwrap_or(""), e)
}

fn skip_ws(b: &[u8], mut i: usize) -> usize {
    while i < b.len() && b[i].is_ascii_whitespace() {
        i += 1;
    }
    i
}

/// A `{...}` group at `i` (after spaces): its content and the index after it.
fn read_arg(text: &str, i: usize) -> Option<(&str, usize)> {
    read_group(text, i, b'{', b'}')
}

fn read_group(text: &str, i: usize, open: u8, close: u8) -> Option<(&str, usize)> {
    let b = text.as_bytes();
    let i = skip_ws(b, i);
    if i >= b.len() || b[i] != open {
        return None;
    }
    let mut depth = 0;
    let mut j = i;
    let limit = (i + 4000).min(b.len());
    while j < limit {
        match b[j] {
            b'\\' => j += 1,
            c if c == open => depth += 1,
            c if c == close => {
                depth -= 1;
                if depth == 0 {
                    return Some((&text[i + 1..j], j + 1));
                }
            }
            _ => {}
        }
        j += 1;
    }
    None
}

/// Whitespace collapsed, cut at `max` characters.
fn tidy(s: &str, max: usize) -> String {
    let mut out = String::new();
    for (n, w) in s.split_whitespace().enumerate() {
        if n > 0 {
            out.push(' ');
        }
        out.push_str(w);
    }
    if out.chars().count() > max {
        let cut: String = out.chars().take(max - 1).collect();
        return cut.trim_end().to_string() + "…";
    }
    out
}

fn env_title(env: &str) -> String {
    let base = env.trim_end_matches('*');
    let mut c = base.chars();
    match c.next() {
        Some(f) => f.to_uppercase().chain(c).collect(),
        None => String::new(),
    }
}

struct Frame<'a> {
    env: &'a str,
    caption: Option<String>,
    /// Labels declared in this frame or passed up from inner frames without a caption: (key, env declared in,
    /// section then).
    labels: Vec<(String, &'a str, String)>,
}

pub fn scan(path: &str, text: &str) -> Syms {
    if path.to_ascii_lowercase().ends_with(".bib") {
        return Syms { bib: scan_bib(text), ..Default::default() };
    }
    let b = text.as_bytes();
    let mut s = Syms::default();
    let mut used: HashSet<&str> = HashSet::new();
    let mut used_envs: HashSet<&str> = HashSet::new();
    let mut section = String::new();
    let mut stack: Vec<Frame> = Vec::new();
    let finish = |labels: Vec<(String, &str, String)>, caption: Option<(&str, &String)>, out: &mut Vec<(String, String)>| {
        for (key, env, sec) in labels {
            let detail = match caption {
                Some((cenv, c)) => format!("{}: {}", env_title(cenv), c),
                None if env.is_empty() => if sec.is_empty() { String::new() } else { format!("§ {sec}") },
                None if sec.is_empty() => env.to_string(),
                None => format!("{env} · § {sec}"),
            };
            out.push((key, detail));
        }
    };
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' => {
                i = skip_line(b, i);
                continue;
            }
            b'\\' => {}
            _ => {
                i += 1;
                continue;
            }
        }
        let (name, mut e) = read_name(b, i + 1);
        i = e;
        if name.is_empty() {
            continue;
        }
        let star = e < b.len() && b[e] == b'*';
        if star {
            e += 1;
        }
        match name {
            "part" | "chapter" | "section" | "subsection" | "subsubsection" | "paragraph" => {
                let mut j = e;
                if let Some((_, after)) = read_group(text, j, b'[', b']') {
                    j = after;
                }
                if let Some((t, after)) = read_arg(text, j) {
                    section = tidy(t, 60);
                    i = after;
                }
            }
            "begin" => {
                if let Some((env, after)) = read_arg(text, e) {
                    used_envs.insert(env);
                    stack.push(Frame { env, caption: None, labels: Vec::new() });
                    i = after;
                }
            }
            "end" => {
                if let Some((env, after)) = read_arg(text, e) {
                    i = after;
                    if let Some(at) = stack.iter().rposition(|f| f.env == env) {
                        while stack.len() > at {
                            let f = stack.pop().unwrap();
                            match &f.caption {
                                Some(c) => finish(f.labels, Some((f.env, c)), &mut s.labels),
                                None => match stack.last_mut() {
                                    Some(parent) => parent.labels.extend(f.labels),
                                    None => finish(f.labels, None, &mut s.labels),
                                },
                            }
                        }
                    }
                }
            }
            "caption" => {
                let mut j = e;
                if let Some((_, after)) = read_group(text, j, b'[', b']') {
                    j = after;
                }
                if let Some((t, after)) = read_arg(text, j) {
                    if let Some(f) = stack.last_mut() {
                        f.caption = Some(tidy(t, 70));
                    }
                    i = after;
                }
            }
            "label" => {
                if let Some((key, after)) = read_arg(text, e) {
                    i = after;
                    let env = stack.last().map_or("", |f| if f.env == "document" { "" } else { f.env });
                    let l = (key.trim().to_string(), env, section.clone());
                    match stack.last_mut() {
                        Some(f) => f.labels.push(l),
                        None => finish(vec![l], None, &mut s.labels),
                    }
                }
            }
            "bibitem" => {
                let mut j = e;
                if let Some((_, after)) = read_group(text, j, b'[', b']') {
                    j = after;
                }
                if let Some((key, after)) = read_arg(text, j) {
                    s.bib.push((key.trim().to_string(), format!("\\bibitem in {path}")));
                    i = after;
                }
            }
            "newcommand" | "renewcommand" | "providecommand" | "DeclareMathOperator" | "DeclareRobustCommand"
            | "NewDocumentCommand" | "RenewDocumentCommand" | "DeclareDocumentCommand" | "def" | "gdef" | "edef" => {
                // `{\name}` or `\name`
                let j = skip_ws(b, e);
                let (cmd, mut j) = if j < b.len() && b[j] == b'{' {
                    match read_arg(text, j) {
                        Some((inner, after)) => (inner.trim().strip_prefix('\\').map(|n| n.trim()), after),
                        None => (None, j),
                    }
                } else if j < b.len() && b[j] == b'\\' {
                    let (n, after) = read_name(b, j + 1);
                    (Some(n), after)
                } else {
                    (None, j)
                };
                let Some(cmd) = cmd.filter(|c| !c.is_empty() && c.bytes().all(|c| is_letter(c) || c == b'@')) else {
                    continue;
                };
                let mut args = 0u8;
                match name {
                    "def" | "gdef" | "edef" => {
                        while j < b.len() && b[j] != b'{' && j - i < 40 {
                            if b[j] == b'#' {
                                args += 1;
                            }
                            j += 1;
                        }
                    }
                    "NewDocumentCommand" | "RenewDocumentCommand" | "DeclareDocumentCommand" => {
                        if let Some((spec, after)) = read_arg(text, j) {
                            args = spec.bytes().filter(|&c| c == b'm').count() as u8;
                            j = after;
                        }
                    }
                    "DeclareMathOperator" => {}
                    _ => {
                        if let Some((n, after)) = read_group(text, j, b'[', b']') {
                            args = n.trim().parse().unwrap_or(0);
                            j = after;
                            if let Some((_, after)) = read_group(text, j, b'[', b']') {
                                args = args.saturating_sub(1);
                                j = after;
                            }
                        }
                    }
                }
                i = j;
                s.commands.push((cmd.to_string(), args.min(9), path.to_string()));
            }
            "newenvironment" | "renewenvironment" | "NewDocumentEnvironment" | "newtheorem" | "declaretheorem"
            | "newtcolorbox" | "newmdenv" | "lstnewenvironment" => {
                if let Some((env, after)) = read_arg(text, e) {
                    s.envs.push((env.trim().to_string(), path.to_string()));
                    i = after;
                }
            }
            _ => {
                if used.insert(name) {
                    let mut j = e;
                    let mut n = 0u8;
                    while n < 3 {
                        match read_arg(text, j) {
                            Some((_, after)) if after > j => {
                                n += 1;
                                j = after;
                            }
                            _ => break,
                        }
                    }
                    s.used_commands.push((name.to_string(), n));
                }
            }
        }
    }
    // Unclosed environments at the end (an `\input` file, or a doc being typed).
    let mut pending = Vec::new();
    while let Some(f) = stack.pop() {
        pending.extend(f.labels);
    }
    finish(pending, None, &mut s.labels);
    s.used_envs = used_envs.into_iter().map(String::from).collect();
    s.used_envs.sort();
    s
}

/// `@type{key, field = {..}, ...}` entries: `(key, detail)` with the detail as `Author et al. Year · Title`.
pub fn scan_bib(text: &str) -> Vec<(String, String)> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(at) = b[i..].iter().position(|&c| c == b'@') {
        let at = i + at;
        let mut j = at + 1;
        while j < b.len() && is_letter(b[j]) {
            j += 1;
        }
        let ty = text[at + 1..j].to_ascii_lowercase();
        j = skip_ws(b, j);
        if ty.is_empty() || j >= b.len() || !matches!(b[j], b'{' | b'(') {
            i = at + 1;
            continue;
        }
        let close = if b[j] == b'{' { b'}' } else { b')' };
        if matches!(ty.as_str(), "string" | "comment" | "preamble") {
            i = read_group(text, j, b[j], close).map_or(j + 1, |(_, after)| after);
            continue;
        }
        let ks = j + 1;
        let Some(kl) = b[ks..].iter().position(|&c| matches!(c, b',' | b'\n' | b'}' | b')')) else { break };
        let key = text[ks..ks + kl].trim().to_string();
        j = ks + kl + 1;
        let (mut title, mut author, mut year) = (String::new(), String::new(), String::new());
        // Fields until the entry's closing brace.
        loop {
            j = skip_ws(b, j);
            if j >= b.len() || b[j] == close || b[j] == b'@' {
                break;
            }
            let fs = j;
            while j < b.len() && (b[j].is_ascii_alphanumeric() || matches!(b[j], b'_' | b'-' | b':')) {
                j += 1;
            }
            let field = text[fs..j].to_ascii_lowercase();
            j = skip_ws(b, j);
            if j >= b.len() || b[j] != b'=' {
                // Not a field: skip to the next comma.
                match b[j..].iter().position(|&c| c == b',' || c == close) {
                    Some(n) if b[j + n] == b',' => j += n + 1,
                    Some(n) => j += n,
                    None => break,
                }
                continue;
            }
            j += 1;
            let mut value = String::new();
            // value: pieces joined by `#`
            loop {
                j = skip_ws(b, j);
                if j >= b.len() {
                    break;
                }
                match b[j] {
                    b'{' => match read_group(text, j, b'{', b'}') {
                        Some((v, after)) => {
                            value.push_str(v);
                            j = after;
                        }
                        None => break,
                    },
                    b'"' => {
                        let mut e = j + 1;
                        let mut depth = 0;
                        while e < b.len() && !(b[e] == b'"' && depth == 0) {
                            match b[e] {
                                b'{' => depth += 1,
                                b'}' => depth -= 1,
                                b'\\' => e += 1,
                                _ => {}
                            }
                            e += 1;
                        }
                        value.push_str(&text[j + 1..e.min(b.len())]);
                        j = e + 1;
                    }
                    _ => {
                        let e = j + b[j..].iter().position(|&c| matches!(c, b',' | b'#' | b'}' | b')' | b'\n')).unwrap_or(b.len() - j);
                        value.push_str(text[j..e].trim());
                        j = e;
                    }
                }
                j = skip_ws(b, j);
                if j < b.len() && b[j] == b'#' {
                    j += 1;
                    continue;
                }
                break;
            }
            match field.as_str() {
                "title" => title = value,
                "author" => author = value,
                "year" => year = value,
                "date" if year.is_empty() => year = value.chars().take(4).collect(),
                _ => {}
            }
            if j < b.len() && b[j] == b',' {
                j += 1;
            }
        }
        if !key.is_empty() {
            out.push((key, bib_detail(&author, &year, &title)));
        }
        i = (j + 1).min(b.len());
    }
    out
}

fn strip_braces(s: &str) -> String {
    s.chars().filter(|c| *c != '{' && *c != '}').collect()
}

fn bib_detail(author: &str, year: &str, title: &str) -> String {
    let author = strip_braces(author);
    let mut names = Vec::new();
    let mut rest = author.as_str();
    // Split on " and " (any case).
    loop {
        let lower = rest.to_ascii_lowercase();
        match lower.find(" and ") {
            Some(n) => {
                names.push(&rest[..n]);
                rest = &rest[n + 5..];
            }
            None => {
                names.push(rest);
                break;
            }
        }
    }
    let first = names.first().map(|n| n.trim()).unwrap_or("");
    let last = match first.split_once(',') {
        Some((l, _)) => l.trim(),
        None => first.split_whitespace().last().unwrap_or(""),
    };
    let mut who = last.to_string();
    if names.len() > 2 || names.iter().any(|n| n.trim() == "others") {
        who.push_str(" et al.");
    } else if names.len() == 2 {
        let second = names[1].trim();
        let l2 = match second.split_once(',') {
            Some((l, _)) => l.trim(),
            None => second.split_whitespace().last().unwrap_or(""),
        };
        who = format!("{who} & {l2}");
    }
    let year = strip_braces(year);
    let head = [who.as_str(), year.trim()].iter().filter(|s| !s.is_empty()).copied().collect::<Vec<_>>().join(" ");
    let title = tidy(&strip_braces(title), 70);
    match (head.is_empty(), title.is_empty()) {
        (false, false) => format!("{head} · {title}"),
        (true, _) => title,
        (false, true) => head,
    }
}

// ---- items ----------------------------------------------------------------------------------------------------------

fn command_item(name: &str, args: u8, detail: &str) -> Item {
    let mut insert = format!("\\{name}");
    let cursor = if args > 0 { Some(insert.len() + 1) } else { None };
    for _ in 0..args {
        insert.push_str("{}");
    }
    Item { label: format!("\\{name}"), kind: "command", detail: detail.to_string(), insert, cursor }
}

/// A built-in template such as `frac{}{}` or `includegraphics[width=\linewidth]{}`.
fn template_item(t: &str) -> Item {
    let n = t.bytes().take_while(|&c| is_letter(c)).count();
    let insert = format!("\\{t}");
    let cursor = insert.find("{}").or_else(|| insert.find("[]")).map(|c| c + 1);
    Item { label: format!("\\{}", &t[..n]), kind: "command", detail: String::new(), insert, cursor }
}

fn env_item(name: &str, detail: &str) -> Item {
    Item { label: name.to_string(), kind: "env", detail: detail.to_string(), insert: name.to_string(), cursor: None }
}

const BUILTIN_ENVS: &[&str] = &[
    "abstract", "algorithm", "algorithmic", "align", "align*", "alignat", "aligned", "appendices", "array", "bmatrix",
    "Bmatrix", "cases", "center", "description", "document", "enumerate", "eqnarray", "equation", "equation*",
    "figure", "figure*", "flalign", "flushleft", "flushright", "frame", "gather", "gather*", "itemize", "lemma",
    "lstlisting", "minipage", "minted", "multline", "multline*", "pmatrix", "proof", "quotation", "quote", "small",
    "split", "subfigure", "subequations", "table", "table*", "tabular", "tabular*", "tabularx", "thebibliography",
    "theorem", "tikzpicture", "titlepage", "verbatim", "vmatrix", "Vmatrix", "wrapfigure", "wraptable",
];

/// Common commands, as templates: the name, then `{}` per argument (the cursor goes in the first).
const BUILTIN_COMMANDS: &[&str] = &[
    // structure
    "documentclass{}", "usepackage{}", "begin{}", "end{}", "part{}", "chapter{}", "section{}", "section*{}",
    "subsection{}", "subsection*{}", "subsubsection{}", "paragraph{}", "subparagraph{}", "appendix", "title{}",
    "author{}", "date{}", "maketitle", "tableofcontents", "item", "label{}", "ref{}", "eqref{}", "pageref{}",
    "autoref{}", "cref{}", "Cref{}", "nameref{}", "cite{}", "citep{}", "citet{}", "citealp{}", "citeauthor{}",
    "citeyear{}", "parencite{}", "textcite{}", "nocite{}", "footnote{}", "footnotemark", "footnotetext{}", "caption{}",
    "centering", "includegraphics[width=\\linewidth]{}", "input{}", "include{}", "bibliography{}",
    "bibliographystyle{}", "addbibresource{}", "printbibliography", "newcommand{}{}", "renewcommand{}{}",
    "newenvironment{}{}{}", "DeclareMathOperator{}{}", "url{}", "href{}{}", "newpage", "clearpage", "pagebreak",
    "linebreak", "newline", "noindent", "indent", "vspace{}", "hspace{}", "vfill", "hfill", "smallskip", "medskip",
    "bigskip", "par", "linewidth", "textwidth", "columnwidth", "hline", "cline{}", "toprule", "midrule",
    "bottomrule", "cmidrule{}", "multicolumn{}{}{}", "multirow{}{}{}", "resizebox{}{}{}", "scalebox{}{}",
    "makebox{}", "fbox{}", "parbox{}{}", "mbox{}", "phantom{}", "today", "LaTeX", "TeX", "ldots", "dots", "cdots",
    "vdots", "ddots", "emph{}", "textbf{}", "textit{}", "texttt{}", "textsc{}", "textsf{}", "textrm{}", "textsl{}",
    "underline{}", "textsuperscript{}", "textsubscript{}", "textcolor{}{}", "color{}", "colorbox{}{}", "tiny",
    "scriptsize", "footnotesize", "small", "normalsize", "large", "Large", "LARGE", "huge", "Huge", "bfseries",
    "itshape", "ttfamily", "rmfamily", "sffamily", "normalfont", "verb", "marginpar{}", "todo{}",
    // math
    "frac{}{}", "dfrac{}{}", "tfrac{}{}", "sqrt{}", "sum", "prod", "int", "iint", "oint", "lim", "limsup", "liminf",
    "sup", "inf", "max", "min", "argmax", "argmin", "log", "ln", "exp", "sin", "cos", "tan", "det", "dim", "ker",
    "Pr", "partial", "nabla", "infty", "left", "right", "big", "Big", "bigg", "Bigg", "langle", "rangle", "lfloor",
    "rfloor", "lceil", "rceil", "mathbb{}", "mathcal{}", "mathbf{}", "mathrm{}", "mathit{}", "mathsf{}", "mathtt{}",
    "mathfrak{}", "mathscr{}", "boldsymbol{}", "bm{}", "operatorname{}", "text{}", "hat{}", "widehat{}", "tilde{}",
    "widetilde{}", "bar{}", "overline{}", "underbrace{}", "overbrace{}", "vec{}", "dot{}", "ddot{}", "binom{}{}",
    "pmod{}", "bmod", "mid", "nmid", "parallel", "perp", "cdot", "times", "div", "pm", "mp", "circ", "bullet",
    "star", "ast", "oplus", "otimes", "odot", "leq", "geq", "le", "ge", "neq", "ne", "approx", "sim", "simeq",
    "cong", "equiv", "propto", "ll", "gg", "subset", "subseteq", "supset", "supseteq", "in", "notin", "ni", "cup",
    "cap", "bigcup", "bigcap", "setminus", "emptyset", "varnothing", "forall", "exists", "nexists", "neg", "land",
    "lor", "wedge", "vee", "implies", "iff", "to", "gets", "mapsto", "rightarrow", "leftarrow", "Rightarrow",
    "Leftarrow", "leftrightarrow", "Leftrightarrow", "longrightarrow", "uparrow", "downarrow", "top", "bot",
    "vdash", "models", "quad", "qquad", "displaystyle", "textstyle", "stackrel{}{}", "overset{}{}", "underset{}{}",
    "tag{}", "notag", "nonumber", "intertext{}", "substack{}", "ell", "hbar", "Re", "Im", "aleph", "prime",
    "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta", "vartheta", "iota", "kappa",
    "lambda", "mu", "nu", "xi", "pi", "varpi", "rho", "varrho", "sigma", "varsigma", "tau", "upsilon", "phi",
    "varphi", "chi", "psi", "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi",
    "Psi", "Omega",
];

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(s: &str) -> Option<(Ctx, &str)> {
        context(s.as_bytes()).map(|c| (c.kind, &s[c.start..]))
    }

    #[test]
    fn contexts() {
        assert_eq!(ctx("see \\"), Some((Ctx::Command, "\\")));
        assert_eq!(ctx("see \\sec"), Some((Ctx::Command, "\\sec")));
        assert_eq!(ctx("line \\\\sec"), None);
        assert_eq!(ctx("as in \\cite{"), Some((Ctx::Cite, "")));
        assert_eq!(ctx("as in \\citep[p.~3]{vas"), Some((Ctx::Cite, "vas")));
        assert_eq!(ctx("as in \\cite{a, b,  ho"), Some((Ctx::Cite, "ho")));
        assert_eq!(ctx("\\Cref{fig:a,"), Some((Ctx::Ref, "")));
        assert_eq!(ctx("\\eqref{eq"), Some((Ctx::Ref, "eq")));
        assert_eq!(ctx("\\href{ht"), None);
        assert_eq!(ctx("\\includegraphics[width=0.5\\linewidth]{figures/a"), Some((Ctx::File(FileKind::Graphics), "figures/a")));
        assert_eq!(ctx("\\input{sec"), Some((Ctx::File(FileKind::Tex), "sec")));
        assert_eq!(ctx("\\begin{fig"), Some((Ctx::Env { end: false }, "fig")));
        assert_eq!(ctx("\\end{"), Some((Ctx::Env { end: true }, "")));
        assert_eq!(ctx("\\textbf{bo"), None);
        assert_eq!(ctx("\\cite{a} and {"), None);
        assert_eq!(ctx("plain text"), None);
    }

    const MAIN: &str = r"\documentclass{article}
\input{macros}
\newcommand{\R}{\mathbb{R}}
\newcommand\vect[1]{\mathbf{#1}}
\newcommand{\pair}[2][x]{(#1, #2)}
\DeclareMathOperator*{\Exp}{\mathbb{E}}
\newtheorem{claim}{Claim}
\begin{document}
\section{Intro}\label{sec:intro}
% \label{commented}
Text \cite{vaswani2017}.
\begin{figure}[t]
  \centering
  \includegraphics{figures/a.png}
  \caption{A   nice
  picture}
  \label{fig:a}
\end{figure}
\subsection{Method}
\begin{equation}
  x = y \label{eq:xy}
\end{equation}
\begin{table}
\begin{center}
\label{tab:t}
\end{center}
\caption{Results}
\end{table}
\mycustom{a}{b}
\end{document}
";

    const BIB: &str = r#"@STRING{PAMI = {IEEE PAMI}}
@inproceedings{vaswani2017,
  title = {Attention Is {All} You Need},
  author = {Vaswani, Ashish and Shazeer, Noam and Parmar, Niki},
  booktitle = PAMI,
  year = 2017,
}
@article{ho2020, author = "Jonathan Ho and Ajay Jain", title = "Denoising " # "Diffusion", year = {2020}}
@comment{ignored}
@misc{solo, author={Knuth, Donald}}
"#;

    #[test]
    fn scans_tex() {
        let s = scan("main.tex", MAIN);
        let labels: HashMap<_, _> = s.labels.iter().cloned().collect();
        assert_eq!(labels["sec:intro"], "§ Intro");
        assert_eq!(labels["fig:a"], "Figure: A nice picture");
        assert_eq!(labels["eq:xy"], "equation · § Method");
        assert_eq!(labels["tab:t"], "Table: Results");
        assert!(!labels.contains_key("commented"));
        let cmds: HashMap<_, _> = s.commands.iter().map(|(n, a, _)| (n.as_str(), *a)).collect();
        assert_eq!(cmds["R"], 0);
        assert_eq!(cmds["vect"], 1);
        assert_eq!(cmds["pair"], 1);
        assert_eq!(cmds["Exp"], 0);
        assert_eq!(s.envs, vec![("claim".to_string(), "main.tex".to_string())]);
        assert!(s.used_commands.contains(&("mycustom".to_string(), 2)));
        assert!(s.used_envs.contains(&"figure".to_string()));
    }

    #[test]
    fn scans_bib() {
        let b = scan_bib(BIB);
        assert_eq!(
            b,
            vec![
                ("vaswani2017".to_string(), "Vaswani et al. 2017 · Attention Is All You Need".to_string()),
                ("ho2020".to_string(), "Ho & Jain 2020 · Denoising Diffusion".to_string()),
                ("solo".to_string(), "Knuth".to_string()),
            ]
        );
    }

    fn index() -> Index {
        let mut ix = Index::default();
        ix.update("d1", 1, "main.tex", MAIN);
        ix.update("d2", 1, "refs.bib", BIB);
        ix
    }

    #[test]
    fn items_by_context() {
        let ix = index();
        let paths: Vec<String> = ["main.tex", "macros.tex", "refs.bib", "figures/a.png", "figures/b.pdf", "data.csv"].map(String::from).to_vec();
        let (back, c, items) = ix.items("see \\cite{a, vas", "", &paths, "main.tex").unwrap();
        assert_eq!((back, c), (3, "cite"));
        assert_eq!(items.iter().map(|i| i.label.as_str()).collect::<Vec<_>>(), ["ho2020", "solo", "vaswani2017"]);

        let (_, _, items) = ix.items("\\ref{", "", &paths, "main.tex").unwrap();
        assert_eq!(items.len(), 4);

        let (back, _, items) = ix.items("$\\ve", "", &paths, "main.tex").unwrap();
        assert_eq!(back, 3);
        let vect = items.iter().find(|i| i.label == "\\vect").unwrap();
        assert_eq!((vect.insert.as_str(), vect.cursor), ("\\vect{}", Some(6)));
        // Project definitions come before the built-ins; nothing twice.
        assert!(items.iter().position(|i| i.label == "\\R").unwrap() < items.iter().position(|i| i.label == "\\alpha").unwrap());
        assert_eq!(items.iter().filter(|i| i.label == "\\section").count(), 1);
        assert!(items.iter().any(|i| i.label == "\\mycustom" && i.insert == "\\mycustom{}{}"));
        let g = items.iter().find(|i| i.label == "\\includegraphics").unwrap();
        assert_eq!(&g.insert[g.cursor.unwrap() - 1..], "{}");

        let (_, _, items) = ix.items("\\includegraphics{", "", &paths, "main.tex").unwrap();
        assert_eq!(items.iter().map(|i| i.insert.as_str()).collect::<Vec<_>>(), ["figures/a.png", "figures/b.pdf"]);
        let (_, _, items) = ix.items("\\input{", "", &paths, "main.tex").unwrap();
        assert_eq!(items.iter().map(|i| i.insert.as_str()).collect::<Vec<_>>(), ["macros"]);
        let (_, _, items) = ix.items("\\bibliography{", "", &paths, "main.tex").unwrap();
        assert_eq!(items.iter().map(|i| i.insert.as_str()).collect::<Vec<_>>(), ["refs"]);

        let upto = "\\begin{document}\n\\begin{claim}\n\\begin{itemize}\\end{itemize}\n";
        let (_, _, items) = ix.items("\\end{", upto, &paths, "main.tex").unwrap();
        assert_eq!((items[0].label.as_str(), items[0].detail.as_str()), ("claim", "open"));
        assert!(items.iter().any(|i| i.label == "figure"));
        assert!(ix.items("plain", "", &paths, "main.tex").is_none());
    }

    #[test]
    fn rescans_only_changed_docs() {
        let mut ix = index();
        ix.update("d1", 1, "main.tex", "");
        assert!(!ix.docs["d1"].2.labels.is_empty(), "same seq: kept");
        ix.update("d1", 2, "main.tex", "\\label{new}");
        assert_eq!(ix.docs["d1"].2.labels, vec![("new".to_string(), String::new())]);
        ix.retain(|id| id == "d1");
        assert!(!ix.docs.contains_key("d2"));
    }

    /// `TAUDOT_BENCH=<copy of a project> cargo test -p engine --release bench_project -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn bench_project() {
        let dir = std::path::PathBuf::from(std::env::var("TAUDOT_BENCH").expect("TAUDOT_BENCH"));
        let mut files = Vec::new();
        let mut stack = vec![dir.clone()];
        while let Some(d) = stack.pop() {
            for e in std::fs::read_dir(d).unwrap().flatten() {
                let p = e.path();
                if p.is_dir() {
                    stack.push(p);
                } else {
                    files.push(p.strip_prefix(&dir).unwrap().to_string_lossy().to_string());
                }
            }
        }
        let docs: Vec<(String, String)> = files
            .iter()
            .filter(|f| f.ends_with(".tex") || f.ends_with(".bib"))
            .map(|f| (f.clone(), std::fs::read_to_string(dir.join(f)).unwrap()))
            .collect();
        let bytes: usize = docs.iter().map(|d| d.1.len()).sum();
        let mut ix = Index::default();
        let t = std::time::Instant::now();
        for (n, (p, text)) in docs.iter().enumerate() {
            ix.update(&n.to_string(), 0, p, text);
        }
        let cold = t.elapsed();
        let main = docs.iter().position(|d| d.0 == "main.tex").unwrap_or(0);
        let (mp, mt) = &docs[main];
        let mut worst = std::time::Duration::ZERO;
        let mut counts = Vec::new();
        for (round, before) in ["\\", "\\cite{", "\\ref{", "\\includegraphics{", "\\begin{", "\\end{"].iter().enumerate() {
            let t = std::time::Instant::now();
            // As per keystroke: the doc being typed in changed, so it is rescanned.
            ix.update(&main.to_string(), round as u64 + 1, mp, mt);
            let (_, _, items) = ix.items(before, &mt[..mt.len() / 2], &files, mp).unwrap();
            let json = serde_json::to_string(&items).unwrap();
            worst = worst.max(t.elapsed());
            counts.push(format!("{before} {} ({} KB)", items.len(), json.len() / 1024));
            for it in items.iter().take(3) {
                println!("  {before} {} | {} | {}", it.label, it.insert, it.detail);
            }
        }
        println!("{} docs, {} KB; cold index {:?}; worst call incl. rescan of {mp} {:?}", docs.len(), bytes / 1024, cold, worst);
        println!("{}", counts.join("; "));
        assert!(worst < std::time::Duration::from_millis(5));
    }
}
