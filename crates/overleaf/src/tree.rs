//! A project's file tree, kept current from the socket's tree events (`reciveNewDoc`, `reciveNewFile`,
//! `reciveNewFolder`, `reciveEntityRename`, `reciveEntityMove`, `removeEntity`; Overleaf's spelling, see
//! `docs/protocol.md`).

use crate::rest::Kind;
use serde_json::Value;
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entity {
    pub kind: Kind,
    pub name: String,
    /// The containing folder; `None` only for the root folder.
    pub parent: Option<String>,
    /// Files only: the git blob SHA-1 of the content.
    pub hash: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct Tree {
    pub root: String,
    pub entities: HashMap<String, Entity>,
}

/// What a tree event changed. Paths are relative to the project, `/`-separated, without a trailing slash.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TreeChange {
    Added { id: String, kind: Kind, path: String },
    /// A rename or a move. For a folder, everything under it moved too.
    Moved { id: String, kind: Kind, from: String, to: String },
    /// For a folder, `under` lists what was in it (also gone).
    Removed { id: String, kind: Kind, path: String, under: Vec<(String, Kind, String)> },
}

impl Tree {
    /// From `joinProjectResponse`'s `project.rootFolder`.
    pub fn from_project(project: &Value) -> Tree {
        let mut t = Tree::default();
        if let Some(root) = project.get("rootFolder").and_then(Value::as_array).and_then(|a| a.first()) {
            let id = root.get("_id").and_then(Value::as_str).unwrap_or("").to_string();
            t.root = id.clone();
            t.entities.insert(id.clone(), Entity { kind: Kind::Folder, name: String::new(), parent: None, hash: None });
            t.add_folder_contents(&id, root);
        }
        t
    }

    fn add_folder_contents(&mut self, folder_id: &str, folder: &Value) {
        for (key, kind) in [("docs", Kind::Doc), ("fileRefs", Kind::File), ("folders", Kind::Folder)] {
            for e in folder.get(key).and_then(Value::as_array).into_iter().flatten() {
                self.add_raw(folder_id, kind, e);
            }
        }
    }

    fn add_raw(&mut self, parent: &str, kind: Kind, e: &Value) -> Option<String> {
        let id = e.get("_id").and_then(Value::as_str)?.to_string();
        let name = e.get("name").and_then(Value::as_str)?.to_string();
        let hash = e.get("hash").and_then(Value::as_str).map(String::from);
        self.entities.insert(id.clone(), Entity { kind, name, parent: Some(parent.to_string()), hash });
        if kind == Kind::Folder {
            self.add_folder_contents(&id, e);
        }
        Some(id)
    }

    pub fn get(&self, id: &str) -> Option<&Entity> {
        self.entities.get(id)
    }

    /// Path of an entity; `""` for the root folder.
    pub fn path(&self, id: &str) -> Option<String> {
        let mut parts = vec![];
        let mut cur = id;
        loop {
            if parts.len() > self.entities.len() {
                return None; // a cycle (only mid-way through [`Tree::changes_to`])
            }
            let e = self.entities.get(cur)?;
            match &e.parent {
                None => break,
                Some(p) => {
                    parts.push(e.name.as_str());
                    cur = p;
                }
            }
        }
        parts.reverse();
        Some(parts.join("/"))
    }

    /// The entity at `path` (`""` is the root folder).
    pub fn find(&self, path: &str) -> Option<String> {
        let mut cur = self.root.clone();
        for part in path.split('/').filter(|p| !p.is_empty()) {
            cur = self.children(&cur).into_iter().find(|id| self.entities[id].name == part)?;
        }
        Some(cur)
    }

    pub fn children(&self, folder: &str) -> Vec<String> {
        self.entities.iter().filter(|(_, e)| e.parent.as_deref() == Some(folder)).map(|(id, _)| id.clone()).collect()
    }

    /// Everything under a folder, depth first, as `(id, kind, path)`.
    pub fn under(&self, folder: &str) -> Vec<(String, Kind, String)> {
        let mut out = vec![];
        for c in self.children(folder) {
            let e = &self.entities[&c];
            out.push((c.clone(), e.kind, self.path(&c).unwrap_or_default()));
            if e.kind == Kind::Folder {
                out.extend(self.under(&c));
            }
        }
        out
    }

    /// `(id, path)` of every entity of a kind, sorted by path.
    pub fn list(&self, kind: Kind) -> Vec<(String, String)> {
        let mut v: Vec<(String, String)> = self
            .entities
            .iter()
            .filter(|(_, e)| e.kind == kind && e.parent.is_some())
            .filter_map(|(id, _)| Some((id.clone(), self.path(id)?)))
            .collect();
        v.sort_by(|a, b| a.1.cmp(&b.1));
        v
    }

    /// Apply a socket event. `None` if it isn't a tree event, or changes nothing (an event for something we already
    /// did ourselves and recorded).
    pub fn apply_event(&mut self, name: &str, args: &[Value]) -> Option<TreeChange> {
        let s = |i: usize| args.get(i).and_then(Value::as_str);
        match name {
            "reciveNewDoc" | "reciveNewFile" | "reciveNewFolder" => {
                let kind = match name {
                    "reciveNewDoc" => Kind::Doc,
                    "reciveNewFile" => Kind::File,
                    _ => Kind::Folder,
                };
                let parent = s(0)?.to_string();
                let e = args.get(1)?;
                let id = e.get("_id").and_then(Value::as_str)?;
                if let Some(old) = self.entities.get(id) {
                    // Already known (we made it): only take a newer hash.
                    if old.kind == Kind::File {
                        let hash = e.get("hash").and_then(Value::as_str).map(String::from);
                        self.entities.get_mut(id).unwrap().hash = hash.or(old.hash.clone());
                    }
                    return None;
                }
                self.entities.get(&parent)?;
                let id = self.add_raw(&parent, kind, e)?;
                Some(TreeChange::Added { kind, path: self.path(&id)?, id })
            }
            "reciveEntityRename" => {
                let (id, name) = (s(0)?, s(1)?);
                let from = self.path(id)?;
                let e = self.entities.get_mut(id)?;
                if e.name == name {
                    return None;
                }
                e.name = name.to_string();
                let kind = e.kind;
                Some(TreeChange::Moved { id: id.to_string(), kind, from, to: self.path(id)? })
            }
            "reciveEntityMove" => {
                let (id, folder) = (s(0)?, s(1)?);
                self.entities.get(folder)?;
                let from = self.path(id)?;
                let e = self.entities.get_mut(id)?;
                if e.parent.as_deref() == Some(folder) {
                    return None;
                }
                e.parent = Some(folder.to_string());
                let kind = e.kind;
                Some(TreeChange::Moved { id: id.to_string(), kind, from, to: self.path(id)? })
            }
            "removeEntity" => {
                let id = s(0)?;
                self.remove(id)
            }
            _ => None,
        }
    }

    /// Forget an entity (and, for a folder, what's in it).
    pub fn remove(&mut self, id: &str) -> Option<TreeChange> {
        let e = self.entities.get(id)?.clone();
        e.parent.as_ref()?; // never the root
        let path = self.path(id)?;
        let under = if e.kind == Kind::Folder { self.under(id) } else { vec![] };
        for (u, _, _) in &under {
            self.entities.remove(u);
        }
        self.entities.remove(id);
        Some(TreeChange::Removed { id: id.to_string(), kind: e.kind, path, under })
    }

    /// The changes that turn this tree into `new` (a later `joinProjectResponse`'s, after missing the events between),
    /// in an order they can be applied one by one, each path as it is at that point: new folders, moves and renames,
    /// removals (after the moves, so what was moved out of a deleted folder survives), then new docs and files. A file
    /// whose content changed under the same ID isn't reported (Overleaf replaces a file with a new ID).
    pub fn changes_to(&self, new: &Tree) -> Vec<TreeChange> {
        if self.root != new.root || new.root.is_empty() {
            return vec![];
        }
        let mut t = self.clone();
        let mut out = vec![];
        let depth = |tree: &Tree, id: &str| tree.path(id).map_or(usize::MAX, |p| p.split('/').count());
        let mut added: Vec<&String> = new.entities.keys().filter(|id| !self.entities.contains_key(*id)).collect();
        added.sort_by_key(|id| (depth(new, id), (*id).clone()));
        for id in added.iter().filter(|id| new.entities[**id].kind == Kind::Folder) {
            let e = &new.entities[*id];
            t.entities.insert((*id).clone(), e.clone());
            if let Some(path) = t.path(id) {
                out.push(TreeChange::Added { id: (*id).clone(), kind: e.kind, path });
            }
        }
        let mut moved: Vec<&String> = new
            .entities
            .iter()
            .filter(|(id, e)| e.parent.is_some() && self.entities.get(*id).is_some_and(|o| o.parent != e.parent || o.name != e.name))
            .map(|(id, _)| id)
            .collect();
        moved.sort_by_key(|id| (depth(new, id), (*id).clone()));
        for id in moved {
            let Some(from) = t.path(id) else { continue };
            let n = &new.entities[id];
            let e = t.entities.get_mut(id).unwrap();
            e.parent = n.parent.clone();
            e.name = n.name.clone();
            let kind = e.kind;
            if let Some(to) = t.path(id).filter(|to| *to != from) {
                out.push(TreeChange::Moved { id: id.clone(), kind, from, to });
            }
        }
        let mut removed: Vec<&String> = self.entities.keys().filter(|id| !new.entities.contains_key(*id)).collect();
        removed.sort_by_key(|id| (depth(&t, id), (*id).clone()));
        for id in removed {
            if t.entities.contains_key(id) {
                out.extend(t.remove(id));
            }
        }
        for id in added.iter().filter(|id| new.entities[**id].kind != Kind::Folder) {
            let e = &new.entities[*id];
            t.entities.insert((*id).clone(), e.clone());
            if let Some(path) = t.path(id) {
                out.push(TreeChange::Added { id: (*id).clone(), kind: e.kind, path });
            }
        }
        out
    }

    /// Record an entity we created ourselves, before its event arrives.
    pub fn insert(&mut self, id: &str, kind: Kind, parent: &str, name: &str, hash: Option<String>) {
        self.entities.insert(id.to_string(), Entity { kind, name: name.to_string(), parent: Some(parent.to_string()), hash });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tree() -> Tree {
        Tree::from_project(&json!({"rootFolder": [{"_id": "r", "name": "rootFolder",
            "docs": [{"_id": "d1", "name": "main.tex"}],
            "fileRefs": [],
            "folders": [{"_id": "f", "name": "figs", "docs": [], "folders": [],
                "fileRefs": [{"_id": "x", "name": "dot.png", "hash": "abc"}]}]}]}))
    }

    #[test]
    fn paths_and_find() {
        let t = tree();
        assert_eq!(t.path("x").unwrap(), "figs/dot.png");
        assert_eq!(t.find("figs/dot.png").as_deref(), Some("x"));
        assert_eq!(t.find("").as_deref(), Some("r"));
        assert_eq!(t.list(Kind::Doc), vec![("d1".into(), "main.tex".into())]);
        assert_eq!(t.get("x").unwrap().hash.as_deref(), Some("abc"));
    }

    #[test]
    fn events() {
        let mut t = tree();
        let c = t.apply_event("reciveNewFile", &[json!("f"), json!({"_id": "y", "name": "b.png", "hash": "h"}), json!("upload"), json!(null), json!("u")]);
        assert_eq!(c, Some(TreeChange::Added { id: "y".into(), kind: Kind::File, path: "figs/b.png".into() }));
        // The same event again changes nothing.
        assert_eq!(t.apply_event("reciveNewFile", &[json!("f"), json!({"_id": "y", "name": "b.png"})]), None);
        let c = t.apply_event("reciveEntityRename", &[json!("f"), json!("img")]);
        assert_eq!(c, Some(TreeChange::Moved { id: "f".into(), kind: Kind::Folder, from: "figs".into(), to: "img".into() }));
        assert_eq!(t.path("y").unwrap(), "img/b.png");
        let c = t.apply_event("reciveEntityMove", &[json!("d1"), json!("f")]);
        assert_eq!(c, Some(TreeChange::Moved { id: "d1".into(), kind: Kind::Doc, from: "main.tex".into(), to: "img/main.tex".into() }));
        match t.apply_event("removeEntity", &[json!("f"), json!("editor")]) {
            Some(TreeChange::Removed { path, under, .. }) => {
                assert_eq!(path, "img");
                assert_eq!(under.len(), 3);
            }
            c => panic!("{c:?}"),
        }
        assert!(t.list(Kind::Doc).is_empty());
        assert_eq!(t.apply_event("removeEntity", &[json!("f")]), None);
    }

    #[test]
    fn changes_to_a_later_tree() {
        let old = tree();
        // Later: figs deleted, but dot.png moved out first into a new folder img/; main.tex renamed; a doc added.
        let new = Tree::from_project(&json!({"rootFolder": [{"_id": "r", "name": "rootFolder",
            "docs": [{"_id": "d1", "name": "paper.tex"}], "fileRefs": [],
            "folders": [{"_id": "g", "name": "img", "docs": [{"_id": "d2", "name": "cap.tex"}], "folders": [],
                "fileRefs": [{"_id": "x", "name": "dot.png", "hash": "abc"}]}]}]}));
        let ch = old.changes_to(&new);
        assert_eq!(ch, vec![
            TreeChange::Added { id: "g".into(), kind: Kind::Folder, path: "img".into() },
            TreeChange::Moved { id: "d1".into(), kind: Kind::Doc, from: "main.tex".into(), to: "paper.tex".into() },
            TreeChange::Moved { id: "x".into(), kind: Kind::File, from: "figs/dot.png".into(), to: "img/dot.png".into() },
            TreeChange::Removed { id: "f".into(), kind: Kind::Folder, path: "figs".into(), under: vec![] },
            TreeChange::Added { id: "d2".into(), kind: Kind::Doc, path: "img/cap.tex".into() },
        ]);
        assert!(new.changes_to(&new).is_empty());
    }
}
