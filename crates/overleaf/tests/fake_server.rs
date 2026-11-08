//! The client against the fake real-time server (`overleaf::fake`).

use overleaf::fake::{FakeServer, Mode, DOC_ID, PROJECT_ID};
use overleaf::{Applied, DocSync, Http, OtType, ProjectConn, ServerEvent, Style};
use serde_json::json;
use std::time::{Duration, Instant};

async fn wait_confirm(conn: &mut ProjectConn, doc: &mut DocSync, deadline: Duration) -> u64 {
    let end = Instant::now() + deadline;
    loop {
        if let Some(r) = doc.resend_due(Instant::now(), &conn.public_id) {
            conn.apply_ot_update(&r).await.unwrap();
        }
        let ev = tokio::time::timeout(Duration::from_millis(200), conn.next_event()).await;
        if let Ok(Some(ServerEvent::OtUpdateApplied(u))) = ev {
            if let Applied::Confirmed { version } = doc.on_update(u).unwrap() {
                return version;
            }
        }
        assert!(Instant::now() < end, "no confirmation");
    }
}

#[tokio::test]
async fn join_edit_confirm() {
    let fake = FakeServer::start("\\documentclass{article}\nGröße", Mode::Confirm).await;
    let http = Http::with_cookie(&fake.base, "overleaf_session2=s%3Atest").unwrap();
    let mut conn = ProjectConn::connect(&http, PROJECT_ID, Style::Auto).await.unwrap();
    assert_eq!(conn.public_id, "P.1");
    assert_eq!(conn.permissions, "owner");
    let tree = overleaf::file_tree(&conn.project);
    assert_eq!(tree[0].0, "main.tex");
    assert_eq!(tree[2].0, "sections/fig.png");

    let joined = conn.join_doc(DOC_ID, None, None).await.unwrap();
    assert_eq!(joined.text(), "\\documentclass{article}\nGröße");
    assert_eq!(joined.ot_type, OtType::ShareJsTextOt);

    let mut doc = DocSync::new(DOC_ID, joined.ot_type.clone(), joined.version);
    let at = overleaf::text::js_len(&joined.text());
    doc.submit(json!([{"p": at, "i": "\n% ü"}]));
    let u = doc.take_next(Instant::now(), &conn.public_id).unwrap();
    conn.apply_ot_update(&u).await.unwrap();
    assert_eq!(wait_confirm(&mut conn, &mut doc, Duration::from_secs(5)).await, 8);

    let s = fake.state.lock().unwrap();
    assert!(s.cookies.iter().all(|c| c.contains("overleaf_session2=s%3Atest")));
    assert!(s.cookies.len() >= 2, "cookie on handshake and websocket");
    assert_eq!(s.received[0], json!({"doc": DOC_ID, "op": [{"p": 29, "i": "\n% ü"}], "v": 7}));
    assert_eq!(s.text, "\\documentclass{article}\nGröße\n% ü");
    assert_eq!(s.heartbeats_answered, 1);
}

#[tokio::test]
async fn resend_with_dup_if_source() {
    let fake = FakeServer::start("x", Mode::DropFirstConfirm).await;
    let http = Http::with_cookie(&fake.base, "overleaf_session2=x").unwrap();
    let mut conn = ProjectConn::connect(&http, PROJECT_ID, Style::Query).await.unwrap();
    let joined = conn.join_doc(DOC_ID, None, None).await.unwrap();
    let mut doc = DocSync::new(DOC_ID, joined.ot_type.clone(), joined.version);
    doc.submit(json!([{"p": 0, "i": "a"}]));
    let u = doc.take_next(Instant::now(), &conn.public_id).unwrap();
    conn.apply_ot_update(&u).await.unwrap();
    assert_eq!(wait_confirm(&mut conn, &mut doc, Duration::from_secs(10)).await, 8);
    let s = fake.state.lock().unwrap();
    assert_eq!(s.received.len(), 2);
    assert_eq!(s.received[1]["dupIfSource"], json!(["P.1"]));
    assert_eq!(s.received[1]["v"], json!(7));
    assert_eq!(s.text, "ax", "applied once");
}

#[tokio::test]
async fn remote_op_arrives() {
    let fake = FakeServer::start("ab", Mode::Confirm).await;
    let http = Http::with_cookie(&fake.base, "overleaf_session2=x").unwrap();
    let mut conn = ProjectConn::connect(&http, PROJECT_ID, Style::Query).await.unwrap();
    let joined = conn.join_doc(DOC_ID, None, None).await.unwrap();
    let mut doc = DocSync::new(DOC_ID, joined.ot_type.clone(), joined.version);
    fake.remote_insert(1, "Z");
    let ev = tokio::time::timeout(Duration::from_secs(5), conn.next_event()).await.unwrap().unwrap();
    let ServerEvent::OtUpdateApplied(u) = ev else { panic!("{ev:?}") };
    assert_eq!(u.user_id(), Some("u2"));
    match doc.on_update(u).unwrap() {
        Applied::Remote { op, version, .. } => {
            assert_eq!(op, json!([{"p": 1, "i": "Z"}]));
            assert_eq!(version, 8);
        }
        a => panic!("{a:?}"),
    }
}

#[tokio::test]
async fn emit_style_is_rejected_by_ce() {
    let fake = FakeServer::start("", Mode::Confirm).await;
    let http = Http::with_cookie(&fake.base, "overleaf_session2=x").unwrap();
    match ProjectConn::connect(&http, PROJECT_ID, Style::Emit).await {
        Err(overleaf::Error::Rejected(m)) => assert!(m.contains("projectId"), "{m}"),
        Err(e) => panic!("{e}"),
        Ok(_) => panic!("joined"),
    }
}
