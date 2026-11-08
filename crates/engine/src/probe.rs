//! `taudot probe`: the smallest end-to-end check against a real server.

use crate::Login;
use anyhow::{anyhow, bail, Context};
use overleaf::text::js_len;
use overleaf::{Applied, DocSync, OtType, ProjectConn, ServerEvent, Style};
use serde_json::{json, Value};
use std::time::{Duration, Instant};

#[derive(clap::Args)]
pub struct Args {
    #[command(flatten)]
    login: Login,
    /// Project ID, or `classic` / `historyot` to read `OVERLEAF_PROJECT_<NAME>_ID` from the env file. Default: the
    /// first project in the list.
    #[arg(long)]
    project: Option<String>,
    /// Doc path in the project.
    #[arg(long, default_value = "main.tex")]
    doc: String,
    /// Line to append. Default: `% taudot probe <unix time>`.
    #[arg(long)]
    line: Option<String>,
    /// Connection style: auto, query or emit.
    #[arg(long, default_value = "auto")]
    style: String,
    /// Print one JSON object instead of text.
    #[arg(long)]
    json: bool,
    /// Join and print, but don't edit.
    #[arg(long)]
    read_only: bool,
}

pub async fn run(a: Args) -> anyhow::Result<()> {
    let style = match a.style.as_str() {
        "auto" => Style::Auto,
        "query" => Style::Query,
        "emit" => Style::Emit,
        s => bail!("unknown style {s}"),
    };
    let http = a.login.http().await.context("login")?;
    let env = a.login.env()?;
    let project_id = match a.project.as_deref() {
        Some(p) if p.len() == 24 && p.chars().all(|c| c.is_ascii_hexdigit()) => p.to_string(),
        Some(name) => env
            .get(&format!("OVERLEAF_PROJECT_{}_ID", name.to_uppercase()))
            .cloned()
            .ok_or_else(|| anyhow!("no OVERLEAF_PROJECT_{}_ID in the env file", name.to_uppercase()))?,
        None => http.projects().await?.first().map(|p| p.id.clone()).ok_or_else(|| anyhow!("no projects"))?,
    };

    let mut conn = ProjectConn::connect(&http, &project_id, style).await.context("join project")?;
    let tree = overleaf::file_tree(&conn.project);
    let doc_id = tree
        .iter()
        .find(|(path, kind, _)| *kind == "doc" && path == &a.doc)
        .map(|(_, _, id)| id.clone())
        .ok_or_else(|| anyhow!("no doc {} in the project", a.doc))?;
    if !a.json {
        println!("project {} ({:?}), {} access, joined with {:?}", project_id, conn.project["name"], conn.permissions, conn.style);
        println!("public id {}", conn.public_id);
        for (path, kind, id) in &tree {
            println!("  {kind:6} {path}  {id}");
        }
    }

    let joined = conn.join_doc(&doc_id, None, None).await.context("joinDoc")?;
    let text = joined.text();
    if !a.json {
        println!("{}: {}, version {}, {} lines", a.doc, joined.ot_type.as_str(), joined.version, joined.lines.len());
    }
    let mut out = json!({
        "project_id": project_id,
        "public_id": conn.public_id,
        "style": format!("{:?}", conn.style),
        "permissions": conn.permissions,
        "tree": tree.iter().map(|(p, k, i)| json!({"path": p, "kind": k, "id": i})).collect::<Vec<_>>(),
        "doc_id": doc_id,
        "type": joined.ot_type.as_str(),
        "version_before": joined.version,
    });
    if a.read_only {
        if a.json {
            println!("{out}");
        }
        conn.disconnect();
        return Ok(());
    }

    let line = a.line.unwrap_or_else(|| {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        format!("% taudot probe {t}")
    });
    let ins = if text.is_empty() || text.ends_with('\n') { format!("{line}\n") } else { format!("\n{line}") };
    let len = js_len(&text);
    let op = match joined.ot_type {
        OtType::ShareJsTextOt => json!([{"p": len, "i": ins}]),
        OtType::HistoryOt if len == 0 => json!([{"textOperation": [ins]}]),
        OtType::HistoryOt => json!([{"textOperation": [len, ins]}]),
    };
    let mut doc = DocSync::new(&doc_id, joined.ot_type.clone(), joined.version);
    doc.submit(op.clone());
    let u = doc.take_next(Instant::now(), &conn.public_id).unwrap();
    let sent = Instant::now();
    conn.apply_ot_update(&u).await.context("applyOtUpdate")?;

    let deadline = sent + Duration::from_secs(30);
    let version = loop {
        if let Some(r) = doc.resend_due(Instant::now(), &conn.public_id) {
            eprintln!("no confirmation yet, resending with dupIfSource {:?}", r.dup_if_source);
            conn.apply_ot_update(&r).await?;
        }
        if Instant::now() > deadline {
            bail!("no otUpdateApplied confirmation within 30 s");
        }
        let ev = match tokio::time::timeout(Duration::from_millis(500), conn.next_event()).await {
            Err(_) => continue,
            Ok(None) => bail!("connection closed"),
            Ok(Some(ev)) => ev,
        };
        match ev {
            ServerEvent::OtUpdateApplied(u) => match doc.on_update(u)? {
                Applied::Confirmed { version } => break version,
                Applied::Remote { update, .. } => eprintln!("remote op from {:?}", update.user_id()),
                Applied::Ignored => {}
            },
            ServerEvent::OtUpdateError { error, message } => bail!("otUpdateError {error} {message}"),
            ServerEvent::Closed { reason } => bail!("connection closed: {reason}"),
            ServerEvent::ForceDisconnect { message, .. } => bail!("forceDisconnect: {message}"),
            _ => {}
        }
    };
    let ms = sent.elapsed().as_millis();
    if a.json {
        out["op"] = op;
        out["version_after"] = Value::from(version);
        out["confirm_ms"] = Value::from(ms as u64);
        println!("{out}");
    } else {
        println!("appended {line:?}, confirmed by otUpdateApplied in {ms} ms, version {version}");
    }
    conn.disconnect();
    Ok(())
}
