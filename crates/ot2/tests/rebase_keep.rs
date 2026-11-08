//! `Client::rebase_keeping_inflight`: after a full rejoin whose text doesn't have our inflight op, the op stays in
//! flight (carried past the server's changes) and its resend lists the connection it was first sent under.

use ot2::client::Client;
use ot2::text::{self, Component};

fn ins(p: usize, s: &str) -> Component {
    Component::Insert { p, i: s.into() }
}

#[test]
fn inflight_stays_in_flight_with_its_source() {
    let mut c = Client::new("abc", 7);
    c.submit(vec![ins(3, "!")]).unwrap();
    let out = c.flush("P.1").unwrap();
    assert_eq!(out.v, 7);
    c.submit(vec![ins(0, ">")]).unwrap();
    assert_eq!(c.text(), ">abc!");
    // The server, at v9, has a collaborator's "X" in the middle, and not our "!".
    let change = c.rebase_keeping_inflight("abXc", 9).unwrap();
    assert_eq!(c.text(), ">abXc!");
    assert_eq!(text::apply(">abc!", &change).unwrap(), ">abXc!");
    assert_eq!(c.version(), 9);
    assert_eq!(c.inflight().map(|o| text::apply("abXc", o).unwrap()).as_deref(), Some("abXc!"));
    let again = c.resend("P.2").unwrap();
    assert_eq!(again.v, 9);
    assert_eq!(again.dup_if_source, vec!["P.1".to_string(), "P.2".to_string()]);
    assert!(c.pending().is_some());
}
