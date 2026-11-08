//! Overleaf's real-time protocol, as the browser editor speaks it. See `docs/protocol.md`.
//!
//! Layers, bottom up: [`sio`] (socket.io 0.9 frames), [`socket`] (one WebSocket connection), [`http`] (login and
//! REST), [`project`] (join a project and its docs), [`doc`] (send state for one doc).

pub mod doc;
#[cfg(feature = "fake")]
pub mod fake;
pub mod history;
pub mod http;
pub mod project;
pub mod rest;
pub mod sio;
pub mod socket;
pub mod text;
pub mod tree;

pub use doc::{Applied, DocError, DocSync};
pub use http::Http;
pub use project::{file_tree, JoinedDoc, OtType, OutgoingUpdate, ProjectConn, ServerEvent, Style, Update};
pub use rest::{blob_hash, Kind, Uploaded};
pub use tree::{Tree, TreeChange};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("http: {0}")]
    Http(String),
    #[error("login failed: {0}")]
    Login(String),
    #[error("socket.io handshake: {0}")]
    Handshake(String),
    #[error("project connection rejected: {0}")]
    Rejected(String),
    #[error("connection closed")]
    Closed,
    #[error("no answer to {0}")]
    Timeout(String),
    #[error("{method}: server error: {message}")]
    Server { method: String, message: String, code: Option<String> },
    /// `joinDoc(fromVersion)` asked for ops the server no longer has. Do a full join and rebase.
    #[error("server no longer has the requested ops")]
    MissingOps,
    #[error("unexpected answer from server: {0}")]
    Protocol(String),
    #[error(transparent)]
    Doc(#[from] DocError),
}

impl From<reqwest::Error> for Error {
    fn from(e: reqwest::Error) -> Self {
        Error::Http(e.to_string())
    }
}
impl From<url::ParseError> for Error {
    fn from(e: url::ParseError) -> Self {
        Error::Http(e.to_string())
    }
}
impl From<tokio_tungstenite::tungstenite::Error> for Error {
    fn from(e: tokio_tungstenite::tungstenite::Error) -> Self {
        Error::Handshake(e.to_string())
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::Protocol(e.to_string())
    }
}
