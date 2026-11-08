//! Migration from the old name, texsync (the product became Taudot on 2026-11-04). The old names live here and
//! nowhere else in the engine:
//!
//! - `TEXSYNC_*` environment variables are read when the `TAUDOT_*` one is unset (one release).
//! - The engine's home moves from `~/.texsync` to `~/.taudot` on first start, leaving a symlink behind.
//! - A folder's `.texsync.json` / `.texsyncignore` are read when the new names are missing; the new names are written.
//! - Keychain items under service `texsync` are copied to `taudot` when first read (the old ones stay).
//! - The launchd agent `com.texsync.engine` is removed when the new one is installed.

use anyhow::{bail, Context};
use std::path::{Path, PathBuf};

const OLD_ENV: &str = "TEXSYNC_";
const NEW_ENV: &str = "TAUDOT_";
const OLD_HOME: &str = ".texsync";
const NEW_HOME: &str = ".taudot";
pub const OLD_KEYCHAIN_SERVICE: &str = "texsync";
pub const OLD_LAUNCHD_LABEL: &str = "com.texsync.engine";
const OLD_PROJECT_FILE: &str = ".texsync.json";
const OLD_IGNORE_FILE: &str = ".texsyncignore";
pub const PROJECT_FILE: &str = ".taudot.json";
pub const IGNORE_FILE: &str = ".taudotignore";

/// Copies each `TEXSYNC_X` to `TAUDOT_X` where that is unset. Call first thing, before any thread starts.
pub fn env_fallback() {
    for (k, v) in std::env::vars_os() {
        let Some(k) = k.to_str() else { continue };
        if let Some(rest) = k.strip_prefix(OLD_ENV) {
            let new = format!("{NEW_ENV}{rest}");
            if std::env::var_os(&new).is_none() {
                std::env::set_var(new, v);
            }
        }
    }
}

/// `~/.taudot`, without touching anything.
pub fn default_home_path() -> anyhow::Result<PathBuf> {
    Ok(PathBuf::from(std::env::var("HOME").context("HOME")?).join(NEW_HOME))
}

/// `~/.taudot`, after moving `~/.texsync` there if only the old one exists ([`migrate_home`]).
pub fn default_home() -> anyhow::Result<PathBuf> {
    migrate_home(&PathBuf::from(std::env::var("HOME").context("HOME")?))
}

/// In the user's home folder `base`: moves `.texsync` to `.taudot` and leaves `.texsync` as a symlink to it. When
/// `.taudot` already exists (something made its `logs` first), what it lacks is moved in and the rest of the old
/// folder is kept as `.texsync.old-<time>`. Refuses while an engine still runs in the old home.
pub fn migrate_home(base: &Path) -> anyhow::Result<PathBuf> {
    let (old, new) = (base.join(OLD_HOME), base.join(NEW_HOME));
    if !std::fs::symlink_metadata(&old).is_ok_and(|m| m.is_dir()) {
        return Ok(new);
    }
    if std::os::unix::net::UnixStream::connect(old.join("engine.sock")).is_ok() {
        bail!(
            "an engine is still running in {} (the old texsync home); stop it (`texsync service uninstall`, or quit it) and start again: {} is then moved to {}",
            old.display(),
            old.display(),
            new.display()
        );
    }
    if new.exists() {
        for e in std::fs::read_dir(&old)? {
            let e = e?;
            let to = new.join(e.file_name());
            if !to.exists() && e.file_name() != "engine.sock" {
                std::fs::rename(e.path(), &to).with_context(|| format!("moving {} into {}", e.path().display(), new.display()))?;
            }
        }
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
        let kept = base.join(format!("{OLD_HOME}.old-{stamp}"));
        std::fs::rename(&old, &kept)?;
        eprintln!("merged {} into {}; what was left is in {}", old.display(), new.display(), kept.display());
    } else {
        std::fs::rename(&old, &new).with_context(|| format!("moving {} to {}", old.display(), new.display()))?;
        eprintln!("moved {} to {} (a symlink stays at the old place)", old.display(), new.display());
    }
    std::os::unix::fs::symlink(&new, &old).with_context(|| format!("linking {} to {}", old.display(), new.display()))?;
    Ok(new)
}

/// The folder's project file: `.taudot.json`, or the old `.texsync.json` when only that exists.
pub fn project_file(folder: &Path) -> PathBuf {
    let new = folder.join(PROJECT_FILE);
    let old = folder.join(OLD_PROJECT_FILE);
    if !new.exists() && old.exists() {
        old
    } else {
        new
    }
}

/// The folder's ignore files, the old name first.
pub fn ignore_files(folder: &Path) -> [PathBuf; 2] {
    [folder.join(OLD_IGNORE_FILE), folder.join(IGNORE_FILE)]
}

/// Whether `rel` (relative to the folder) is one of the folder's own rule files, old names included.
pub fn is_project_rules(name: &str, rel: &str) -> bool {
    name == IGNORE_FILE || name == OLD_IGNORE_FILE || rel == PROJECT_FILE || rel == OLD_PROJECT_FILE
}

/// The launchd label the agent for `new_label` had before the rename.
pub fn old_label(new_label: &str) -> String {
    new_label.replacen("app.taudot.engine", OLD_LAUNCHD_LABEL, 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_moves_once_and_leaves_a_link() {
        let base = std::env::temp_dir().join(format!("taudot-compat-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join(".texsync/backup")).unwrap();
        std::fs::write(base.join(".texsync/clones.json"), "{}").unwrap();
        let home = migrate_home(&base).unwrap();
        assert_eq!(home, base.join(".taudot"));
        assert_eq!(std::fs::read_to_string(home.join("clones.json")).unwrap(), "{}");
        assert!(home.join("backup").is_dir());
        assert_eq!(std::fs::read_link(base.join(".texsync")).unwrap(), home);
        // Again: nothing to do.
        assert_eq!(migrate_home(&base).unwrap(), home);
        // A live engine in the old home blocks the move.
        let b2 = base.join("second");
        std::fs::create_dir_all(b2.join(".texsync")).unwrap();
        let _l = std::os::unix::net::UnixListener::bind(b2.join(".texsync/engine.sock")).unwrap();
        assert!(migrate_home(&b2).is_err());
        assert!(b2.join(".texsync").is_dir() && !b2.join(".taudot").exists());
        // `.taudot` made first (txs's logs): the old home is merged in.
        let b3 = base.join("third");
        std::fs::create_dir_all(b3.join(".texsync/logs")).unwrap();
        std::fs::write(b3.join(".texsync/clones.json"), "[1]").unwrap();
        std::fs::write(b3.join(".texsync/logs/engine.log"), "old").unwrap();
        std::fs::create_dir_all(b3.join(".taudot/logs")).unwrap();
        let home = migrate_home(&b3).unwrap();
        assert_eq!(std::fs::read_to_string(home.join("clones.json")).unwrap(), "[1]");
        assert_eq!(std::fs::read_link(b3.join(".texsync")).unwrap(), home);
        assert!(std::fs::read_dir(&b3).unwrap().any(|e| e.unwrap().file_name().to_string_lossy().starts_with(".texsync.old-")));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn old_project_files_are_read() {
        let d = std::env::temp_dir().join(format!("taudot-compat-pf-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        assert_eq!(project_file(&d), d.join(".taudot.json"));
        std::fs::write(d.join(".texsync.json"), "{}").unwrap();
        assert_eq!(project_file(&d), d.join(".texsync.json"));
        std::fs::write(d.join(".taudot.json"), "{}").unwrap();
        assert_eq!(project_file(&d), d.join(".taudot.json"));
        assert!(is_project_rules(".texsyncignore", ".texsyncignore") && is_project_rules(".taudot.json", ".taudot.json"));
        assert_eq!(old_label("app.taudot.engine.ab12"), "com.texsync.engine.ab12");
        let _ = std::fs::remove_dir_all(&d);
    }
}
