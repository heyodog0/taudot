//! Folder sync, both ways: the project's tree (docs, binary files, folders) kept in step with the local folder.
//!
//! Remote: tree events (`reciveNewDoc`, `reciveNewFile`, `reciveEntityRename`, ...) update [`Tree`] at once and
//! queue the disk work (download, rename, delete), done on the next tick. Local: a file watcher marks paths dirty;
//! once they've been quiet for [`QUIET`], [`Actor::sync_local`] compares disk with the tree. A tracked path that
//! vanished and an untracked one with the same content are a rename or move; what's left is a delete or an upload.
//! A doc's file that changed is diffed against the text last known on disk and sent as an edit made at that seq, so
//! the engine transforms it past whatever arrived since (principle 2).
//!
//! What syncs is decided as Overleaf's Git bridge would, as if every upload were a `git add`:
//! - Never, either way: hidden paths (`.taudot*`, `.git`, `.DS_Store`, `.gitignore` itself), LaTeX build outputs
//!   and editor droppings ([`ignored`]).
//! - Not uploaded when new: paths matched by the folder's `.gitignore` files (any depth, with `.git/info/exclude`),
//!   by `.taudotignore` at the top, or by `"ignore": [patterns]` in `.taudot.json` ([`Rules`]); later ones win, so
//!   `!figures/*.pdf` in `.taudotignore` re-includes what `.gitignore` leaves out.
//! - Like a file git already tracks, a path Overleaf has keeps syncing both ways whatever those files say, and
//!   Overleaf's files are always written locally: ignore rules only keep new local files off Overleaf.
//!
//! The engine's own writes need no bookkeeping: everything is compared by content, and a file that already holds
//! what the tree says is left alone.

use super::{write_atomic_bytes, Actor};
use anyhow::{anyhow, bail, Context};
use notify::{RecursiveMode, Watcher};
use ot::edit;
use overleaf::{blob_hash, Kind, TreeChange};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

/// Local changes wait this long after the last file event, so editors' save dances (write a temp file, delete,
/// rename) are over before we look.
pub(super) const QUIET: Duration = Duration::from_millis(300);
/// A doc file that shrank by more than [`SHRINK_BYTES`] (and a quarter) is sent only once it has stayed so this long.
const SHRINK_CONFIRM: Duration = Duration::from_millis(1500);
const SHRINK_BYTES: usize = 256;
/// Overleaf CE's `maxUploadSize` (`services/web/config/settings.defaults.js`). overleaf.com: unverified.
pub(super) const UPLOAD_LIMIT: u64 = 50 * 1024 * 1024;
/// Don't delete on Overleaf when at least this many tracked entities vanish at once and they are over half the
/// project: more likely a `git checkout`, an unmounted disk or a mistake than intent.
const MASS_DELETE: usize = 5;

pub(super) struct Watch {
    _watcher: notify::RecommendedWatcher,
    rx: mpsc::UnboundedReceiver<PathBuf>,
}

pub(super) fn watch(folder: &Path) -> anyhow::Result<Watch> {
    let (tx, rx) = mpsc::unbounded_channel();
    let mut w = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if let Ok(ev) = res {
            for p in ev.paths {
                let _ = tx.send(p);
            }
        }
    })?;
    w.watch(folder, RecursiveMode::Recursive)?;
    Ok(Watch { _watcher: w, rx })
}

/// The next path the watcher reports; never resolves without a watcher.
pub(super) async fn next_path(w: &mut Option<Watch>) -> Option<PathBuf> {
    match w {
        Some(w) => w.rx.recv().await,
        None => std::future::pending().await,
    }
}

/// LaTeX build outputs, editor swap and backup files, and anything hidden (`.taudot.json`, `.git`, the engine's
/// temporary files) never go to Overleaf. A PDF next to a doc of the same name is the build output.
pub(super) fn ignored(rel: &str, is_doc_stem: impl Fn(&str) -> bool) -> bool {
    const OUTPUTS: [&str; 22] = [
        "aux", "log", "out", "toc", "lof", "lot", "fls", "fdb_latexmk", "synctex", "bbl", "blg", "bcf", "nav", "snm",
        "vrb", "xdv", "dvi", "swp", "swo", "swx", "tmp", "bak",
    ];
    let name = rel.rsplit('/').next().unwrap_or(rel);
    if rel.split('/').any(|c| c.starts_with('.') || c.starts_with("_minted") || c == "__pycache__") {
        return true;
    }
    if name.ends_with('~') || name == "4913" || (name.starts_with('#') && name.ends_with('#')) || name.ends_with(".synctex.gz")
        || name.ends_with(".run.xml")
    {
        return true;
    }
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    if OUTPUTS.contains(&ext.as_str()) {
        return true;
    }
    if ext == "pdf" {
        let stem = &rel[..rel.len() - 4];
        return is_doc_stem(&format!("{stem}.tex"));
    }
    false
}

/// The folder's own ignore rules: `.gitignore` files, `.taudotignore` and `.taudot.json`'s `ignore`.
#[derive(Default)]
pub(super) struct Rules {
    /// Highest priority first; each with the folder its patterns are relative to.
    sets: Vec<(PathBuf, ignore::gitignore::Gitignore)>,
}

/// Files whose change means the rules must be read again.
pub(super) fn is_rules_file(rel: &str) -> bool {
    let name = rel.rsplit('/').next().unwrap_or(rel);
    name == ".gitignore" || crate::compat::is_project_rules(name, rel) || rel == ".git/info/exclude"
}

impl Rules {
    pub(super) fn load(folder: &Path) -> (Rules, Vec<String>) {
        let mut errors = vec![];
        let mut sets = vec![];
        fn file(dir: &Path, path: &Path, sets: &mut Vec<(PathBuf, ignore::gitignore::Gitignore)>, errors: &mut Vec<String>) {
            if !path.is_file() {
                return;
            }
            let mut b = ignore::gitignore::GitignoreBuilder::new(dir);
            if let Some(e) = b.add(path) {
                errors.push(format!("{}: {e}", path.display()));
            }
            match b.build() {
                Ok(g) if !g.is_empty() => sets.push((dir.to_path_buf(), g)),
                Ok(_) => {}
                Err(e) => errors.push(format!("{}: {e}", path.display())),
            }
        }
        // .taudot.json first (highest), then .taudotignore, then .gitignore from the deepest folder up.
        if let Ok(t) = std::fs::read_to_string(crate::compat::project_file(folder)) {
            match serde_json::from_str::<Value>(&t) {
                Ok(v) => {
                    let pats: Vec<&str> = v.get("ignore").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).collect();
                    if !pats.is_empty() {
                        let mut b = ignore::gitignore::GitignoreBuilder::new(folder);
                        for p in pats {
                            if let Err(e) = b.add_line(None, p) {
                                errors.push(format!(".taudot.json ignore {p:?}: {e}"));
                            }
                        }
                        match b.build() {
                            Ok(g) => sets.push((folder.to_path_buf(), g)),
                            Err(e) => errors.push(format!(".taudot.json ignore: {e}")),
                        }
                    }
                }
                Err(e) => errors.push(format!(".taudot.json: {e}")),
            }
        }
        // The new name's rules win over the old one's (compat.rs).
        for f in crate::compat::ignore_files(folder).iter().rev() {
            file(folder, f, &mut sets, &mut errors);
        }
        let mut dirs = vec![];
        let mut stack = vec![folder.to_path_buf()];
        while let Some(d) = stack.pop() {
            dirs.push(d.clone());
            for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
                let name = e.file_name();
                let n = name.to_string_lossy();
                if e.file_type().is_ok_and(|t| t.is_dir()) && !n.starts_with('.') && n != "node_modules" {
                    stack.push(e.path());
                }
            }
        }
        dirs.sort_by_key(|d| std::cmp::Reverse(d.components().count()));
        for d in &dirs {
            file(d, &d.join(".gitignore"), &mut sets, &mut errors);
        }
        file(folder, &folder.join(".git/info/exclude"), &mut sets, &mut errors);
        (Rules { sets }, errors)
    }

    /// True if `rel` (a file, or a folder when `is_dir`) is ignored by these rules.
    pub(super) fn ignores(&self, folder: &Path, rel: &str, is_dir: bool) -> bool {
        let abs = folder.join(rel);
        for (dir, g) in &self.sets {
            if !abs.starts_with(dir) || &abs == dir {
                continue;
            }
            match g.matched_path_or_any_parents(&abs, is_dir) {
                ignore::Match::Ignore(_) => return true,
                ignore::Match::Whitelist(_) => return false,
                ignore::Match::None => {}
            }
        }
        false
    }
}

/// Each astral character as two U+FFFD, as Overleaf's browser sends it (`docs/protocol.md`, Astral characters).
pub(super) fn bmp_only(s: &str) -> std::borrow::Cow<'_, str> {
    if s.chars().all(|c| (c as u32) < 0x10000) {
        return s.into();
    }
    s.chars().map(|c| if (c as u32) < 0x10000 { c.to_string() } else { "\u{FFFD}\u{FFFD}".into() }).collect::<String>().into()
}

fn parent_of(rel: &str) -> (&str, &str) {
    rel.rsplit_once('/').unwrap_or(("", rel))
}

/// Every path under `dir` (relative to `root`), files and folders, skipping what `skip(rel, is_dir)` says.
fn walk(root: &Path, dir: &Path, skip: &dyn Fn(&str, bool) -> bool, out: &mut Vec<String>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let Some(rel) = rel_path(root, &p) else { continue };
        let is_dir = e.file_type().is_ok_and(|t| t.is_dir());
        if skip(&rel, is_dir) {
            continue;
        }
        out.push(rel);
        if is_dir {
            walk(root, &p, skip, out);
        }
    }
}

pub(super) fn rel_path(root: &Path, p: &Path) -> Option<String> {
    let r = p.strip_prefix(root).ok()?;
    let s = r.to_str()?.trim_end_matches('/').to_string();
    (!s.is_empty()).then_some(s)
}

impl Actor {
    fn tree_lists(&self) -> (Vec<Value>, Vec<Value>) {
        let docs = self.tree.list(Kind::Doc).into_iter().map(|(id, p)| json!({"doc_id": id, "path": p})).collect();
        let files = self.tree.list(Kind::File).into_iter().map(|(id, p)| json!({"file_id": id, "path": p})).collect();
        (docs, files)
    }

    /// `{docs, files}` for `project.open`.
    pub(super) fn tree_json(&self) -> Value {
        let (docs, files) = self.tree_lists();
        json!({"docs": docs, "files": files})
    }

    /// Tell clients the tree changed: `project.tree {project_id, change, docs, files}`.
    fn tree_note(&self, change: &TreeChange, origin: &str) {
        let (docs, files) = self.tree_lists();
        let change = match change {
            TreeChange::Added { id, kind, path } => json!({"op": "added", "type": kind, "id": id, "path": path}),
            TreeChange::Moved { id, kind, from, to } => json!({"op": "moved", "type": kind, "id": id, "from": from, "path": to}),
            TreeChange::Removed { id, kind, path, .. } => json!({"op": "removed", "type": kind, "id": id, "path": path}),
        };
        self.note("project.tree", None, json!({"project_id": self.project_id, "origin": origin, "change": change, "docs": docs, "files": files}));
    }

    /// A doc that is gone from the project. Its unconfirmed edits can't be sent anywhere: the text with them is kept
    /// beside deleted files (`backup/deleted/`), and its backup is removed so it is never replayed.
    pub(super) fn forget_doc(&mut self, id: &str, why: &str) {
        let Some(d) = self.docs.remove(id) else { return };
        let _ = std::fs::remove_file(self.backup_path(id));
        let n = d.unconfirmed();
        if n == 0 {
            return;
        }
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |t| t.as_secs());
        let keep = self.home.join("backup").join("deleted").join(&self.project_id).join(format!("{}.{stamp}.unsent", d.path));
        let text = match crate::engine::write_atomic(&keep, d.client.text()) {
            Ok(()) => format!("{} was {why} with {n} unsent edit(s); your text is kept in {}", d.path, keep.display()),
            Err(e) => format!("{} was {why} with {n} unsent edit(s), which are lost: {e:#}", d.path),
        };
        self.activity(Some(id), "error", text);
    }

    /// Doc paths follow the tree.
    fn refresh_doc_paths(&mut self) {
        let paths: Vec<(String, String)> = self.docs.keys().filter_map(|id| Some((id.clone(), self.tree.path(id)?))).collect();
        for (id, p) in paths {
            self.docs.get_mut(&id).unwrap().path = p;
        }
    }

    /// A tree event from the socket. Returns false if it wasn't one.
    pub(super) fn on_tree_event(&mut self, name: &str, args: &[Value]) -> bool {
        if !matches!(name, "reciveNewDoc" | "reciveNewFile" | "reciveNewFolder" | "reciveEntityRename" | "reciveEntityMove" | "removeEntity") {
            return false;
        }
        let Some(change) = self.tree.apply_event(name, args) else { return true };
        self.take_tree_change(change);
        true
    }

    /// A remote tree change, already in `self.tree`: docs follow it, clients hear of it, the disk work is queued.
    pub(super) fn take_tree_change(&mut self, change: TreeChange) {
        match &change {
            TreeChange::Moved { .. } => self.refresh_doc_paths(),
            TreeChange::Removed { id, under, .. } => {
                for gone in std::iter::once(id).chain(under.iter().map(|(i, _, _)| i)) {
                    self.forget_doc(gone, "deleted on Overleaf");
                }
            }
            TreeChange::Added { .. } => {}
        }
        self.activity(None, "tree", describe(&change));
        self.tree_note(&change, "remote");
        self.tree_work.push_back(change);
    }

    /// Disk work for remote tree changes.
    pub(super) async fn apply_remote_tree(&mut self) {
        while let Some(change) = self.tree_work.pop_front() {
            let Some(folder) = self.folder.clone() else { continue };
            if let Err(e) = self.apply_remote_change(&folder, &change).await {
                self.activity(None, "error", format!("{}: {e:#}", describe(&change)));
            }
        }
    }

    async fn apply_remote_change(&mut self, folder: &Path, change: &TreeChange) -> anyhow::Result<()> {
        match change {
            TreeChange::Added { id, kind: Kind::Doc, path } => {
                self.open_doc(path).await?;
                self.write_doc_file(id)?;
            }
            TreeChange::Added { id, kind: Kind::File, path } => self.download(folder, id, path).await?,
            TreeChange::Added { kind: Kind::Folder, path, .. } => std::fs::create_dir_all(folder.join(path))?,
            TreeChange::Moved { from, to, .. } => {
                let (a, b) = (folder.join(from), folder.join(to));
                if a.exists() && !b.exists() {
                    if let Some(p) = b.parent() {
                        std::fs::create_dir_all(p)?;
                    }
                    std::fs::rename(&a, &b).with_context(|| format!("renaming {from} to {to}"))?;
                } else if a.is_file() && b.is_file() {
                    // The new name was written first (a mirror write after the tree changed): the old file goes, kept
                    // beside deleted files if it holds anything the new one doesn't.
                    if std::fs::read(&a)? != std::fs::read(&b)? {
                        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
                        let keep = self.home.join("backup").join("deleted").join(&self.project_id).join(format!("{from}.{stamp}"));
                        std::fs::create_dir_all(keep.parent().unwrap())?;
                        std::fs::copy(&a, &keep)?;
                        self.activity(None, "warning", format!("{from} was renamed to {to} on Overleaf; the old file differed and is kept in {}", keep.display()));
                    }
                    std::fs::remove_file(&a)?;
                }
            }
            TreeChange::Removed { path, .. } => {
                let p = folder.join(path);
                if p.exists() {
                    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
                    let keep = self.home.join("backup").join("deleted").join(&self.project_id).join(format!("{path}.{stamp}"));
                    std::fs::create_dir_all(keep.parent().unwrap())?;
                    // Keep what was on disk: it may hold changes that never reached Overleaf.
                    std::fs::rename(&p, &keep).or_else(|_| {
                        if p.is_dir() { std::fs::remove_dir_all(&p) } else { std::fs::remove_file(&p) }
                    })?;
                }
            }
        }
        Ok(())
    }

    /// Write a doc's file now and remember it as what's on disk.
    pub(super) fn write_doc_file(&mut self, id: &str) -> anyhow::Result<()> {
        let Some(folder) = self.folder.clone() else { return Ok(()) };
        let d = self.docs.get_mut(id).ok_or_else(|| anyhow!("doc {id} is not open"))?;
        super::write_atomic(&folder.join(&d.path), d.client.text())?;
        d.disk = Some((d.seq, d.client.text().to_owned()));
        d.mirror_first = None;
        Ok(())
    }

    /// Fetch a binary file unless the local copy already has its hash.
    pub(super) async fn download(&mut self, folder: &Path, id: &str, path: &str) -> anyhow::Result<()> {
        let file = folder.join(path);
        let want = self.tree.get(id).and_then(|e| e.hash.clone());
        if let (Ok(local), Some(h)) = (std::fs::read(&file), &want) {
            if &blob_hash(&local) == h {
                return Ok(());
            }
        }
        let bytes = self.http.download_file(&self.project_id, id).await?;
        if let Some(h) = &want {
            let got = blob_hash(&bytes);
            if &got != h {
                tracing::warn!(path, "downloaded hash {got} differs from the tree's {h}");
            }
        }
        if let Some(e) = self.tree.entities.get_mut(id) {
            e.hash = Some(blob_hash(&bytes));
        }
        write_atomic_bytes(&file, &bytes)
    }

    /// Initial mirror of binary files and folders: download what's missing or different (keeping a differing local
    /// copy in `backup/conflicts/`).
    pub(super) async fn mirror_files(&mut self, folder: &Path) -> anyhow::Result<()> {
        for (_, path) in self.tree.list(Kind::Folder) {
            std::fs::create_dir_all(folder.join(path))?;
        }
        for (id, path) in self.tree.list(Kind::File) {
            let file = folder.join(&path);
            let want = self.tree.get(&id).and_then(|e| e.hash.clone());
            if let Ok(local) = std::fs::read(&file) {
                if want.as_deref() == Some(blob_hash(&local).as_str()) {
                    continue;
                }
                let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
                let keep = self.home.join("backup").join("conflicts").join(&self.project_id).join(format!("{path}.{stamp}"));
                write_atomic_bytes(&keep, &local)?;
                self.activity(None, "conflict", format!("{path} on disk differed from Overleaf; kept it as {}", keep.display()));
            }
            if let Err(e) = self.download(folder, &id, &path).await {
                self.activity(None, "error", format!("could not download {path}: {e:#}"));
            }
        }
        Ok(())
    }

    /// Start watching, and look at everything once. Untracked files found now are uploaded only if `adopt`.
    pub(super) fn start_watch(&mut self, folder: &Path, adopt: bool) -> anyhow::Result<()> {
        self.watch = Some(watch(folder)?);
        self.load_rules(folder);
        let mut all = vec![];
        walk(folder, folder, &|p, d| self.is_ignored_as(p, d), &mut all);
        let untracked: Vec<String> = all
            .iter()
            .filter(|p| self.tree.find(p).is_none() && folder.join(p).is_file())
            .filter(|p| !self.is_ignored(p))
            .cloned()
            .collect();
        if !adopt && !untracked.is_empty() {
            self.activity(None, "untracked", format!("not on Overleaf, left alone until changed: {}", untracked.join(", ")));
            all.retain(|p| !untracked.contains(p));
        }
        self.dirty.extend(all);
        self.dirty_at = Instant::now() - QUIET;
        Ok(())
    }

    fn is_ignored(&self, rel: &str) -> bool {
        let is_dir = self.folder.as_ref().is_some_and(|f| f.join(rel).is_dir());
        self.is_ignored_as(rel, is_dir)
    }

    /// Never synced (`ignored`), or new and matched by the folder's rules. Paths Overleaf has always sync.
    fn is_ignored_as(&self, rel: &str, is_dir: bool) -> bool {
        if ignored(rel, |doc| self.tree.find(doc).is_some_and(|id| self.tree.get(&id).is_some_and(|e| e.kind == Kind::Doc))) {
            return true;
        }
        match &self.folder {
            Some(f) => self.tree.find(rel).is_none() && self.rules.ignores(f, rel, is_dir),
            None => false,
        }
    }

    /// Read the ignore rules again. Paths they no longer ignore are looked at, so a file let in is uploaded.
    fn load_rules(&mut self, folder: &Path) {
        let (rules, errors) = Rules::load(folder);
        for e in errors {
            self.activity(None, "warning", format!("ignore rules: {e}"));
        }
        let old = std::mem::replace(&mut self.rules, rules);
        if old.sets.is_empty() {
            return;
        }
        let mut let_in = vec![];
        let skip = |p: &str, d: bool| ignored(p, |_| false) || (self.tree.find(p).is_none() && self.rules.ignores(folder, p, d));
        walk(folder, folder, &skip, &mut let_in);
        let_in.retain(|p| self.tree.find(p).is_none() && old.ignores(folder, p, folder.join(p).is_dir()));
        if !let_in.is_empty() {
            self.dirty.extend(let_in);
            self.dirty_at = Instant::now();
        }
    }

    /// A path the watcher reported.
    pub(super) fn on_path(&mut self, p: PathBuf) {
        let Some(folder) = &self.folder else { return };
        let rel = rel_path(folder, &p).or_else(|| rel_path(folder, &p.canonicalize().ok()?));
        if let Some(rel) = rel {
            if is_rules_file(&rel) {
                let folder = folder.clone();
                self.load_rules(&folder);
                return;
            }
            if !self.is_ignored(&rel) {
                self.dirty.insert(rel);
                self.dirty_at = Instant::now();
            }
        }
    }

    /// Bring local changes to Overleaf once the dirty paths have been quiet for [`QUIET`].
    pub(super) async fn sync_local(&mut self) {
        if self.dirty.is_empty() || self.dirty_at.elapsed() < QUIET || self.conn.is_none() || !self.tree_work.is_empty() {
            return;
        }
        let Some(folder) = self.folder.clone() else { return };
        if !folder.is_dir() {
            self.activity(None, "error", format!("{} is gone; not syncing deletes", folder.display()));
            self.dirty.clear();
            return;
        }
        let dirty = std::mem::take(&mut self.dirty);
        if let Err(e) = self.reconcile(&folder, dirty).await {
            self.activity(None, "error", format!("syncing local changes: {e:#}"));
        }
    }

    async fn reconcile(&mut self, folder: &Path, dirty: BTreeSet<String>) -> anyhow::Result<()> {
        // Expand folders that exist into everything under them.
        let mut paths: BTreeSet<String> = BTreeSet::new();
        for rel in dirty {
            let abs = folder.join(&rel);
            if abs.is_dir() {
                let mut v = vec![];
                walk(folder, &abs, &|p, d| self.is_ignored_as(p, d), &mut v);
                paths.extend(v);
            }
            paths.insert(rel);
        }
        let mut gone: Vec<(String, Kind, String)> = vec![];
        let mut new_files: Vec<String> = vec![];
        let mut new_dirs: Vec<String> = vec![];
        let mut changed: Vec<(String, Kind)> = vec![];
        for rel in &paths {
            if self.is_ignored(rel) {
                continue;
            }
            let meta = std::fs::symlink_metadata(folder.join(rel)).ok();
            let exists_as = meta.as_ref().map(|m| if m.is_dir() { Kind::Folder } else { Kind::File });
            match self.tree.find(rel) {
                Some(id) => {
                    let kind = self.tree.get(&id).unwrap().kind;
                    match (kind, exists_as) {
                        (Kind::Folder, Some(Kind::Folder)) => {}
                        (Kind::Doc | Kind::File, Some(Kind::File)) => changed.push((id, kind)),
                        (_, None) => gone.push((id, kind, rel.clone())),
                        (_, Some(_)) => self.activity(None, "error", format!("{rel} changed between file and folder; not syncing it")),
                    }
                }
                None => match exists_as {
                    Some(Kind::Folder) => new_dirs.push(rel.clone()),
                    Some(_) if meta.as_ref().is_some_and(|m| m.is_file()) => new_files.push(rel.clone()),
                    _ => {}
                },
            }
        }
        // Inside a vanished folder, only the folder counts.
        let gone_dirs: Vec<String> = gone.iter().filter(|g| g.1 == Kind::Folder).map(|g| g.2.clone()).collect();
        gone.retain(|(_, _, p)| !gone_dirs.iter().any(|d| p.starts_with(&format!("{d}/"))));

        // Renames and moves: a vanished entity and a new path with the same content.
        let mut moves: Vec<(String, Kind, String)> = vec![];
        let mut unmatched = vec![];
        for (id, kind, rel) in gone {
            let found = match kind {
                Kind::Folder => {
                    let names: Vec<String> = self
                        .tree
                        .under(&id)
                        .into_iter()
                        .filter(|(_, k, _)| *k != Kind::Folder)
                        .map(|(_, _, p)| p[rel.len() + 1..].to_string())
                        .collect();
                    new_dirs
                        .iter()
                        .find(|d| !names.is_empty() && names.iter().all(|n| folder.join(d).join(n).is_file()))
                        .cloned()
                }
                Kind::Doc => {
                    let d = self.docs.get(&id);
                    let texts: Vec<String> = d.map(|d| d.client.text().to_owned()).into_iter().chain(d.and_then(|d| d.disk.as_ref().map(|x| x.1.clone()))).collect();
                    new_files.iter().find(|f| std::fs::read_to_string(folder.join(f)).is_ok_and(|t| texts.contains(&t))).cloned()
                }
                Kind::File => {
                    let h = self.tree.get(&id).and_then(|e| e.hash.clone());
                    new_files.iter().find(|f| std::fs::read(folder.join(f)).is_ok_and(|b| Some(blob_hash(&b)) == h)).cloned()
                }
            };
            match found {
                Some(to) => {
                    if kind == Kind::Folder {
                        new_files.retain(|f| !f.starts_with(&format!("{to}/")));
                        new_dirs.retain(|d| d != &to && !d.starts_with(&format!("{to}/")));
                    } else {
                        new_files.retain(|f| f != &to);
                    }
                    moves.push((id, kind, to));
                }
                None => unmatched.push((id, kind, rel)),
            }
        }
        for (id, kind, to) in moves {
            self.move_remote(&id, kind, &to).await?;
        }

        // Deletes, unless it looks like a mass disappearance.
        let total = self.tree.entities.len().saturating_sub(1);
        let n_gone: usize = unmatched.iter().map(|(id, k, _)| if *k == Kind::Folder { 1 + self.tree.under(id).len() } else { 1 }).sum();
        if n_gone >= MASS_DELETE && n_gone * 2 > total {
            let list: Vec<&str> = unmatched.iter().map(|g| g.2.as_str()).collect();
            self.activity(None, "error", format!("{n_gone} of {total} files vanished at once; not deleting them on Overleaf: {}", list.join(", ")));
        } else {
            for (id, kind, rel) in unmatched {
                if folder.join(&rel).exists() {
                    continue;
                }
                self.http.delete(&self.project_id, kind, &id).await.with_context(|| format!("deleting {rel} on Overleaf"))?;
                if let Some(ch) = self.tree.remove(&id) {
                    if let TreeChange::Removed { under, .. } = &ch {
                        for (u, _, _) in under {
                            self.forget_doc(u, "deleted here");
                        }
                    }
                    self.forget_doc(&id, "deleted here");
                    self.activity(None, "tree", format!("deleted {rel} on Overleaf"));
                    self.tree_note(&ch, "local");
                }
            }
        }

        // New folders (empty ones too) and files.
        for d in new_dirs {
            self.ensure_folder(&d).await?;
        }
        for f in new_files {
            if let Err(e) = self.upload(folder, &f).await {
                self.activity(None, "error", format!("could not upload {f}: {e:#}"));
            }
        }

        // Changed content.
        for (id, kind) in changed {
            match kind {
                Kind::Doc => self.disk_changed(&id),
                _ => {
                    let Some(rel) = self.tree.path(&id) else { continue };
                    let bytes = std::fs::read(folder.join(&rel))?;
                    if self.tree.get(&id).and_then(|e| e.hash.as_deref()) != Some(blob_hash(&bytes).as_str()) {
                        if let Err(e) = self.upload(folder, &rel).await {
                            self.activity(None, "error", format!("could not upload {rel}: {e:#}"));
                        }
                    }
                }
            }
        }
        Ok(())
    }

    /// The folder at `rel`, made on Overleaf (with its parents) if needed. Returns its ID.
    async fn ensure_folder(&mut self, rel: &str) -> anyhow::Result<String> {
        let mut cur = self.tree.root.clone();
        let mut path = String::new();
        for part in rel.split('/').filter(|p| !p.is_empty()) {
            path = if path.is_empty() { part.to_string() } else { format!("{path}/{part}") };
            cur = match self.tree.find(&path) {
                Some(id) => id,
                None => {
                    let id = self.http.create_folder(&self.project_id, &cur, part).await.with_context(|| format!("creating folder {path}"))?;
                    self.tree.insert(&id, Kind::Folder, &cur, part, None);
                    let ch = TreeChange::Added { id: id.clone(), kind: Kind::Folder, path: path.clone() };
                    self.activity(None, "tree", format!("created folder {path} on Overleaf"));
                    self.tree_note(&ch, "local");
                    id
                }
            };
        }
        Ok(cur)
    }

    /// Move and/or rename an entity on Overleaf so it sits at `to`.
    async fn move_remote(&mut self, id: &str, kind: Kind, to: &str) -> anyhow::Result<()> {
        let from = self.tree.path(id).unwrap_or_default();
        let (dir, name) = parent_of(to);
        let folder_id = self.ensure_folder(dir).await?;
        let e = self.tree.get(id).ok_or_else(|| anyhow!("{from} left the tree"))?.clone();
        if e.parent.as_deref() != Some(folder_id.as_str()) {
            self.http.move_to(&self.project_id, kind, id, &folder_id).await.with_context(|| format!("moving {from} to {dir}/"))?;
            self.tree.apply_event("reciveEntityMove", &[json!(id), json!(folder_id)]);
        }
        if e.name != name {
            self.http.rename(&self.project_id, kind, id, name).await.with_context(|| format!("renaming {from} to {name}"))?;
            self.tree.apply_event("reciveEntityRename", &[json!(id), json!(name)]);
        }
        self.refresh_doc_paths();
        let ch = TreeChange::Moved { id: id.to_string(), kind, from: from.clone(), to: to.to_string() };
        self.activity(None, "tree", format!("moved {from} to {to} on Overleaf"));
        self.tree_note(&ch, "local");
        Ok(())
    }

    /// Upload a new or changed local file. Overleaf decides whether text becomes a doc; we never upload over a doc.
    async fn upload(&mut self, folder: &Path, rel: &str) -> anyhow::Result<()> {
        let abs = folder.join(rel);
        let size = std::fs::metadata(&abs)?.len();
        if size > UPLOAD_LIMIT {
            bail!("{} MB is over Overleaf's upload limit of {} MB", size / (1 << 20), UPLOAD_LIMIT / (1 << 20));
        }
        let bytes = std::fs::read(&abs)?;
        if let Ok(t) = std::str::from_utf8(&bytes) {
            if rel.ends_with(".tex") && t.chars().any(|c| (c as u32) >= 0x10000) {
                self.activity(None, "warning", format!("{rel} has characters outside the BMP (emoji?); Overleaf will store it as a binary file, not an editable doc"));
            }
        }
        let (dir, name) = parent_of(rel);
        let folder_id = self.ensure_folder(dir).await?;
        let old = self.tree.find(rel);
        let up = self.http.upload(&self.project_id, &folder_id, name, bytes.clone()).await?;
        if let Some(old) = old.filter(|o| *o != up.id) {
            // A replaced file gets a new ID; the server's removeEntity for the old one then changes nothing.
            self.tree.remove(&old);
        }
        let hash = (up.kind == Kind::File).then(|| up.hash.clone().unwrap_or_else(|| blob_hash(&bytes)));
        self.tree.insert(&up.id, up.kind, &folder_id, name, hash);
        let ch = TreeChange::Added { id: up.id.clone(), kind: up.kind, path: rel.to_string() };
        self.activity(None, "tree", format!("uploaded {rel} ({} bytes) as a {}", bytes.len(), up.kind.as_str()));
        self.tree_note(&ch, "local");
        if up.kind == Kind::Doc {
            self.open_doc(rel).await?;
            let d = self.docs.get_mut(&up.id).unwrap();
            if d.client.text().as_bytes() == bytes.as_slice() {
                d.disk = Some((d.seq, d.client.text().to_owned()));
            } else {
                // Overleaf normalised it (line endings, encoding): write back what it holds.
                self.write_doc_file(&up.id)?;
            }
        }
        Ok(())
    }

    /// A doc's file changed on disk. Send the difference from the text last known on disk as an edit made at that
    /// seq. A file that holds the doc's text at some recent seq (our own write, or an attached editor saving) is not
    /// an edit.
    pub(super) fn disk_changed(&mut self, id: &str) {
        let Some(folder) = self.folder.clone() else { return };
        let Some(d) = self.docs.get(id) else { return };
        let path = d.path.clone();
        let raw = match std::fs::read(folder.join(&path)) {
            Ok(b) => b,
            Err(_) => return,
        };
        let Ok(text) = String::from_utf8(raw) else {
            self.activity(Some(id), "error", format!("{path} is not UTF-8 any more; not sending it"));
            return;
        };
        if text == d.client.text() {
            self.docs.get_mut(id).unwrap().disk = Some((d.seq, text));
            return;
        }
        let (base_seq, base_text) = d.disk.clone().unwrap_or_else(|| (d.seq, d.client.text().to_owned()));
        if text == base_text {
            return;
        }
        // Walk back from the current text: does the file hold the doc at some seq since the base?
        let mut t = d.client.text().to_owned();
        let mut held_at = None;
        for c in d.log.iter().rev().take_while(|c| c.seq > base_seq) {
            match ot::text::apply(&t, &ot::text::invert(&c.op)) {
                Ok(prev) => t = prev,
                Err(_) => break,
            }
            if t == text {
                held_at = Some(c.seq - 1);
                break;
            }
        }
        if let Some(seq) = held_at {
            let d = self.docs.get_mut(id).unwrap();
            d.disk = Some((seq, text));
            d.mirror_first.get_or_insert(Instant::now());
            return;
        }
        // A file that lost much of its text may be half written (a slow or non-atomic writer): send that only once it
        // has stayed so for [`SHRINK_CONFIRM`].
        let shrunk = base_text.len().saturating_sub(text.len());
        if shrunk > SHRINK_BYTES && text.len() < base_text.len() * 3 / 4 {
            let d = self.docs.get_mut(id).unwrap();
            let since = match &d.shrink_seen {
                Some((t, at)) if *t == text => *at,
                _ => {
                    d.shrink_seen = Some((text.clone(), Instant::now()));
                    Instant::now()
                }
            };
            if since.elapsed() < SHRINK_CONFIRM {
                self.dirty.insert(path.clone());
                self.dirty_at = Instant::now();
                return;
            }
        }
        let d = self.docs.get_mut(id).unwrap();
        d.shrink_seen = None;
        if let Some(why) = d.readonly.clone() {
            self.activity(Some(id), "error", format!("{path} changed on disk but the doc is read-only ({why}); not sent"));
            return;
        }
        let new = bmp_only(&text).into_owned();
        if new != text {
            self.activity(Some(id), "warning", format!("{path}: characters outside the BMP sent as U+FFFD, as Overleaf's editor does"));
        }
        let op = ot::diff::diff(&base_text, &new);
        let edits = match edit::from_classic(&base_text, &op) {
            Ok(e) => e,
            Err(e) => {
                self.activity(Some(id), "error", format!("{path}: could not diff the file: {e}"));
                return;
            }
        };
        self.edit_source = Some("disk");
        let sent = self.edit(id, base_seq, edits, None, None);
        self.edit_source = None;
        match sent {
            Ok(_) => {
                let d = self.docs.get_mut(id).unwrap();
                if d.client.text() == text {
                    d.disk = Some((d.seq, text));
                } else if let Err(e) = self.write_doc_file(id) {
                    // Changes arrived meanwhile (or U+FFFD replaced something): write the merged text back.
                    self.activity(Some(id), "error", format!("could not write {path}: {e:#}"));
                }
                self.activity(Some(id), "disk", format!("sent changes to {path} made on disk"));
            }
            Err(e) => self.activity(Some(id), "error", format!("{path} changed on disk but could not be sent: {e:#}")),
        }
    }
}

fn describe(c: &TreeChange) -> String {
    match c {
        TreeChange::Added { kind, path, .. } => format!("{} {path} added on Overleaf", kind.as_str()),
        TreeChange::Moved { from, to, .. } => format!("{from} moved to {to} on Overleaf"),
        TreeChange::Removed { path, .. } => format!("{path} deleted on Overleaf"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ignore_rules() {
        let doc = |p: &str| p == "main.tex" || p == "sub/ch.tex";
        for p in ["main.aux", ".taudot.json", ".main.tex.taudot-12~", "main.tex~", "sub/.ch.tex.swp", "4913", "main.pdf",
            "sub/ch.pdf", "main.synctex.gz", ".git/HEAD", "_minted-main/x", "main.run.xml"]
        {
            assert!(ignored(p, doc), "{p} should be ignored");
        }
        for p in ["main.tex", "figs/plot.pdf", "refs.bib", "img.png", "sub/ch.tex"] {
            assert!(!ignored(p, doc), "{p} should sync");
        }
    }

    #[test]
    fn folder_rules() {
        let dir = std::env::temp_dir().join(format!("taudot-rules-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for d in ["figures", "sub", "notes", "build"] {
            std::fs::create_dir_all(dir.join(d)).unwrap();
        }
        let w = |p: &str, t: &str| std::fs::write(dir.join(p), t).unwrap();
        w(".gitignore", "*.pdf\nbuild/\n/secret.tex\n");
        w("sub/.gitignore", "!keep.pdf\ndraft-*\n");
        w(".taudotignore", "!figures/*.pdf\n*.csv\n");
        w(".taudot.json", r#"{"project": "x", "ignore": ["notes/", "!keep.csv"]}"#);
        let (r, errors) = Rules::load(&dir);
        assert!(errors.is_empty(), "{errors:?}");
        let ig = |p: &str| r.ignores(&dir, p, dir.join(p).is_dir());
        for p in ["paper.pdf", "build", "build/x.tex", "secret.tex", "sub/draft-1.tex", "data.csv", "notes", "notes/a.tex", "sub/other.pdf"] {
            assert!(ig(p), "{p} should be ignored");
        }
        for p in ["main.tex", "figures/plot.pdf", "sub/keep.pdf", "sub/secret.tex", "keep.csv", "sub/ch.tex"] {
            assert!(!ig(p), "{p} should sync");
        }
        assert!(is_rules_file("sub/.gitignore") && is_rules_file(".taudot.json") && !is_rules_file("sub/.taudot.json"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn astral_becomes_two_replacement_chars() {
        assert_eq!(bmp_only("a😀b"), "a\u{FFFD}\u{FFFD}b");
        assert_eq!(bmp_only("plain é"), "plain é");
    }
}
