//! A socket.io 0.9 client over WebSocket.
//!
//! [`Socket::connect`] does the handshake GET, opens the WebSocket, and starts a reader task and a writer task. The
//! reader answers heartbeats, resolves acks, and passes everything else on as [`Incoming`].

use crate::sio::{Frame, Handshake};
use crate::Error;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use url::Url;

/// What the reader passes on.
#[derive(Debug, Clone, PartialEq)]
pub enum Incoming {
    /// The server's `1::`.
    Connect,
    Event { name: String, args: Vec<Value> },
    /// The connection ended. No more events follow.
    Closed { reason: String },
}

/// Settings for one connection.
#[derive(Debug, Clone)]
pub struct ConnectOptions {
    /// Query string pairs sent on the handshake and the WebSocket URL, such as `projectId`.
    pub query: Vec<(String, String)>,
    /// `Cookie` header value.
    pub cookie: Option<String>,
    /// How long to wait for an ack before giving up on a call.
    pub call_timeout: Duration,
    /// Path of the socket.io resource, `socket.io` on Overleaf.
    pub resource: String,
}

impl Default for ConnectOptions {
    fn default() -> Self {
        ConnectOptions {
            query: vec![],
            cookie: None,
            call_timeout: Duration::from_secs(30),
            resource: "socket.io".into(),
        }
    }
}

type AckMap = HashMap<u64, oneshot::Sender<Vec<Value>>>;

struct Inner {
    out: mpsc::UnboundedSender<Message>,
    acks: Mutex<AckMap>,
    next_id: AtomicU64,
    closed: AtomicBool,
    call_timeout: Duration,
}

/// A connected socket. Cheap to clone; all clones share the connection.
#[derive(Clone)]
pub struct Socket {
    inner: Arc<Inner>,
    pub handshake: Handshake,
}

impl Socket {
    /// Handshake with `base` (such as `http://localhost:8800`) and open the WebSocket.
    pub async fn connect(
        http: &reqwest::Client,
        base: &Url,
        opts: ConnectOptions,
    ) -> Result<(Socket, mpsc::UnboundedReceiver<Incoming>), Error> {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let mut hs_url = base.join(&format!("{}/1/", opts.resource))?;
        {
            let mut q = hs_url.query_pairs_mut();
            for (k, v) in &opts.query {
                q.append_pair(k, v);
            }
            q.append_pair("t", &t.to_string());
        }
        let mut req = http.get(hs_url.clone());
        if let Some(c) = &opts.cookie {
            req = req.header(reqwest::header::COOKIE, c);
        }
        let resp = req.send().await?;
        let status = resp.status();
        let body = resp.text().await?;
        if !status.is_success() {
            return Err(Error::Handshake(format!("{status}: {}", body.chars().take(200).collect::<String>())));
        }
        let handshake = Handshake::parse(&body).map_err(|e| Error::Handshake(e.to_string()))?;
        tracing::debug!(sid = %handshake.sid, "socket.io handshake");
        if !handshake.transports.iter().any(|t| t == "websocket") {
            return Err(Error::Handshake(format!("server offers no websocket transport: {body}")));
        }

        let mut ws_url = base.join(&format!("{}/1/websocket/{}", opts.resource, handshake.sid))?;
        match ws_url.scheme() {
            "https" => ws_url.set_scheme("wss").ok(),
            _ => ws_url.set_scheme("ws").ok(),
        };
        {
            let mut q = ws_url.query_pairs_mut();
            for (k, v) in &opts.query {
                q.append_pair(k, v);
            }
        }
        let mut request = ws_url.as_str().into_client_request()?;
        if let Some(c) = &opts.cookie {
            request.headers_mut().insert(
                "Cookie",
                HeaderValue::from_str(c).map_err(|_| Error::Handshake("cookie is not a valid header".into()))?,
            );
        }
        // Overleaf checks Origin against its allowed origins when that setting is on.
        if let Ok(origin) = HeaderValue::from_str(base.origin().ascii_serialization().as_str()) {
            request.headers_mut().insert("Origin", origin);
        }
        let (ws, _) = tokio::time::timeout(Duration::from_secs(20), tokio_tungstenite::connect_async(request))
            .await
            .map_err(|_| Error::Timeout("websocket connect".into()))??;
        let (mut sink, mut stream) = ws.split();

        let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();
        let (in_tx, in_rx) = mpsc::unbounded_channel::<Incoming>();
        let inner = Arc::new(Inner {
            out: out_tx,
            acks: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            closed: AtomicBool::new(false),
            call_timeout: opts.call_timeout,
        });

        // Writer.
        tokio::spawn(async move {
            while let Some(m) = out_rx.recv().await {
                let is_close = matches!(m, Message::Close(_));
                if sink.send(m).await.is_err() || is_close {
                    break;
                }
            }
            let _ = sink.close().await;
        });

        // Reader. The server sends a heartbeat well inside `heartbeat_timeout`; silence for longer means it's gone.
        let reader_inner = inner.clone();
        let silence = match handshake.heartbeat_timeout {
            0 => Duration::from_secs(3600),
            s => Duration::from_secs(s + 5),
        };
        tokio::spawn(async move {
            let inner = reader_inner;
            let reason = loop {
                let msg = match tokio::time::timeout(silence, stream.next()).await {
                    Err(_) => break "no heartbeat from server".to_string(),
                    Ok(None) => break "connection closed".to_string(),
                    Ok(Some(Err(e))) => break format!("websocket error: {e}"),
                    Ok(Some(Ok(m))) => m,
                };
                let text = match msg {
                    Message::Text(t) => t,
                    Message::Close(c) => break format!("closed by server: {c:?}"),
                    _ => continue,
                };
                let frame = match Frame::parse(&text) {
                    Ok(f) => f,
                    Err(e) => {
                        tracing::warn!("{e}");
                        continue;
                    }
                };
                tracing::trace!(frame = %text, "recv");
                match frame {
                    Frame::Heartbeat => {
                        let _ = inner.out.send(Message::Text(Frame::Heartbeat.to_string()));
                    }
                    Frame::Connect => {
                        let _ = in_tx.send(Incoming::Connect);
                    }
                    Frame::Event { name, args, ack } => {
                        if ack.is_some() {
                            // Overleaf's server never asks the client for an ack.
                            tracing::warn!(%name, "server asked for an ack, ignoring");
                        }
                        let _ = in_tx.send(Incoming::Event { name, args });
                    }
                    Frame::Ack { id, args } => {
                        if let Some(tx) = inner.acks.lock().unwrap().remove(&id) {
                            let _ = tx.send(args);
                        }
                    }
                    Frame::Disconnect => break "server sent disconnect".to_string(),
                    Frame::Error { reason, advice } => {
                        break format!("socket.io error {reason}+{advice}");
                    }
                    Frame::Message(_) | Frame::Json(_) | Frame::Noop => {}
                }
            };
            inner.closed.store(true, Ordering::SeqCst);
            // Dropping the senders fails every pending call.
            inner.acks.lock().unwrap().clear();
            let _ = inner.out.send(Message::Close(None));
            let _ = in_tx.send(Incoming::Closed { reason });
        });

        Ok((Socket { inner, handshake }, in_rx))
    }

    pub fn is_closed(&self) -> bool {
        self.inner.closed.load(Ordering::SeqCst)
    }

    fn send_frame(&self, f: &Frame) -> Result<(), Error> {
        if self.is_closed() {
            return Err(Error::Closed);
        }
        let s = f.to_string();
        tracing::trace!(frame = %s, "send");
        self.inner.out.send(Message::Text(s)).map_err(|_| Error::Closed)
    }

    /// Emit an event without waiting for an answer.
    pub fn emit(&self, name: &str, args: Vec<Value>) -> Result<(), Error> {
        self.send_frame(&Frame::Event { name: name.into(), args, ack: None })
    }

    /// Emit an event and wait for the server's ack. Returns the ack's arguments as they came, error first.
    pub async fn call(&self, name: &str, args: Vec<Value>) -> Result<Vec<Value>, Error> {
        let id = self.inner.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.inner.acks.lock().unwrap().insert(id, tx);
        if let Err(e) = self.send_frame(&Frame::Event { name: name.into(), args, ack: Some(id) }) {
            self.inner.acks.lock().unwrap().remove(&id);
            return Err(e);
        }
        match tokio::time::timeout(self.inner.call_timeout, rx).await {
            Ok(Ok(args)) => Ok(args),
            Ok(Err(_)) => Err(Error::Closed),
            Err(_) => {
                self.inner.acks.lock().unwrap().remove(&id);
                Err(Error::Timeout(name.to_string()))
            }
        }
    }

    /// Send socket.io's disconnect and close.
    pub fn disconnect(&self) {
        let _ = self.send_frame(&Frame::Disconnect);
        self.inner.closed.store(true, Ordering::SeqCst);
        let _ = self.inner.out.send(Message::Close(None));
    }
}
