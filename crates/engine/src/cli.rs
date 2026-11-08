//! The CLI side: `taudot clone`, `taudot open`, `taudot rpc`. Each talks to the running engine over its socket
//! (`docs/api.md`) and starts it first if none is running: through launchd when the service is installed, else as a
//! detached `taudot serve` logging to `<home>/logs/engine.log`.

use crate::service;
use anyhow::{anyhow, bail, Context};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

#[derive(clap::Args, Clone)]
pub struct EngineOpts {
    /// Engine home, holding `engine.sock`. Default `$TAUDOT_HOME` or `~/.taudot`.
    #[arg(long, env = "TAUDOT_HOME")]
    pub home: Option<PathBuf>,
    /// Passed to `taudot serve` when the engine has to be started: a `KEY=VALUE` credentials file (local CE only).
    #[arg(long)]
    pub env_file: Option<PathBuf>,
    /// With --env-file: which user.
    #[arg(long)]
    pub user: Option<String>,
}

#[derive(clap::Args)]
pub struct CloneArgs {
    /// The project's Overleaf URL, e.g. https://www.overleaf.com/project/<id>.
    pub url: String,
    /// Folder to create. Default: the project's name, in the current folder.
    pub folder: Option<PathBuf>,
    /// Clone into a folder that isn't empty.
    #[arg(long)]
    pub force: bool,
    #[arg(long)]
    pub json: bool,
    #[command(flatten)]
    pub engine: EngineOpts,
}

#[derive(clap::Args)]
pub struct OpenArgs {
    /// A folder made by `taudot clone` (default: the current folder).
    pub folder: Option<PathBuf>,
    /// Only make sure the engine syncs the folder; don't build the Rex layout.
    #[arg(long)]
    pub no_layout: bool,
    #[command(flatten)]
    pub engine: EngineOpts,
}

#[derive(clap::Args)]
pub struct RpcArgs {
    /// Method, e.g. `project.status`.
    pub method: String,
    /// Params as JSON.
    #[arg(default_value = "{}")]
    pub params: String,
    #[command(flatten)]
    pub engine: EngineOpts,
}

pub fn home(opt: &Option<PathBuf>) -> anyhow::Result<PathBuf> {
    match opt {
        Some(h) => Ok(h.clone()),
        None => crate::compat::default_home(),
    }
}

/// One JSON-RPC connection to the engine.
pub struct Client {
    w: tokio::net::unix::OwnedWriteHalf,
    lines: tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
    next: u64,
}

impl Client {
    pub async fn call(&mut self, method: &str, params: Value) -> anyhow::Result<Value> {
        self.next += 1;
        let id = self.next;
        let req = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.w.write_all(format!("{req}\n").as_bytes()).await?;
        loop {
            let line = self.lines.next_line().await?.ok_or_else(|| anyhow!("the engine closed the connection"))?;
            let v: Value = serde_json::from_str(&line)?;
            if v.get("id") == Some(&json!(id)) {
                if let Some(e) = v.get("error") {
                    bail!("{}", e.get("message").and_then(Value::as_str).unwrap_or(&e.to_string()));
                }
                return Ok(v["result"].clone());
            }
        }
    }
}

/// Connect to the engine, starting it if needed.
pub async fn engine(o: &EngineOpts) -> anyhow::Result<Client> {
    let home = home(&o.home)?;
    let sock = home.join("engine.sock");
    if let Ok(s) = UnixStream::connect(&sock).await {
        return Ok(client(s));
    }
    if service::installed(&home) {
        service::kickstart(&home)?;
    } else {
        std::fs::create_dir_all(home.join("logs"))?;
        let log = std::fs::OpenOptions::new().create(true).append(true).open(home.join("logs/engine.log"))?;
        let mut cmd = std::process::Command::new(std::env::current_exe()?);
        cmd.arg("serve").arg("--home").arg(&home);
        if let Some(e) = &o.env_file {
            cmd.arg("--env-file").arg(e);
        }
        if let Some(u) = &o.user {
            cmd.arg("--user").arg(u);
        }
        use std::os::unix::process::CommandExt;
        cmd.stdin(std::process::Stdio::null()).stdout(log.try_clone()?).stderr(log).process_group(0);
        cmd.spawn().context("starting taudot serve")?;
    }
    for _ in 0..100 {
        if let Ok(s) = UnixStream::connect(&sock).await {
            return Ok(client(s));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    bail!("the engine did not start; see {}", home.join("logs/engine.log").display())
}

fn client(s: UnixStream) -> Client {
    let (r, w) = s.into_split();
    Client { w, lines: BufReader::new(r).lines(), next: 0 }
}

/// A folder name from a project name: letters, digits, `-` and `_`; spaces become `-`.
fn slug(name: &str) -> String {
    let s: String = name
        .trim()
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
        .collect();
    let s = s.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-");
    if s.is_empty() { "overleaf-project".into() } else { s }
}

pub async fn clone(a: CloneArgs) -> anyhow::Result<()> {
    if !a.url.contains("/project/") {
        bail!("{} is not a project URL (…/project/<id>)", a.url);
    }
    let mut c = engine(&a.engine).await?;
    let folder = match &a.folder {
        Some(f) => f.clone(),
        None => {
            let p = c.call("project.open", json!({"url": a.url})).await?;
            std::env::current_dir()?.join(slug(p["name"].as_str().unwrap_or("")))
        }
    };
    let folder = if folder.is_absolute() { folder } else { std::env::current_dir()?.join(folder) };
    let pid = a.url.split('/').skip_while(|s| *s != "project").nth(1).unwrap_or("").split(['?', '#']).next().unwrap_or("").to_string();
    let r = c.call("project.clone", json!({"url": a.url, "project_id": pid, "folder": folder, "force": a.force})).await?;
    let folder = PathBuf::from(r["folder"].as_str().unwrap_or_default());
    if a.json {
        println!("{r}");
        return Ok(());
    }
    println!("Cloned \"{}\" into {} ({} docs, {} files). The engine keeps it in sync both ways.", r["name"].as_str().unwrap_or(""), folder.display(), r["docs"], r["files"]);
    println!("Open the editor and preview in Rex:\n  taudot open {}", shell_quote(&folder));
    Ok(())
}

fn shell_quote(p: &Path) -> String {
    let s = p.display().to_string();
    if s.chars().all(|c| c.is_alphanumeric() || "/._-~".contains(c)) { s } else { format!("'{}'", s.replace('\'', "'\\''")) }
}

/// The Rex layout script: `$TAUDOT_LAYOUT`, else `clients/rex/taudot-layout.sh` in the checkout this binary was
/// built from.
fn layout_script() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("TAUDOT_LAYOUT") {
        return Some(PathBuf::from(p));
    }
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../clients/rex/taudot-layout.sh");
    p.exists().then_some(p)
}

pub async fn open(a: OpenArgs) -> anyhow::Result<()> {
    let folder = a.folder.clone().unwrap_or(std::env::current_dir()?).canonicalize()?;
    if !crate::compat::project_file(&folder).exists() {
        bail!("{} has no .taudot.json; make one with `taudot clone <overleaf url>`", folder.display());
    }
    let mut c = engine(&a.engine).await?;
    let p = c.call("project.open", json!({"folder": folder})).await?;
    println!("syncing \"{}\" in {}", p["name"].as_str().unwrap_or(""), folder.display());
    if a.no_layout {
        return Ok(());
    }
    let rex = std::process::Command::new("sh").arg("-c").arg("command -v rex").output().is_ok_and(|o| o.status.success());
    match (rex, layout_script()) {
        (true, Some(script)) => {
            let st = std::process::Command::new(&script).arg(&folder).status().with_context(|| format!("running {}", script.display()))?;
            if !st.success() {
                bail!("{} failed", script.display());
            }
        }
        (false, _) => println!("rex isn't on PATH; edit the folder with any editor, the engine syncs it"),
        (_, None) => println!("no Rex layout script found (set TAUDOT_LAYOUT); the engine syncs the folder meanwhile"),
    }
    Ok(())
}

pub async fn rpc(a: RpcArgs) -> anyhow::Result<()> {
    let params: Value = serde_json::from_str(&a.params).context("params must be JSON")?;
    let mut c = engine(&a.engine).await?;
    let r = c.call(&a.method, params).await?;
    println!("{}", serde_json::to_string_pretty(&r)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn slugs() {
        assert_eq!(super::slug("My Paper: draft 2"), "My-Paper-draft-2");
        assert_eq!(super::slug("  "), "overleaf-project");
        assert_eq!(super::slug("Grüße"), "Grüße");
    }
}
