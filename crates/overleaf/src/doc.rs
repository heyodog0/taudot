//! Per-doc send state: one update in flight, later edits queued, confirmation on `otUpdateApplied`, resend with
//! `dupIfSource`, catch-up after a reconnect. Mirrors the browser's `share-js-doc.ts`.
//!
//! No I/O here, so every path is unit-tested. Ops are raw JSON until `crates/ot` lands. Transforming local edits
//! against concurrent remote ones needs that crate, so for now a remote op that arrives while we have unconfirmed
//! edits is reported as [`DocError::NeedsTransform`] and the caller stops writing (fail safe).

use crate::project::{OtType, OutgoingUpdate, Update};
use serde_json::Value;
use std::time::{Duration, Instant};

/// The browser resends after 5 s without a confirmation (`INFLIGHT_OP_TIMEOUT` in `share-js-doc.ts`).
pub const RESEND_AFTER: Duration = Duration::from_secs(5);

#[derive(Debug, Clone)]
pub struct Inflight {
    pub op: Value,
    /// The doc version the op was made against.
    pub v: u64,
    /// Every connection public ID this op was sent under, oldest first.
    pub sent_under: Vec<String>,
    pub sent_at: Instant,
    /// Set after a reconnect; resend at once.
    pub must_resend: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Applied {
    /// Our in-flight update was confirmed. The doc is now at `version`.
    Confirmed { version: u64 },
    /// Someone else's op, to apply to our copy. The doc is now at `version`.
    Remote { op: Value, version: u64, update: Update },
    /// Not for this doc, already seen, or queued until earlier versions arrive.
    Ignored,
}

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum DocError {
    #[error("remote op at v{v} arrived while we have unconfirmed edits; transforms need crates/ot")]
    NeedsTransform { v: u64 },
    #[error("confirmation for v{got}, expected v{want}")]
    BadConfirm { got: u64, want: u64 },
    #[error("confirmation with nothing in flight (v{v})")]
    UnexpectedConfirm { v: u64 },
}

#[derive(Debug)]
pub struct DocSync {
    pub doc_id: String,
    pub ot_type: OtType,
    /// The server version our copy matches.
    pub version: u64,
    pub inflight: Option<Inflight>,
    /// Edits not yet sent, oldest first.
    pub pending: Vec<Value>,
    /// Remote updates that arrived ahead of `version`.
    out_of_order: Vec<Update>,
}

impl DocSync {
    pub fn new(doc_id: &str, ot_type: OtType, version: u64) -> DocSync {
        DocSync { doc_id: doc_id.into(), ot_type, version, inflight: None, pending: vec![], out_of_order: vec![] }
    }

    pub fn is_idle(&self) -> bool {
        self.inflight.is_none() && self.pending.is_empty()
    }

    /// Queue a local op. Both formats send a list of components (`sharejs-text-ot`) or edit operations
    /// (`history-ot`) that apply in order.
    pub fn submit(&mut self, op: Value) {
        self.pending.push(op);
    }

    /// The next update to send, if nothing is in flight. Pending ops are concatenated, which is composition for
    /// both formats since each is a list applied in order.
    pub fn take_next(&mut self, now: Instant, public_id: &str) -> Option<OutgoingUpdate> {
        if self.inflight.is_some() || self.pending.is_empty() {
            return None;
        }
        let mut parts = vec![];
        for p in self.pending.drain(..) {
            match p {
                Value::Array(a) => parts.extend(a),
                other => parts.push(other),
            }
        }
        let op = Value::Array(parts);
        self.inflight = Some(Inflight {
            op: op.clone(),
            v: self.version,
            sent_under: vec![public_id.to_string()],
            sent_at: now,
            must_resend: false,
        });
        Some(OutgoingUpdate {
            doc: self.doc_id.clone(),
            op,
            v: self.version,
            last_v: None,
            hash: None,
            meta: None,
            dup_if_source: None,
        })
    }

    /// The in-flight update again, if it's due: unconfirmed for [`RESEND_AFTER`], or sent before a reconnect.
    /// `dupIfSource` lists the current connection first, then every earlier one, as the browser does.
    pub fn resend_due(&mut self, now: Instant, public_id: &str) -> Option<OutgoingUpdate> {
        let doc = self.doc_id.clone();
        let f = self.inflight.as_mut()?;
        if !f.must_resend && now.duration_since(f.sent_at) < RESEND_AFTER {
            return None;
        }
        let mut dup = vec![public_id.to_string()];
        dup.extend(f.sent_under.iter().filter(|s| *s != public_id).cloned());
        if !f.sent_under.iter().any(|s| s == public_id) {
            f.sent_under.push(public_id.to_string());
        }
        f.sent_at = now;
        f.must_resend = false;
        Some(OutgoingUpdate {
            doc,
            op: f.op.clone(),
            v: f.v,
            last_v: None,
            hash: None,
            meta: None,
            dup_if_source: Some(dup),
        })
    }

    /// Call after reconnecting, before the catch-up `joinDoc`.
    pub fn on_reconnect(&mut self) {
        if let Some(f) = self.inflight.as_mut() {
            f.must_resend = true;
        }
    }

    /// Handle one `otUpdateApplied` (or one catch-up op from `joinDoc`). Remote ops ahead of our version are held
    /// back and come out of later calls through [`DocSync::drain_ready`].
    pub fn on_update(&mut self, u: Update) -> Result<Applied, DocError> {
        if u.doc != self.doc_id {
            return Ok(Applied::Ignored);
        }
        let ours = match (&self.inflight, u.source()) {
            (Some(f), Some(src)) => f.sent_under.iter().any(|s| s == src),
            _ => false,
        };
        if u.op.is_none() || ours {
            // A confirmation: the sender gets only {doc, v}; a catch-up op from one of our earlier connections is
            // our own op coming back.
            let Some(f) = &self.inflight else {
                return Err(DocError::UnexpectedConfirm { v: u.v });
            };
            if u.v < self.version && ours {
                return Ok(Applied::Ignored);
            }
            if u.v != self.version {
                return Err(DocError::BadConfirm { got: u.v, want: self.version });
            }
            let _ = f;
            self.inflight = None;
            self.version += 1;
            return Ok(Applied::Confirmed { version: self.version });
        }
        if u.v < self.version {
            return Ok(Applied::Ignored);
        }
        if u.v > self.version {
            self.out_of_order.push(u);
            return Ok(Applied::Ignored);
        }
        if !self.is_idle() {
            return Err(DocError::NeedsTransform { v: u.v });
        }
        self.version += 1;
        let op = u.op.clone().unwrap_or(Value::Null);
        Ok(Applied::Remote { op, version: self.version, update: u })
    }

    /// Held-back updates that are now next in line.
    pub fn drain_ready(&mut self) -> Result<Vec<Applied>, DocError> {
        let mut out = vec![];
        loop {
            let Some(i) = self.out_of_order.iter().position(|u| u.v == self.version) else { break };
            let u = self.out_of_order.remove(i);
            out.push(self.on_update(u)?);
        }
        self.out_of_order.retain(|u| u.v > self.version);
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn confirm(v: u64) -> Update {
        Update { doc: "d".into(), v, op: None, meta: None, last_v: None, hash: None, dup: None }
    }
    fn remote(v: u64, source: &str) -> Update {
        Update {
            doc: "d".into(),
            v,
            op: Some(json!([{"p": 0, "i": "r"}])),
            meta: Some(json!({"source": source, "user_id": "u2"})),
            last_v: None,
            hash: None,
            dup: None,
        }
    }

    #[test]
    fn send_and_confirm() {
        let mut d = DocSync::new("d", OtType::ShareJsTextOt, 10);
        let t0 = Instant::now();
        d.submit(json!([{"p": 0, "i": "a"}]));
        d.submit(json!([{"p": 1, "i": "b"}]));
        let u = d.take_next(t0, "P.1").unwrap();
        assert_eq!(u.v, 10);
        assert_eq!(u.op, json!([{"p": 0, "i": "a"}, {"p": 1, "i": "b"}]));
        // One in flight at a time.
        d.submit(json!([{"p": 2, "i": "c"}]));
        assert!(d.take_next(t0, "P.1").is_none());
        assert_eq!(d.on_update(confirm(10)).unwrap(), Applied::Confirmed { version: 11 });
        let u = d.take_next(t0, "P.1").unwrap();
        assert_eq!(u.v, 11);
    }

    #[test]
    fn confirm_without_inflight_is_an_error() {
        let mut d = DocSync::new("d", OtType::ShareJsTextOt, 1);
        assert!(d.on_update(confirm(1)).is_err());
    }

    #[test]
    fn other_docs_are_ignored() {
        let mut d = DocSync::new("d", OtType::ShareJsTextOt, 1);
        let mut u = remote(1, "P.x");
        u.doc = "other".into();
        assert_eq!(d.on_update(u).unwrap(), Applied::Ignored);
        assert_eq!(d.version, 1);
    }

    #[test]
    fn resend_after_timeout_with_dup_if_source() {
        let mut d = DocSync::new("d", OtType::ShareJsTextOt, 3);
        let t0 = Instant::now();
        d.submit(json!([{"p": 0, "i": "a"}]));
        d.take_next(t0, "P.1").unwrap();
        assert!(d.resend_due(t0 + Duration::from_secs(1), "P.1").is_none());
        let r = d.resend_due(t0 + RESEND_AFTER, "P.1").unwrap();
        assert_eq!(r.v, 3);
        assert_eq!(r.dup_if_source, Some(vec!["P.1".to_string()]));
    }

    #[test]
    fn resend_after_reconnect_lists_every_connection() {
        let mut d = DocSync::new("d", OtType::ShareJsTextOt, 3);
        let t0 = Instant::now();
        d.submit(json!([{"p": 0, "i": "a"}]));
        d.take_next(t0, "P.1").unwrap();
        d.on_reconnect();
        let r = d.resend_due(t0, "P.2").unwrap();
        assert_eq!(r.dup_if_source, Some(vec!["P.2".to_string(), "P.1".to_string()]));
        d.on_reconnect();
        let r = d.resend_due(t0, "P.3").unwrap();
        assert_eq!(r.dup_if_source, Some(vec!["P.3".to_string(), "P.1".to_string(), "P.2".to_string()]));
    }

    #[test]
    fn catch_up_op_from_earlier_connection_confirms() {
        // We sent under P.1, got disconnected before the confirmation. joinDoc(fromVersion) returns our op with
        // meta.source P.1.
        let mut d = DocSync::new("d", OtType::ShareJsTextOt, 3);
        d.submit(json!([{"p": 0, "i": "a"}]));
        d.take_next(Instant::now(), "P.1").unwrap();
        d.on_reconnect();
        assert_eq!(d.on_update(remote(3, "P.1")).unwrap(), Applied::Confirmed { version: 4 });
        assert!(d.resend_due(Instant::now(), "P.2").is_none());
    }

    #[test]
    fn remote_ops_apply_in_order() {
        let mut d = DocSync::new("d", OtType::ShareJsTextOt, 5);
        assert_eq!(d.on_update(remote(6, "P.x")).unwrap(), Applied::Ignored);
        assert_eq!(d.version, 5);
        match d.on_update(remote(5, "P.x")).unwrap() {
            Applied::Remote { version, .. } => assert_eq!(version, 6),
            a => panic!("{a:?}"),
        }
        let ready = d.drain_ready().unwrap();
        assert_eq!(ready.len(), 1);
        assert_eq!(d.version, 7);
        // Already seen.
        assert_eq!(d.on_update(remote(5, "P.x")).unwrap(), Applied::Ignored);
    }

    #[test]
    fn remote_op_during_inflight_fails_safe() {
        let mut d = DocSync::new("d", OtType::ShareJsTextOt, 5);
        d.submit(json!([{"p": 0, "i": "a"}]));
        d.take_next(Instant::now(), "P.1").unwrap();
        assert_eq!(d.on_update(remote(5, "P.x")), Err(DocError::NeedsTransform { v: 5 }));
    }
}
