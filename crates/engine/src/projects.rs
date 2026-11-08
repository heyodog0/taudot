//! `projects.list`, and what `project.clone` / `project.forget` need (docs/api.md, Projects): the user's Overleaf
//! projects as the dashboard lists them, marked with the folders on this Mac that mirror them.
//!
//! The list is the dashboard's own call, `POST /api/project` (`ProjectListController.getProjectsJson` in Overleaf
//! CE: every project at once, with owner and last editor; CE doesn't paginate yet). Older servers without it get
//! `GET /user/projects`, which has only `_id`, `name` and `accessLevel` and leaves out archived and trashed ones.
//!
//! The engine remembers every folder it mirrors in `<home>/clones.json`:
//! `{"clones": [{server, project_id, folder, name, last_opened}]}` (`last_opened` in ms since 1970), newest first.

use crate::login;
use crate::Login;
use anyhow::{anyhow, bail, Context};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn index_path(home: &Path) -> PathBuf {
    home.join("clones.json")
}

pub fn read_index(home: &Path) -> Vec<Value> {
    std::fs::read_to_string(index_path(home))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v["clones"].as_array().cloned())
        .unwrap_or_default()
}

/// Holds the index for a read-change-write: other threads of this engine (a mutex) and other processes on this Mac,
/// such as `taudot clone` (`flock` on `clones.lock`).
struct IndexLock {
    _guard: std::sync::MutexGuard<'static, ()>,
    _file: Option<std::fs::File>,
}

fn lock_index(home: &Path) -> IndexLock {
    static M: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let guard = M.lock().unwrap_or_else(|e| e.into_inner());
    extern "C" {
        fn flock(fd: i32, op: i32) -> i32;
    }
    let file = std::fs::OpenOptions::new().create(true).append(true).open(home.join("clones.lock")).ok();
    if let Some(f) = &file {
        use std::os::fd::AsRawFd;
        // LOCK_EX; released when the file closes
        unsafe { flock(f.as_raw_fd(), 2) };
    }
    IndexLock { _guard: guard, _file: file }
}

fn write_index(home: &Path, clones: &[Value]) -> anyhow::Result<()> {
    let tmp = home.join(format!("clones.json.tmp{}", std::process::id()));
    std::fs::write(&tmp, serde_json::to_string_pretty(&json!({"clones": clones}))? + "\n")?;
    std::fs::rename(&tmp, index_path(home))?;
    Ok(())
}

/// Note that `folder` mirrors `project_id` on `server`, opened now.
pub fn remember(home: &Path, server: &str, project_id: &str, folder: &Path, name: &str) -> anyhow::Result<()> {
    let _lock = lock_index(home);
    let folder = folder.display().to_string();
    let mut clones = read_index(home);
    clones.retain(|c| c["folder"].as_str() != Some(folder.as_str()));
    clones.insert(0, json!({"server": server, "project_id": project_id, "folder": folder, "name": name, "last_opened": now_ms()}));
    write_index(home, &clones)
}

/// Drop `folder` (or, without one, every folder of the project) from the index.
pub fn forget(home: &Path, server: &str, project_id: &str, folder: Option<&Path>) -> anyhow::Result<()> {
    let _lock = lock_index(home);
    let mut clones = read_index(home);
    let n = clones.len();
    clones.retain(|c| match folder {
        Some(f) => c["folder"].as_str() != Some(&*f.display().to_string()),
        None => !(c["project_id"] == project_id && c["server"] == server),
    });
    if clones.len() != n {
        write_index(home, &clones)?;
    }
    Ok(())
}

/// The project a folder's `.taudot.json` names: `(server or None, project_id)`.
pub fn folder_project(folder: &Path) -> Option<(Option<String>, String)> {
    let raw = std::fs::read_to_string(crate::compat::project_file(folder)).ok()?;
    let v: Value = serde_json::from_str(&raw).ok()?;
    let project = v.get("project")?.as_str()?;
    if !project.contains('/') {
        return Some((None, project.to_string()));
    }
    let id = project.split('/').skip_while(|s| *s != "project").nth(1)?;
    let id = id.split(['?', '#']).next()?.to_string();
    Some((login::origin(project).ok(), id))
}

/// Folders on this Mac that mirror projects of `server`: `project_id -> (folder, last_opened)`, from the index and
/// from the `.taudot.json` of each folder directly inside `scan`. A folder that no longer names its project is left
/// out. A folder whose `.taudot.json` names only an ID counts for the engine's own server (`own_server`).
pub fn local_folders(home: &Path, server: &str, own_server: &str, scan: &[PathBuf]) -> std::collections::HashMap<String, (String, Option<u64>)> {
    let mut out: std::collections::HashMap<String, (String, Option<u64>)> = Default::default();
    let ours = |f: &Path, pid: &str| match folder_project(f) {
        Some((srv, id)) => id == pid && srv.as_deref().unwrap_or(own_server) == server,
        None => false,
    };
    for c in read_index(home) {
        let (Some(pid), Some(f)) = (c["project_id"].as_str(), c["folder"].as_str()) else { continue };
        if c["server"].as_str() != Some(server) || out.contains_key(pid) || !ours(Path::new(f), pid) {
            continue;
        }
        out.insert(pid.to_string(), (f.to_string(), c["last_opened"].as_u64()));
    }
    for dir in scan {
        let Ok(rd) = std::fs::read_dir(dir) else { continue };
        for e in rd.flatten() {
            let f = e.path().canonicalize().unwrap_or(e.path());
            if let Some((srv, id)) = folder_project(&f) {
                if srv.as_deref().unwrap_or(own_server) == server && !out.contains_key(&id) {
                    out.insert(id, (f.display().to_string(), None));
                }
            }
        }
    }
    out
}

/// `{id, name, email}` from the dashboard's `UserRef` (`{id, email, firstName, lastName}`).
fn user_ref(u: &Value) -> Value {
    if !u.is_object() {
        return Value::Null;
    }
    let s = |k: &str| u.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let email = s("email");
    let name = format!("{} {}", s("firstName"), s("lastName")).trim().to_string();
    let name = if name.is_empty() { email.split('@').next().unwrap_or("").to_string() } else { name };
    json!({"id": s("id"), "name": name, "email": email})
}

/// One project from `POST /api/project`, in the API's shape.
pub fn project_json(p: &Value) -> Value {
    json!({
        "id": p.get("id").or(p.get("_id")).cloned().unwrap_or(Value::Null),
        "name": p["name"],
        "owner": user_ref(&p["owner"]),
        "last_updated": p.get("lastUpdated").cloned().unwrap_or(Value::Null),
        "last_updated_by": user_ref(&p["lastUpdatedBy"]),
        "access_level": p.get("accessLevel").cloned().unwrap_or(Value::Null),
        "source": p.get("source").cloned().unwrap_or(Value::Null),
        "archived": p["archived"].as_bool().unwrap_or(false),
        "trashed": p["trashed"].as_bool().unwrap_or(false),
    })
}

/// The projects the logged-in user can see on `server`, as the dashboard lists them.
async fn fetch(http: &mut overleaf::Http) -> anyhow::Result<(Vec<Value>, &'static str)> {
    login::whoami_http(http).await?;
    let csrf = match http.csrf.clone() {
        Some(c) => c,
        None => http.fetch_csrf("project").await?,
    };
    let resp = http
        .client
        .post(http.base.join("api/project")?)
        .header("accept", "application/json")
        .header("x-csrf-token", csrf)
        .json(&json!({}))
        .send()
        .await?;
    let status = resp.status();
    if status.is_success() {
        let v: Value = resp.json().await.context("POST /api/project: not JSON")?;
        let list = v["projects"].as_array().ok_or_else(|| anyhow!("POST /api/project: no projects in the answer"))?;
        return Ok((list.iter().map(project_json).collect(), "api/project"));
    }
    if status.as_u16() != 404 && status.as_u16() != 405 {
        bail!("POST /api/project: {status}");
    }
    let list = http.projects().await?;
    let out = list
        .iter()
        .map(|p| {
            let mut v = serde_json::Map::from_iter(p.rest.clone());
            v.insert("id".into(), json!(p.id));
            v.insert("name".into(), json!(p.name));
            project_json(&Value::Object(v))
        })
        .collect();
    Ok((out, "user/projects"))
}

/// `projects.list {url?, scan?}` → `{server, projects: [...], from}`.
pub async fn list(engine: &Login, home: &Path, p: &Value) -> anyhow::Result<Value> {
    let server = crate::account::server(p)?;
    let login = crate::account::login_for(engine, Some(&server))?;
    let mut http = login.http().await?;
    let (mut projects, from) = fetch(&mut http).await?;
    let scan: Vec<PathBuf> = p["scan"].as_array().into_iter().flatten().filter_map(Value::as_str).map(expand).collect();
    let own = login::origin(&engine.url).unwrap_or_default();
    let local = local_folders(home, &server, &own, &scan);
    for pr in &mut projects {
        if let Some((f, opened)) = pr["id"].as_str().and_then(|id| local.get(id)) {
            pr["local_folder"] = json!(f);
            if let Some(t) = opened {
                pr["last_opened"] = json!(t);
            }
        }
    }
    Ok(json!({"server": server, "projects": projects, "from": from}))
}

/// `project.create {url?, name, template?: "blank"|"example"}` → `{project_id, name, server}`: a new project on
/// the server, as the dashboard's New Project does (`POST /project/new {projectName, template}`,
/// `ProjectController.newProject`; any template other than `example` makes the basic one-file project).
pub async fn create(engine: &Login, p: &Value) -> anyhow::Result<Value> {
    let server = crate::account::server(p)?;
    let name = p["name"].as_str().map(str::trim).unwrap_or("");
    if name.is_empty() {
        bail!("a new project needs a name");
    }
    let template = match p["template"].as_str().unwrap_or("blank") {
        "blank" => "none",
        "example" => "example",
        other => bail!("template must be blank or example, not {other}"),
    };
    let login = crate::account::login_for(engine, Some(&server))?;
    let mut http = login.http().await?;
    login::whoami_http(&mut http).await?;
    let csrf = match http.csrf.clone() {
        Some(c) => c,
        None => http.fetch_csrf("project").await?,
    };
    let resp = http
        .client
        .post(http.base.join("project/new")?)
        .header("accept", "application/json")
        .header("x-csrf-token", csrf)
        .json(&json!({"projectName": name, "template": template}))
        .send()
        .await?;
    let status = resp.status();
    if !status.is_success() {
        bail!("POST /project/new: {status}: {}", resp.text().await.unwrap_or_default().chars().take(200).collect::<String>());
    }
    let v: Value = resp.json().await.context("POST /project/new: not JSON")?;
    let id = v["project_id"].as_str().ok_or_else(|| anyhow!("POST /project/new: no project_id in {v}"))?;
    Ok(json!({"project_id": id, "name": name, "server": server}))
}

/// `~/x` → `$HOME/x`.
pub fn expand(p: &str) -> PathBuf {
    match p.strip_prefix("~/") {
        Some(rest) => PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(rest),
        None => PathBuf::from(p),
    }
}

/// Before a clone: make `folder` and name the project in its `.taudot.json`. Returns whether the folder was made
/// here (so a failed clone can take it away again). A folder that already names this project is fine as it is; one
/// with other files needs `force`.
pub fn prepare_clone(folder: &Path, server: &str, project_id: &str, force: bool) -> anyhow::Result<bool> {
    if let Some((srv, id)) = folder_project(folder) {
        if id == project_id && srv.as_deref().is_none_or(|s| s == server) {
            return Ok(false);
        }
        bail!("{} already mirrors another project ({id})", folder.display());
    }
    let existed = folder.exists();
    if existed && !folder.is_dir() {
        bail!("{} is a file", folder.display());
    }
    if existed && std::fs::read_dir(folder)?.flatten().any(|e| e.file_name() != ".DS_Store") && !force {
        bail!("{} exists and isn't empty", folder.display());
    }
    std::fs::create_dir_all(folder).with_context(|| format!("creating {}", folder.display()))?;
    let url = format!("{server}/project/{project_id}");
    std::fs::write(folder.join(".taudot.json"), serde_json::to_string_pretty(&json!({"project": url}))? + "\n")?;
    Ok(!existed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dashboard_project_shape() {
        let p = json!({"id": "p1", "name": "Paper", "archived": false, "trashed": true, "accessLevel": "readWrite",
            "source": "invite", "lastUpdated": "2026-11-01T10:00:00.000Z",
            "lastUpdatedBy": {"id": "u2", "email": "bob@x", "firstName": "Bob", "lastName": "B"},
            "owner": {"id": "u1", "email": "alice@x", "firstName": "", "lastName": ""}});
        let v = project_json(&p);
        assert_eq!(v["owner"], json!({"id": "u1", "name": "alice", "email": "alice@x"}));
        assert_eq!(v["last_updated_by"]["name"], "Bob B");
        assert_eq!(v["access_level"], "readWrite");
        assert_eq!(v["trashed"], true);
        assert_eq!(project_json(&json!({"_id": "p2", "name": "x", "accessLevel": "owner"}))["last_updated_by"], Value::Null);
    }

    #[test]
    fn index_and_local_folders() {
        let home = std::env::temp_dir().join(format!("taudot-test-index-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let srv = "https://www.overleaf.com";
        let (a, b, scan) = (home.join("a"), home.join("b"), home.join("Overleaf"));
        assert!(prepare_clone(&a, srv, "p1", false).unwrap());
        assert!(!prepare_clone(&a, srv, "p1", false).unwrap(), "same project again is fine");
        assert!(prepare_clone(&a, srv, "p2", false).is_err(), "another project's folder");
        std::fs::create_dir_all(&b).unwrap();
        std::fs::write(b.join("x.tex"), "x").unwrap();
        assert!(prepare_clone(&b, srv, "p2", false).is_err(), "not empty");
        remember(&home, srv, "p1", &a, "A").unwrap();
        // Found by scanning: a folder made by `taudot clone` before the index existed.
        prepare_clone(&scan.join("c"), srv, "p3", false).unwrap();
        // Another server's project with the same ID isn't ours.
        prepare_clone(&scan.join("d"), "http://localhost:8800", "p4", false).unwrap();
        let l = local_folders(&home, srv, "http://localhost:8800", &[scan.clone()]);
        assert_eq!(l["p1"].0, a.display().to_string());
        assert!(l["p1"].1.is_some());
        assert_eq!(l["p3"].0, scan.join("c").canonicalize().unwrap().display().to_string());
        assert!(!l.contains_key("p4"));
        // A folder that no longer names its project drops out.
        std::fs::remove_file(a.join(".taudot.json")).unwrap();
        assert!(!local_folders(&home, srv, "", &[]).contains_key("p1"));
        forget(&home, srv, "p1", Some(&a)).unwrap();
        assert!(read_index(&home).is_empty());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn concurrent_remembers_all_land() {
        // E20: the clones index is read, changed and written back; two at once (projects opened together) lost one.
        let home = std::env::temp_dir().join(format!("taudot-clones-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let hs: Vec<_> = (0..16)
            .map(|i| {
                let home = home.clone();
                std::thread::spawn(move || remember(&home, "https://x", &format!("p{i}"), Path::new(&format!("/f/{i}")), "n"))
            })
            .collect();
        for h in hs {
            h.join().unwrap().unwrap();
        }
        assert_eq!(read_index(&home).len(), 16);
        let _ = std::fs::remove_dir_all(&home);
    }
}
