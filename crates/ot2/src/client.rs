//! One document's client state, in the classic format: the server's text at a version, one op in flight and the
//! edits made since (pending). This is the state machine of ShareJS 0.6's client `Doc` (MIT, Joseph Gentle:
//! `src/client/doc.coffee`), with the additions `docs/protocol.md` lists: confirmations by `{v}` only, resends with
//! `dupIfSource`, catch-up after a reconnect, out-of-order updates held until their version comes up, and a rebase
//! after a full rejoin. No I/O: the caller sends what [`Client::flush`] returns and feeds back what the server says.

use std::collections::BTreeMap;

use crate::diff::diff;
use crate::text::{self, Op, Side};
use crate::OtError;

/// What to send with `applyOtUpdate`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outgoing {
    pub op: Op,
    /// The version the op was made against.
    pub v: u64,
    /// Connection IDs this op was sent under before. Send as `dupIfSource` when not empty.
    pub dup_if_source: Vec<String>,
}

/// An update from the server for this document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Incoming {
    pub v: u64,
    /// `None` for a confirmation of our own op (`otUpdateApplied` with only `{v, doc}`).
    pub op: Option<Op>,
    /// `meta.source`, the connection that sent it.
    pub source: Option<String>,
}

/// What the caller should do after an update.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Our inflight op is confirmed. Call [`Client::flush`] to send the pending one.
    Confirmed,
    /// Someone else's edit, transformed to apply to the text the user sees now.
    Remote(Op),
}

/// Client state for one document in the classic format.
#[derive(Debug, Clone)]
pub struct Client {
    server: String,
    version: u64,
    inflight: Option<Op>,
    sent_under: Vec<String>,
    pending: Option<Op>,
    text: String,
    queue: BTreeMap<u64, Incoming>,
}

/// Positions the user's cursor should move to after a remote op. Inserts at the cursor push it along.
pub fn transform_cursor(pos: usize, op: &Op) -> usize {
    text::transform_position(pos, op, Side::Right)
}

impl Client {
    /// A client for a document just joined at `version` with `text`.
    pub fn new(text: impl Into<String>, version: u64) -> Self {
        let text = text.into();
        Client {
            server: text.clone(),
            version,
            inflight: None,
            sent_under: Vec::new(),
            pending: None,
            text,
            queue: BTreeMap::new(),
        }
    }

    /// A client restored from a backup: the server's `base` text at `version`, an op that was in flight under the
    /// connections `sent_under`, and a pending op on top. Feed it the catch-up ops from `joinDoc(version)` next; one
    /// whose source is in `sent_under` confirms the inflight op, as after a reconnect.
    pub fn restore(
        base: impl Into<String>,
        version: u64,
        inflight: Option<(Op, Vec<String>)>,
        pending: Option<Op>,
    ) -> Result<Self, OtError> {
        let mut c = Client::new(base, version);
        if let Some((op, sources)) = inflight {
            c.text = text::apply(&c.text, &op)?;
            c.inflight = Some(op);
            c.sent_under = sources;
        }
        if let Some(op) = pending {
            c.text = text::apply(&c.text, &op)?;
            c.pending = Some(op);
        }
        Ok(c)
    }

    /// The connections the inflight op was sent under, oldest first.
    pub fn inflight_sources(&self) -> &[String] {
        &self.sent_under
    }

    /// The text the user sees, with all local edits.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// The server's text at [`Client::version`].
    pub fn server_text(&self) -> &str {
        &self.server
    }

    pub fn version(&self) -> u64 {
        self.version
    }

    pub fn inflight(&self) -> Option<&Op> {
        self.inflight.as_ref()
    }

    pub fn pending(&self) -> Option<&Op> {
        self.pending.as_ref()
    }

    /// Number of updates waiting for an earlier version to arrive.
    pub fn queued(&self) -> usize {
        self.queue.len()
    }

    /// True when every local edit is confirmed.
    pub fn is_idle(&self) -> bool {
        self.inflight.is_none() && self.pending.is_none()
    }

    /// Applies a local edit and queues it to be sent. The edit is normalized first, so empty components are dropped
    /// wherever they point.
    pub fn submit(&mut self, op: Op) -> Result<(), OtError> {
        let op = text::normalize(op);
        self.text = text::apply(&self.text, &op)?;
        let pending = match self.pending.take() {
            Some(p) => text::compose(&p, &op),
            None => op,
        };
        self.pending = if pending.is_empty() { None } else { Some(pending) };
        Ok(())
    }

    /// If nothing is in flight, moves the pending op in flight and returns it to send under connection `conn`.
    pub fn flush(&mut self, conn: &str) -> Option<Outgoing> {
        if self.inflight.is_some() {
            return None;
        }
        let op = self.pending.take()?;
        self.inflight = Some(op.clone());
        self.sent_under = vec![conn.to_owned()];
        Some(Outgoing { op, v: self.version, dup_if_source: Vec::new() })
    }

    /// The inflight op again, to resend under connection `conn` after a timeout or reconnect. Its `dup_if_source`
    /// lists every connection it was sent under, so the server won't apply it twice.
    pub fn resend(&mut self, conn: &str) -> Option<Outgoing> {
        let op = self.inflight.clone()?;
        if !self.sent_under.iter().any(|s| s == conn) {
            self.sent_under.push(conn.to_owned());
        }
        Some(Outgoing { op, v: self.version, dup_if_source: self.sent_under.clone() })
    }

    /// `otUpdateApplied` with only `{v}`: our inflight op is confirmed at version `v`.
    pub fn on_ack(&mut self, v: u64) -> Result<Vec<Event>, OtError> {
        self.receive(Incoming { v, op: None, source: None })
    }

    /// Someone's op at version `v`.
    pub fn on_remote(&mut self, op: Op, v: u64, source: Option<String>) -> Result<Vec<Event>, OtError> {
        self.receive(Incoming { v, op: Some(op), source })
    }

    /// Our inflight op is confirmed: it is now part of the server's text.
    fn confirm(&mut self) -> Result<Vec<Event>, OtError> {
        let op = self.inflight.take().ok_or(OtError::NothingInflight)?;
        self.server = text::apply(&self.server, &op)?;
        self.sent_under.clear();
        self.version += 1;
        Ok(vec![Event::Confirmed])
    }

    /// A remote op at the current version: apply it to the server text, transform it past our inflight and pending
    /// ops and them past it (the browser's `transformX(client, server)`), and show the result.
    fn apply_remote(&mut self, op: Op) -> Result<Vec<Event>, OtError> {
        self.server = text::apply(&self.server, &op)?;
        self.version += 1;
        let mut op = op;
        if let Some(inflight) = &self.inflight {
            let (i2, o2) = text::transform_x(inflight, &op)?;
            self.inflight = Some(i2);
            op = o2;
        }
        if let Some(pending) = &self.pending {
            let (p2, o2) = text::transform_x(pending, &op)?;
            self.pending = if p2.is_empty() { None } else { Some(p2) };
            op = o2;
        }
        self.text = text::apply(&self.text, &op)?;
        Ok(vec![Event::Remote(op)])
    }

    /// An update at the current version. A remote op sent under one of our inflight op's connections is that op's
    /// confirmation (as in ShareJS's `_onMessage`, and how catch-up confirms it).
    fn handle(&mut self, msg: Incoming) -> Result<Vec<Event>, OtError> {
        match msg.op {
            None => self.confirm(),
            Some(op) => {
                let ours = self.inflight.is_some() && msg.source.is_some_and(|s| self.sent_under.contains(&s));
                if ours {
                    self.confirm()
                } else {
                    self.apply_remote(op)
                }
            }
        }
    }

    /// Processes an update, and any queued ones it unblocks, in version order. An error means our copy has drifted
    /// from the server's: stop sending and [`Client::rebase`].
    pub fn receive(&mut self, msg: Incoming) -> Result<Vec<Event>, OtError> {
        if msg.v > self.version {
            self.queue.insert(msg.v, msg);
            return Ok(Vec::new());
        }
        // One below our version was already counted: a duplicate's confirmation carries the original op's version
        // (protocol.md), and the browser drops such updates.
        let mut events = if msg.v == self.version { self.handle(msg)? } else { Vec::new() };
        events.extend(self.drain()?);
        Ok(events)
    }

    /// Handles queued updates whose version has come up, and drops ones already passed.
    fn drain(&mut self) -> Result<Vec<Event>, OtError> {
        let mut events = Vec::new();
        loop {
            let Some((&v, _)) = self.queue.first_key_value() else { break };
            if v > self.version {
                break;
            }
            let msg = self.queue.remove(&v).expect("present");
            if v == self.version {
                events.extend(self.handle(msg)?);
            }
        }
        Ok(events)
    }

    /// Applies ops fetched with `joinDoc(fromVersion = version())`, in order. Like the browser's `catchUp`, each is
    /// taken to be at the current version.
    pub fn catch_up(&mut self, updates: Vec<(Op, Option<String>)>) -> Result<Vec<Event>, OtError> {
        let mut events = Vec::new();
        for (op, source) in updates {
            events.extend(self.handle(Incoming { v: self.version, op: Some(op), source })?);
        }
        events.extend(self.drain()?);
        Ok(events)
    }

    /// Carries unconfirmed edits onto a fresh copy of the document, after a full rejoin that returned `text` at
    /// `version` but not the ops in between. Returns the op that turns the text the user sees now into the new one.
    /// Afterwards [`Client::flush`] sends all unconfirmed edits as one new op.
    ///
    /// `inflight_applied` says whether the server applied our inflight op before we lost track. Pass `None` if
    /// unknown; then [`Client::inflight_seems_applied`] decides, which is a guess. With nothing in flight it is
    /// ignored.
    ///
    /// The server's changes are recovered by a character diff, so a local edit inside a region the server rewrote
    /// can land at the edge of that region. It is never dropped.
    pub fn rebase(&mut self, text: &str, version: u64, inflight_applied: Option<bool>) -> Result<Op, OtError> {
        let applied = match &self.inflight {
            None => false,
            Some(_) => inflight_applied.unwrap_or_else(|| self.inflight_seems_applied(text)),
        };
        // The server's text before its unknown changes, and our edits on top of it.
        let inflight = self.inflight.take().unwrap_or_default();
        let pending = self.pending.take().unwrap_or_default();
        let (base, local) = if applied {
            (text::apply(&self.server, &inflight)?, pending)
        } else {
            (self.server.clone(), text::compose(&inflight, &pending))
        };
        // Their changes, recovered by a diff, and ours carried past them with ours first at equal positions, as the
        // server would. Their side, transformed past ours, is what the user's screen needs.
        let theirs = diff(&base, text);
        let (local2, change) = text::transform_x(&local, &theirs)?;
        let shown = text::apply(text, &local2)?;
        self.server = text.to_owned();
        self.version = version;
        self.sent_under.clear();
        self.queue.clear();
        self.text = shown;
        self.pending = if local2.is_empty() { None } else { Some(local2) };
        Ok(change)
    }

    /// Like [`Client::rebase`] when the inflight op is not in `text`, but it stays in flight (carried past the
    /// server's changes) under the connections it was sent under, rather than joining the pending op. Its resend then
    /// carries `dupIfSource`, so if the first send is still queued on the server and applied later, the resend is
    /// dropped as a duplicate instead of applying the edit twice. Afterwards resend it ([`Client::resend`]).
    pub fn rebase_keeping_inflight(&mut self, text: &str, version: u64) -> Result<Op, OtError> {
        let inflight = self.inflight.take().unwrap_or_default();
        let pending = self.pending.take().unwrap_or_default();
        let theirs = diff(&self.server, text);
        let (inflight2, theirs1) = text::transform_x(&inflight, &theirs)?;
        let (pending2, change) = text::transform_x(&pending, &theirs1)?;
        self.text = text::apply(&text::apply(text, &inflight2)?, &pending2)?;
        self.server = text.to_owned();
        self.version = version;
        self.queue.clear();
        if inflight2.is_empty() {
            self.sent_under.clear();
        } else {
            self.inflight = Some(inflight2);
        }
        self.pending = if pending2.is_empty() { None } else { Some(pending2) };
        Ok(change)
    }

    /// A guess at whether the server applied the inflight op, from whether the fresh `text` is closer to our base
    /// with it than without it.
    pub fn inflight_seems_applied(&self, text: &str) -> bool {
        let Some(inflight) = &self.inflight else { return false };
        let Ok(with) = text::apply(&self.server, inflight) else { return false };
        distance(&with, text) < distance(&self.server, text)
    }
}

/// How many characters a character diff inserts and deletes between two texts.
fn distance(a: &str, b: &str) -> usize {
    diff(a, b)
        .iter()
        .map(|c| match c {
            text::Component::Insert { i, .. } => i.chars().count(),
            text::Component::Delete { d, .. } => d.chars().count(),
            text::Component::Comment { .. } => 0,
        })
        .sum()
}
