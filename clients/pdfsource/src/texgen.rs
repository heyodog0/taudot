//! From a paragraph's glyphs and a hypothesis (fonts, measures, line-breaking parameters) to TeX input that should
//! typeset to the same glyphs.

use crate::layout::{Line, Para};
use crate::pdf::{Font, Pdf};
use crate::texmf::Texmf;
use std::collections::HashMap;
use std::fmt::Write;

/// A TeX font that reproduces a PDF font: the TFM to load, at what size, and the input for each PDF code.
#[derive(Debug, Clone)]
pub struct TexFont {
    pub tfm: String,
    pub size_pt: f64,
    /// PDF code → char codes to type (several when TeX builds the glyph as a ligature).
    pub input: HashMap<u32, Vec<u32>>,
    pub slant: f64,
    /// Interword space, stretch, shrink, extra (pt): fontdimens 2–4 and 7 at size.
    pub space: [f64; 4],
    /// fontdimen6 (quad) at size, pt.
    pub quad: f64,
    /// `\pdfmapline` for the raw font, without the font program (positions don't need it).
    pub mapline: String,
    /// The NFSS font that loads this TFM (for runs that let LaTeX and microtype set fonts up).
    pub nfss: Option<crate::texmf::Nfss>,
    /// PDF code → the TFM char TeX ends up with (after ligatures), and the TFM's kerns between those chars (pt).
    pub tchar: HashMap<u32, u32>,
    pub kerns: HashMap<(u32, u32), f64>,
}

pub fn colkey(left: f64, right: f64) -> i64 {
    (left * 100.0).round() as i64 * 1_000_000 + (right * 100.0).round() as i64
}

pub const SP_PER_BP: f64 = 65536.0 * 72.27 / 72.0;

pub fn sp(bp: f64) -> i64 {
    (bp * SP_PER_BP).round() as i64
}

/// TeX's at-size from the PDF's size in bp: the nearest 0.01 pt (LaTeX's sizes are all such).
pub fn size_pt(bp: f64) -> f64 {
    (bp * 72.27 / 72.0 * 100.0).round() / 100.0
}

/// Candidates for one PDF font, best first. Empty if the font isn't found in TeX Live.
pub fn candidates(tx: &mut Texmf, f: &Font, size_bp: f64, used: &[u32]) -> Vec<TexFont> {
    let lines: Vec<_> = tx.map.iter().filter(|m| m.ps == f.name).cloned().collect();
    let mut raws: Vec<(String, String)> = vec![];
    for m in &lines {
        if m.special.contains("Slant") || m.special.contains("Extend") {
            continue;
        }
        let ok = match &m.enc {
            Some(e) => match tx.encoding(e) {
                Some(v) => used.iter().all(|c| f.names.get(c).map_or(true, |n| v.get(*c as usize) == Some(n))),
                None => false,
            },
            None => true,
        };
        if ok {
            let mut ml = format!("={} {}", m.tfm, m.ps);
            if !m.special.is_empty() {
                ml += &format!(" \"{}\"", m.special);
            }
            if let Some(e) = &m.enc {
                ml += &format!(" <{e}");
            }
            // The font program: pdfTeX needs it for a built-in encoding (glyph names) and for font expansion.
            match m.file.as_ref().and_then(|f| tx.find(f).map(|_| f.clone())) {
                Some(f) => ml += &format!(" <{f}"),
                None if m.enc.is_none() => continue,
                None => {}
            }
            raws.push((m.tfm.clone(), ml));
        }
    }
    let pt = size_pt(size_bp);
    let mut out = vec![];
    for (raw, mapline) in raws {
        if tx.tfm(&raw).is_none() {
            continue;
        }
        let mut vfs: Vec<String> = tx.vf_candidates(&raw);
        vfs.sort_by_key(|v| {
            let rank = if v.ends_with("7t") { 0 } else if v.ends_with("8t") { 1 } else { 5 };
            (rank, v.len(), v.clone())
        });
        // Text through a virtual font first (LaTeX's way), the raw font last.
        let mut opts: Vec<(String, HashMap<u32, u32>, f64)> = vec![];
        for v in vfs.iter().take(12) {
            let Some(vf) = tx.vf(v) else { continue };
            if vf.fonts.values().all(|(n, _)| *n != raw) {
                continue;
            }
            let scale = vf.fonts.values().find(|(n, _)| *n == raw).map(|x| x.1).unwrap_or(1.0);
            let mut inv: HashMap<u32, u32> = HashMap::new();
            for (vc, (n, rc)) in &vf.single {
                if *n == raw {
                    let e = inv.entry(*rc).or_insert(*vc);
                    if (*vc == *rc && *e != *rc) || (*e != *rc && *vc < *e) {
                        *e = *vc;
                    }
                }
            }
            // A VF needn't map every code (a bullet may come from TS1 while text is OT1): codes it lacks fail only the
            // paragraphs that use them. Rank by coverage.
            let cover = used.iter().filter(|c| inv.contains_key(c)).count();
            if cover * 2 >= used.len() && (scale - 1.0).abs() < 1e-6 {
                opts.push((v.clone(), inv, scale));
            }
        }
        opts.sort_by_key(|o| std::cmp::Reverse(used.iter().filter(|c| o.1.contains_key(c)).count()));
        if tx.has(&format!("{raw}.tfm")) {
            opts.push((raw.clone(), used.iter().map(|&c| (c, c)).collect(), 1.0));
        }
        for (name, map, _) in opts {
            let tfm_name = name.clone();
            let Some(tfm) = tx.tfm(&name).cloned() else { continue };
            let mut input = HashMap::new();
            for (&pc, &vc) in &map {
                input.insert(pc, decompose(&tfm.ligs, vc, 0));
            }
            let p = |k: usize| tfm.param.get(k).copied().unwrap_or(0.0) * pt;
            out.push(TexFont {
                tfm: name,
                size_pt: pt,
                input,
                slant: tfm.param.get(1).copied().unwrap_or(0.0),
                space: [p(2), p(3), p(4), p(7)],
                quad: p(6),
                mapline: mapline.clone(),
                nfss: tx.nfss_of(&tfm_name, pt),
                tchar: map.clone(),
                kerns: tfm.kerns.iter().map(|(&k, &v)| (k, v * pt)).collect(),
            });
        }
    }
    out
}

/// Chars to type for a char that a ligature can make: the shortest pair, recursively (fi → f i, — → - - -).
fn decompose(ligs: &HashMap<(u32, u32), u32>, c: u32, depth: usize) -> Vec<u32> {
    let letter = |c: u32| (b'a' as u32..=b'z' as u32).contains(&c) || (b'A' as u32..=b'Z' as u32).contains(&c);
    // Letters and digits are typed as themselves; anything a ligature makes (dashes, quotes, ¡ ¿, fi) is typed as
    // the ligature's input, since that is how sources get them and TeX's kerns differ between the two routes.
    let digit = |c: u32| (b'0' as u32..=b'9' as u32).contains(&c);
    if depth > 3 || letter(c) || digit(c) {
        return vec![c];
    }
    let mut best: Option<Vec<u32>> = None;
    for (&(a, b), &r) in ligs {
        if r == c && a != c && b != c {
            let mut v = decompose(ligs, a, depth + 1);
            v.extend(decompose(ligs, b, depth + 1));
            if best.as_ref().map_or(true, |x| v.len() < x.len() || (v.len() == x.len() && v < *x)) {
                best = Some(v);
            }
        }
    }
    best.unwrap_or_else(|| vec![c])
}

/// How a line-end hyphen is read.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Hyph {
    /// TeX hyphenated the word there: drop the hyphen, join the halves.
    Discretionary,
    /// The hyphen is in the source (a compound): keep it, no space.
    Explicit,
}

#[derive(Debug, Clone)]
pub struct Params {
    pub hsize_sp: i64,
    pub parindent_sp: i64,
    pub left_sp: i64,
    pub tolerance: i32,
    pub pretolerance: i32,
    pub emergencystretch_pt: f64,
    pub italic_correction: bool,
    /// amsmath's \boldsymbol instead of bm's (when bm is loaded).
    pub ams_bold: bool,
    /// \frenchspacing (all space factors 1000), as in bibliographies (\sfcode`\.=1000).
    pub french: bool,
    /// Control spaces after , and ; inside citation brackets.
    pub cite_spaces: bool,
    /// sp added to the snapped \labelsep of a list item.
    pub labelsep_adj: i64,
    /// Hanging indent after the first line (sp), 0 for none.
    pub hang_sp: i64,
    /// \newblock's shrink is −.07em (some venue styles) instead of .07em.
    pub newblock_neg: bool,
}

#[derive(Debug, Clone)]
pub struct Hyp {
    pub params: Params,
    /// PDF font index → chosen candidate index.
    pub font_choice: HashMap<usize, usize>,
    /// Per line-end hyphen (line index) → reading.
    pub hyph: HashMap<usize, Hyph>,
    /// Calibrated left edges: column left (bp, key 1/100) → sp.
    pub lefts: HashMap<i64, i64>,
    /// Per line: sp added to the reconstructed rounding residual (the PDF chain is known to about 1 sp).
    pub resid: HashMap<usize, i64>,
    /// Items (glyph index over the paragraph's lines) whose preceding space is unbreakable (`~`).
    pub ties: std::collections::HashSet<usize>,
    /// Items that start a word TeX must not hyphenate.
    pub nohyph: std::collections::HashSet<usize>,
}

impl Hyp {
    pub fn left_of(&self, left_bp: f64, right_bp: f64) -> i64 {
        *self.lefts.get(&colkey(left_bp, right_bp)).unwrap_or(&sp(left_bp)) + self.params.left_sp
    }
}

pub struct Gen<'a> {
    pub pdf: &'a Pdf,
    /// Font key (a PDF font at one size) → candidates.
    pub fonts: &'a HashMap<usize, Vec<TexFont>>,
    pub fkey: &'a HashMap<(usize, i64), usize>,
}

pub fn size_key(size: f64) -> i64 {
    (size.abs() * 1000.0).round() as i64
}

pub fn font_cs(i: usize) -> String {
    // Control word of letters only.
    let mut s = String::from("pdfsrcf");
    let mut n = i;
    loop {
        s.push((b'a' + (n % 26) as u8) as char);
        n /= 26;
        if n == 0 {
            break;
        }
    }
    s
}

const ESC: char = '\u{1}';

impl<'a> Gen<'a> {
    pub fn hyphen_at_end(&self, l: &Line, hyp: &Hyp) -> bool {
        let Some(g) = l.glyphs.last() else { return false };
        let k = self.k(g);
        let Some(tf) = hyp.font_choice.get(&k).and_then(|&i| self.fonts.get(&k)?.get(i)) else { return false };
        tf.input.get(&g.code).map(|v| v == &vec![45]).unwrap_or(false)
    }

    /// Paragraph text as TeX input under the special catcodes (see `preamble`). Err: why it can't be written.
    /// A displayed formula: `$$ source \eqno\hbox{number} $$` in an otherwise empty paragraph (TeX drops it).
    fn display_input(&self, p: &Para, hyp: &Hyp) -> Result<String, String> {
        let tf = |f: usize| -> Option<&TexFont> { self.fonts.get(&f)?.get(*hyp.font_choice.get(&f)?) };
        let nf = p.lines.len() - p.eqno as usize;
        let gl: Vec<crate::pdf::Glyph> = p.lines[..nf].iter().flat_map(|l| l.glyphs.iter().cloned()).collect();
        let size0 = p.lines[..nf].iter().map(|l| l.size).fold(0.0, f64::max);
        let m = crate::math::display_source(&self.pdf.fonts, &gl, &p.rules, size0)?;
        let mut s = format!("{ESC}PSdd ");
        let mut esc = false;
        for ch in m.chars() {
            if esc {
                esc = false;
                if !ch.is_ascii_alphabetic() {
                    s.push(ch);
                    continue;
                }
            }
            match ch {
                '\\' => {
                    s.push(ESC);
                    esc = true;
                }
                '{' => s.push('\u{2}'),
                '}' => s.push('\u{3}'),
                '^' => s.push_str("\u{1}sp "),
                '_' => s.push_str("\u{1}sb "),
                c => s.push(c),
            }
        }
        if let Some(n) = p.lines.last().filter(|_| p.eqno) {
            let _ = write!(s, "{ESC}eqno{ESC}hbox\u{2}");
            let mut cf = usize::MAX;
            for g in &n.glyphs {
                let k = self.k(g);
                if k != cf {
                    let _ = write!(s, "{ESC}{}\u{2}\u{3}", font_cs(k));
                    cf = k;
                }
                let f = tf(k).ok_or("number font")?;
                for &c in f.input.get(&g.code).ok_or("number glyph")? {
                    if (33..127).contains(&c) && !char::from_u32(c).unwrap().is_ascii_whitespace() {
                        s.push(char::from_u32(c).unwrap());
                    } else {
                        let _ = write!(s, "{ESC}char{c} ");
                    }
                }
            }
            s.push('\u{3}');
        }
        let _ = write!(s, "{ESC}PSdd ");
        Ok(s)
    }

    /// A bibliography entry "[n] text" (hanging indent, label at the line start, the text after it exactly at the
    /// indent): the number of label glyphs, else 0. Styles box the label (left-aligned) in \labelwidth + \labelsep.
    fn bib_label(&self, p: &Para) -> usize {
        if p.hang <= 0.0 || p.label > 0 || p.label_box > 0.0 || p.lines.len() < 2 {
            return 0;
        }
        let l = &p.lines[0];
        let t = |g: &crate::pdf::Glyph| crate::layout::glyph_text(&self.pdf.fonts[g.font], g.code);
        if l.glyphs.first().is_none_or(|g| t(g) != "[" || (g.x - l.left).abs() > 0.05) {
            return 0;
        }
        match (1..l.glyphs.len().min(8)).find(|&k| t(&l.glyphs[k]) == "]") {
            Some(k) if l.glyphs.get(k + 1).is_some_and(|g| (g.x - (l.left + p.hang)).abs() < 0.05) => k + 1,
            _ => 0,
        }
    }

    pub fn para_input(&self, p: &Para, hyp: &Hyp, main_font: usize) -> Result<String, String> {
        if p.display {
            return self.display_input(p, hyp);
        }
        let mut s = String::new();
        let mut cur: Option<usize> = None;
        let nlines = p.lines.len();
        let tf = |f: usize| -> Option<&TexFont> { self.fonts.get(&f)?.get(*hyp.font_choice.get(&f)?) };
        // Flatten glyphs with the separator before each: 0 none, 1 space, 2 line-end hyphen join.
        struct Item {
            font: usize,
            code: u32,
            sep: u8,
            drop: bool,
            /// Gap before this glyph on its line (bp), for a space within the line.
            gap: f64,
            /// A space factor to force for the space before this glyph (1000: `\ `, 3000: sentence space).
            sf: Option<u32>,
            /// Colour literal painted just before this glyph.
            pre: String,
            /// Unexpanded in a line that microtype expanded: the glyph was in a box (e.g. a citation link).
            boxed: bool,
            /// Inline math starting at this glyph (its source); the span's other glyphs are `skip`.
            math: Option<String>,
            skip: bool,
        }
        let cm_text = self.name_of(main_font).starts_with("CM");
        let bib = self.bib_label(p);
        let mut items: Vec<Item> = vec![];
        let mut all_spans = vec![];
        for l in &p.lines {
            all_spans.push(self.math_spans(l, cm_text)?);
        }
        // Fonts this paragraph shows expanded (microtype), once per paragraph.
        let expanding: std::collections::HashSet<usize> = p.lines.iter().flat_map(|q| q.glyphs.iter()).filter(|x| (x.hscale - 1.0).abs() > 1e-4).map(|x| x.font).collect();
        for (li, l) in p.lines.iter().enumerate() {
            let hy = li + 1 < nlines && self.hyphen_at_end(l, hyp);
            let reading = hyp.hyph.get(&li).copied().unwrap_or(Hyph::Discretionary);
            let spans = all_spans[li].clone();
            // A formula that continues from the previous line: its glyphs here belong to the source written there.
            let continued = li > 0 && spans.first().is_some_and(|s| s.0 == 0) && all_spans[li - 1].last().is_some_and(|s| s.1 == p.lines[li - 1].glyphs.len());
            let line_expanded = l.glyphs.iter().any(|x| (x.hscale - 1.0).abs() > 1e-4);
            for (gi, g) in l.glyphs.iter().enumerate() {
                if g.size < 0.0 {
                    return Err("figure text".into());
                }
                let span = spans.iter().find(|s| s.0 <= gi && gi < s.1);
                let cont_here = continued && span.is_some_and(|s| s.0 == 0);
                let math = match span {
                    Some(s) if s.0 == gi && !cont_here => {
                        // The span's glyphs, plus those of the formula's continuation on the next lines (on this baseline).
                        let mut sgv: Vec<crate::pdf::Glyph> = l.glyphs[s.0..s.1].to_vec();
                        let mut lj = li;
                        while s.1 == l.glyphs.len() && lj + 1 < nlines && all_spans[lj].last().is_some_and(|t| t.1 == p.lines[lj].glyphs.len()) {
                            let Some(&t) = all_spans[lj + 1].first().filter(|t| t.0 == 0) else { break };
                            let nl = &p.lines[lj + 1];
                            for x in &nl.glyphs[t.0..t.1] {
                                let mut x = x.clone();
                                x.y += l.y - nl.y;
                                sgv.push(x);
                            }
                            if t.1 != nl.glyphs.len() { break; }
                            lj += 1;
                        }
                        let sg = &sgv[..];
                        if sg.iter().all(|x| crate::math::math_font(&self.pdf.fonts[x.font]).is_none() && x.y > l.y + 0.01) {
                            // A footnote mark (LaTeX's \@makefnmark): text font, smaller, raised as a superscript.
                            let mut t = String::from("\u{1}hbox\u{2}\u{1}(\u{1}sp\u{2}\u{1}hbox\u{2}");
                            let mut cf = usize::MAX;
                            for x in sg {
                                let k = self.k(x);
                                if k != cf {
                                    t += &format!("\u{1}{}\u{2}\u{3}", font_cs(k));
                                    cf = k;
                                }
                                let f = tf(k).ok_or("footnote mark font")?;
                                for &c in f.input.get(&x.code).ok_or("footnote mark glyph")? {
                                    if (33..127).contains(&c) { t.push(char::from_u32(c).unwrap()); } else { t += &format!("\u{1}char{c} "); }
                                }
                            }
                            t += "\u{3}\u{3}\u{1})\u{3}";
                            Some(format!("\u{0}{t}"))
                        } else {
                            Some(crate::math::span_source(&self.pdf.fonts, sg, l.y, l.size)?)
                        }
                    }
                    _ => None,
                };
                let skip = span.is_some_and(|s| s.0 != gi) || cont_here;
                // An accent over the next letter: \'e and friends (TeX's \accent places and kerns it).
                let accent_of = |x: &crate::pdf::Glyph| self.pdf.fonts[x.font].names.get(&x.code).and_then(|n| accent_cmd(n));
                let accent_here = span.is_none() && accent_of(g).is_some() && l.glyphs.get(gi + 1).is_some_and(|b| b.x < g.x + g.adv && b.font == g.font);
                let accented = span.is_none() && gi > 0 && accent_of(&l.glyphs[gi - 1]).is_some() && g.x < l.glyphs[gi - 1].x + l.glyphs[gi - 1].adv && g.font == l.glyphs[gi - 1].font;
                let math = if accent_here {
                    let b = &l.glyphs[gi + 1];
                    let f = tf(self.k(b)).ok_or("accent font")?;
                    let codes = f.input.get(&b.code).ok_or("accent base")?;
                    let base: String = if self.pdf.fonts[b.font].names.get(&b.code).map(|n| n.as_str()) == Some("dotlessi") {
                        "\u{1}i ".into()
                    } else {
                        codes.iter().map(|&c| char::from_u32(c).unwrap_or('?')).collect()
                    };
                    Some(format!("\u{0}\u{1}{}\u{2}{}\u{3}", accent_cmd(&self.pdf.fonts[g.font].names[&g.code]).unwrap(), base))
                } else {
                    math
                };
                let skip = skip || accented;
                let mut sep = 0;
                if gi == 0 && li > 0 {
                    let prev_hy = self.hyphen_at_end(&p.lines[li - 1], hyp);
                    sep = if prev_hy { 2 } else { 1 };
                } else if gi > 0 {
                    let pg = &l.glyphs[gi - 1];
                    if g.x - (pg.x + pg.adv) > 0.12 * g.size {
                        sep = 1;
                    }
                }
                let drop = hy && gi + 1 == l.glyphs.len() && reading == Hyph::Discretionary;
                let gap = if gi > 0 { g.x - (l.glyphs[gi - 1].x + l.glyphs[gi - 1].adv) } else { 0.0 };
                let pre = if gi > 0 || li > 0 { g.pre.clone() } else { String::new() };
                let font_expands = expanding.contains(&g.font);
                let boxed = line_expanded && font_expands && (g.hscale - 1.0).abs() < 1e-4;
                let (font, code) = if span.is_some() { (main_font, u32::MAX) } else if accent_here { (self.k(g), u32::MAX) } else { (self.k(g), g.code) };
                let sep = if skip { 0 } else { sep };
                // The text after a list label starts at the item's left edge: no space, the label is in an \llap.
                let sep = if li == 0 && p.label > 0 && gi == p.label { 0 } else { sep };
                let sep = if li == 0 && bib > 0 && gi == bib { 0 } else { sep };
                items.push(Item { font, code, sep, drop, gap, sf: None, pre, boxed: boxed && span.is_none() && !(li == 0 && gi < p.label), math, skip });
            }
            let start = items.len() - l.glyphs.len();
            self.space_factors(&mut items[start..], hyp, main_font, p.hang > 0.0 || p.label > 0, li + 1 == nlines, |it| (it.font, it.code, it.sep, it.gap), |it, v| it.sf = v);
        }
        // Citations: natbib and LaTeX's \cite put a control space after the commas and semicolons inside the
        // brackets (space factor 1000), not the 1250/1500 a typed space gets. A bracket span counts as a citation
        // when it holds a year or only numbers.
        if hyp.params.cite_spaces {
            let ch = |it: &Item| -> Option<char> { if it.code == u32::MAX { return None; } tf(it.font)?.input.get(&it.code)?.last().and_then(|&c| char::from_u32(c)) };
            let mut i = 0;
            while i < items.len() {
                if matches!(ch(&items[i]), Some('(') | Some('[')) {
                    let close = if ch(&items[i]) == Some('(') { ')' } else { ']' };
                    if let Some(j) = (i + 1..items.len().min(i + 400)).find(|&j| ch(&items[j]) == Some(close)) {
                        let text: String = items[i + 1..j].iter().filter_map(|it| ch(it)).collect();
                        let year = text.as_bytes().windows(4).any(|w| (w.starts_with(b"19") || w.starts_with(b"20")) && w.iter().all(|b| b.is_ascii_digit()));
                        let numeric = !text.is_empty() && text.chars().all(|c| c.is_ascii_digit() || c == ',' || c == ';' || c == '-' || c == '–');
                        if year || numeric {
                            for k in i + 2..j {
                                if items[k].sep == 1 && items[k].sf.is_none() && matches!(ch(&items[k - 1]), Some(',') | Some(';')) {
                                    items[k].sf = Some(1000);
                                }
                            }
                        }
                        i = j;
                    }
                }
                i += 1;
            }
        }
        // A numbered heading ("3.4\quad Title"): LaTeX sets the number and its quad in a box (\@hangfrom), so
        // microtype doesn't protrude the number. The number: up to 10 glyphs of digits, capitals and dots.
        let head_num = (1..items.len().min(11))
            .find(|&k| items[k].sep == 1 && matches!(items[k].sf, Some(4) | Some(5)))
            .filter(|&k| {
                let txt: Vec<char> = items[..k].iter().filter_map(|it| tf(it.font)?.input.get(&it.code)?.last().and_then(|&c| char::from_u32(c))).collect();
                txt.len() == k && items[1..k].iter().all(|it| it.sep == 0) && txt.iter().any(|c| c.is_ascii_digit()) && txt.iter().all(|c| c.is_ascii_digit() || c.is_ascii_uppercase() || *c == '.')
            })
            .filter(|_| p.label == 0 && bib == 0 && p.label_box == 0.0)
            .unwrap_or(0);
        let mut boxed_from: Option<Option<usize>> = None; // open box: the font before it
        for i in 0..items.len() {
            let it = &items[i];
            if p.label_box > 0.0 && i == 0 {
                // A footnote: \hbox to <box>{\hss mark}, then the text.
                let _ = write!(s, "{ESC}PSnoindent{ESC}hbox to{}sp\u{2}{ESC}hss ", sp(p.label_box));
            } else if p.label > 0 && i == 0 {
                // A colour literal at the text start goes before the label (a whatsit between them would stop
                // pdfTeX's search for the character to protrude).
                if let Some(t) = items.get(p.label).filter(|t| !t.pre.is_empty()) {
                    let _ = write!(s, "{ESC}pdfcolorstack0 set\u{2}{}\u{3}", t.pre);
                }
                // As LaTeX's \item builds it: back by \labelwidth + \labelsep, the label right-aligned in a box of
                // \labelwidth, then \labelsep (the label width here is any; positions don't depend on it).
                let g = texgen_label_sep(p.label_sep) + hyp.params.labelsep_adj;
                let _ = write!(s, "\u{1}hskip-20pt\u{1}hskip-{g}sp\u{1}hbox to20pt\u{2}\u{1}hfil ");
            }
            if head_num > 0 && i == 0 {
                // (\@hangfrom{\hskip<indent>\@svsec}: glue first in the box, which stops protrusion)
                let _ = write!(s, "{ESC}hbox\u{2}{ESC}hskip0pt{ESC}relax ");
            }
            if bib > 0 && i == 0 {
                // A bibliography label left-aligned in a box as wide as the hanging indent: the text starts there.
                let _ = write!(s, "{ESC}hbox to{}sp\u{2}", hyp.params.hang_sp);
            }
            if bib > 0 && i == bib {
                let _ = write!(s, "{ESC}hss\u{3}");
                cur = None;
            }
            if p.label_box > 0.0 && i == p.label {
                s.push('\u{3}');
                cur = None;
            } else if p.label > 0 && i == p.label {
                // LaTeX's \item: the label ends \labelsep before the text (snapped to a nice length).
                let g = texgen_label_sep(p.label_sep) + hyp.params.labelsep_adj;
                let _ = write!(s, "\u{3}\u{1}hskip{g}sp ");
                cur = None;
            }
            if let Some(saved) = boxed_from {
                if !it.boxed || it.sep != 0 {
                    s.push('\u{3}');
                    cur = saved;
                    boxed_from = None;
                }
            }
            if it.skip {
                continue;
            }
            let f = tf(it.font).ok_or_else(|| format!("font {}", self.name_of(it.font)))?;
            // The space's font: the left glyph's if both sides share it, else the main font if either side has it.
            let sf = if it.sep == 1 {
                let left = items[i - 1].font;
                Some(if left == it.font { left } else if it.font == main_font || left == main_font { main_font } else { left })
            } else {
                None
            };
            // Italic correction (LaTeX's \emph, \textit): leaving a slanted font for an upright one, except before . or ,
            if hyp.params.italic_correction && i > 0 {
                let target = sf.unwrap_or(it.font);
                if let (Some(pf), Some(tg)) = (tf(items[i - 1].font), tf(target)) {
                    let next = f.input.get(&it.code).and_then(|v| v.first().copied());
                    if items[i - 1].font != target && pf.slant > 0.0 && tg.slant <= 0.0 && (it.sep != 0 || !matches!(next, Some(46) | Some(44))) {
                        let _ = write!(s, "{ESC}/");
                    }
                }
            }
            if let Some(sf) = sf {
                if cur != Some(sf) {
                    let _ = write!(s, "{ESC}{}\u{2}\u{3}", font_cs(sf));
                    cur = Some(sf);
                }
                if hyp.ties.contains(&i) {
                    let _ = write!(s, "{ESC}penalty10000\u{2}\u{3}");
                }
                match it.sf {
                    Some(1000) => {
                        let _ = write!(s, "{ESC} ");
                    }
                    Some(2) => {
                        let _ = write!(s, "{ESC} {ESC} ");
                    }
                    Some(q @ (4 | 5)) if i == head_num => {
                        let _ = write!(s, "{ESC}{}\u{3}", if q == 4 { "quad" } else { "enspace" });
                        cur = None;
                    }
                    Some(4) => {
                        let _ = write!(s, "{ESC}quad ");
                    }
                    Some(5) => {
                        let _ = write!(s, "{ESC}enspace ");
                    }
                    Some(6) => {
                        let _ = write!(s, "{ESC},");
                    }
                    Some(7) => {
                        let _ = write!(s, " {ESC}hskip.11em plus.33em minus{}.07em\u{2}\u{3}", if hyp.params.newblock_neg { "-" } else { "" });
                    }
                    Some(8) => {
                        let _ = write!(s, "{ESC} {ESC}hskip.11em plus.33em minus{}.07em\u{2}\u{3}", if hyp.params.newblock_neg { "-" } else { "" });
                    }
                    Some(v) => {
                        let _ = write!(s, "{ESC}spacefactor{v}\u{2}\u{3} ");
                    }
                    None => s.push(' '),
                }
            }
            if cur != Some(it.font) {
                let _ = write!(s, "{ESC}{}\u{2}\u{3}", font_cs(it.font));
                cur = Some(it.font);
            }
            if hyp.nohyph.contains(&i) {
                // An explicit kern before a word keeps TeX from hyphenating it (TeX §896); it moves nothing.
                let _ = write!(s, "{ESC}kern0pt\u{2}\u{3}");
            }
            if !it.pre.is_empty() && !(p.label > 0 && i == p.label) {
                let _ = write!(s, "{ESC}pdfcolorstack0 set\u{2}{}\u{3}", it.pre);
            }
            if let Some(raw) = it.math.as_ref().and_then(|m| m.strip_prefix('\u{0}')) {
                s.push_str(raw);
                continue;
            }
            if let Some(m) = &it.math {
                // The text's catcodes are private (see PScats): translate the math source to them.
                let m = if hyp.params.ams_bold { m.replace("\\boldsymbol", "\\amsboldsymbol") } else { m.clone() };
                let _ = write!(s, "{ESC}(");
                let mut esc = false;
                for ch in m.chars() {
                    if esc {
                        // A control symbol (\{ \} \| \,): the char after the escape, as is.
                        esc = false;
                        if !ch.is_ascii_alphabetic() {
                            s.push(ch);
                            continue;
                        }
                    }
                    match ch {
                        '\\' => {
                            s.push(ESC);
                            esc = true;
                        }
                        '{' => s.push('\u{2}'),
                        '}' => s.push('\u{3}'),
                        '^' => { let _ = write!(s, "{ESC}sp "); }
                        '_' => { let _ = write!(s, "{ESC}sb "); }
                        c => s.push(c),
                    }
                }
                let _ = write!(s, "{ESC})");
                continue;
            }
            if it.boxed && boxed_from.is_none() {
                let _ = write!(s, "{ESC}hbox\u{2}");
                boxed_from = Some(cur);
            }
            if it.drop {
                continue;
            }
            let protruded = p.lines[0].glyphs.get(p.label).is_some_and(|g| g.x < p.lines[0].left - 0.01);
            if p.label > 0 && i == p.label && protruded {
                // microtype's patch of \item: the item text starts with \leftprotrusion (relax without microtype). It
                // protrudes only a character it can see: text opening with a font command (\textbf{...}) isn't.
                let _ = write!(s, "{ESC}csname leftprotrusion{ESC}endcsname ");
            }
            let codes = f.input.get(&it.code).ok_or_else(|| format!("unmapped glyph {} in {}", it.code, f.tfm))?;
            // A TFM kern the original doesn't show (the source broke it, e.g. with a macro or `{}` between the
            // letters): an empty group keeps TeX from kerning.
            if i > 0 && it.sep == 0 && it.math.is_none() {
                let q = &items[i - 1];
                if q.font == it.font && q.code != u32::MAX && !q.skip && !q.drop && q.boxed == it.boxed {
                    if let (Some(&a), Some(&b)) = (f.tchar.get(&q.code), f.tchar.get(&it.code)) {
                        let k = f.kerns.get(&(a, b)).copied().unwrap_or(0.0) * 72.0 / 72.27;
                        if k.abs() > 0.1 && it.gap.abs() < k.abs() / 2.0 {
                            s.push_str("\u{2}\u{3}");
                        }
                    }
                }
            }
            for &c in codes {
                let ch = char::from_u32(c).unwrap_or('?');
                if (33..127).contains(&c) {
                    s.push(ch);
                } else {
                    let _ = write!(s, "{ESC}char{c} ");
                }
            }
        }
        if boxed_from.is_some() {
            s.push('\u{3}');
        }
        Ok(s)
    }
}

/// The run's preamble: fonts, catcodes, the shipping macro.
pub fn preamble(fonts: &HashMap<usize, Vec<TexFont>>, choice_of: &dyn Fn(usize) -> Vec<usize>, w_bp: f64, h_bp: f64, latex: Option<&str>) -> String {
    let mut s = String::new();
    if let Some(mt) = latex {
        // A LaTeX document, so fonts load through NFSS and microtype sets them up as in the original.
        // microtype's default sets cover the \rmdefault and \sfdefault families: the body font's family is the roman one.
        // "microtype options or -|roman family|class size option|packages"
        let v: Vec<&str> = mt.split('|').collect();
        let (mt, rm, size, pkgs) = (v[0], v.get(1).copied().unwrap_or("cmr"), v.get(2).copied().unwrap_or("10pt"), v.get(3).copied().unwrap_or(""));
        let _ = write!(s, "\\documentclass[{size}]{{article}}\\usepackage[TS1,T1,OT1]{{fontenc}}\\renewcommand\\rmdefault{{{rm}}}");
        if !pkgs.is_empty() {
            // bm redefines \boldsymbol; keep amsmath's as \amsboldsymbol so a paragraph can use either.
            let (before, bm) = match pkgs.strip_suffix(",bm") {
                Some(b) => (b, true),
                None => (pkgs, false),
            };
            let _ = write!(s, "\\usepackage{{{before}}}\\let\\amsboldsymbol\\boldsymbol");
            if bm {
                let _ = write!(s, "\\usepackage{{bm}}");
            }
        }
        if mt != "-" {
            let _ = write!(s, "\\usepackage[{mt}]{{microtype}}");
        }
        let _ = writeln!(s, "\\begin{{document}}");
    }
    s.push_str("\\catcode`\\^^A=0 \\catcode`\\^^B=1 \\catcode`\\^^C=2\n");
    s.push_str("\\expandafter\\let\\expandafter\\PSship\\csname tex_shipout:D\\endcsname\n");
    s.push_str("\\expandafter\\let\\expandafter\\PSindent\\csname tex_indent:D\\endcsname\n");
    s.push_str("\\expandafter\\let\\expandafter\\PSnoindent\\csname tex_noindent:D\\endcsname\n");
    s.push_str("\\expandafter\\let\\expandafter\\PSpar\\csname tex_par:D\\endcsname\n");
    s.push_str("\\expandafter\\let\\expandafter\\PSeverypar\\csname tex_everypar:D\\endcsname\n");
    s.push_str("\\expandafter\\let\\expandafter\\PSend\\csname tex_end:D\\endcsname\n");
    let _ = writeln!(s, "\\pdfpagewidth={w_bp:.4}bp \\pdfpageheight={h_bp:.4}bp \\hoffset=-1in \\voffset=-1in");
    s.push_str("\\pdfcompresslevel=0 \\pdfobjcompresslevel=0\n");
    // Take a paragraph's lines off the end of the vbox into boxes 201.. (201 = last line); \count254 = how many.
    // $$ for displays (the text's catcodes make $ other).
    s.push_str("\\def\\PSdd{$$}\n");
    s.push_str("\\def\\PSpeel{\\global\\count254=0 \\PSpeelone}\n");
    s.push_str("\\def\\PSpeelone{\\unskip\\unpenalty\\unskip\\setbox2=\\lastbox\\ifvoid2 \\else\\global\\advance\\count254 1 \\global\\setbox\\numexpr200+\\count254\\relax=\\box2 \\expandafter\\PSpeelone\\fi}\n");
    // Catcodes for the text: everything "other" but letters and space; ^^A is the escape, ^^B ^^C group.
    s.push_str("\\def\\PScats{\\count255=0 \\loop\\ifnum\\count255<256 \\catcode\\count255=12 \\advance\\count255 1 \\repeat\n");
    s.push_str(" \\count255=`a \\loop\\ifnum\\count255<`z \\catcode\\count255=11 \\advance\\count255 1 \\repeat \\catcode`z=11\n");
    s.push_str(" \\count255=`A \\loop\\ifnum\\count255<`Z \\catcode\\count255=11 \\advance\\count255 1 \\repeat \\catcode`Z=11\n");
    s.push_str(" \\catcode`\\ =10 \\catcode`\\^^A=0 \\catcode`\\^^B=1 \\catcode`\\^^C=2 \\catcode`\\^^M=5 }\n");
    let mut maps: Vec<&str> = fonts.values().flatten().map(|f| f.mapline.as_str()).collect();
    maps.sort();
    maps.dedup();
    for m in maps {
        let _ = writeln!(s, "\\pdfmapline{{{m}}}");
    }
    for (&fi, cands) in fonts {
        for ci in choice_of(fi) {
            if let Some(f) = cands.get(ci) {
                if let (Some(true), Some((e, fa, se, sh))) = (latex.map(|l| !l.starts_with('-')), &f.nfss) {
                    let _ = writeln!(s, "\\def\\{}{}{{\\fontsize{{{}}}{{{}}}\\usefont{{{e}}}{{{fa}}}{{{se}}}{{{sh}}}}}", font_cs(fi), ci_suffix(ci), f.size_pt, f.size_pt);
                    continue;
                }
                let _ = writeln!(s, "\\font\\{}{}={} at {}pt \\hyphenchar\\{}{}=45", font_cs(fi), ci_suffix(ci), f.tfm, f.size_pt, font_cs(fi), ci_suffix(ci));
            }
        }
    }
    s
}

pub fn ci_suffix(ci: usize) -> String {
    // Candidate index as letters after the font's control word: z, zz... (0 → none).
    "z".repeat(ci)
}

/// One paragraph shipped on its own page.
pub fn para_page(body: &str, p: &Para, hyp: &Hyp, sel: &[(usize, usize)]) -> String {
    let pr = &hyp.params;
    let mut s = String::new();
    s.push_str("\\begingroup\n");
    for &(fi, ci) in sel {
        let _ = writeln!(s, "\\let\\{}=\\{}{}", font_cs(fi), font_cs(fi), ci_suffix(ci));
    }
    let _ = writeln!(
        s,
        "\\setbox0\\vbox{{\\hsize={}sp \\parindent={}sp \\leftskip=0pt \\rightskip=0pt \\parfillskip=0pt plus 1fil \
         \\tolerance={} \\pretolerance={} \\emergencystretch={}pt \\looseness=0 \\hangindent={}sp \\hangafter=1 \\parshape=0 \
         \\spaceskip=0pt \\xspaceskip=0pt {} \\language=0 \\lefthyphenmin=2 \\righthyphenmin=3 \\uchyph=1 \
         \\hyphenpenalty=50 \\exhyphenpenalty=50 \\linepenalty=10 \\adjdemerits=10000 \\doublehyphendemerits=10000 \
         \\finalhyphendemerits=5000 \\PSeverypar={{}} \\baselineskip=12pt \\lineskip=1pt \\lineskiplimit=0pt",
        pr.hsize_sp, pr.parindent_sp, pr.tolerance, pr.pretolerance, pr.emergencystretch_pt, pr.hang_sp, if pr.french { "\\frenchspacing" } else { "\\nonfrenchspacing" }
    );
    s.push_str("\\PScats ");
    let start = if p.start == crate::layout::Start::Indented { "\u{1}PSindent " } else { "\u{1}PSnoindent " };
    s.push_str(start);
    s.push_str(body);
    s.push_str("\u{1}PSpar\u{1}PSpeel\u{3}\n");
    // Each line at its own column's left edge (a paragraph may run over two columns).
    s.push_str("\\PSship\\vbox{");
    // An empty page-mode literal before each line ends the text object, so each line starts afresh (see line_place).
    for i in 0..p.lines.len() + 4 {
        // \lastbox drops a line's shift (TeX §1080), so a hanging indent is added back here.
        let l = line_place(p, hyp, i) + if i > 0 { hyp.params.hang_sp } else { 0 };
        if p.display {
            // \lastbox dropped the display's shift too: TeX centres the formula (half(z - w), §1202) or, with a
            // number, ends the box at the right edge (it packs formula, kern and number: width z - d, §1204).
            let n = "\\numexpr200+\\count254-0\\relax";
            let d = if p.eqno { format!("\\dimexpr{}sp-\\wd{n}\\relax", pr.hsize_sp) } else { format!("\\dimexpr({}sp-\\wd{n})/2\\relax", pr.hsize_sp) };
            if i == 0 {
                let _ = write!(s, "\\ifnum\\count254>0 \\kern14pt\\moveright{l}sp\\hbox{{\\pdfliteral page{{q Q}}\\kern{d}\\box{n}}}\\fi\n");
            }
            continue;
        }
        let _ = write!(s, "\\ifnum\\count254>{i} \\kern14pt\\moveright{l}sp\\hbox{{\\pdfliteral page{{q Q}}\\box\\numexpr200+\\count254-{i}\\relax}}\\fi\n");
    }
    s.push_str("}\n\\endgroup\n");
    s
}

impl<'a> Gen<'a> {
    pub fn k(&self, g: &crate::pdf::Glyph) -> usize {
        *self.fkey.get(&(g.font, size_key(g.size))).unwrap_or(&usize::MAX)
    }

    pub fn name_of(&self, k: usize) -> String {
        self.fkey.iter().find(|e| *e.1 == k).map(|((f, s), _)| format!("{} {:.3}", self.pdf.fonts[*f].name, *s as f64 / 1000.0)).unwrap_or_default()
    }
}

/// TeX's `round_decimals` and unit conversion: the sp TeX gets from `<int>.<digits><unit>`.
fn tex_dim(int: i64, digits: &[u8], unit: &str) -> i64 {
    let mut a: i64 = 0;
    for &d in digits.iter().rev() {
        a = (a + d as i64 * 131072) / 10;
    }
    let x = int * 65536 + (a + 1) / 2;
    let (n, d) = match unit {
        "pt" => (1, 1),
        "pc" => (12, 1),
        "in" => (7227, 100),
        "bp" => (7227, 7200),
        "cm" => (7227, 254),
        "mm" => (7227, 2540),
        _ => (1, 1),
    };
    x * n / d
}

/// How "nice" a length is: 10 × the fewest decimals that give it in pt, pc, in, bp, mm or cm (+ the unit's rank);
/// 100 if none with up to three decimals.
pub fn nice_rank(v: i64) -> i64 {
    let mut best = 100;
    for (ui, unit) in ["pt", "pc", "in", "bp", "mm", "cm"].iter().enumerate() {
        let per = tex_dim(1, &[], unit) as f64;
        let approx = v as f64 / per;
        for k in 0..=3usize {
            let scale = 10f64.powi(k as i32);
            let c = (approx * scale).round() as i64;
            for c in [c - 1, c, c + 1] {
                let neg = c < 0;
                let ca = c.abs();
                let int = ca / scale as i64;
                let frac = ca % scale as i64;
                let digits: Vec<u8> = (0..k).rev().map(|j| ((frac / 10i64.pow(j as u32)) % 10) as u8).collect();
                let mut s = tex_dim(int, &digits, unit);
                if neg {
                    s = -s;
                }
                if s == v {
                    best = best.min(10 * k as i64 + ui as i64);
                }
            }
        }
    }
    best
}

/// TeX's space factor after a char code (LaTeX's \nonfrenchspacing sfcodes): (factor, transparent).
fn sfcode(c: u32) -> (u32, bool) {
    match c {
        46 | 63 | 33 => (3000, false),
        58 => (2000, false),
        59 => (1500, false),
        44 => (1250, false),
        41 | 39 | 93 => (0, true),
        65..=90 => (999, false),
        _ => (1000, false),
    }
}

impl<'a> Gen<'a> {
    /// The space factor TeX uses for the space after the chars typed so far, from the default sfcodes.
    fn default_sf(&self, typed: &[u32]) -> u32 {
        let mut sf = 1000;
        for &c in typed {
            let (v, transparent) = sfcode(c);
            if transparent {
                continue;
            }
            sf = if v == 3000 && sf < 1000 { 1000 } else { v };
        }
        sf
    }

    /// Mark spaces whose width shows a space factor other than TeX's default for the text (`\ `, `\@`, `~`).
    /// Each line's glue ratio is solved from its ordinary spaces (factor 1000) in its main font.
    fn space_factors<T>(&self, items: &mut [T], hyp: &Hyp, main_font: usize, bib: bool, last: bool, get: impl Fn(&T) -> (usize, u32, u8, f64), mut set: impl FnMut(&mut T, Option<u32>)) {
        if hyp.params.french {
            return;
        }
        let tf = |f: usize| -> Option<&TexFont> { self.fonts.get(&f)?.get(*hyp.font_choice.get(&f)?) };
        let Some(mf) = tf(main_font) else { return };
        let k = 72.0 / 72.27;
        let (w, y, z, x) = (mf.space[0] * k, mf.space[1] * k, mf.space[2] * k, mf.space[3] * k);
        let quad = mf.quad * k;
        // Default factor before each space in the line, from what was typed since the line start.
        let mut typed: Vec<u32> = vec![];
        let mut gaps: Vec<(usize, u32, f64)> = vec![];
        let mut others: Vec<(usize, f64)> = vec![];
        // Ratios from ordinary spaces between two glyphs of one other font (a line set mostly in italics).
        let mut other_r: Vec<f64> = vec![];
        for i in 0..items.len() {
            let (font, code, sep, gap) = get(&items[i]);
            if sep == 1 && i > 0 {
                let left = get(&items[i - 1]).0;
                if left == main_font && font == main_font {
                    gaps.push((i, self.default_sf(&typed), gap));
                } else {
                    others.push((i, gap));
                    if left == font && self.default_sf(&typed) == 1000 {
                        if let Some(f) = tf(font).filter(|f| f.space[1] > 0.0) {
                            let k = 72.0 / 72.27;
                            other_r.push(if gap >= f.space[0] * k { (gap - f.space[0] * k) / (f.space[1] * k) } else { (gap - f.space[0] * k) / (f.space[2] * k).max(1e-9) });
                        }
                    }
                }
                typed.clear();
            }
            if code == u32::MAX {
                typed.clear(); // after math the space factor is 1000
            } else if let Some(v) = tf(font).and_then(|f| f.input.get(&code)) {
                typed.extend(v);
            }
        }
        let mut normal: Vec<f64> = gaps.iter().filter(|g| g.1 == 1000 || g.1 == 999).map(|g| g.2).collect();
        // A heading's "3.1\quad Title": the quad isn't an ordinary space, keep it out of the ratio.
        let is_rigid = |g: f64| [quad, quad / 2.0].iter().any(|w| (g - w).abs() < 0.006);
        let only_rigid = !normal.is_empty() && normal.iter().all(|&g| is_rigid(g));
        normal.retain(|&g| !is_rigid(g));
        // A paragraph's last line is set at its natural width (\parfillskip takes the rest): ratio 0 even with no
        // ordinary space to solve it from.
        if y <= 0.0 || (normal.is_empty() && other_r.is_empty() && !only_rigid && !last) {
            return;
        }
        normal.sort_by(|a, b| a.partial_cmp(b).unwrap());
        other_r.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let r = if normal.is_empty() && other_r.is_empty() {
            0.0 // only quads (a heading's natural width), or a last line
        } else if normal.is_empty() {
            other_r[other_r.len() / 2]
        } else {
            let g0 = normal[normal.len() / 2];
            if g0 >= w { (g0 - w) / y } else if z > 0.0 { (g0 - w) / z } else { 0.0 }
        };
        let pred = |sf: f64| -> f64 {
            let extra = if sf >= 2000.0 { x } else { 0.0 };
            w + extra + if r >= 0.0 { r * y * sf / 1000.0 } else { r * z * 1000.0 / sf }
        };
        // Rigid gaps: \quad (section numbers, run-in heads), \enspace, \, (thin space): the exact width, clearly
        // not this line's ordinary space.
        // The em is the current font's: a heading's \quad is in the heading font, not the body's.
        let rigid = |g: f64, normal: f64, quad: f64| -> Option<u32> {
            if (normal - g).abs() < 0.02 {
                return None;
            }
            [(quad, 4u32), (quad / 2.0, 5), (quad * 0.16667, 6)].iter().find(|(w, _)| (g - w).abs() < 0.006).map(|x| x.1)
        };
        for &(i, g) in &others {
            let q = tf(get(&items[i]).0).map_or(quad, |f| f.quad * k);
            if let Some(m) = rigid(g, pred(1000.0), q) {
                set(&mut items[i], Some(m));
            }
        }
        for (i, d, g) in gaps {
            if let Some(m) = rigid(g, pred(d as f64), quad) {
                set(&mut items[i], Some(m));
                continue;
            }
            let ed = (pred(d as f64) - g).abs();
            let mut best = (d, ed);
            // 2 stands for two spaces (`~` and a space, or `\ \ `): twice the factor-1000 glue.
            for c in [1000u32, 3000, 2] {
                if (d == 1000 || d == 999) && c != 2 {
                    continue;
                }
                let e = (if c == 2 { 2.0 * pred(1000.0) } else { pred(c as f64) } - g).abs();
                if e + 0.005 < best.1 {
                    best = (c, e);
                }
            }
            // \newblock (bibliographies): the space after a block's final period, then \hskip .11em plus .33em.
            // 7: that space with its default factor, 8: with factor 1000 (bibliographies set \sfcode`\.=1000).
            if bib && d >= 2000 {
                let nb = 0.11 * quad + if r >= 0.0 { r * 0.33 * quad } else { r * 0.07 * quad };
                for (c, base) in [(7u32, pred(d as f64)), (8, pred(1000.0))] {
                    let e = (base + nb - g).abs();
                    if e + 0.005 < best.1 {
                        best = (c, e);
                    }
                }
            }
            if best.0 != d {
                set(&mut items[i], Some(best.0));
            }
        }
    }
}

/// Where to put line `i`'s box (sp from the page's left edge) so that its first glyph starts with the same rounding
/// residual as in the original: pdfTeX writes each glyph's kern from (exact position − its PDF position), and the
/// original's PDF position at a line start (`line_h`) carries the history of the page's Td chain. A fresh text
/// object here starts at the printed grid, so the box moves by up to ~33 sp to make the residual equal.
pub fn line_place(p: &Para, hyp: &Hyp, i: usize) -> i64 {
    let l = &p.lines[i.min(p.lines.len() - 1)];
    let left = hyp.left_of(l.left, l.right);
    let o = if i == 0 && p.label > 0 {
        sp(l.glyphs[0].x - l.left)
    } else if i == 0 && p.start == crate::layout::Start::Indented {
        hyp.params.parindent_sp
    } else if i > 0 {
        hyp.params.hang_sp
    } else {
        0
    };
    if i >= p.lines.len() || p.display || std::env::var("PDFSOURCE_NORESID").is_ok() {
        return left;
    }
    let a = left + o;
    let r = a - l.glyphs[0].line_h + hyp.resid.get(&i).copied().unwrap_or(0);
    if r.abs() > 80 {
        return left;
    }
    let mut best: Option<(i64, i64)> = None; // (|a' − a|, a')
    for d in -100..=100 {
        let ap = a + d;
        let so = crate::pdf::divide_scaled_bp(ap).1;
        if ap - so == r && best.map_or(true, |b| d.abs() < b.0) {
            best = Some((d.abs(), ap));
        }
    }
    best.map(|b| b.1 - o).unwrap_or(left)
}

impl<'a> Gen<'a> {
    /// Per glyph of the paragraph (lines in order): (separator before it, dropped as TeX's own hyphen).
    pub fn item_meta(&self, p: &Para, hyp: &Hyp) -> Vec<(u8, bool)> {
        let n = p.lines.len();
        let mut v = vec![];
        for (li, l) in p.lines.iter().enumerate() {
            let hy = li + 1 < n && self.hyphen_at_end(l, hyp);
            let disc = hyp.hyph.get(&li).copied().unwrap_or(Hyph::Discretionary) == Hyph::Discretionary;
            for (gi, g) in l.glyphs.iter().enumerate() {
                let sep = if gi == 0 && li > 0 {
                    if self.hyphen_at_end(&p.lines[li - 1], hyp) { 2 } else { 1 }
                } else if gi > 0 && g.x - (l.glyphs[gi - 1].x + l.glyphs[gi - 1].adv) > 0.12 * g.size {
                    1
                } else {
                    0
                };
                v.push((sep, hy && disc && gi + 1 == l.glyphs.len()));
            }
        }
        v
    }
}

impl<'a> Gen<'a> {
    /// Glyph ranges of a line that are inline math: math fonts, glyphs off the baseline, and (when the text font
    /// isn't CM) CM roman digits and operators; in CM text, CM roman non-letters touching math.
    pub fn math_spans(&self, l: &Line, cm_text: bool) -> Result<Vec<(usize, usize)>, String> {
        use crate::math::{math_font, MathFont::*};
        let n = l.glyphs.len();
        let mut m: Vec<bool> = l
            .glyphs
            .iter()
            .map(|g| {
                let mf = math_font(&self.pdf.fonts[g.font]);
                (g.y - l.y).abs() > 0.01
                    || matches!(mf, Some(Italic | BoldItalic | Symbols | Ext | Msbm | Msam))
                    || (matches!(mf, Some(Roman | Bold)) && !cm_text)
            })
            .collect();
        if cm_text {
            loop {
                let mut changed = false;
                for i in 0..n {
                    if m[i] {
                        continue;
                    }
                    let g = &l.glyphs[i];
                    let roman = matches!(math_font(&self.pdf.fonts[g.font]), Some(Roman | Bold));
                    let letter = char::from_u32(g.code).is_some_and(|c| c.is_ascii_alphabetic());
                    let touch = |j: usize| {
                        let (a, b) = if j < i { (&l.glyphs[j], g) } else { (g, &l.glyphs[j]) };
                        m[j] && b.x - (a.x + a.adv) < 0.35 * g.size
                    };
                    if roman && !letter && ((i > 0 && touch(i - 1)) || (i + 1 < n && touch(i + 1))) {
                        m[i] = true;
                        changed = true;
                    }
                }
                if !changed {
                    break;
                }
            }
        }
        let mut spans = vec![];
        let mut i = 0;
        while i < n {
            if m[i] {
                let a = i;
                while i < n && m[i] {
                    i += 1;
                }
                spans.push((a, i));
            } else {
                i += 1;
            }
        }
        Ok(spans)
    }
}

/// LaTeX's accent command for an accent glyph name (OT1 `\accent` accents drawn over the next letter).
pub fn accent_cmd(name: &str) -> Option<&'static str> {
    Some(match name {
        "acute" => "'",
        "grave" => "`",
        "dieresis" => "\"",
        "circumflex" => "^",
        "tilde" => "~",
        "macron" => "=",
        "dotaccent" => ".",
        "breve" => "u",
        "caron" => "v",
        "hungarumlaut" => "H",
        "ring" => "r",
        _ => return None,
    })
}

/// The label separation in sp: the measured gap, snapped to the nicest TeX length within 80 sp.
/// A measured length snapped to a short TeX length (at most one decimal in some unit) within `reach` sp, else as is.
pub fn snap_short(v: i64, reach: i64) -> i64 {
    (v - reach..=v + reach).map(|c| (nice_rank(c), (c - v).abs(), c)).filter(|e| e.0 < 20).min().map_or(v, |e| e.2)
}

pub fn texgen_label_sep(gap_bp: f64) -> i64 {
    let c = sp(gap_bp);
    (c - 80..=c + 80).min_by_key(|v| (nice_rank(*v), (v - c).abs())).unwrap_or(c)
}
