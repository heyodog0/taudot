//! socket.io 0.9 wire format.
//!
//! Every frame is `type:id:endpoint:data`. Overleaf only uses the default endpoint (empty). The types we meet:
//!
//! | type | meaning | example |
//! |---|---|---|
//! | 0 | disconnect | `0::` |
//! | 1 | connect | `1::` |
//! | 2 | heartbeat, echo it back | `2::` |
//! | 3 | plain message | `3:::hello` |
//! | 4 | JSON message | `4:::{"a":1}` |
//! | 5 | event, `{name, args}` | `5:1+::{"name":"joinDoc","args":["abc"]}` |
//! | 6 | ack, `id+[args]` | `6:::1+[null,["line"],3]` |
//! | 7 | error, `reason+advice` | `7:::1+0` |
//! | 8 | noop | `8::` |
//!
//! An id ending in `+` asks the other side to ack with data. The handshake is an HTTP GET to
//! `/socket.io/1/?<query>` that answers `sid:heartbeat:close:transports`.

use serde_json::Value;
use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum Frame {
    Disconnect,
    Connect,
    Heartbeat,
    Message(String),
    Json(Value),
    /// An event. `ack` is the message id when the sender wants a reply.
    Event { name: String, args: Vec<Value>, ack: Option<u64> },
    Ack { id: u64, args: Vec<Value> },
    Error { reason: String, advice: String },
    Noop,
}

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
#[error("bad socket.io frame: {reason}: {frame:?}")]
pub struct FrameError {
    pub reason: &'static str,
    pub frame: String,
}

fn bad(reason: &'static str, frame: &str) -> FrameError {
    FrameError { reason, frame: frame.chars().take(200).collect() }
}

impl Frame {
    pub fn parse(s: &str) -> Result<Frame, FrameError> {
        // Split into at most 4 parts; the data part may itself contain ':'.
        let mut parts = s.splitn(4, ':');
        let ty = parts.next().ok_or_else(|| bad("empty", s))?;
        let id = parts.next().unwrap_or("");
        let _endpoint = parts.next().unwrap_or("");
        let data = parts.next().unwrap_or("");
        match ty {
            "0" => Ok(Frame::Disconnect),
            "1" => Ok(Frame::Connect),
            "2" => Ok(Frame::Heartbeat),
            "3" => Ok(Frame::Message(data.to_string())),
            "4" => Ok(Frame::Json(serde_json::from_str(data).map_err(|_| bad("json", s))?)),
            "5" => {
                let v: Value = serde_json::from_str(data).map_err(|_| bad("event json", s))?;
                let name = v
                    .get("name")
                    .and_then(Value::as_str)
                    .ok_or_else(|| bad("event without name", s))?
                    .to_string();
                let args = match v.get("args") {
                    None | Some(Value::Null) => vec![],
                    Some(Value::Array(a)) => a.clone(),
                    Some(_) => return Err(bad("event args not a list", s)),
                };
                let ack = match id.strip_suffix('+') {
                    Some(n) => Some(n.parse().map_err(|_| bad("event id", s))?),
                    None if id.is_empty() => None,
                    // An id without '+' asks for a data-less ack. Overleaf never does this.
                    None => Some(id.parse().map_err(|_| bad("event id", s))?),
                };
                Ok(Frame::Event { name, args, ack })
            }
            "6" => {
                let (id, rest) = match data.split_once('+') {
                    Some((id, rest)) => (id, rest),
                    None => (data, ""),
                };
                let id = id.parse().map_err(|_| bad("ack id", s))?;
                let args = if rest.is_empty() {
                    vec![]
                } else {
                    match serde_json::from_str(rest).map_err(|_| bad("ack json", s))? {
                        Value::Array(a) => a,
                        _ => return Err(bad("ack args not a list", s)),
                    }
                };
                Ok(Frame::Ack { id, args })
            }
            "7" => {
                let (reason, advice) = data.split_once('+').unwrap_or((data, ""));
                Ok(Frame::Error { reason: reason.to_string(), advice: advice.to_string() })
            }
            "8" => Ok(Frame::Noop),
            _ => Err(bad("unknown type", s)),
        }
    }
}

impl fmt::Display for Frame {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Frame::Disconnect => write!(f, "0::"),
            Frame::Connect => write!(f, "1::"),
            Frame::Heartbeat => write!(f, "2::"),
            Frame::Message(m) => write!(f, "3:::{m}"),
            Frame::Json(v) => write!(f, "4:::{v}"),
            Frame::Event { name, args, ack } => {
                let body = serde_json::json!({ "name": name, "args": args });
                match ack {
                    Some(id) => write!(f, "5:{id}+::{body}"),
                    None => write!(f, "5:::{body}"),
                }
            }
            Frame::Ack { id, args } => write!(f, "6:::{id}+{}", Value::Array(args.clone())),
            Frame::Error { reason, advice } => write!(f, "7:::{reason}+{advice}"),
            Frame::Noop => write!(f, "8::"),
        }
    }
}

/// The answer to the handshake GET.
#[derive(Debug, Clone, PartialEq)]
pub struct Handshake {
    pub sid: String,
    /// Seconds. Zero means the server sends no heartbeats.
    pub heartbeat_timeout: u64,
    pub close_timeout: u64,
    pub transports: Vec<String>,
}

impl Handshake {
    pub fn parse(body: &str) -> Result<Handshake, FrameError> {
        let mut p = body.trim().split(':');
        let sid = p.next().filter(|s| !s.is_empty()).ok_or_else(|| bad("handshake sid", body))?;
        let num = |x: Option<&str>| x.unwrap_or("").parse::<u64>().unwrap_or(0);
        let heartbeat_timeout = num(p.next());
        let close_timeout = num(p.next());
        let transports = p.next().unwrap_or("").split(',').filter(|s| !s.is_empty()).map(String::from).collect();
        Ok(Handshake { sid: sid.to_string(), heartbeat_timeout, close_timeout, transports })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn control_frames() {
        assert_eq!(Frame::parse("1::").unwrap(), Frame::Connect);
        assert_eq!(Frame::parse("2::").unwrap(), Frame::Heartbeat);
        assert_eq!(Frame::parse("0::").unwrap(), Frame::Disconnect);
        assert_eq!(Frame::parse("8::").unwrap(), Frame::Noop);
        assert_eq!(Frame::Heartbeat.to_string(), "2::");
    }

    #[test]
    fn event_from_server_without_ack() {
        let f = Frame::parse(r#"5:::{"name":"otUpdateApplied","args":[{"v":4,"doc":"abc"}]}"#).unwrap();
        assert_eq!(
            f,
            Frame::Event { name: "otUpdateApplied".into(), args: vec![json!({"v":4,"doc":"abc"})], ack: None }
        );
    }

    #[test]
    fn event_data_with_colons() {
        let f = Frame::parse(r#"5:::{"name":"x","args":["a:b:c"]}"#).unwrap();
        assert_eq!(f, Frame::Event { name: "x".into(), args: vec![json!("a:b:c")], ack: None });
    }

    #[test]
    fn event_with_ack_round_trips() {
        let f = Frame::Event { name: "joinDoc".into(), args: vec![json!("d1"), json!(-1)], ack: Some(7) };
        let s = f.to_string();
        assert_eq!(s, r#"5:7+::{"args":["d1",-1],"name":"joinDoc"}"#);
        assert_eq!(Frame::parse(&s).unwrap(), f);
    }

    #[test]
    fn ack_with_args() {
        let f = Frame::parse(r#"6:::3+[null,["a","b"],12,[],{},"sharejs-text-ot",{"canSkipLeaveDoc":true}]"#).unwrap();
        match f {
            Frame::Ack { id, args } => {
                assert_eq!(id, 3);
                assert_eq!(args.len(), 7);
                assert_eq!(args[2], json!(12));
            }
            _ => panic!("{f:?}"),
        }
    }

    #[test]
    fn ack_without_args() {
        assert_eq!(Frame::parse("6:::9").unwrap(), Frame::Ack { id: 9, args: vec![] });
    }

    #[test]
    fn error_frame() {
        assert_eq!(
            Frame::parse("7:::1+0").unwrap(),
            Frame::Error { reason: "1".into(), advice: "0".into() }
        );
    }

    #[test]
    fn rejects_junk() {
        assert!(Frame::parse("9::").is_err());
        assert!(Frame::parse("5:::notjson").is_err());
        assert!(Frame::parse("6:::x+[]").is_err());
    }

    #[test]
    fn handshake() {
        let h = Handshake::parse("Ab_cD-ef:60:60:websocket,xhr-polling").unwrap();
        assert_eq!(h.sid, "Ab_cD-ef");
        assert_eq!(h.heartbeat_timeout, 60);
        assert_eq!(h.transports, vec!["websocket", "xhr-polling"]);
        assert!(Handshake::parse("").is_err());
    }
}
