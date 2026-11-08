//! `taudot`: the engine binary.

mod compat;
mod account;
mod cli;
mod engine;
mod history;
mod login;
mod probe;
mod projects;
mod serve;
mod service;

use clap::{Parser, Subcommand};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "taudot", version, about = "Keep a local LaTeX project in sync with Overleaf")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Log in, join a project, append a line to a doc, wait for the server's confirmation.
    Probe(probe::Args),
    /// Run the engine: JSON-RPC over a Unix socket (docs/api.md).
    Serve(serve::Args),
    /// Log in to an Overleaf server with the session from your browser; kept in the Keychain.
    Login(login::Args),
    /// Make a local folder for an Overleaf project, mirrored and kept in sync both ways.
    Clone(cli::CloneArgs),
    /// Sync a cloned folder (starting the engine if needed) and open the Rex layout.
    Open(cli::OpenArgs),
    /// Call an engine method and print the result (docs/api.md).
    Rpc(cli::RpcArgs),
    /// The engine as a launchd agent: install, uninstall, status.
    Service(service::Args),
}

/// Login and server settings shared by subcommands.
#[derive(clap::Args, Clone, Debug)]
pub struct Login {
    /// Overleaf server. Never overleaf.com in tests.
    #[arg(long, default_value = "http://localhost:8800")]
    pub url: String,
    /// `KEY=VALUE` file with credentials, such as the testbed's `docker/.env.test`.
    #[arg(long)]
    pub env_file: Option<PathBuf>,
    /// Which user from the env file: `user1`, `user2` or `admin`.
    #[arg(long, default_value = "user1")]
    pub user: String,
    #[arg(long, env = "TAUDOT_EMAIL")]
    pub email: Option<String>,
    #[arg(long, env = "TAUDOT_PASSWORD", hide_env_values = true)]
    pub password: Option<String>,
    /// Session cookie instead of email and password, e.g. `overleaf_session2=...`.
    #[arg(long, env = "TAUDOT_COOKIE", hide_env_values = true)]
    pub cookie: Option<String>,
    /// Keep `taudot login` sessions in this JSON file instead of the Keychain (tests).
    #[arg(long, hide = true)]
    pub sessions: Option<PathBuf>,
}

impl Login {
    /// True if a rejected session can be renewed by logging in again (we have a password, not just a cookie).
    pub fn can_relogin(&self) -> bool {
        if self.cookie.is_some() {
            return false;
        }
        let key = self.user.to_uppercase();
        let env = self.env().unwrap_or_default();
        self.password.is_some() || env.contains_key(&format!("OVERLEAF_{key}_PASSWORD"))
    }

    pub fn env(&self) -> anyhow::Result<HashMap<String, String>> {
        let Some(p) = &self.env_file else { return Ok(HashMap::new()) };
        let text = std::fs::read_to_string(p).map_err(|e| anyhow::anyhow!("{}: {e}", p.display()))?;
        Ok(text
            .lines()
            .filter(|l| !l.trim_start().starts_with('#'))
            .filter_map(|l| l.split_once('='))
            .map(|(k, v)| (k.trim().to_string(), v.trim().trim_matches('"').to_string()))
            .collect())
    }

    pub async fn http(&self) -> anyhow::Result<overleaf::Http> {
        if let Some(c) = &self.cookie {
            return Ok(overleaf::Http::with_cookie(&self.url, c)?);
        }
        let env = self.env()?;
        let has_password = self.password.is_some() || env.contains_key(&format!("OVERLEAF_{}_PASSWORD", self.user.to_uppercase()));
        if !has_password {
            // A session stored by `taudot login`.
            let origin = login::origin(&self.url)?;
            if let Some(c) = login::session_get(self.sessions.as_deref(), &origin) {
                return Ok(overleaf::Http::with_cookie(&self.url, &c)?);
            }
            anyhow::bail!("not logged in to {origin}: run `taudot login --url {origin}` (or pass --env-file / --password)");
        }
        let key = self.user.to_uppercase();
        let email = self
            .email
            .clone()
            .or_else(|| env.get(&format!("OVERLEAF_{key}_EMAIL")).cloned())
            .ok_or_else(|| anyhow::anyhow!("no email: pass --email or --env-file"))?;
        let password = self
            .password
            .clone()
            .or_else(|| env.get(&format!("OVERLEAF_{key}_PASSWORD")).cloned())
            .ok_or_else(|| anyhow::anyhow!("no password: pass --password or --env-file"))?;
        let mut http = overleaf::Http::new(&self.url)?;
        http.login(&email, &password).await?;
        Ok(http)
    }
}

fn main() -> anyhow::Result<()> {
    // Before the runtime's threads: the old TEXSYNC_* names still work (compat.rs).
    compat::env_fallback();
    tokio::runtime::Builder::new_multi_thread().enable_all().build()?.block_on(run())
}

async fn run() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_env("TAUDOT_LOG"))
        .with_writer(std::io::stderr)
        .init();
    match Cli::parse().cmd {
        Cmd::Probe(a) => probe::run(a).await,
        Cmd::Serve(a) => serve::run(a).await,
        Cmd::Login(a) => login::run(a).await,
        Cmd::Clone(a) => cli::clone(a).await,
        Cmd::Open(a) => cli::open(a).await,
        Cmd::Rpc(a) => cli::rpc(a).await,
        Cmd::Service(a) => service::run(a).await,
    }
}
