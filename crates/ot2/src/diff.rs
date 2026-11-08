//! The smallest classic op that turns one text into another, by character. Used to rebase local edits after a full
//! rejoin, where the server sends a new text but not the ops that made it, and by the engine to turn a file saved on
//! disk into an op instead of a whole-file replacement (principle 2).
//!
//! Common prefix and suffix are trimmed, then the middle is compared with Myers' O(ND) algorithm ("An O(ND)
//! Difference Algorithm and Its Variations", 1986).

use crate::text::{Component, Op};

/// One step of an edit script from `a` to `b`.
#[derive(Clone, Copy, PartialEq)]
enum Step {
    Keep,
    Del,
    Ins,
}

/// Myers' greedy shortest edit script, with the trace kept for backtracking.
fn myers(a: &[char], b: &[char]) -> Vec<Step> {
    let (n, m) = (a.len() as isize, b.len() as isize);
    let max = (n + m) as usize;
    let off = max as isize + 1;
    let at = |k: isize| (off + k) as usize;
    let mut v = vec![0isize; 2 * max + 3];
    // Before round d only diagonals -d..=d matter, so keep just those: O(D²) memory, not O(D·(N+M)).
    let mut trace: Vec<Vec<isize>> = Vec::new();
    'outer: for d in 0..=max as isize {
        trace.push(v[at(-d)..=at(d)].to_vec());
        let mut k = -d;
        while k <= d {
            let down = k == -d || (k != d && v[at(k - 1)] < v[at(k + 1)]);
            let mut x = if down { v[at(k + 1)] } else { v[at(k - 1)] + 1 };
            let mut y = x - k;
            while x < n && y < m && a[x as usize] == b[y as usize] {
                x += 1;
                y += 1;
            }
            v[at(k)] = x;
            if x >= n && y >= m {
                break 'outer;
            }
            k += 2;
        }
    }
    let mut steps = Vec::new();
    let (mut x, mut y) = (n, m);
    for d in (1..trace.len()).rev() {
        let row = &trace[d];
        let d = d as isize;
        let v = |k: isize| row[(k + d) as usize];
        let k = x - y;
        let down = k == -d || (k != d && v(k - 1) < v(k + 1));
        let pk = if down { k + 1 } else { k - 1 };
        let (px, py) = (v(pk), v(pk) - pk);
        while x > px && y > py {
            steps.push(Step::Keep);
            x -= 1;
            y -= 1;
        }
        if down {
            steps.push(Step::Ins);
            y -= 1;
        } else {
            steps.push(Step::Del);
            x -= 1;
        }
    }
    while x > 0 && y > 0 {
        steps.push(Step::Keep);
        x -= 1;
        y -= 1;
    }
    steps.reverse();
    steps
}

/// An op that turns `old` into `new`, with deletes and inserts at character granularity.
pub fn diff(old: &str, new: &str) -> Op {
    let a: Vec<char> = old.chars().collect();
    let b: Vec<char> = new.chars().collect();
    let pre = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let suf = a[pre..].iter().rev().zip(b[pre..].iter().rev()).take_while(|(x, y)| x == y).count();
    let (am, bm) = (&a[pre..a.len() - suf], &b[pre..b.len() - suf]);
    let mut pos: usize = a[..pre].iter().map(|c| c.len_utf16()).sum();
    let (mut i, mut j) = (0, 0);
    let mut op = Op::new();
    let (mut del, mut ins) = (String::new(), String::new());
    let flush = |op: &mut Op, pos: &mut usize, del: &mut String, ins: &mut String| {
        if !del.is_empty() {
            op.push(Component::Delete { p: *pos, d: std::mem::take(del) });
        }
        if !ins.is_empty() {
            *pos += crate::units::utf16_len(ins);
            op.push(Component::Insert { p: *pos - crate::units::utf16_len(ins), i: std::mem::take(ins) });
        }
    };
    for s in myers(am, bm) {
        match s {
            Step::Keep => {
                flush(&mut op, &mut pos, &mut del, &mut ins);
                pos += am[i].len_utf16();
                i += 1;
                j += 1;
            }
            Step::Del => {
                del.push(am[i]);
                i += 1;
            }
            Step::Ins => {
                ins.push(bm[j]);
                j += 1;
            }
        }
    }
    flush(&mut op, &mut pos, &mut del, &mut ins);
    op
}
