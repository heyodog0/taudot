//! One project connection: join the project, join docs, send updates, receive events.

use crate::socket::{ConnectOptions, Incoming, Socket};
use crate::text::decode_packed;
use crate::{Error, Http};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::sync::mpsc;

/// How to join the project.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Style {
    /// Try [`Style::Query`], fall back to [`Style::Emit`] if the server rejects it.
    Auto,
    /// Newer: `?projectId=` on the handshake, the server answers `joinProjectResponse`. The only style Overleaf CE
    /// `e039ad2` accepts (`services/real-time/app/js/Router.js`).
    Query,
    /// Older: connect, then call `joinProject({project_id})`.
    Emit,
}

/// The edit format of a doc, from `joinDoc`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum OtType {
    ShareJsTextOt,
    HistoryOt,
}

impl OtType {
    pub fn parse(s: &str) -> Result<OtType, Error> {
        match s {
            "sharejs-text-ot" => Ok(OtType::ShareJsTextOt),
            "history-ot" => Ok(OtType::HistoryOt),
            other => Err(Error::Protocol(format!("unknown doc type {other:?}"))),
        }
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            OtType::ShareJsTextOt => "sharejs-text-ot",
            OtType::HistoryOt => "history-ot",
        }
    }
}

/// The answer to `joinDoc`.
#[derive(Debug, Clone)]
pub struct JoinedDoc {
    /// Lines as real text (decoded from the Latin-1 packing for `sharejs-text-ot`).
    pub lines: Vec<String>,
    pub version: u64,
    /// Updates since `fromVersion`, oldest first. Empty for a full join.
    pub ops: Vec<Update>,
    pub ranges: Value,
    pub ot_type: OtType,
    pub can_skip_leave_doc: bool,
    /// For `history-ot`, the raw `StringFileData` (`content`, `comments`, `trackedChanges`).
    pub history_snapshot: Option<Value>,
}

impl JoinedDoc {
    pub fn text(&self) -> String {
        self.lines.join("\n")
    }
}

/// An update as the server broadcasts it in `otUpdateApplied`. A confirmation of our own update has only `doc` and
/// `v`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Update {
    pub doc: String,
    pub v: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub op: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meta: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "lastV")]
    pub last_v: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hash: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dup: Option<bool>,
}

impl Update {
    /// `meta.source`, the public ID of the connection that sent it.
    pub fn source(&self) -> Option<&str> {
        self.meta.as_ref()?.get("source")?.as_str()
    }
    pub fn user_id(&self) -> Option<&str> {
        self.meta.as_ref()?.get("user_id")?.as_str()
    }
}

/// An update we send. Only fields the server's strict schema allows (`applyOtUpdateSchema` in
/// `services/real-time/app/js/Router.js`); anything else gets us disconnected.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct OutgoingUpdate {
    pub doc: String,
    pub op: Value,
    pub v: u64,
    #[serde(skip_serializing_if = "Option::is_none", rename = "lastV")]
    pub last_v: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hash: Option<String>,
    /// Tracked changes: `{tc: <18 hex chars>}`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub meta: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "dupIfSource")]
    pub dup_if_source: Option<Vec<String>>,
}

/// Server events, typed where we act on them.
#[derive(Debug, Clone)]
pub enum ServerEvent {
    OtUpdateApplied(Update),
    /// `otUpdateError(error, message)`. The server disconnects us right after.
    OtUpdateError { error: Value, message: Value },
    /// `forceDisconnect(message, delaySeconds)`.
    ForceDisconnect { message: Value, delay: Option<f64> },
    ReconnectGracefully,
    Other { name: String, args: Vec<Value> },
    Closed { reason: String },
}

impl ServerEvent {
    fn from_incoming(i: Incoming) -> Option<ServerEvent> {
        match i {
            Incoming::Connect => None,
            Incoming::Closed { reason } => Some(ServerEvent::Closed { reason }),
            Incoming::Event { name, args } => Some(match name.as_str() {
                "otUpdateApplied" => match args.first().cloned().map(serde_json::from_value::<Update>) {
                    Some(Ok(u)) => ServerEvent::OtUpdateApplied(u),
                    _ => ServerEvent::Other { name, args },
                },
                "otUpdateError" => ServerEvent::OtUpdateError {
                    error: args.first().cloned().unwrap_or(Value::Null),
                    message: args.get(1).cloned().unwrap_or(Value::Null),
                },
                "forceDisconnect" => ServerEvent::ForceDisconnect {
                    message: args.first().cloned().unwrap_or(Value::Null),
                    delay: args.get(1).and_then(Value::as_f64),
                },
                "reconnectGracefully" => ServerEvent::ReconnectGracefully,
                _ => ServerEvent::Other { name, args },
            }),
        }
    }
}

/// A joined project.
pub struct ProjectConn {
    pub socket: Socket,
    pub project_id: String,
    /// This connection's public ID. The server stamps our updates with it as `meta.source`.
    pub public_id: String,
    pub project: Value,
    pub permissions: String,
    pub protocol_version: Option<i64>,
    pub style: Style,
    events: mpsc::UnboundedReceiver<Incoming>,
    /// Events that arrived while joining, handed out first.
    early: Vec<Incoming>,
}

const JOIN_TIMEOUT: Duration = Duration::from_secs(30);

impl ProjectConn {
    pub async fn connect(http: &Http, project_id: &str, style: Style) -> Result<ProjectConn, Error> {
        match style {
            Style::Query | Style::Emit => Self::connect_style(http, project_id, style).await,
            Style::Auto => match Self::connect_style(http, project_id, Style::Query).await {
                Err(Error::Rejected(msg)) if msg.contains("projectId") || msg.contains("timed out") => {
                    tracing::info!("query style rejected ({msg}), trying joinProject");
                    Self::connect_style(http, project_id, Style::Emit).await
                }
                r => r,
            },
        }
    }

    async fn connect_style(http: &Http, project_id: &str, style: Style) -> Result<ProjectConn, Error> {
        // Overleaf Workshop fetches this first so overleaf.com's load balancer sets its affinity cookie, which then
        // goes with the handshake and the WebSocket (unverified that it's needed; harmless on CE).
        if let Ok(u) = http.base.join("socket.io/socket.io.js") {
            let _ = http.client.get(u).send().await;
        }
        let mut opts = ConnectOptions { cookie: http.cookie_header(), ..Default::default() };
        if style == Style::Query {
            opts.query.push(("projectId".into(), project_id.into()));
        }
        let (socket, mut events) = Socket::connect(&http.client, &http.base, opts).await?;
        let mut early = vec![];
        let deadline = tokio::time::Instant::now() + JOIN_TIMEOUT;
        let mut public_id: Option<String> = None;
        loop {
            let ev = match tokio::time::timeout_at(deadline, events.recv()).await {
                Err(_) => {
                    socket.disconnect();
                    return Err(Error::Rejected("timed out waiting to join the project".into()));
                }
                Ok(None) => return Err(Error::Closed),
                Ok(Some(ev)) => ev,
            };
            match ev {
                Incoming::Closed { reason } => return Err(Error::Rejected(format!("closed while joining: {reason}"))),
                Incoming::Event { name, args } if name == "connectionRejected" => {
                    socket.disconnect();
                    let msg = args
                        .first()
                        .and_then(|a| a.get("message"))
                        .and_then(Value::as_str)
                        .map(String::from)
                        .unwrap_or_else(|| Value::Array(args.clone()).to_string());
                    return Err(Error::Rejected(msg));
                }
                Incoming::Event { name, args } if name == "joinProjectResponse" && style == Style::Query => {
                    let body = args.into_iter().next().unwrap_or(Value::Null);
                    let public_id = body
                        .get("publicId")
                        .and_then(Value::as_str)
                        .ok_or_else(|| Error::Protocol(format!("joinProjectResponse without publicId: {body}")))?
                        .to_string();
                    return Ok(ProjectConn {
                        socket,
                        project_id: project_id.into(),
                        public_id,
                        project: body.get("project").cloned().unwrap_or(Value::Null),
                        permissions: body
                            .get("permissionsLevel")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                        protocol_version: body.get("protocolVersion").and_then(Value::as_i64),
                        style,
                        events,
                        early,
                    });
                }
                Incoming::Event { name, args } if name == "connectionAccepted" => {
                    // Older servers: connectionAccepted(_, publicId).
                    public_id = args.get(1).and_then(Value::as_str).map(String::from);
                    if style == Style::Emit {
                        break;
                    }
                }
                Incoming::Connect if style == Style::Emit && public_id.is_none() => {
                    // Wait briefly for connectionAccepted, which carries the public ID.
                    continue;
                }
                other => early.push(other),
            }
        }
        let public_id = public_id.ok_or_else(|| Error::Protocol("no public ID from connectionAccepted".into()))?;
        let r = socket.call("joinProject", vec![json!({ "project_id": project_id })]).await?;
        let r = ack_ok(r, "joinProject")?;
        Ok(ProjectConn {
            socket,
            project_id: project_id.into(),
            public_id,
            project: r.first().cloned().unwrap_or(Value::Null),
            permissions: r.get(1).and_then(Value::as_str).unwrap_or("").to_string(),
            protocol_version: r.get(2).and_then(Value::as_i64),
            style,
            events,
            early,
        })
    }

    /// Next server event. `None` after [`ServerEvent::Closed`].
    pub async fn next_event(&mut self) -> Option<ServerEvent> {
        loop {
            let i = if !self.early.is_empty() { self.early.remove(0) } else { self.events.recv().await? };
            if let Some(e) = ServerEvent::from_incoming(i) {
                return Some(e);
            }
        }
    }

    /// `joinDoc(docId, fromVersion, options)`. `from_version` of `None` asks for the whole doc.
    pub async fn join_doc(&self, doc_id: &str, from_version: Option<u64>, age_ms: Option<u64>) -> Result<JoinedDoc, Error> {
        let mut options = json!({ "encodeRanges": true, "supportsHistoryOT": true });
        if let Some(age) = age_ms {
            options["age"] = json!(age);
        }
        let from: i64 = from_version.map(|v| v as i64).unwrap_or(-1);
        let r = self.socket.call("joinDoc", vec![json!(doc_id), json!(from), options]).await?;
        let r = ack_ok(r, "joinDoc")?;
        parse_join_doc(r)
    }

    /// `applyOtUpdate(docId, update)`. Success only means the server queued it; the confirmation is
    /// `otUpdateApplied` with `{doc, v}` and no op.
    pub async fn apply_ot_update(&self, update: &OutgoingUpdate) -> Result<(), Error> {
        let r = self.socket.call("applyOtUpdate", vec![json!(update.doc), serde_json::to_value(update)?]).await?;
        ack_ok(r, "applyOtUpdate").map(|_| ())
    }

    /// `applyOtUpdate` as a future that doesn't borrow the connection, so the caller can await the server's answer
    /// in another task and keep reading events meanwhile.
    pub fn send_ot_update(&self, update: &OutgoingUpdate) -> impl std::future::Future<Output = Result<(), Error>> + Send + 'static {
        let socket = self.socket.clone();
        let args = serde_json::to_value(update).map(|u| vec![json!(update.doc), u]);
        async move {
            let r = socket.call("applyOtUpdate", args?).await?;
            ack_ok(r, "applyOtUpdate").map(|_| ())
        }
    }

    pub async fn connected_users(&self) -> Result<Value, Error> {
        let r = self.socket.call("clientTracking.getConnectedUsers", vec![]).await?;
        Ok(ack_ok(r, "clientTracking.getConnectedUsers")?.into_iter().next().unwrap_or(Value::Null))
    }

    pub fn update_position(&self, doc_id: &str, row: u64, column: u64) -> Result<(), Error> {
        self.socket
            .emit("clientTracking.updatePosition", vec![json!({ "row": row, "column": column, "doc_id": doc_id })])
    }

    pub fn disconnect(&self) {
        self.socket.disconnect()
    }
}

/// Split an ack into error and results. The server's error is `{message, code?}` (`Router._handleError`).
pub(crate) fn ack_ok(mut args: Vec<Value>, method: &str) -> Result<Vec<Value>, Error> {
    if args.is_empty() {
        return Ok(args);
    }
    let err = args.remove(0);
    if err.is_null() {
        return Ok(args);
    }
    let message = err.get("message").and_then(Value::as_str).map(String::from).unwrap_or_else(|| err.to_string());
    let code = err.get("code").and_then(Value::as_str).map(String::from);
    if message == "doc updater could not load requested ops" {
        return Err(Error::MissingOps);
    }
    Err(Error::Server { method: method.into(), message, code })
}

pub(crate) fn parse_join_doc(r: Vec<Value>) -> Result<JoinedDoc, Error> {
    let bad = |what: &str| Error::Protocol(format!("joinDoc answer: {what}"));
    let ot_type = OtType::parse(r.get(4).and_then(Value::as_str).unwrap_or("sharejs-text-ot"))?;
    let first = r.first().cloned().unwrap_or(Value::Null);
    // history-ot sends the raw StringFileData, `{content, comments?, trackedChanges?}`, instead of lines (observed on
    // CE 6.3.0).
    let mut history_snapshot = None;
    let raw_lines: Vec<Value> = match (&ot_type, &first) {
        (OtType::HistoryOt, Value::Object(o)) => {
            let content = o.get("content").and_then(Value::as_str).ok_or_else(|| bad("snapshot without content"))?;
            history_snapshot = Some(first.clone());
            content.split('\n').map(|l| Value::String(l.to_string())).collect()
        }
        (_, Value::Array(a)) => a.clone(),
        _ => return Err(bad("lines")),
    };
    let mut lines = Vec::with_capacity(raw_lines.len());
    for l in &raw_lines {
        let l = l.as_str().ok_or_else(|| bad("line is not a string"))?;
        lines.push(match ot_type {
            OtType::ShareJsTextOt => decode_packed(l).map_err(|e| bad(&e.to_string()))?,
            OtType::HistoryOt => l.to_string(),
        });
    }
    let version = r.get(1).and_then(Value::as_u64).ok_or_else(|| bad("version"))?;
    let ops = match r.get(2) {
        None | Some(Value::Null) => vec![],
        Some(v) => serde_json::from_value(v.clone()).map_err(|e| bad(&format!("ops: {e}")))?,
    };
    let mut ranges = r.get(3).cloned().unwrap_or(Value::Null);
    if ot_type == OtType::ShareJsTextOt {
        decode_ranges(&mut ranges).map_err(|e| bad(&e.to_string()))?;
    }
    let can_skip_leave_doc = r.get(5).and_then(|o| o.get("canSkipLeaveDoc")).and_then(Value::as_bool).unwrap_or(false);
    Ok(JoinedDoc { lines, version, ops, ranges, ot_type, can_skip_leave_doc, history_snapshot })
}

/// With `encodeRanges`, comment `op.c` and change `op.i`/`op.d` come packed like the lines.
fn decode_ranges(ranges: &mut Value) -> Result<(), crate::text::PackedError> {
    for (list, keys) in [("comments", &["c"][..]), ("changes", &["i", "d"][..])] {
        if let Some(items) = ranges.get_mut(list).and_then(Value::as_array_mut) {
            for item in items {
                for k in keys {
                    if let Some(s) = item.pointer(&format!("/op/{k}")).and_then(Value::as_str) {
                        let d = decode_packed(s)?;
                        item["op"][*k] = Value::String(d);
                    }
                }
            }
        }
    }
    Ok(())
}

/// The doc tree of a joined project: `(path, kind, id)` for every doc, file and folder.
pub fn file_tree(project: &Value) -> Vec<(String, &'static str, String)> {
    fn walk(folder: &Value, prefix: &str, out: &mut Vec<(String, &'static str, String)>) {
        let id = |v: &Value| v.get("_id").and_then(Value::as_str).unwrap_or("").to_string();
        let name = |v: &Value| v.get("name").and_then(Value::as_str).unwrap_or("?").to_string();
        for (key, kind) in [("docs", "doc"), ("fileRefs", "file")] {
            for e in folder.get(key).and_then(Value::as_array).into_iter().flatten() {
                out.push((format!("{prefix}{}", name(e)), kind, id(e)));
            }
        }
        for f in folder.get("folders").and_then(Value::as_array).into_iter().flatten() {
            let path = format!("{prefix}{}/", name(f));
            out.push((path.clone(), "folder", id(f)));
            walk(f, &path, out);
        }
    }
    let mut out = vec![];
    for root in project.get("rootFolder").and_then(Value::as_array).into_iter().flatten() {
        walk(root, "", &mut out);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::encode_packed;

    #[test]
    fn join_doc_classic_decodes_lines_and_ranges() {
        let r = vec![
            json!([encode_packed("\\section{Größe}"), "x"]),
            json!(42),
            json!([]),
            json!({"comments": [{"id": "c1", "op": {"p": 9, "c": encode_packed("Größe"), "t": "t1"}}],
                   "changes": [{"id": "x1", "op": {"p": 0, "i": encode_packed("ü")}}]}),
            json!("sharejs-text-ot"),
            json!({"canSkipLeaveDoc": true}),
        ];
        let d = parse_join_doc(r).unwrap();
        assert_eq!(d.text(), "\\section{Größe}\nx");
        assert_eq!(d.version, 42);
        assert_eq!(d.ot_type, OtType::ShareJsTextOt);
        assert!(d.can_skip_leave_doc);
        assert_eq!(d.ranges["comments"][0]["op"]["c"], "Größe");
        assert_eq!(d.ranges["changes"][0]["op"]["i"], "ü");
    }

    #[test]
    fn join_doc_history_ot_lines_raw() {
        let r = vec![json!(["Größe"]), json!(3), json!(null), json!({}), json!("history-ot")];
        let d = parse_join_doc(r).unwrap();
        assert_eq!(d.text(), "Größe");
        assert_eq!(d.ot_type, OtType::HistoryOt);
    }

    #[test]
    fn join_doc_history_ot_snapshot() {
        // Recorded from CE 6.3.0.
        let r: Vec<Value> = serde_json::from_str(
            r#"[{"content":"\\documentclass{article}\nGröße\n"},0,[],{},"history-ot",{"canSkipLeaveDoc":true}]"#,
        )
        .unwrap();
        let d = parse_join_doc(r).unwrap();
        assert_eq!(d.text(), "\\documentclass{article}\nGröße\n");
        assert_eq!(d.ot_type, OtType::HistoryOt);
        assert!(d.history_snapshot.is_some());
    }

    #[test]
    fn join_doc_catch_up_ops() {
        let r = vec![
            json!(["a"]),
            json!(5),
            json!([{"doc": "d", "v": 4, "op": [{"p": 0, "i": "a"}], "meta": {"source": "P.x", "user_id": "u"}}]),
            json!({}),
            json!("sharejs-text-ot"),
        ];
        let d = parse_join_doc(r).unwrap();
        assert_eq!(d.ops.len(), 1);
        assert_eq!(d.ops[0].source(), Some("P.x"));
    }

    #[test]
    fn unknown_type_fails_safe() {
        let r = vec![json!(["a"]), json!(1), json!([]), json!({}), json!("crdt-9000")];
        assert!(parse_join_doc(r).is_err());
    }

    #[test]
    fn ack_errors() {
        assert_eq!(ack_ok(vec![json!(null), json!(1)], "m").unwrap(), vec![json!(1)]);
        assert!(matches!(
            ack_ok(vec![json!({"message": "doc updater could not load requested ops"})], "joinDoc"),
            Err(Error::MissingOps)
        ));
        match ack_ok(vec![json!({"message": "client does not support history-ot", "code": "x"})], "joinDoc") {
            Err(Error::Server { message, code, .. }) => {
                assert_eq!(message, "client does not support history-ot");
                assert_eq!(code.as_deref(), Some("x"));
            }
            r => panic!("{r:?}"),
        }
    }

    #[test]
    fn outgoing_update_has_only_allowed_fields() {
        let u = OutgoingUpdate {
            doc: "d".into(),
            op: json!([{"p": 0, "i": "x"}]),
            v: 3,
            last_v: None,
            hash: None,
            meta: None,
            dup_if_source: Some(vec!["P.a".into()]),
        };
        assert_eq!(
            serde_json::to_value(&u).unwrap(),
            json!({"doc": "d", "op": [{"p": 0, "i": "x"}], "v": 3, "dupIfSource": ["P.a"]})
        );
    }

    #[test]
    fn tree() {
        let p = json!({"rootFolder": [{"_id": "r", "name": "rootFolder",
            "docs": [{"_id": "d1", "name": "main.tex"}],
            "fileRefs": [{"_id": "f1", "name": "fig.png"}],
            "folders": [{"_id": "s", "name": "sec", "docs": [{"_id": "d2", "name": "a.tex"}], "fileRefs": [], "folders": []}]}]});
        let t = file_tree(&p);
        assert_eq!(
            t,
            vec![
                ("main.tex".into(), "doc", "d1".into()),
                ("fig.png".into(), "file", "f1".into()),
                ("sec/".into(), "folder", "s".into()),
                ("sec/a.tex".into(), "doc", "d2".into()),
            ]
        );
    }
}
