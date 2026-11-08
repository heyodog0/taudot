//! `taudot service install|uninstall|status`: the engine as a launchd agent, one for all projects, started at login
//! and restarted if it crashes. Logs go to `<home>/logs/engine.log`.
//!
//! The default home (`~/.taudot` of the user's real home folder) gets the label `app.taudot.engine`; any other home
//! gets its own label, so a test engine never replaces the user's, even one run with `HOME` pointed elsewhere.
//!
//! `taudot service ensure` is what Taudot.app runs at every launch with the engine inside the bundle: it installs the
//! agent, points it at this binary when the app was moved or the agent came from somewhere else (a repo build, an
//! older copy), and restarts the engine when the binary is newer than the running engine (an update). The binary is
//! never overwritten in place (macOS kills a process whose signed file changed under it): an update replaces the
//! whole bundle, so the path stays and the file is new.

use anyhow::{bail, Context};
use std::path::{Path, PathBuf};

#[derive(clap::Args)]
pub struct Args {
    #[command(subcommand)]
    pub cmd: Sub,
    /// Engine home. Default `$TAUDOT_HOME` or `~/.taudot`.
    #[arg(long, env = "TAUDOT_HOME", global = true)]
    pub home: Option<PathBuf>,
    #[arg(long, global = true)]
    pub json: bool,
}

#[derive(clap::Subcommand)]
pub enum Sub {
    /// Write the launchd agent and start it.
    Install,
    /// Stop the agent and remove it.
    Uninstall,
    /// Whether the agent is installed and the engine answers.
    Status,
    /// Install, repoint or restart the agent so it runs this binary (what the app runs at launch). Does nothing when
    /// `TAUDOT_NO_SERVICE` is set (the engine is then started on demand, as a child of whoever asks).
    Ensure,
}

fn default_home() -> anyhow::Result<PathBuf> {
    crate::compat::default_home()
}

/// The user's home folder from the user database, whatever `$HOME` says.
fn real_home() -> Option<PathBuf> {
    #[repr(C)]
    struct Passwd {
        name: *const i8,
        passwd: *const i8,
        uid: u32,
        gid: u32,
        change: i64,
        class: *const i8,
        gecos: *const i8,
        dir: *const i8,
        shell: *const i8,
        expire: i64,
    }
    extern "C" {
        fn getpwuid(uid: u32) -> *const Passwd;
    }
    // SAFETY: getpwuid returns a pointer to static storage or null; pw_dir is a C string. Called rarely, and the
    // string is copied out at once.
    unsafe {
        let p = getpwuid(libc_getuid());
        if p.is_null() || (*p).dir.is_null() {
            return None;
        }
        let s = std::ffi::CStr::from_ptr((*p).dir).to_string_lossy().into_owned();
        Some(PathBuf::from(s))
    }
}

pub fn label(home: &Path) -> String {
    let default = crate::compat::default_home_path().is_ok_and(|d| d == home);
    let real = real_home().is_none_or(|r| r.join(".taudot") == home);
    if default && real {
        return "app.taudot.engine".into();
    }
    use sha1::Digest;
    let h = sha1::Sha1::digest(home.to_string_lossy().as_bytes());
    format!("app.taudot.engine.{}", h.iter().take(4).map(|b| format!("{b:02x}")).collect::<String>())
}

fn plist_path(home: &Path) -> anyhow::Result<PathBuf> {
    Ok(PathBuf::from(std::env::var("HOME")?).join("Library/LaunchAgents").join(format!("{}.plist", label(home))))
}

pub fn installed(home: &Path) -> bool {
    plist_path(home).is_ok_and(|p| p.exists())
}

fn domain() -> String {
    // SAFETY: getuid has no preconditions.
    format!("gui/{}", unsafe { libc_getuid() })
}

extern "C" {
    #[link_name = "getuid"]
    fn libc_getuid() -> u32;
}

fn launchctl(args: &[&str]) -> anyhow::Result<std::process::Output> {
    std::process::Command::new("/bin/launchctl").args(args).output().context("running launchctl")
}

pub fn kickstart(home: &Path) -> anyhow::Result<()> {
    let target = format!("{}/{}", domain(), label(home));
    let out = launchctl(&["kickstart", &target])?;
    if !out.status.success() {
        bail!("launchctl kickstart {target}: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn plist(label: &str, exe: &Path, home: &Path) -> String {
    let log = home.join("logs/engine.log");
    let path = std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key>
  <array><string>{exe}</string><string>serve</string><string>--home</string><string>{home}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>{log}</string>
  <key>StandardErrorPath</key><string>{log}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TAUDOT_LOG</key><string>taudot=info</string>
    <key>PATH</key><string>{path}</string>
  </dict>
</dict>
</plist>
"#,
        label = xml_escape(label),
        exe = xml_escape(&exe.display().to_string()),
        home = xml_escape(&home.display().to_string()),
        log = xml_escape(&log.display().to_string()),
        path = xml_escape(&path),
    )
}

pub async fn run(a: Args) -> anyhow::Result<()> {
    let home = match &a.home {
        Some(h) => h.clone(),
        None => default_home()?,
    };
    let label = label(&home);
    let plist_file = plist_path(&home)?;
    let target = format!("{}/{label}", domain());
    match a.cmd {
        Sub::Install => {
            let exe = std::env::current_exe()?.canonicalize()?;
            if exe.components().any(|c| c.as_os_str() == "target") {
                eprintln!("note: {} is a build output; `cargo install --path crates/engine` gives a stable path", exe.display());
            }
            install(&home, &label, &plist_file, &target, &exe).await?;
            println!("installed {label}: {} serve --home {}; logs in {}", exe.display(), home.display(), home.join("logs/engine.log").display());
        }
        Sub::Ensure => {
            if std::env::var_os("TAUDOT_NO_SERVICE").is_some() {
                println!("{}", if a.json { r#"{"action":"skipped"}"#.to_string() } else { "skipped (TAUDOT_NO_SERVICE)".into() });
                return Ok(());
            }
            let exe = std::env::current_exe()?.canonicalize()?;
            let action = ensure(&home, &label, &plist_file, &target, &exe).await?;
            if a.json {
                println!("{}", serde_json::json!({"action": action, "label": label, "exe": exe}));
            } else {
                println!("{label}: {action} ({})", exe.display());
            }
        }
        Sub::Uninstall => {
            if loaded(&target) {
                let out = launchctl(&["bootout", &target])?;
                if !out.status.success() {
                    bail!("launchctl bootout: {}", String::from_utf8_lossy(&out.stderr).trim());
                }
                wait_unloaded(&target).await;
            }
            match std::fs::remove_file(&plist_file) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.into()),
                _ => {}
            }
            wait_socket(&home, false).await;
            println!("uninstalled {label}");
        }
        Sub::Status => {
            let pid = launchctl(&["print", &target]).ok().filter(|o| o.status.success()).and_then(|o| {
                String::from_utf8_lossy(&o.stdout).lines().find_map(|l| l.trim().strip_prefix("pid = ").map(|p| p.trim().to_string()))
            });
            let answers = tokio::net::UnixStream::connect(home.join("engine.sock")).await.is_ok();
            let s = serde_json::json!({"label": label, "installed": plist_file.exists(), "loaded": loaded(&target),
                "pid": pid, "engine_answers": answers, "home": home, "log": home.join("logs/engine.log")});
            if a.json {
                println!("{s}");
            } else {
                println!(
                    "{label}: {}, {}; engine {}",
                    if plist_file.exists() { "installed" } else { "not installed" },
                    match &pid { Some(p) => format!("running (pid {p})"), None => "not running".into() },
                    if answers { "answers" } else { "does not answer" }
                );
            }
        }
    }
    Ok(())
}

/// The program the agent's plist runs (its first ProgramArguments string).
fn plist_exe(text: &str) -> Option<PathBuf> {
    let a = text.find("<key>ProgramArguments</key>")?;
    let rest = &text[a..];
    let s = rest.find("<string>")? + "<string>".len();
    let e = rest[s..].find("</string>")?;
    let raw = &rest[s..s + e];
    Some(PathBuf::from(raw.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")))
}

/// What `ensure` does, decided from the plist on disk, whether launchd has it, and the times of the binary and of
/// the running engine's socket. Pure, for tests.
#[derive(Debug, PartialEq)]
enum Plan {
    Install,
    Load,
    /// Loaded but no engine answers (it exited 0, which launchd doesn't restart, or it hangs).
    Start,
    Restart,
    Nothing,
}

fn plan(
    plist: Option<&str>,
    exe: &Path,
    loaded: bool,
    exe_changed: Option<std::time::SystemTime>,
    socket_made: Option<std::time::SystemTime>,
    answers: bool,
) -> Plan {
    match plist.and_then(plist_exe) {
        Some(p) if p == exe => {}
        _ => return Plan::Install,
    }
    if !loaded {
        return Plan::Load;
    }
    if !answers {
        return Plan::Start;
    }
    match (exe_changed, socket_made) {
        (Some(c), Some(s)) if c > s => Plan::Restart,
        _ => Plan::Nothing,
    }
}

/// The binary's change time (ctime: set when the file was made on this disk, so an update's copy is newer than an
/// engine started before it, whatever mtime the archive kept).
fn changed(p: &Path) -> Option<std::time::SystemTime> {
    use std::os::unix::fs::MetadataExt;
    let m = std::fs::metadata(p).ok()?;
    Some(std::time::UNIX_EPOCH + std::time::Duration::new(m.ctime() as u64, m.ctime_nsec() as u32))
}

async fn ensure(home: &Path, label: &str, plist_file: &Path, target: &str, exe: &Path) -> anyhow::Result<&'static str> {
    let text = std::fs::read_to_string(plist_file).ok();
    let sock = home.join("engine.sock");
    let socket_made = std::fs::symlink_metadata(&sock).ok().and_then(|m| m.modified().ok());
    let answers = tokio::net::UnixStream::connect(&sock).await.is_ok();
    match plan(text.as_deref(), exe, loaded(target), changed(exe), socket_made, answers) {
        Plan::Install => {
            install(home, label, plist_file, target, exe).await?;
            Ok(if text.is_some() { "repointed" } else { "installed" })
        }
        Plan::Load => {
            let since = std::time::SystemTime::now();
            let out = launchctl(&["bootstrap", &domain(), &plist_file.display().to_string()])?;
            if !out.status.success() {
                bail!("launchctl bootstrap: {}", String::from_utf8_lossy(&out.stderr).trim());
            }
            wait_fresh_socket(home, since).await?;
            Ok("loaded")
        }
        Plan::Start | Plan::Restart => {
            // -k kills a running engine first. Either way, wait for a socket made after this, so the caller doesn't
            // connect to the old engine on its way out.
            let since = std::time::SystemTime::now();
            let out = launchctl(&["kickstart", "-k", target])?;
            if !out.status.success() {
                bail!("launchctl kickstart -k {target}: {}", String::from_utf8_lossy(&out.stderr).trim());
            }
            wait_fresh_socket(home, since).await?;
            Ok(if answers { "restarted" } else { "started" })
        }
        Plan::Nothing => Ok("up to date"),
    }
}

async fn install(home: &Path, label: &str, plist_file: &Path, target: &str, exe: &Path) -> anyhow::Result<()> {
    std::fs::create_dir_all(home.join("logs"))?;
    std::fs::create_dir_all(plist_file.parent().unwrap())?;
    // An engine already running by hand in this home would hold the socket: the agent's would exit.
    if tokio::net::UnixStream::connect(home.join("engine.sock")).await.is_ok() && !loaded(target) {
        bail!("an engine is already running in {} (not under launchd); stop it first", home.display());
    }
    if loaded(target) {
        let _ = launchctl(&["bootout", target]);
        // bootout returns before the job is gone; a bootstrap now fails ("Input/output error").
        wait_unloaded(target).await;
    }
    // The agent from before the rename (texsync) would hold the same home: remove it first.
    let old = crate::compat::old_label(label);
    let old_target = format!("{}/{old}", domain());
    if loaded(&old_target) {
        let _ = launchctl(&["bootout", &old_target]);
        wait_unloaded(&old_target).await;
    }
    wait_socket(home, false).await;
    let old_plist = plist_file.with_file_name(format!("{old}.plist"));
    if old_plist.exists() {
        std::fs::remove_file(&old_plist)?;
        println!("removed the old agent {old}");
    }
    std::fs::write(plist_file, plist(label, exe, home))?;
    let since = std::time::SystemTime::now();
    let out = launchctl(&["bootstrap", &domain(), &plist_file.display().to_string()])?;
    if !out.status.success() {
        bail!("launchctl bootstrap: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    wait_fresh_socket(home, since).await?;
    Ok(())
}

/// Until launchd no longer has the job (up to 5 s).
async fn wait_unloaded(target: &str) {
    for _ in 0..50 {
        if !loaded(target) {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}

/// Until an engine started after `since` answers: its socket file is newer than that (the old engine's, still
/// answering on its way out, isn't). Up to 10 s.
async fn wait_fresh_socket(home: &Path, since: std::time::SystemTime) -> anyhow::Result<()> {
    let sock = home.join("engine.sock");
    for _ in 0..100 {
        let fresh = std::fs::symlink_metadata(&sock).ok().and_then(|m| m.modified().ok()).is_some_and(|t| t >= since);
        if fresh && tokio::net::UnixStream::connect(&sock).await.is_ok() {
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    bail!("the engine did not start (no new {} after 10 s; see {})", sock.display(), home.join("logs/engine.log").display())
}

fn loaded(target: &str) -> bool {
    launchctl(&["print", target]).is_ok_and(|o| o.status.success())
}

async fn wait_socket(home: &Path, up: bool) {
    for _ in 0..50 {
        if tokio::net::UnixStream::connect(home.join("engine.sock")).await.is_ok() == up {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_differ_by_home() {
        let d = crate::compat::default_home_path().unwrap();
        assert_eq!(label(&d), "app.taudot.engine");
        assert_ne!(label(Path::new("/tmp/a")), label(Path::new("/tmp/b")));
        assert!(plist("l", Path::new("/x/taudot"), Path::new("/h")).contains("<string>/h/logs/engine.log</string>"));
    }

    #[test]
    fn a_home_under_another_home_variable_gets_its_own_label() {
        // HOME pointed at a scratch folder (the release's clean-account run): its ~/.taudot is not the user's.
        let scratch = Path::new("/tmp/scratch-home/.taudot");
        assert_ne!(label(scratch), "app.taudot.engine");
        assert_eq!(label(&real_home().unwrap().join(".taudot")), label(&real_home().unwrap().join(".taudot")));
    }

    #[test]
    fn ensure_plans() {
        use std::time::{Duration, UNIX_EPOCH};
        let exe = Path::new("/Applications/Taudot.app/Contents/MacOS/taudot");
        let here = plist("app.taudot.engine", exe, Path::new("/h"));
        let repo = plist("app.taudot.engine", Path::new("/Users/me/code/taudot/target/release/taudot"), Path::new("/h"));
        assert_eq!(plist_exe(&here).as_deref(), Some(exe));
        let (t1, t2) = (UNIX_EPOCH + Duration::from_secs(100), UNIX_EPOCH + Duration::from_secs(200));
        assert_eq!(plan(None, exe, false, None, None, false), Plan::Install);
        assert_eq!(plan(Some(&repo), exe, true, Some(t1), Some(t2), true), Plan::Install);
        assert_eq!(plan(Some(&here), exe, false, Some(t1), None, false), Plan::Load);
        assert_eq!(plan(Some(&here), exe, true, Some(t1), Some(t2), true), Plan::Nothing);
        assert_eq!(plan(Some(&here), exe, true, Some(t2), Some(t1), true), Plan::Restart);
        // E13: loaded, but the engine exited 0 (launchd doesn't restart a successful exit) or hangs: start it.
        assert_eq!(plan(Some(&here), exe, true, Some(t2), None, false), Plan::Start);
        assert_eq!(plan(Some(&here), exe, true, Some(t1), Some(t2), false), Plan::Start);
        let odd = plist("l", Path::new("/A & B/Taudot.app/Contents/MacOS/taudot"), Path::new("/h"));
        assert_eq!(plist_exe(&odd).as_deref(), Some(Path::new("/A & B/Taudot.app/Contents/MacOS/taudot")));
    }
}
