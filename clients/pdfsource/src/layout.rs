//! Glyphs → lines → columns → paragraphs, from the PDF alone.

use crate::glyphs::name_text;
use crate::pdf::{Font, Glyph, Pdf, Rule};
use std::collections::HashMap;

pub fn glyph_text(f: &Font, code: u32) -> String {
    if let Some(n) = f.names.get(&code) {
        let t = name_text(n);
        if !t.is_empty() {
            return t;
        }
    }
    if let Some(u) = f.unicode.get(&code) {
        return u.clone();
    }
    "\u{fffd}".into()
}

#[derive(Debug, Clone)]
pub struct Line {
    pub page: usize,
    pub glyphs: Vec<Glyph>,
    /// Baseline.
    pub y: f64,
    pub x0: f64,
    pub x1: f64,
    /// Most common (font, size) of the line's glyphs on the baseline.
    pub font: usize,
    pub size: f64,
    /// Glyphs off the baseline (scripts, math) or in forms.
    pub off_baseline: usize,
    /// Left edge of the column the line was taken in (set for paragraph lines).
    pub left: f64,
    /// Right edge of that column.
    pub right: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Column {
    pub left: f64,
    pub right: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Start {
    /// First line indented by the paragraph indent.
    Indented,
    /// Not indented, after a vertical gap or at the top of the column (a heading's first paragraph, or a
    /// paragraph continued from the previous column: `continued` tells which, if known).
    Flush,
}

#[derive(Debug, Clone)]
pub struct Para {
    pub lines: Vec<Line>,
    pub column: Column,
    pub start: Start,
    /// The last line is shorter than the column (the paragraph ends here for sure).
    pub ends_short: bool,
    /// Pages and column index of the parts, for the report.
    pub at: Vec<(usize, usize)>,
    /// Joined from parts on several columns or pages.
    pub joined: bool,
    /// Hanging indent of lines after the first (bp; 0: none), as in bibliography entries.
    pub hang: f64,
    /// A list item: the number of label glyphs at the start of the first line (0: none), and the gap after them.
    pub label: usize,
    pub label_sep: f64,
    /// A footnote: the label (its mark) is right-aligned in a box this wide at the column's left (bp; 0: none).
    pub label_box: f64,
    /// The paragraph indent of this paragraph's text size (bp).
    pub indent: f64,
    /// A displayed formula (`$$...$$`): its lines (numerators, limits... are lines of their own), in the PDF's order.
    pub display: bool,
    /// The display's last line is its equation number, flush right on the formula's baseline.
    pub eqno: bool,
    /// Rules (fraction bars) inside a display.
    pub rules: Vec<crate::pdf::Rule>,
}

#[derive(Debug)]
pub struct Doc {
    pub pages: usize,
    pub lines: Vec<Line>,
    pub columns: Vec<Column>,
    /// Columns before this index are page columns; the rest are indented blocks inside them (lists, quotes).
    pub n_main: usize,
    pub body_size: f64,
    pub body_font: usize,
    pub parindent: f64,
    pub baselineskip: f64,
    pub paras: Vec<Para>,
    /// Text lines not taken into any body paragraph (headings, captions, footnotes, tables, displays...).
    pub other_lines: usize,
}

fn key(v: f64, q: f64) -> i64 {
    (v / q).round() as i64
}

fn mode<I: Iterator<Item = f64>>(it: I, q: f64) -> Option<(f64, usize)> {
    let mut h: HashMap<i64, (usize, f64)> = HashMap::new();
    for v in it {
        let e = h.entry(key(v, q)).or_insert((0, 0.0));
        e.0 += 1;
        e.1 += v;
    }
    h.into_iter().max_by(|a, b| a.1 .0.cmp(&b.1 .0).then(b.0.cmp(&a.0))).map(|(_, (n, s))| (s / n as f64, n))
}

/// Lines from glyphs in content order: a line runs while the baseline stays and x moves on; glyphs smaller than
/// the line's font on another baseline nearby (scripts) stay in the line.
pub fn lines_of(page: usize, glyphs: &[Glyph]) -> Vec<Line> {
    let mut out: Vec<Line> = vec![];
    let mut cur: Vec<Glyph> = vec![];
    let flush = |cur: &mut Vec<Glyph>, out: &mut Vec<Line>| {
        if cur.is_empty() {
            return;
        }
        let gs = std::mem::take(cur);
        let (by, _) = mode(gs.iter().map(|g| g.y), 0.01).unwrap();
        let on: Vec<&Glyph> = gs.iter().filter(|g| (g.y - by).abs() < 0.01).collect();
        let mut fh: HashMap<(usize, i64), usize> = HashMap::new();
        for g in &on {
            *fh.entry((g.font, key(g.size, 0.001))).or_default() += 1;
        }
        let ((font, sk), _) = fh.into_iter().max_by_key(|e| (e.1, e.0 .1, std::cmp::Reverse(e.0 .0))).unwrap();
        let x0 = gs.iter().map(|g| g.x).fold(f64::MAX, f64::min);
        let x1 = gs.iter().map(|g| g.x + g.adv).fold(f64::MIN, f64::max);
        let off = gs.iter().filter(|g| (g.y - by).abs() >= 0.01 || g.size < 0.0).count();
        out.push(Line { page, y: by, x0, x1, font, size: sk as f64 * 0.001, off_baseline: off, left: x0, right: x1, glyphs: gs });
    };
    for g in glyphs {
        if let Some(last) = cur.last() {
            let base = cur[0].y;
            let sz = cur[0].size.abs().max(g.size.abs()).max(1.0);
            let same_base = (g.y - last.y).abs() < 0.01 || (g.y - base).abs() < 0.01;
            // Scripts (smaller, raised or lowered), and text-size glyphs moved off the baseline while the line goes on
            // (big operators on the math axis, \raisebox).
            let forward = g.x >= last.x + last.adv - 0.5 * sz;
            let script = (g.y - base).abs() < 0.6 * sz && (g.size.abs() < cur[0].size.abs() * 0.95 || forward);
            // A script stacked under or over another one (x^a_b) moves left; that stays in the line.
            let back = g.x < last.x + last.adv - 0.5 * sz && !(same_base && g.x > last.x - 0.01) && !(script && g.x > cur[0].x);
            let far = g.x > last.x + last.adv + 3.0 * sz; // a gutter
            if !(same_base || script) || back || far || (g.size < 0.0) != (last.size < 0.0) {
                flush(&mut cur, &mut out);
            }
        }
        cur.push(g.clone());
    }
    flush(&mut cur, &mut out);
    out
}

pub fn analyze(pdf: &mut Pdf, only: Option<usize>) -> Doc {
    let n = pdf.page_count();
    let mut lines = vec![];
    let mut rules: Vec<(usize, Rule)> = vec![];
    for p in 1..=n {
        if only.is_some_and(|o| o != p) {
            continue;
        }
        if let Ok(pg) = pdf.page(p) {
            rules.extend(pg.rules.iter().map(|r| (p, r.clone())));
            let text: Vec<Glyph> = pg.glyphs.into_iter().collect();
            lines.extend(lines_of(p, &text));
        }
    }
    // Body font: most glyphs on baselines.
    let mut fh: HashMap<(usize, i64), usize> = HashMap::new();
    for l in &lines {
        *fh.entry((l.font, key(l.size, 0.001))).or_default() += l.glyphs.len();
    }
    let ((body_font, bs), _) = fh.iter().max_by_key(|e| (*e.1, e.0 .1, std::cmp::Reverse(e.0 .0))).map(|(k, v)| (*k, *v)).unwrap_or(((0, 0), 0));
    let body_size = bs as f64 * 0.001;
    // Margin kerning (protrusion) only with font expansion seen, i.e. microtype.
    let microtype = lines.iter().flat_map(|l| l.glyphs.iter()).any(|g| (g.hscale - 1.0).abs() > 1e-4);
    let is_body = |l: &Line| (l.size - body_size).abs() < 0.01 && l.glyphs.len() >= 3;

    // Columns: modes of right edges of long body lines, each with the mode of their left edges.
    let long: Vec<&Line> = lines.iter().filter(|l| is_body(l) && l.glyphs.len() > 25).collect();
    let mut columns: Vec<Column> = vec![];
    let mut rights: HashMap<i64, Vec<&Line>> = HashMap::new();
    for l in &long {
        rights.entry(key(l.x1, 0.5)).or_default().push(l);
    }
    let mut rv: Vec<(i64, Vec<&Line>)> = rights.into_iter().collect();
    rv.sort_by_key(|e| (std::cmp::Reverse(e.1.len()), e.0)); // ties by edge: deterministic
    for (_, ls) in rv.iter().take(10) {
        if ls.len() < 4 {
            continue;
        }
        let (r, _) = mode(ls.iter().map(|l| l.x1), 0.002).unwrap();
        let (left, _) = mode(ls.iter().map(|l| l.x0), 0.002).unwrap();
        if std::env::var("PDFSOURCE_COLS").is_ok() {
            let mut h: HashMap<i64, usize> = HashMap::new();
            for l in ls.iter() { *h.entry(key(l.x0, 0.01)).or_default() += 1; }
            let mut v: Vec<_> = h.into_iter().collect();
            v.sort_by_key(|e| std::cmp::Reverse(e.1));
            eprintln!("group r={r:.3} n={} left={left:.3} top x0: {:?}", ls.len(), &v[..v.len().min(4)]);
        }
        if !columns.iter().any(|c| (c.right - r).abs() < 1.5 || (c.left - left).abs() < 1.5) {
            columns.push(Column { left, right: r });
        }
    }
    columns.sort_by(|a, b| a.left.partial_cmp(&b.left).unwrap());

    let colw = |c: &Column| c.right - c.left;
    // The indent: first lines indented from a column's left edge whose next line returns to that edge (a block
    // indented on both sides, like an abstract, doesn't count).
    let parindent = mode(
        lines.windows(2).filter(|w| is_body(&w[0]) && w[0].page == w[1].page).filter_map(|w| {
            let (l, n) = (&w[0], &w[1]);
            columns
                .iter()
                .find(|c| l.x1 <= c.right + 3.0 && l.x0 > c.left + 1.0 && l.x0 < c.left + 0.12 * colw(c) && (n.x0 - c.left).abs() < 0.4 * body_size)
                .map(|c| l.x0 - c.left)
        }),
        0.002,
    )
    .map(|m| m.0)
    .unwrap_or(0.0);
    let baselineskip = mode(
        lines.windows(2).filter(|w| w[0].page == w[1].page && is_body(&w[0]) && is_body(&w[1])).map(|w| w[0].y - w[1].y).filter(|d| *d > 0.0),
        0.002,
    )
    .map(|m| m.0)
    .unwrap_or(body_size * 1.2);

    // Indented blocks (list bodies, quotes): a line whose neighbour above or below starts at the same x, inside a
    // column but not at its left edge, belongs to a sub-column with that left edge.
    let n_main = columns.len();
    let mut block: Vec<Option<usize>> = vec![None; lines.len()];
    for j in 0..lines.len() {
        let l = &lines[j];
        if !is_body(l) {
            continue;
        }
        let same = |k: usize| {
            let n = &lines[k];
            n.page == l.page && is_body(n) && (n.x0 - l.x0).abs() < 0.01 && ((n.y - l.y).abs() - baselineskip).abs() < 0.05
        };
        if !((j > 0 && same(j - 1)) || (j + 1 < lines.len() && same(j + 1))) {
            continue;
        }
        // Lines at a page column's own edge (an abstract's narrower column) aren't blocks.
        let tol = if microtype { 0.4 * body_size } else { 0.01 };
        if columns[..n_main].iter().any(|c| l.x0 <= c.left + 0.01 && l.x0 > c.left - tol && l.x1 <= c.right + 0.25 * body_size) {
            continue;
        }
        let Some(host) = columns[..n_main].iter().position(|c| l.x0 > c.left + 1.0 && l.x0 < c.left + 0.4 * (c.right - c.left) && l.x1 <= c.right + 0.25 * body_size) else { continue };
        let right = columns[host].right;
        let merge = if microtype { 0.4 * body_size } else { 0.01 };
        // Only sub-columns merge (a page column's edge must not move).
        let idx = match columns.iter().enumerate().skip(n_main).find(|(_, c)| (c.left - l.x0).abs() < merge && (c.right - right).abs() < 0.01).map(|e| e.0) {
            Some(i) => {
                columns[i].left = columns[i].left.max(l.x0); // protrusion only moves lines left
                i
            }
            None => {
                columns.push(Column { left: l.x0, right });
                columns.len() - 1
            }
        };
        block[j] = Some(idx);
    }
    // List items: a label (bullet, dash, 1., (a)) then a gap; the text's left edge is a sub-column, and the lines
    // that follow at that edge continue the item.
    let mut item: Vec<Option<(usize, usize, f64)>> = vec![None; lines.len()];
    for j in 0..lines.len() {
        let l = &lines[j];
        if !is_body(l) || l.glyphs.len() < 3 {
            continue;
        }
        let t: Vec<String> = l.glyphs.iter().take(5).map(|g| glyph_text(&pdf.fonts[g.font], g.code)).collect();
        let alnum = |s: &str| s.chars().all(|c| c.is_ascii_alphanumeric());
        let n = if ["•", "∙", "·", "–", "—", "∗", "*", "◦", "‣", "−"].contains(&t[0].as_str()) {
            1
        } else if t[0] == "(" {
            (2..t.len()).find(|&k| t[k] == ")" && t[1..k].iter().all(|s| alnum(s))).map(|k| k + 1).unwrap_or(0)
        } else {
            (1..t.len().min(4)).find(|&k| (t[k] == "." || t[k] == ")") && t[..k].iter().all(|s| alnum(s))).map(|k| k + 1).unwrap_or(0)
        };
        if n == 0 || n >= l.glyphs.len() {
            continue;
        }
        let (a, b) = (&l.glyphs[n - 1], &l.glyphs[n]);
        let gap = b.x - (a.x + a.adv);
        if gap < 0.25 * body_size {
            continue;
        }
        // Under microtype the first text glyph may be protruded too: the next line (unprotruded, usually) decides.
        let tol = if microtype { 0.4 * body_size } else { 0.01 };
        let mut text_x = b.x;
        if let Some(nl) = lines.get(j + 1) {
            if nl.page == l.page && (nl.x0 - text_x).abs() < tol && ((l.y - nl.y) - baselineskip).abs() < 0.05 {
                text_x = text_x.max(nl.x0);
            }
        }
        // An item has structure: its next line continues at the text edge, or the label line starts off the column's
        // edge and indent (a dash opening an ordinary line is text).
        let next_at_text = lines.get(j + 1).is_some_and(|nl| nl.page == l.page && (nl.x0 - text_x).abs() < tol && ((l.y - nl.y) - baselineskip).abs() < 0.05);
        let at_edge = columns[..n_main].iter().any(|c| (l.x0 - c.left).abs() < 0.01 || (parindent > 0.0 && (l.x0 - c.left - parindent).abs() < 0.01));
        if !next_at_text && at_edge {
            continue;
        }
        let Some(host) = columns[..n_main].iter().position(|c| l.x0 > c.left - 0.5 * body_size && text_x > c.left + 1.0 && text_x < c.left + 0.4 * (c.right - c.left) && l.x1 <= c.right + 0.25 * body_size) else { continue };
        let right = columns[host].right;
        // The text after a label is never protruded (the label starts the line): exact edges only.
        let idx = match columns.iter().enumerate().skip(n_main).find(|(_, c)| (c.left - text_x).abs() < 0.01 && (c.right - right).abs() < 0.01).map(|e| e.0) {
            Some(i) => {
                columns[i].left = columns[i].left.max(text_x);
                i
            }
            None => {
                columns.push(Column { left: text_x, right });
                columns.len() - 1
            }
        };
        // \labelsep runs from the label to the item's edge (the first text glyph may be protruded left of it).
        item[j] = Some((idx, n, text_x - (a.x + a.adv)));
        block[j] = None;
        let mut k = j + 1;
        while k < lines.len() && lines[k].page == l.page && is_body(&lines[k]) && lines[k].x0 <= text_x + 0.01 && lines[k].x0 > text_x - tol && lines[k].x1 <= right + 0.25 * body_size && ((lines[k - 1].y - lines[k].y) - baselineskip).abs() < 0.05 {
            block[k] = Some(idx);
            k += 1;
        }
    }
    let columns = columns;
    // Paragraphs: walk body lines in order per column.
    let in_col = |l: &Line| -> Option<usize> {
        // At a column's left edge (first choice) or its indent, or up to 0.4 em left of either (microtype's protrusion).
        let near = |x: f64| l.x0 <= x + 0.01 && l.x0 > x - if microtype { 0.4 * body_size } else { 0.01 };
        let fits = |i: usize| l.x1 <= columns[i].right + 0.25 * body_size;
        (0..n_main)
            .find(|&i| near(columns[i].left) && fits(i))
            .or_else(|| (0..n_main).find(|&i| parindent > 0.0 && near(columns[i].left + parindent) && fits(i)))
    };
    let full = |l: &Line, c: &Column| (l.x1 - c.right).abs() < 0.02 || (l.x1 > c.right && l.x1 < c.right + 0.3 * body_size);
    let mut paras: Vec<Para> = vec![];
    let mut open: Option<Para> = None;
    let mut taken = 0usize;
    let mut prev: Option<(usize, usize, f64)> = None; // page, column, y of the last body line
    for (j, l) in lines.iter().enumerate() {
        // A line at a hanging indent other than \parindent (natbib's \bibhang) right after a full line of a flush
        // paragraph that starts at the column edge: the entry goes on (lines after the first all at the indent;
        // under microtype a line may start protruded, so the indent is the largest offset seen).
        let hang_col = prev.filter(|_| is_body(l) && item[j].is_none()).and_then(|(pg, pc, py)| {
            let p = open.as_ref()?;
            let c = &columns[pc];
            let h = l.x0 - c.left;
            let ok = pg == l.page
                && ((py - l.y) - baselineskip).abs() < 0.05
                && p.start == Start::Flush
                && !p.ends_short
                && p.label == 0
                // (a list item whose label wasn't recognised: a bullet or dash opens it)
                && p.lines[0].glyphs.first().is_none_or(|g| !matches!(glyph_text(&pdf.fonts[g.font], g.code).as_str(), "•" | "–" | "—" | "-" | "∗" | "*" | "◦" | "·" | "⋅" | "▪"))
                && l.x1 <= c.right + 0.25 * body_size
                && if p.hang > 0.0 { h <= p.hang + 0.01 && h > p.hang - if microtype { 0.4 * body_size } else { 0.01 } } else { p.lines.len() == 1 && h > 0.3 * body_size && h < 3.0 * body_size };
            ok.then_some(pc)
        });
        let ci = if !is_body(l) { None } else if hang_col.is_some() { hang_col } else if let Some((ix, _, _)) = item[j] { Some(ix) } else if block[j].is_some() { block[j] } else { in_col(l) };
        let Some(ci) = ci else {
            if let Some(p) = open.take() {
                paras.push(p);
            }
            prev = None;
            continue;
        };
        let c = columns[ci];
        let indented = parindent > 0.0 && l.x0 <= c.left + parindent + 0.01 && l.x0 > c.left + parindent - if microtype { 0.4 * body_size } else { 0.01 };
        let follows = prev.is_some_and(|(pg, pc, py)| pg == l.page && pc == ci && ((py - l.y) - baselineskip).abs() < 0.05);
        let continues_open = open.as_ref().is_some_and(|p| !p.ends_short && p.hang == 0.0) && follows && !indented && item[j].is_none();
        // An indented line right after a full line of a flush paragraph: a hanging indent (a bibliography entry).
        let hangs = hang_col.is_some() || (indented && follows && open.as_ref().is_some_and(|p| !p.ends_short && p.start == Start::Flush && (p.lines.len() == 1 || p.hang > 0.0)));
        if continues_open || hangs {
            let p = open.as_mut().unwrap();
            if hangs {
                p.hang = p.hang.max(l.x0 - c.left);
            }
            p.ends_short = !full(l, &c);
            let mut l = l.clone();
            l.left = c.left;
            l.right = c.right;
            p.lines.push(l);
        } else {
            if let Some(p) = open.take() {
                paras.push(p);
            }
            open = Some(Para {
                lines: vec![Line { left: c.left, right: c.right, ..l.clone() }],
                column: c,
                start: if indented && item[j].is_none() { Start::Indented } else { Start::Flush },
                ends_short: !full(l, &c),
                at: vec![(l.page, ci)],
                joined: false,
                hang: 0.0,
                label: item[j].map_or(0, |x| x.1),
                label_sep: item[j].map_or(0.0, |x| x.2),
                label_box: 0.0,
                indent: parindent,
                display: false,
                eqno: false,
                rules: vec![],
            });
        }
        taken += 1;
        prev = Some((l.page, ci, l.y));
    }
    if let Some(p) = open.take() {
        paras.push(p);
    }
    // Join a paragraph that runs to the end of a column with the flush one that opens the next column or page.
    let mut joined: Vec<Para> = vec![];
    for p in paras {
        if let Some(last) = joined.last_mut() {
            let next_col = last.at.last().map(|&(pg, ci)| (pg, ci)) != Some((p.lines[0].page, columns.iter().position(|c| *c == p.column).unwrap_or(99)));
            let top = !p.lines.is_empty();
            if !last.ends_short && p.start == Start::Flush && p.label == 0 && next_col && top && (colw(&last.column) - colw(&p.column)).abs() < 0.01 {
                last.lines.extend(p.lines);
                last.ends_short = p.ends_short;
                last.at.extend(p.at);
                last.joined = true;
                continue;
            }
        }
        joined.push(p);
    }
    let mut taken = taken;
    // Other text sizes (footnotes, small abstracts and captions): the page columns, their own indent and leading.
    // A footnote opens with its mark raised in a box at the column's left (\@makefntext: \hbox to 1.8em{\hss mark}).
    let mut sizes: HashMap<i64, usize> = HashMap::new();
    for l in &lines {
        if l.glyphs.len() >= 3 && l.size < body_size - 0.3 && l.size > 0.6 * body_size {
            *sizes.entry(key(l.size, 0.001)).or_default() += 1;
        }
    }
    let mut sv: Vec<(i64, usize)> = sizes.into_iter().filter(|e| e.1 >= 6).collect();
    sv.sort_by_key(|e| (std::cmp::Reverse(e.1), e.0));
    for (sk, _) in sv.into_iter().take(3) {
        let s = sk as f64 * 0.001;
        let is_s = |l: &Line| (l.size - s).abs() < 0.01 && l.glyphs.len() >= 3;
        let bskip = mode(lines.windows(2).filter(|w| w[0].page == w[1].page && is_s(&w[0]) && is_s(&w[1])).map(|w| w[0].y - w[1].y).filter(|d| *d > 0.0), 0.002).map(|m| m.0).unwrap_or(s * 1.2);
        let pind = mode(
            lines.windows(2).filter(|w| is_s(&w[0]) && w[0].page == w[1].page).filter_map(|w| {
                columns[..n_main].iter().find(|c| w[0].x1 <= c.right + 3.0 && w[0].x0 > c.left + 1.0 && w[0].x0 < c.left + 0.12 * colw(c) && (w[1].x0 - c.left).abs() < 0.01).map(|c| w[0].x0 - c.left)
            }),
            0.002,
        )
        .map(|m| m.0)
        .unwrap_or(0.0);
        let mut open: Option<Para> = None;
        let mut prev: Option<(usize, usize, f64)> = None;
        for l in &lines {
            if !is_s(l) {
                if let Some(p) = open.take() { joined.push(p); }
                prev = None;
                continue;
            }
            // A raised, smaller mark first, then text inside the first few ems: a footnote.
            let nmark = l.glyphs.iter().take_while(|g| g.y > l.y + 0.01 && g.size.abs() < s - 0.01).count();
            let mark = (nmark > 0 && nmark < l.glyphs.len()).then(|| l.glyphs[nmark].x);
            let near = |x: f64, edge: f64| x <= edge + 0.01 && x > edge - if microtype { 0.4 * s } else { 0.01 };
            let fits = |c: &Column| l.x1 <= c.right + 0.25 * s;
            let ci = (0..n_main).find(|&i| {
                let c = &columns[i];
                fits(c) && match mark { Some(tx) => tx > c.left && tx < c.left + 3.0 * s && l.x0 >= c.left - 0.01, None => near(l.x0, c.left) || (pind > 0.0 && near(l.x0, c.left + pind)) }
            });
            let Some(ci) = ci else {
                if let Some(p) = open.take() { joined.push(p); }
                prev = None;
                continue;
            };
            let c = columns[ci];
            let indented = mark.is_none() && pind > 0.0 && near(l.x0, c.left + pind);
            let follows = prev.is_some_and(|(pg, pc, py)| pg == l.page && pc == ci && ((py - l.y) - bskip).abs() < 0.05);
            let full = (l.x1 - c.right).abs() < 0.02 || (l.x1 > c.right && l.x1 < c.right + 0.3 * s);
            // As in the body: an indented line after a full line of a flush paragraph is a hanging indent.
            let hangs = indented && follows && open.as_ref().is_some_and(|p| !p.ends_short && p.start == Start::Flush && p.label == 0 && (p.lines.len() == 1 || p.hang > 0.0));
            if (open.as_ref().is_some_and(|p| !p.ends_short && p.hang == 0.0) && follows && !indented && mark.is_none()) || hangs {
                let p = open.as_mut().unwrap();
                if hangs {
                    p.hang = l.x0 - c.left;
                }
                p.ends_short = !full;
                p.lines.push(Line { left: c.left, right: c.right, ..l.clone() });
            } else {
                if let Some(p) = open.take() { joined.push(p); }
                open = Some(Para {
                    lines: vec![Line { left: c.left, right: c.right, ..l.clone() }],
                    column: c,
                    start: if indented { Start::Indented } else { Start::Flush },
                    ends_short: !full,
                    at: vec![(l.page, ci)],
                    joined: false,
                    hang: 0.0,
                    label: if mark.is_some() { nmark } else { 0 },
                    label_sep: 0.0,
                    label_box: mark.map_or(0.0, |tx| tx - c.left),
                    indent: pind,
                    display: false,
                eqno: false,
                rules: vec![],
                });
            }
            taken += 1;
            prev = Some((l.page, ci, l.y));
        }
        if let Some(p) = open.take() { joined.push(p); }
    }
    // Displayed formulas: body-size lines with math between the paragraphs, inside a page column but off both
    // edges; the lines of one display (numerators, denominators, limits) are those with nothing else between them.
    // An equation number "(n)" ends at the column's right edge.
    let used: std::collections::HashSet<(usize, i64, i64)> = joined.iter().flat_map(|p| p.lines.iter()).map(|l| (l.page, key(l.y, 0.001), key(l.x0, 0.001))).collect();
    let is_used = |l: &Line| used.contains(&(l.page, key(l.y, 0.001), key(l.x0, 0.001)));
    let mathy = |g: &Glyph| {
        let n = pdf.fonts[g.font].name.to_ascii_uppercase();
        ["CMMI", "CMSY", "CMEX", "CMBSY", "MSBM", "MSAM"].iter().any(|f| n.starts_with(f))
    };
    let text_of = |l: &Line| -> String { l.glyphs.iter().map(|g| glyph_text(&pdf.fonts[g.font], g.code)).collect() };
    // Not text with a symbol in it (a caption's "256 × 256"): no word of five letters in a text font.
    let wordy = |l: &Line| {
        let mut run = 0;
        for (k, g) in l.glyphs.iter().enumerate() {
            let letter = !mathy(g) && glyph_text(&pdf.fonts[g.font], g.code).chars().all(|c| c.is_alphabetic());
            let joined_prev = k > 0 && g.x - (l.glyphs[k - 1].x + l.glyphs[k - 1].adv) < 0.12 * g.size;
            run = if letter { if joined_prev { run + 1 } else { 1 } } else { 0 };
            if run >= 5 {
                return true;
            }
        }
        false
    };
    let mut in_display = vec![false; lines.len()];
    for j in 0..lines.len() {
        let l = &lines[j];
        if in_display[j] || is_used(l) || (l.size - body_size).abs() > 0.01 || !l.glyphs.iter().any(|g| mathy(g)) || wordy(l) {
            continue;
        }
        let dbg = std::env::var("PDFSOURCE_DISP").is_ok();
        let why = |w: &str| if dbg { eprintln!("display? p{} y={:.2} {:?}: {w}", l.page, l.y, text_of(l)) };
        let Some(ci) = (0..n_main).find(|&i| l.x0 > columns[i].left + 0.5 * body_size && l.x1 < columns[i].right + 0.01) else { why("column"); continue };
        let c = columns[ci];
        let inside = |m: &Line| m.page == l.page && m.x1 > c.left && m.x0 < c.right;
        // The paragraph lines just above and below bound the display.
        let above = lines.iter().filter(|m| inside(m) && is_used(m) && m.y > l.y).map(|m| m.y).fold(f64::MAX, f64::min);
        let below = lines.iter().filter(|m| inside(m) && is_used(m) && m.y < l.y).map(|m| m.y).fold(f64::MIN, f64::max);
        let (top, bot) = (above.min(l.y + 3.0 * baselineskip), below.max(l.y - 3.0 * baselineskip));
        // Grow from this line: lines close above or below one already taken (a numerator, a limit, a big
        // delimiter's pieces reach further), so consecutive displays stay apart.
        let pool: Vec<usize> = (0..lines.len()).filter(|&k| inside(&lines[k]) && !is_used(&lines[k]) && lines[k].y < top && lines[k].y > bot).collect();
        let reach = |m: &Line| if m.glyphs.iter().any(|g| pdf.fonts[g.font].name.to_ascii_uppercase().starts_with("CMEX")) { 2.0 * body_size } else { 1.3 * body_size };
        let mut ks: Vec<usize> = vec![j];
        loop {
            let add: Vec<usize> = pool.iter().copied().filter(|k| !ks.contains(k) && ks.iter().any(|&m| (lines[m].y - lines[*k].y).abs() < reach(&lines[m]).max(reach(&lines[*k])))).collect();
            if add.is_empty() {
                break;
            }
            ks.extend(add);
        }
        ks.sort();
        if let Some(&k) = ks.iter().find(|&&k| in_display[k] || wordy(&lines[k]) || lines[k].x0 < c.left - 0.01 || lines[k].x1 > c.right + body_size) {
            why(&format!("window {} {} {:?}", in_display[k], wordy(&lines[k]), text_of(&lines[k]))); continue;
        }
        // Clear of the paragraphs around it (an inline radical or limit sticks out of its text line by less).
        if ks.iter().any(|&k| above - lines[k].y < 0.75 * baselineskip || lines[k].y - below < 0.75 * baselineskip) {
            why("clear"); continue;
        }
        // Nothing within the display's height that isn't in it (a figure's text, the other column's lines are outside).
        let (ytop, ybot) = ks.iter().fold((f64::MIN, f64::MAX), |(t, b), &k| (t.max(lines[k].y), b.min(lines[k].y)));
        if ytop - ybot > 4.0 * baselineskip {
            why(&format!("tall {:?}", ks.iter().map(|&k| (lines[k].y, text_of(&lines[k]))).collect::<Vec<_>>())); continue;
        }
        let mut ls: Vec<Line> = ks.iter().map(|&k| Line { left: c.left, right: c.right, ..lines[k].clone() }).collect();
        // The number: a line of "(...)" in a text font ending at the right edge, last in the PDF's order.
        let num = |m: &Line| {
            let t = text_of(m);
            m.x1 > c.right - 0.02 && m.x1 < c.right + body_size && t.starts_with('(') && t.ends_with(')') && t.chars().count() >= 3 && !m.glyphs.iter().any(|g| mathy(g)) && m.glyphs.iter().all(|g| (g.y - m.y).abs() < 0.01)
        };
        let nums = ls.iter().filter(|m| num(m)).count();
        if nums > 1 || (nums == 1 && !num(ls.last().unwrap())) {
            why("numbers"); continue;
        }
        // Off both edges unless it is the number (a line ending at the right edge is a paragraph's).
        if ls.iter().any(|m| !num(m) && (m.x0 < c.left + 0.5 * body_size || m.x1 > c.right - 0.02)) {
            why("edges"); continue;
        }
        let rs: Vec<Rule> = rules.iter().filter(|(pg, r)| *pg == l.page && r.y1 - r.y0 < 1.0 && r.x1 - r.x0 > 1.0 && r.x0 > c.left && r.x1 < c.right && r.y0 < ytop + body_size && r.y1 > ybot - 0.5 * body_size).map(|x| x.1.clone()).collect();
        for &k in &ks {
            in_display[k] = true;
        }
        taken += ls.len();
        ls.iter_mut().for_each(|m| m.right = c.right);
        joined.push(Para {
            lines: ls,
            column: c,
            start: Start::Flush,
            ends_short: true,
            at: vec![(l.page, ci)],
            joined: false,
            hang: 0.0,
            label: 0,
            label_sep: 0.0,
            label_box: 0.0,
            indent: parindent,
            display: true,
            eqno: nums == 1,
            rules: rs,
        });
    }
    let other = lines.len() - taken;
    Doc { pages: n, lines, columns, n_main, body_size, body_font, parindent, baselineskip, paras: joined, other_lines: other }
}

pub fn line_text(pdf: &Pdf, l: &Line) -> String {
    let mut s = String::new();
    let mut last: Option<&Glyph> = None;
    for g in &l.glyphs {
        if let Some(p) = last {
            if g.x - (p.x + p.adv) > 0.12 * g.size.abs() {
                s.push(' ');
            }
        }
        s.push_str(&glyph_text(&pdf.fonts[g.font], g.code));
        last = Some(g);
    }
    s
}

pub fn print(pdf: &Pdf, d: &Doc) {
    println!(
        "pages {} lines {} body {} {:.4} columns {:?} parindent {:.3} baselineskip {:.3} paras {} other lines {}",
        d.pages, d.lines.len(), pdf.fonts[d.body_font].name, d.body_size, d.columns, d.parindent, d.baselineskip,
        d.paras.len(), d.other_lines
    );
    for (i, p) in d.paras.iter().enumerate() {
        println!("¶{i} {:?} short={} joined={} at={:?}{}", p.start, p.ends_short, p.joined, p.at, if p.display { " display" } else { "" });
        for l in &p.lines {
            let t = line_text(pdf, l);
            println!("   p{} y={:.3} x0={:.3} x1={:.3} | {}", l.page, l.y, l.x0, l.x1, t.chars().take(90).collect::<String>());
        }
    }
}
