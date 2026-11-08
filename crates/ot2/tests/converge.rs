//! Three simulated clients edit one document through a simulated Overleaf server, with random interleaving, delayed and
//! reordered delivery, timeouts and resends with `dupIfSource`, dropped connections with catch-up, and full rejoins
//! with rebase. Pass condition: once everything is delivered, every client and the server hold the same text.
//!
//! The server follows Overleaf's document updater: it transforms an incoming op as the left side against every op
//! since the op's version, rejects a resend whose earlier copy it already applied (`dupIfSource`) and only confirms it,
//! confirms to the sender with `{v}` and sends the full op to everyone else
//! (`services/document-updater/app/js/sharejs/server/model.js`, `ShareJsUpdateManager.js`,
//! `services/real-time/app/js/DocumentUpdaterController.js`).

mod common;

use std::collections::VecDeque;

use common::{random_op, random_text, Rng};
use ot2::client::{Client, Event, Incoming};
use ot2::text::{self, Op, Side};
use proptest::prelude::*;

struct Update {
    op: Op,
    v: u64,
    dup_if_source: Vec<String>,
    source: String,
}

struct Server {
    text: String,
    log: Vec<(Op, String)>,
}

impl Server {
    fn version(&self) -> u64 {
        self.log.len() as u64
    }

    /// Returns `(source, ack version, applied op)`; the op is `None` for a duplicate that is only confirmed.
    fn receive(&mut self, u: Update) -> (String, u64, Option<Op>) {
        assert!(u.v <= self.version(), "op from the future");
        let mut op = u.op;
        let mut v = u.v;
        for (old, src) in &self.log[u.v as usize..] {
            if u.dup_if_source.contains(src) {
                return (u.source, v, None);
            }
            op = text::transform(&op, old, Side::Left).expect("server transform");
            v += 1;
        }
        self.text = text::apply(&self.text, &op).expect("server apply");
        self.log.push((op.clone(), u.source.clone()));
        (u.source, v, Some(op))
    }
}

struct Peer {
    client: Client,
    conn: String,
    /// Every connection this peer has had, to tell whether the server applied its inflight op.
    past_conns: Vec<String>,
    connected: bool,
    up: VecDeque<Update>,
    down: VecDeque<Incoming>,
    reconnects: usize,
}

struct Sim {
    rng: Rng,
    server: Server,
    peers: Vec<Peer>,
    remote_events: usize,
}

impl Sim {
    fn new(seed: u64, n: usize) -> Self {
        let mut rng = Rng::new(seed);
        let text = random_text(&mut rng, 10);
        let peers = (0..n)
            .map(|i| Peer {
                client: Client::new(text.clone(), 0),
                conn: format!("p{i}c0"),
                past_conns: vec![format!("p{i}c0")],
                connected: true,
                up: VecDeque::new(),
                down: VecDeque::new(),
                reconnects: 0,
            })
            .collect();
        Sim { rng, server: Server { text, log: vec![] }, peers, remote_events: 0 }
    }

    fn deliver_up(&mut self, i: usize) {
        let Some(u) = self.peers[i].up.pop_front() else { return };
        let (source, v, op) = self.server.receive(u);
        for p in &mut self.peers {
            if !p.connected {
                continue;
            }
            if p.conn == source {
                p.down.push_back(Incoming { v, op: None, source: None });
            } else if let Some(op) = &op {
                p.down.push_back(Incoming { v, op: Some(op.clone()), source: Some(source.clone()) });
            }
        }
    }

    fn deliver_down(&mut self, i: usize) {
        let p = &mut self.peers[i];
        if p.down.is_empty() {
            return;
        }
        // Mostly in order, sometimes one of the next few first, as Overleaf's redis can reorder.
        let k = if self.rng.below(5) == 0 { self.rng.below(p.down.len().min(3)) } else { 0 };
        let msg = p.down.remove(k).unwrap();
        let events = p.client.receive(msg).expect("client receive");
        self.remote_events += events.iter().filter(|e| matches!(e, Event::Remote(_))).count();
    }

    fn flush(&mut self, i: usize) {
        let p = &mut self.peers[i];
        if !p.connected {
            return;
        }
        if let Some(out) = p.client.flush(&p.conn) {
            p.up.push_back(Update { op: out.op, v: out.v, dup_if_source: out.dup_if_source, source: p.conn.clone() });
        }
    }

    fn resend(&mut self, i: usize) {
        let p = &mut self.peers[i];
        if !p.connected {
            return;
        }
        if let Some(out) = p.client.resend(&p.conn) {
            p.up.push_back(Update { op: out.op, v: out.v, dup_if_source: out.dup_if_source, source: p.conn.clone() });
        }
    }

    fn disconnect(&mut self, i: usize) {
        if !self.peers[i].connected {
            return;
        }
        // Each message on the wire either got through before the drop or is lost.
        let ups: Vec<Update> = self.peers[i].up.drain(..).collect();
        for u in ups {
            if self.rng.below(2) == 0 {
                self.peers[i].up.push_back(u);
                self.deliver_up(i);
            }
        }
        let p = &mut self.peers[i];
        p.connected = false;
        p.down.clear();
    }

    fn reconnect(&mut self, i: usize) {
        if self.peers[i].connected {
            return;
        }
        let full_rejoin = self.rng.below(4) == 0;
        let p = &mut self.peers[i];
        p.reconnects += 1;
        p.conn = format!("p{i}c{}", p.reconnects);
        p.past_conns.push(p.conn.clone());
        p.connected = true;
        let from = p.client.version() as usize;
        if full_rejoin {
            // ClientRequestedMissingOpsError: fresh text, no ops. Whether our inflight op made it is known here from
            // the log; the engine will know it from the doc's history or fall back to a guess.
            let applied = self.server.log[from..].iter().any(|(_, src)| p.past_conns.contains(src));
            p.client.rebase(&self.server.text, self.server.version(), Some(applied)).expect("rebase");
        } else {
            let updates = self.server.log[from..].iter().map(|(op, src)| (op.clone(), Some(src.clone()))).collect();
            p.client.catch_up(updates).expect("catch up");
        }
        self.resend(i);
        self.flush(i);
    }

    fn local_edit(&mut self, i: usize) {
        let doc = self.peers[i].client.text().to_owned();
        let op = random_op(&mut self.rng, &doc, 3, true);
        self.peers[i].client.submit(op).expect("submit");
    }

    fn step(&mut self) {
        let i = self.rng.below(self.peers.len());
        match self.rng.below(100) {
            0..=24 => self.local_edit(i),
            25..=39 => self.flush(i),
            40..=64 => self.deliver_up(i),
            65..=94 => self.deliver_down(i),
            95..=96 => self.resend(i),
            97 => self.disconnect(i),
            _ => self.reconnect(i),
        }
    }

    /// Reconnect everyone and deliver everything until nothing moves.
    fn settle(&mut self) {
        for i in 0..self.peers.len() {
            self.reconnect(i);
        }
        for _ in 0..10_000 {
            let mut moved = false;
            for i in 0..self.peers.len() {
                self.flush(i);
                while !self.peers[i].up.is_empty() {
                    self.deliver_up(i);
                    moved = true;
                }
            }
            for i in 0..self.peers.len() {
                while !self.peers[i].down.is_empty() {
                    self.deliver_down(i);
                    moved = true;
                }
            }
            if !moved {
                return;
            }
        }
        panic!("did not settle");
    }

    fn check(&self) -> Result<(), TestCaseError> {
        for (i, p) in self.peers.iter().enumerate() {
            prop_assert!(p.client.is_idle(), "peer {} still has unconfirmed edits", i);
            prop_assert_eq!(p.client.queued(), 0);
            prop_assert_eq!(p.client.version(), self.server.version(), "peer {} version", i);
            prop_assert_eq!(p.client.text(), self.server.text.as_str(), "peer {} text", i);
            prop_assert_eq!(p.client.server_text(), self.server.text.as_str(), "peer {} base", i);
        }
        Ok(())
    }
}

fn run(seed: u64, steps: usize) -> Result<Sim, TestCaseError> {
    let mut sim = Sim::new(seed, 3);
    for _ in 0..steps {
        sim.step();
    }
    sim.settle();
    sim.check()?;
    Ok(sim)
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(10_000))]

    #[test]
    fn three_clients_converge(seed: u64, steps in 20usize..300) {
        run(seed, steps)?;
    }
}

/// The simulation must actually produce concurrency, or convergence is trivially true.
#[test]
fn simulation_exercises_concurrency() {
    let (mut versions, mut transformed) = (0, 0);
    for seed in 0..50 {
        let sim = run(seed, 300).unwrap();
        versions += sim.server.version();
        transformed += sim.remote_events;
    }
    eprintln!("{versions} ops applied, {transformed} remote ops shown");
    assert!(versions > 500 && transformed > 1000, "{versions} {transformed}");
}

/// An update queued before a reconnect stayed in the queue after `catch_up` moved past it.
#[test]
fn queue_drained_after_catch_up() {
    run(17044619005502577618, 98).unwrap();
}
