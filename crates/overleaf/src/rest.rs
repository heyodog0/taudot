//! The project's file tree over REST: binary files up and down, new docs and folders, rename, move, delete.
//!
//! Routes and events are in `docs/protocol.md` ("Other socket events", "Files"). Every write sends the
//! `X-CSRF-Token` header, so [`Http::csrf`] must be set (any page fetched with [`Http::fetch_csrf`]).

use crate::{Error, Http};
use serde::Deserialize;
use serde_json::{json, Value};
use sha1::{Digest, Sha1};

/// Kinds of entity in a project's tree, as Overleaf's routes spell them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Doc,
    File,
    Folder,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Doc => "doc",
            Kind::File => "file",
            Kind::Folder => "folder",
        }
    }
}

/// What `POST /Project/:id/upload` answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Uploaded {
    pub id: String,
    /// `doc` when Overleaf took the file as editable text, else `file`.
    pub kind: Kind,
    pub hash: Option<String>,
}

/// Overleaf's file hash: the git blob SHA-1 of the bytes (observed on CE 6.3.0: `hash` in `fileRefs` and in the
/// upload answer equals `git hash-object`).
pub fn blob_hash(bytes: &[u8]) -> String {
    let mut h = Sha1::new();
    h.update(format!("blob {}\0", bytes.len()).as_bytes());
    h.update(bytes);
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

impl Http {
    fn csrf_token(&self) -> Result<&str, Error> {
        self.csrf.as_deref().ok_or_else(|| Error::Http("no CSRF token yet: fetch a page first".into()))
    }

    async fn send_json(&self, method: reqwest::Method, path: &str, body: Option<Value>) -> Result<Value, Error> {
        let mut req = self
            .client
            .request(method.clone(), self.base.join(path)?)
            .header("X-CSRF-Token", self.csrf_token()?)
            .header(reqwest::header::ACCEPT, "application/json");
        if let Some(b) = body {
            req = req.json(&b);
        }
        let resp = req.send().await?;
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(Error::Http(format!("{method} /{path}: {status} {}", text.chars().take(200).collect::<String>())));
        }
        Ok(serde_json::from_str(&text).unwrap_or(Value::Null))
    }

    /// The bytes of a binary file (`GET /Project/:id/file/:fileId`).
    pub async fn download_file(&self, project_id: &str, file_id: &str) -> Result<Vec<u8>, Error> {
        let path = format!("Project/{project_id}/file/{file_id}");
        let resp = self.client.get(self.base.join(&path)?).send().await?;
        let status = resp.status();
        if !status.is_success() {
            return Err(Error::Http(format!("GET /{path}: {status}")));
        }
        Ok(resp.bytes().await?.to_vec())
    }

    /// Upload a file into a folder (`POST /Project/:id/upload?folder_id=`, multipart field `qqfile`). An existing
    /// file of that name is replaced and gets a new ID; an existing doc has its whole content replaced, so don't
    /// upload over docs. Overleaf makes an editable text file a doc (`FileTypeManager.isEditable`).
    pub async fn upload(&self, project_id: &str, folder_id: &str, name: &str, bytes: Vec<u8>) -> Result<Uploaded, Error> {
        let len = bytes.len();
        let part = reqwest::multipart::Part::bytes(bytes).file_name(name.to_string());
        let form = reqwest::multipart::Form::new()
            .text("name", name.to_string())
            .text("type", "application/octet-stream")
            .part("qqfile", part);
        let path = format!("Project/{project_id}/upload?folder_id={folder_id}");
        let resp = self
            .client
            .post(self.base.join(&path)?)
            .header("X-CSRF-Token", self.csrf_token()?)
            .header(reqwest::header::ACCEPT, "application/json")
            .multipart(form)
            .send()
            .await?;
        let status = resp.status();
        let body: Value = resp.json().await.unwrap_or(Value::Null);
        if status.as_u16() == 413 {
            return Err(Error::Http(format!("upload {name}: {len} bytes is over the server's upload limit")));
        }
        if !status.is_success() || body.get("success") != Some(&json!(true)) {
            let why = body.get("error").and_then(Value::as_str).unwrap_or("upload failed");
            return Err(Error::Http(format!("upload {name}: {status} {why}")));
        }
        #[derive(Deserialize)]
        struct R {
            entity_id: String,
            entity_type: String,
            hash: Option<String>,
        }
        let r: R = serde_json::from_value(body)?;
        let kind = if r.entity_type == "doc" { Kind::Doc } else { Kind::File };
        Ok(Uploaded { id: r.entity_id, kind, hash: r.hash })
    }

    /// A new empty doc (`POST /project/:id/doc`). Returns its ID.
    pub async fn create_doc(&self, project_id: &str, folder_id: &str, name: &str) -> Result<String, Error> {
        let r = self
            .send_json(reqwest::Method::POST, &format!("project/{project_id}/doc"), Some(json!({"name": name, "parent_folder_id": folder_id})))
            .await?;
        id_of(&r)
    }

    /// A new folder (`POST /project/:id/folder`). Returns its ID.
    pub async fn create_folder(&self, project_id: &str, parent_id: &str, name: &str) -> Result<String, Error> {
        let r = self
            .send_json(reqwest::Method::POST, &format!("project/{project_id}/folder"), Some(json!({"name": name, "parent_folder_id": parent_id})))
            .await?;
        id_of(&r)
    }

    pub async fn rename(&self, project_id: &str, kind: Kind, id: &str, name: &str) -> Result<(), Error> {
        let path = format!("project/{project_id}/{}/{id}/rename", kind.as_str());
        self.send_json(reqwest::Method::POST, &path, Some(json!({"name": name}))).await.map(|_| ())
    }

    pub async fn move_to(&self, project_id: &str, kind: Kind, id: &str, folder_id: &str) -> Result<(), Error> {
        let path = format!("project/{project_id}/{}/{id}/move", kind.as_str());
        self.send_json(reqwest::Method::POST, &path, Some(json!({"folder_id": folder_id}))).await.map(|_| ())
    }

    pub async fn delete(&self, project_id: &str, kind: Kind, id: &str) -> Result<(), Error> {
        let path = format!("project/{project_id}/{}/{id}", kind.as_str());
        self.send_json(reqwest::Method::DELETE, &path, None).await.map(|_| ())
    }

    /// Whether the session is still logged in: `GET /user/settings` lands on the login page when it isn't. Also
    /// keeps a rolling session alive (`docs/protocol.md`, Session expiry).
    pub async fn session_alive(&self) -> Result<bool, Error> {
        let resp = self.client.get(self.base.join("user/settings")?).send().await?;
        let landed = resp.url().path().to_string();
        let status = resp.status();
        if landed.ends_with("/login") || status.as_u16() == 401 || status.as_u16() == 403 {
            return Ok(false);
        }
        if !status.is_success() {
            return Err(Error::Http(format!("GET /user/settings: {status}")));
        }
        Ok(true)
    }
}

fn id_of(r: &Value) -> Result<String, Error> {
    r.get("_id").and_then(Value::as_str).map(String::from).ok_or_else(|| Error::Protocol(format!("no _id in {r}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_is_git_blob_sha1() {
        // `git hash-object` of these 13 bytes, and the hash CE 6.3.0 gave the same upload.
        let b = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 1, 2, 3, 255];
        assert_eq!(blob_hash(&b), "d360e0cdd66ed94205b794c9f50489349679cf66");
    }
}
