//! Proof by reproduction: typeset every paragraph again from the recovered text and parameters, read the result
//! with the same reader, compare every line break and glyph position. Search the parameters on a mismatch.

use crate::layout::{lines_of, Doc, Line, Para, Start};
use crate::pdf::Pdf;
use crate::texgen::{self, size_key, Gen, Hyp, Hyph, Params, TexFont};
use crate::texmf::Texmf;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::process::Command;
use std::time::Instant;

/// Tolerance on glyph x, in bp: pdfTeX writes positions with 3 decimals.
const TOL: f64 = 0.0015;

#[derive(Debug, Clone)]
pub struct Outcome {
    pub proven: bool,
    pub reason: String,
    pub max_dx: f64,
    pub tries: usize,
    pub source: String,
    pub hyp: Option<Hyp>,
    /// The LaTeX setup of the run that proved it ("microtype|family|size|packages"), if not the plain one.
    pub pre: String,
}

pub struct Report {
    pub file: String,
    pub pages: usize,
    pub paras: Vec<(usize, Outcome)>,
    pub doc_lines: usize,
    pub para_lines: Vec<usize>,
    pub words: Vec<usize>,
    pub other_lines: usize,
    pub tex_runs: usize,
    pub ms_total: f64,
    pub ms_tex: f64,
    pub geometry: String,
    /// Font macros for the emitted LaTeX.
    pub fonts_tex: String,
}

/// The parameter sets tried in order when line breaks differ (LaTeX's defaults first, then common settings).
const BREAKS: [(i32, i32, f64); 6] = [(200, 100, 0.0), (9999, 100, 3.0 * 10.0), (1000, 100, 0.0), (400, 100, 0.0), (200, 100, 10.0), (10000, -1, 0.0)];

struct State {
    hyp: Hyp,
    break_set: usize,
    flipped: Vec<usize>,
    tries: usize,
    done: Option<Outcome>,
    last_reason: String,
    /// Lines whose residual was searched.
    searched: std::collections::HashSet<usize>,
}

fn tex_env() -> Vec<(String, String)> {
    let r = crate::texmf::ref_dir();
    let tl = std::env::var("PDFSOURCE_TLROOT").unwrap_or_else(|_| r.join("texlive-2026/store-root").display().to_string());
    vec![
        ("TEXMFCNF".into(), format!("{tl}-cnf:{tl}/texmf-dist/web2c")),
        ("TEXFORMATS".into(), format!(".:{}", r.join("universal/fmt-2026").display())),
        ("SOURCE_DATE_EPOCH".into(), "1700000000".into()),
        ("FORCE_SOURCE_DATE".into(), "1".into()),
    ]
}

fn pdflatex() -> PathBuf {
    std::env::var("PDFSOURCE_PDFLATEX").map(PathBuf::from).unwrap_or_else(|_| {
        crate::texmf::ref_dir().join("universal/bin-static/pdflatex")
    })
}

/// One comparison of a re-typeset paragraph with the original.
#[derive(Debug, Clone)]
pub struct Cmp {
    pub ok: bool,
    pub why: String,
    pub bad_line: Option<usize>,
    pub max_dx: f64,
    /// Glyphs out of place (1000 per line if the lines differ): the calibration's score.
    pub misses: usize,
    pub text: String,
    /// A break the reproduction took that the original didn't: (glyph index, true = a space, false = in a word).
    pub forbid: Option<(usize, bool)>,
    /// |dx| of the first glyph out of place.
    pub first_dx: f64,
}

struct Ctx<'a> {
    pdf: &'a Pdf,
    doc: &'a Doc,
    tg: Gen<'a>,
    fonts: &'a HashMap<usize, Vec<TexFont>>,
    main: Vec<usize>,
    work: PathBuf,
    size: (f64, f64),
    runs: usize,
    ms_tex: f64,
    /// Some(microtype options) when the PDF shows font expansion: run as a LaTeX document with microtype.
    latex: Option<String>,
}

impl<'a> Ctx<'a> {
    /// Typeset each (paragraph, hypothesis) on its own page in one pdfLaTeX run and compare.
    fn batch(&mut self, items: &[(usize, Hyp)]) -> Vec<Cmp> {
        let mut out: Vec<Option<Cmp>> = vec![None; items.len()];
        let mut body = String::new();
        let mut shipped: Vec<(usize, String)> = vec![];
        for (j, (i, hyp)) in items.iter().enumerate() {
            let p = &self.doc.paras[*i];
            match self.tg.para_input(p, hyp, self.main[*i]) {
                Ok(text) => {
                    let sel: Vec<(usize, usize)> = hyp.font_choice.iter().map(|(&k, &c)| (k, c)).collect();
                    body.push_str(&texgen::para_page(&text, p, hyp, &sel));
                    shipped.push((j, text));
                }
                Err(e) => out[j] = Some(Cmp { ok: false, why: e, bad_line: None, max_dx: 0.0, misses: usize::MAX, text: String::new(), forbid: None, first_dx: 0.0 }),
            }
        }
        if !shipped.is_empty() {
            let fonts = self.fonts;
            let all = |k: usize| -> Vec<usize> { (0..fonts.get(&k).map_or(0, |v| v.len())).collect() };
            let pre = texgen::preamble(fonts, &all, self.size.0, self.size.1, self.latex.as_deref());
            let job = format!("r{}", self.runs);
            std::fs::write(self.work.join(format!("{job}.tex")), format!("{pre}{body}\\PSend\n")).unwrap();
            let _ = std::fs::remove_file(self.work.join(format!("{job}.pdf")));
            let t = Instant::now();
            let _ = Command::new(pdflatex())
                .args(["-interaction=batchmode", &format!("{job}.tex")])
                .current_dir(&self.work)
                .envs(tex_env())
                .stdin(std::process::Stdio::null())
                .output();
            self.ms_tex += t.elapsed().as_secs_f64() * 1000.0;
            self.runs += 1;
            let rp = self.work.join(format!("{job}.pdf"));
            let fail = |why: String| Cmp { ok: false, why, bad_line: None, max_dx: 0.0, misses: usize::MAX, text: String::new(), forbid: None, first_dx: 0.0 };
            match Pdf::open(rp.to_str().unwrap()) {
                Err(e) => {
                    for (j, _) in &shipped {
                        out[*j] = Some(fail(format!("tex: {e}")));
                    }
                }
                Ok(repro) if repro.page_count() != shipped.len() => {
                    for (j, _) in &shipped {
                        out[*j] = Some(fail(format!("tex: {} pages for {}", repro.page_count(), shipped.len())));
                    }
                }
                Ok(mut repro) => {
                    for (pi, (j, text)) in shipped.iter().enumerate() {
                        let page = repro.page(pi + 1).unwrap();
                        let lines = lines_of(pi + 1, &page.glyphs);
                        let (i, hyp) = &items[*j];
                        let mut c = compare(self.pdf, &repro, &self.doc.paras[*i], &lines, hyp);
                        if c.why.starts_with("breaks") {
                            if let Some(bl) = c.bad_line {
                                c.forbid = my_break(&self.tg, self.pdf, &repro, &self.doc.paras[*i], &lines, hyp, bl);
                            }
                        }
                        c.text = text.clone();
                        out[*j] = Some(c);
                    }
                }
            }
        }
        out.into_iter().map(|c| c.unwrap()).collect()
    }

    /// Score candidates for one parameter on a few paragraphs; returns the best value.
    fn scan(&mut self, paras: &[(usize, Hyp)], cands: &[i64], set: &dyn Fn(&mut Hyp, i64)) -> Option<(i64, usize)> {
        let mut items = vec![];
        for &v in cands {
            for (i, h) in paras {
                let mut h = h.clone();
                set(&mut h, v);
                items.push((*i, h));
            }
        }
        let res = self.batch(&items);
        let mut best: Option<(i64, usize, i64)> = None;
        for (ci, &v) in cands.iter().enumerate() {
            let score: usize = res[ci * paras.len()..(ci + 1) * paras.len()].iter().map(|c| c.misses.min(1_000_000)).sum();
            if std::env::var("PDFSOURCE_DEBUG").is_ok() {
                eprintln!("scan {v} {score}");
            }
            let dist = texgen::nice_rank(v) * 1_000_000 + (v - cands[cands.len() / 2]).abs();
            if best.map_or(true, |b| score < b.1 || (score == b.1 && dist < b.2)) {
                best = Some((v, score, dist));
            }
        }
        best.map(|b| (b.0, b.1))
    }
}

pub fn prove(pdf: &Pdf, doc: &Doc, file: &str) -> Report {
    let t0 = Instant::now();
    let mut tx = Texmf::new();
    // Fonts: every (PDF font, size) in paragraphs.
    let mut fkey: HashMap<(usize, i64), usize> = HashMap::new();
    let mut used: HashMap<usize, Vec<u32>> = HashMap::new();
    for p in &doc.paras {
        for l in &p.lines {
            for g in &l.glyphs {
                if g.size < 0.0 {
                    continue;
                }
                let n = fkey.len();
                let k = *fkey.entry((g.font, size_key(g.size))).or_insert(n);
                used.entry(k).or_default().push(g.code);
            }
        }
    }
    let mut fonts: HashMap<usize, Vec<TexFont>> = HashMap::new();
    for (&(fi, sk), &k) in &fkey {
        let mut u = used.remove(&k).unwrap_or_default();
        u.sort();
        u.dedup();
        fonts.insert(k, texgen::candidates(&mut tx, &pdf.fonts[fi], sk as f64 / 1000.0, &u));
        if std::env::var("PDFSOURCE_FONTS").is_ok() {
            for c in &fonts[&k] {
                eprintln!("font {} {:.3}: {} {} {:?}", pdf.fonts[fi].name, sk as f64 / 1000.0, c.tfm, c.size_pt, c.nfss);
            }
        }
    }
    let main: Vec<usize> = doc
        .paras
        .iter()
        .map(|p| {
            let mut h: HashMap<usize, usize> = HashMap::new();
            for l in &p.lines {
                for g in &l.glyphs {
                    *h.entry(*fkey.get(&(g.font, size_key(g.size))).unwrap_or(&usize::MAX)).or_default() += 1;
                }
            }
            h.into_iter().max_by_key(|e| (e.1, std::cmp::Reverse(e.0))).map(|e| e.0).unwrap_or(0)
        })
        .collect();
    let work = std::env::var("PDFSOURCE_WORK").map(PathBuf::from).unwrap_or_else(|_| std::env::temp_dir().join("pdfsource"));
    let _ = std::fs::create_dir_all(&work);
    // Under microtype, prefer the body family's own .fd where it maps the same TFM (microtype only treats the
    // \rmdefault family; TS1/cmr maps to Latin Modern, for one).
    if doc.paras.iter().flat_map(|p| p.lines.iter()).flat_map(|l| l.glyphs.iter()).any(|g| (g.hscale - 1.0).abs() > 1e-4) {
        let mut h: HashMap<usize, usize> = HashMap::new();
        for m in &main {
            *h.entry(*m).or_default() += 1;
        }
        let _ = h;
        let body = *fkey.get(&(doc.body_font, size_key(doc.body_size))).unwrap_or(&0);
        let fam = fonts.get(&body).and_then(|c| c.iter().find_map(|f| f.nfss.as_ref())).map(|n| n.1.clone()).unwrap_or("cmr".into());
        for c in fonts.values_mut().flatten() {
            if let Some((e, f, _, _)) = c.nfss.clone() {
                if f != fam {
                    if let Some(n) = tx.nfss_in(&e, &fam, &c.tfm, c.size_pt) {
                        c.nfss = Some(n);
                    }
                }
            }
        }
    }
    let mut cx = Ctx { pdf, doc, tg: Gen { pdf, fonts: &fonts, fkey: &fkey }, fonts: &fonts, main, work, size: pdf_page_size(pdf), runs: 0, ms_tex: 0.0, latex: None };
    if doc.paras.iter().flat_map(|p| p.lines.iter()).flat_map(|l| l.glyphs.iter()).any(|g| (g.hscale - 1.0).abs() > 1e-4) {
        // The body font's NFSS family is \rmdefault.
        let mut h: HashMap<usize, usize> = HashMap::new();
        for m in &cx.main {
            *h.entry(*m).or_default() += 1;
        }
        let _ = h;
        let body = *fkey.get(&(doc.body_font, size_key(doc.body_size))).unwrap_or(&0);
        let fam = fonts.get(&body).and_then(|c| c.iter().find_map(|f| f.nfss.as_ref())).map(|n| n.1.clone()).unwrap_or("cmr".into());
        cx.latex = Some(format!("{}|{fam}", std::env::var("PDFSOURCE_MICROTYPE").unwrap_or_default()));
    }
    // Math needs LaTeX's math fonts: a document of the body's size with amsmath (and amssymb for the AMS fonts).
    let has = |p: &dyn Fn(&str) -> bool| doc.paras.iter().flat_map(|q| q.lines.iter()).flat_map(|l| l.glyphs.iter()).any(|g| p(&pdf.fonts[g.font].name));
    if has(&|n: &str| crate::math::math_font(&crate::pdf::Font { name: n.to_string(), ..pdf.fonts[0].clone() }).is_some_and(|m| m != crate::math::MathFont::Roman && m != crate::math::MathFont::Bold)) {
        let pt = doc.body_size * 72.27 / 72.0;
        let size = if pt < 10.5 { "10pt" } else if pt < 11.5 { "11pt" } else { "12pt" };
        let mut pk = String::from(if has(&|n: &str| n.starts_with("MSBM") || n.starts_with("MSAM")) { "amsmath,amssymb" } else { "amsmath" });
        // Bold math italic: with bm loaded \boldsymbol is \bm, whose scripts sit as on a plain character.
        if has(&|n: &str| n.starts_with("CMMIB") || n.starts_with("CMBSY")) {
            pk += ",bm";
        }
        let (mt, rm) = match &cx.latex { Some(l) => { let v: Vec<&str> = l.split('|').collect(); (v[0].to_string(), v.get(1).unwrap_or(&"cmr").to_string()) } None => ("-".to_string(), "cmr".to_string()) };
        cx.latex = Some(format!("{mt}|{rm}|{size}|{pk}"));
    }

    let mut font_choice = HashMap::new();
    for (&k, c) in &fonts {
        if !c.is_empty() {
            font_choice.insert(k, 0);
        }
    }
    // Column geometry: hsize per column (right − left), the paragraph indent.
    let mut hsize: HashMap<i64, i64> = doc.columns.iter().map(|c| (ckey2(c.left, c.right), texgen::sp(c.right - c.left))).collect();
    let mut parindent = texgen::sp(doc.parindent);
    let mut lefts: HashMap<i64, i64> = HashMap::new();
    derive_blocks(doc, &mut hsize, &mut lefts);
    let base = |p: &Para, hsize: &HashMap<i64, i64>, parindent: i64, lefts: &HashMap<i64, i64>| Hyp {
        params: Params {
            hsize_sp: *hsize.get(&ckey2(p.column.left, p.column.right)).unwrap_or(&texgen::sp(p.column.right - p.column.left)),
            parindent_sp: if p.start == Start::Indented { parindent } else { 0 },
            left_sp: 0,
            tolerance: 200,
            pretolerance: 100,
            emergencystretch_pt: 0.0,
            italic_correction: true,
            ams_bold: false,
            hang_sp: if p.hang > 0.0 { if (texgen::sp(p.hang) - parindent).abs() < 200 { parindent } else { texgen::sp(p.hang) } } else { 0 },
        },
        font_choice: font_choice.clone(),
        hyph: HashMap::new(),
        lefts: lefts.clone(),
        resid: HashMap::new(),
        ties: Default::default(),
        nohyph: Default::default(),
    };

    let mut states: Vec<State> = doc
        .paras
        .iter()
        .map(|p| State { hyp: base(p, &hsize, parindent, &lefts), break_set: 0, flipped: vec![], tries: 0, done: None, last_reason: String::new(), searched: Default::default() })
        .collect();
    for (i, p) in doc.paras.iter().enumerate() {
        if let Some(r) = precheck(pdf, p).or_else(|| strays(doc, p)) {
            states[i].done = Some(Outcome { proven: false, reason: r, max_dx: 0.0, tries: 0, source: String::new(), hyp: None, pre: String::new() });
        }
    }

    if let Ok(f) = std::env::var("PDFSOURCE_FORCE") {
        // Debug: hsize,left,parindent in sp; skip calibration.
        let v: Vec<i64> = f.split(',').filter_map(|s| s.parse().ok()).collect();
        for st in states.iter_mut() {
            st.hyp.params.hsize_sp = v[0];
            if let Some(c) = doc.columns.first() { st.hyp.lefts.insert(ckey2(c.left, c.right), v[1]); }
            if let (Some(c), Some(&l2)) = (doc.columns.get(1), v.get(3)) { st.hyp.lefts.insert(ckey2(c.left, c.right), l2); }
            if st.hyp.params.parindent_sp != 0 { st.hyp.params.parindent_sp = v[2]; }
        }
    }
    let microtype = cx.latex.as_ref().is_some_and(|l| !l.starts_with('-'));
    let mut calibrated = std::env::var("PDFSOURCE_FORCE").is_ok();
    // Preamble alternatives tried in turn on what is still unproven: with bm, then without (bm moves some scripts).
    let mut variants = vec![cx.latex.clone()];
    if let Some(l) = cx.latex.as_ref().filter(|l| l.ends_with(",bm")) {
        variants.push(Some(l.trim_end_matches(",bm").to_string()));
    }
    for (vi, var) in variants.iter().enumerate() {
    if vi > 0 {
        cx.latex = var.clone();
        for (i, st) in states.iter_mut().enumerate() {
            if st.done.as_ref().is_some_and(|o| !o.proven && o.hyp.is_some()) {
                st.done = None;
                st.hyp = base(&doc.paras[i], &hsize, parindent, &lefts);
                st.break_set = 0;
                st.flipped.clear();
                st.searched.clear();
            }
        }
    }
    for _round in 0..40 {
        let todo: Vec<usize> = (0..states.len()).filter(|&i| states[i].done.is_none()).collect();
        if todo.is_empty() {
            break;
        }
        let items: Vec<(usize, Hyp)> = todo.iter().map(|&i| (i, states[i].hyp.clone())).collect();
        let res = cx.batch(&items);
        for (&i, c) in todo.iter().zip(&res) {
            states[i].tries += 1;
            if c.ok {
                states[i].done = Some(Outcome { proven: true, reason: String::new(), max_dx: c.max_dx, tries: states[i].tries, source: c.text.clone(), hyp: Some(states[i].hyp.clone()), pre: cx.latex.clone().unwrap_or_default() });
            }
        }
        // After the first round: calibrate each column's geometry on paragraphs whose lines already match.
        if !calibrated {
            calibrated = true;
            let mut changed = false;
            for col in &doc.columns[..doc.n_main] {
                let mut cal: Vec<(usize, usize)> = todo
                    .iter()
                    .zip(&res)
                    .filter(|e| { let (i, c) = (*e.0, e.1); (c.ok || (c.why.starts_with("positions") && (c.max_dx < 0.05 || microtype))) && ((doc.paras[i].column.right - doc.paras[i].column.left) - (col.right - col.left)).abs() < 0.02 && !doc.paras[i].joined })
                    .map(|(&i, _)| (i, doc.paras[i].lines.len()))
                    .collect();
                cal.sort_by_key(|e| std::cmp::Reverse(e.1));
                cal.truncate(40);
                if cal.is_empty() {
                    continue;
                }
                let few: Vec<(usize, usize)> = cal.iter().take(6).copied().collect();
                let k = ckey2(col.left, col.right);
                let mk = |set: &[(usize, usize)], hs: &HashMap<i64, i64>, pi: i64, lf: &HashMap<i64, i64>| -> Vec<(usize, Hyp)> {
                    set.iter().map(|&(i, _)| (i, base(&doc.paras[i], hs, pi, lf))).collect()
                };
                for pass in 0..2 {
                    // hsize: coarse (8 sp steps) on the first pass, then 1 sp around the best; the score is smooth in it.
                    for (step, reach) in if pass == 0 { vec![(8i64, 80i64), (1, 8)] } else { vec![(1, 8)] } {
                        let h0 = hsize[&k];
                        let cands: Vec<i64> = (-reach..=reach).map(|d| h0 + step * d).collect();
                        let set = if step > 1 { &few } else { &cal };
                        if let Some((v, _)) = cx.scan(&mk(set, &hsize, parindent, &lefts), &cands, &|h, v| h.params.hsize_sp = v) {
                            changed |= v != h0;
                            // Columns of one width share it.
                            for c in &doc.columns {
                                if ((c.right - c.left) - (col.right - col.left)).abs() < 0.02 {
                                    hsize.insert(ckey2(c.left, c.right), v);
                                }
                            }
                        }
                    }
                    let l0 = *lefts.get(&ckey2(col.left, col.right)).unwrap_or(&texgen::sp(col.left));
                    // Wide on the first pass with a few paragraphs, then narrow with all of them.
                    let (reach, set) = if pass == 0 { (40, &few) } else { (3, &cal) };
                    let cands: Vec<i64> = (-reach..=reach).map(|d| l0 + d).collect();
                    if let Some((v, _)) = cx.scan(&mk(set, &hsize, parindent, &lefts), &cands, &|h, v| {
                        h.lefts.insert(ckey2(col.left, col.right), v);
                    }) {
                        changed |= v != l0;
                        lefts.insert(k, v);
                    }
                    // Along the ridge: left + d with hsize − d keeps the right edge (the two trade off).
                    {
                        let h0 = hsize[&k];
                        let l0 = *lefts.get(&k).unwrap_or(&texgen::sp(col.left));
                        let cands: Vec<i64> = (-8..=8).map(|d| h0 + d).collect();
                        if let Some((v, _)) = cx.scan(&mk(&cal, &hsize, parindent, &lefts), &cands, &|h, v| {
                            h.params.hsize_sp = v;
                            h.lefts.insert(k, l0 + (h0 - v));
                        }) {
                            if v != h0 {
                                changed = true;
                                lefts.insert(k, l0 + (h0 - v));
                                for c in &doc.columns {
                                    if ((c.right - c.left) - (col.right - col.left)).abs() < 0.02 {
                                        hsize.insert(ckey2(c.left, c.right), v);
                                    }
                                }
                            }
                        }
                    }
                    if pass == 0 && cal.iter().any(|&(i, _)| doc.paras[i].start == Start::Indented) {
                        let p0 = parindent;
                        let ind: Vec<(usize, usize)> = cal.iter().filter(|e| doc.paras[e.0].start == Start::Indented).take(6).copied().collect();
                        let cands: Vec<i64> = (-40..=40).map(|d| p0 + d).collect();
                        if let Some((v, _)) = cx.scan(&mk(&ind, &hsize, parindent, &lefts), &cands, &|h, v| {
                            if h.params.parindent_sp != 0 {
                                h.params.parindent_sp = v
                            }
                        }) {
                            changed |= v != p0;
                            parindent = v;
                        }
                    }
                }
            }
            derive_blocks(doc, &mut hsize, &mut lefts);
            if changed {
                for (i, st) in states.iter_mut().enumerate() {
                    if st.done.as_ref().is_some_and(|o| o.proven) {
                        st.done = None;
                    }
                    if st.done.is_none() {
                        st.hyp = base(&doc.paras[i], &hsize, parindent, &lefts);
                        st.break_set = 0;
                        st.flipped.clear();
                    }
                }
                continue;
            }
        }
        let mut rsearch: Vec<(usize, usize)> = vec![];
        for (&i, c) in todo.iter().zip(&res) {
            let st = &mut states[i];
            if st.done.is_some() {
                continue;
            }
            let p = &doc.paras[i];
            st.last_reason = c.why.clone();
            let mut moved = false;
            if c.why.starts_with("breaks") {
                let upto = c.bad_line.unwrap_or(p.lines.len()).min(p.lines.len() - 1);
                for li in (0..=upto).rev() {
                    if li + 1 < p.lines.len() && cx.tg.hyphen_at_end(&p.lines[li], &st.hyp) && !st.flipped.contains(&li) {
                        st.flipped.push(li);
                        let cur = st.hyp.hyph.get(&li).copied().unwrap_or(Hyph::Discretionary);
                        st.hyp.hyph.insert(li, if cur == Hyph::Discretionary { Hyph::Explicit } else { Hyph::Discretionary });
                        moved = true;
                        break;
                    }
                }
                if !moved && st.hyp.ties.len() + st.hyp.nohyph.len() < 16 {
                    if let Some((at, space)) = c.forbid {
                        let set = if space { &mut st.hyp.ties } else { &mut st.hyp.nohyph };
                        moved = set.insert(at);
                    }
                }
                if !moved && st.break_set + 1 < BREAKS.len() {
                    st.break_set += 1;
                    let (t, pt, es) = BREAKS[st.break_set];
                    st.hyp.params.tolerance = t;
                    st.hyp.params.pretolerance = pt;
                    st.hyp.params.emergencystretch_pt = es;
                    st.hyp.hyph.clear();
                    st.flipped.clear();
                    moved = true;
                }
            } else if c.why.starts_with("positions") && c.first_dx < 0.0105 && c.bad_line.is_some() {
                // One unit off: the line start's residual (known to a few sp) is searched below, once per line.
                let li = c.bad_line.unwrap();
                if st.searched.insert(li) {
                    rsearch.push((i, li));
                    moved = true;
                }
            } else if c.why.contains(" dy ") && !st.hyp.params.ams_bold && c.text.contains("boldsymbol") {
                // Scripts on bold math sit differently under bm and amsmath.
                st.hyp.params.ams_bold = true;
                moved = true;
            } else if c.why.starts_with("unmapped glyph") {
                // Another candidate of the same font that maps every code this paragraph uses (a TS1 bullet among OT1 text).
                for l in &p.lines {
                    for g in &l.glyphs {
                        let k = cx.tg.k(g);
                        let Some(cands) = fonts.get(&k) else { continue };
                        let cur = *st.hyp.font_choice.get(&k).unwrap_or(&0);
                        if cands.get(cur).is_some_and(|f| f.input.contains_key(&g.code)) {
                            continue;
                        }
                        let codes: Vec<u32> = p.lines.iter().flat_map(|q| q.glyphs.iter()).filter(|x| cx.tg.k(x) == k).map(|x| x.code).collect();
                        if let Some(ni) = (0..cands.len()).find(|&ci| codes.iter().all(|c| cands[ci].input.contains_key(c))) {
                            st.hyp.font_choice.insert(k, ni);
                            moved = true;
                        }
                    }
                }
            } else if st.hyp.params.italic_correction && c.why.contains("after-italic") {
                st.hyp.params.italic_correction = false;
                moved = true;
            }
            if !moved {
                st.done = Some(Outcome { proven: false, reason: c.why.clone(), max_dx: c.max_dx, tries: st.tries, source: c.text.clone(), hyp: Some(st.hyp.clone()), pre: String::new() });
            }
        }
        if !rsearch.is_empty() {
            // All residual offsets for each such line in one run; keep the one that gets furthest (smallest |d| on ties).
            let offs: Vec<i64> = (-33..=33).collect();
            let mut items = vec![];
            for &(i, li) in &rsearch {
                for &d in &offs {
                    let mut h = states[i].hyp.clone();
                    h.resid.insert(li, d);
                    items.push((i, h));
                }
            }
            let res = cx.batch(&items);
            for (n, &(i, li)) in rsearch.iter().enumerate() {
                let mut best: Option<(usize, i64)> = None; // (progress, d)
                for (k, &d) in offs.iter().enumerate() {
                    let c = &res[n * offs.len() + k];
                    let prog = if c.ok { usize::MAX } else { c.bad_line.unwrap_or(0) };
                    if prog > li && best.map_or(true, |b| prog > b.0 || (prog == b.0 && d.abs() < b.1.abs())) {
                        best = Some((prog, d));
                    }
                }
                if let Some((_, d)) = best {
                    states[i].hyp.resid.insert(li, d);
                }
            }
        }
    }
    }
    if let Ok(n) = std::env::var("PDFSOURCE_SHOW").map(|s| s.parse::<usize>().unwrap_or(0)) {
        if let Some(st) = states.get(n) {
            let p = &doc.paras[n];
            let src = cx.tg.para_input(p, &st.hyp, cx.main[n]).unwrap_or_else(|e| e);
            eprintln!("--- para {n}: {:?}\n{}", st.hyp.params, src.replace('\u{1}', "\\").replace('\u{2}', "{").replace('\u{3}', "}"));
            for l in &p.lines {
                let mut s = String::new();
                let mut last: Option<&crate::pdf::Glyph> = None;
                for g in &l.glyphs {
                    if let Some(q) = last {
                        let gap = g.x - (q.x + q.adv);
                        if gap.abs() > 0.01 { s += &format!("[{gap:.3}]"); }
                    }
                    s += &crate::layout::glyph_text(&pdf.fonts[g.font], g.code);
                    last = Some(g);
                }
                s = format!("[h={} x={:.4} place={}] {s}", l.glyphs[0].line_h, l.glyphs[0].x, texgen::line_place(p, &st.hyp, p.lines.iter().position(|q| std::ptr::eq(q, l)).unwrap()));
                eprintln!("  {s}");
            }
        }
    }
    let paras: Vec<(usize, Outcome)> = states
        .into_iter()
        .enumerate()
        .map(|(i, s)| {
            let r = s.last_reason.clone();
            (i, s.done.unwrap_or(Outcome { proven: false, reason: r, max_dx: 0.0, tries: s.tries, source: String::new(), hyp: None, pre: String::new() }))
        })
        .collect();
    Report {
        file: file.to_string(),
        pages: doc.pages,
        paras,
        doc_lines: doc.lines.len(),
        para_lines: doc.paras.iter().map(|p| p.lines.len()).collect(),
        words: doc.paras.iter().map(words_in).collect(),
        other_lines: doc.other_lines,
        tex_runs: cx.runs,
        ms_total: t0.elapsed().as_secs_f64() * 1000.0,
        ms_tex: cx.ms_tex,
        fonts_tex: {
            // The body font's NFSS family and size: its variants become \normalfont + \itshape, \bfseries ...
            let bk = *fkey.get(&(doc.body_font, size_key(doc.body_size))).unwrap_or(&usize::MAX);
            let body = fonts.get(&bk).and_then(|c| c.first()).and_then(|f| f.nfss.clone().map(|n| (n, f.size_pt)));
            let mut v: Vec<String> = fonts
                .iter()
                .filter_map(|(&k, c)| c.first().map(|f| (k, f)))
                .map(|(k, f)| match &f.nfss {
                    Some((_, fa, se, sh)) if body.as_ref().is_some_and(|((_, bf, _, _), bs)| bf == fa && (bs - f.size_pt).abs() < 0.01) => {
                        let mut d = String::from("\\normalfont");
                        if se.starts_with('b') { d += "\\bfseries"; }
                        match sh.as_str() { "it" => d += "\\itshape", "sl" => d += "\\slshape", "sc" => d += "\\scshape", _ => {} }
                        format!("\\newcommand\\{}{{{d}}}", texgen::font_cs(k))
                    }
                    Some((e, fa, se, sh)) => format!("\\newcommand\\{}{{\\fontsize{{{}}}{{{}}}\\usefont{{{e}}}{{{fa}}}{{{se}}}{{{sh}}}}}", texgen::font_cs(k), f.size_pt, f.size_pt * 1.2),
                    None => format!("\\font\\{}={} at {}pt", texgen::font_cs(k), f.tfm, f.size_pt),
                })
                .collect();
            v.sort();
            if let Some(((_, fam, _, _), _)) = &body {
                v.insert(0, format!("\\renewcommand\\rmdefault{{{fam}}}"));
            }
            v.join("\n")
        },
        geometry: format!(
            "hsize {:?} lefts {:?} parindent {}sp",
            hsize.values().collect::<Vec<_>>(),
            lefts.values().collect::<Vec<_>>(),
            parindent
        ),
    }
}

fn ckey(left_bp: f64) -> i64 {
    (left_bp * 100.0).round() as i64
}

/// A column's key for its geometry: left and right edge (a list block can share an abstract's left edge).
pub fn ckey2(left: f64, right: f64) -> i64 {
    texgen::colkey(left, right)
}
fn words_in(p: &Para) -> usize {
    let mut n = 0;
    for l in &p.lines {
        n += 1;
        for w in l.glyphs.windows(2) {
            if w[1].x - (w[0].x + w[0].adv) > 0.12 * w[1].size.abs() {
                n += 1;
            }
        }
    }
    n
}

fn pdf_page_size(pdf: &Pdf) -> (f64, f64) {
    let pages = pdf.doc.get_pages();
    if let Some(id) = pages.values().next() {
        if let Ok(d) = pdf.doc.get_dictionary(*id) {
            if let Ok(lopdf::Object::Array(a)) = d.get(b"MediaBox") {
                let v: Vec<f64> = a.iter().map(|o| o.as_float().map(|f| f as f64).or(o.as_i64().map(|i| i as f64)).unwrap_or(0.0)).collect();
                if v.len() == 4 {
                    return (v[2] - v[0], v[3] - v[1]);
                }
            }
        }
    }
    (612.0, 792.0)
}

/// Reasons known before typesetting.
fn precheck(pdf: &Pdf, p: &Para) -> Option<String> {
    for l in &p.lines {
        for g in &l.glyphs {
            let n = pdf.fonts[g.font].name.to_ascii_uppercase();
        }
        // Accents: a glyph drawn over the previous one.
        for w in l.glyphs.windows(2) {
            let on = |g: &crate::pdf::Glyph| (g.y - l.y).abs() < 0.01;
            let accent = pdf.fonts[w[0].font].names.get(&w[0].code).is_some_and(|n| texgen::accent_cmd(n).is_some());
            if on(&w[0]) && on(&w[1]) && !accent && w[1].x < w[0].x + w[0].adv - 0.3 * w[0].size {
                return Some("accent or overlap".into());
            }
        }
    }
    None
}

/// Same lines, same glyphs, same x (relative to the column's left), same offsets from the baseline.
/// Same lines, same glyphs, same x (relative to each line's column left), same offsets from the baseline.
fn compare(pdf: &Pdf, repro: &Pdf, p: &Para, lines: &[Line], hyp: &Hyp) -> Cmp {
    let mut max_dx: f64 = 0.0;
    let mut misses = 0usize;
    let mut first: Option<(String, usize)> = None;
    let mut first_dx = 0.0;
    let txt = |f: &Pdf, g: &crate::pdf::Glyph| crate::layout::glyph_text(&f.fonts[g.font], g.code);
    let n = p.lines.len().min(lines.len());
    for i in 0..n {
        let (a, b) = (&p.lines[i], &lines[i]);
        let _ = hyp.left_of(a.left, a.right);
        let same = |x: &crate::pdf::Glyph, y: &crate::pdf::Glyph| x.code == y.code && pdf.fonts[x.font].name == repro.fonts[y.font].name;
        if a.glyphs.len() != b.glyphs.len() || !a.glyphs.iter().zip(&b.glyphs).all(|(x, y)| same(x, y)) {
            misses += 1000;
            if first.is_none() {
                let k = a.glyphs.iter().zip(&b.glyphs).position(|(x, y)| !same(x, y));
                let at = k.unwrap_or(a.glyphs.len().min(b.glyphs.len()));
                let ctx: String = a.glyphs.iter().skip(at.saturating_sub(3)).take(6).map(|g| txt(pdf, g)).collect();
                let rtx: String = b.glyphs.iter().skip(at.saturating_sub(3)).take(6).map(|g| txt(repro, g)).collect();
                let detail = match (a.glyphs.get(at), b.glyphs.get(at)) {
                    (Some(x), Some(y)) => format!(" [{} {:.4} vs {} {:.4}]", pdf.fonts[x.font].name, x.hscale, repro.fonts[y.font].name, y.hscale),
                    _ => String::new(),
                };
                let why = if k.is_none() || (i > 0 && at < 3) || at + 6 >= a.glyphs.len().min(b.glyphs.len()) {
                    format!("breaks: line {i} glyph {at} ({ctx:?} vs {rtx:?})")
                } else {
                    format!("glyphs: line {i} glyph {at} ({ctx:?} vs {rtx:?}){detail}")
                };
                first = Some((why, i));
            }
            continue;
        }
        for (k, (x, y)) in a.glyphs.iter().zip(&b.glyphs).enumerate() {
            let dx = if k == 0 {
                (x.x - a.left) - (y.x - texgen::line_place(p, hyp, i) as f64 / texgen::SP_PER_BP)
            } else {
                (x.x - a.glyphs[0].x) - (y.x - b.glyphs[0].x)
            };
            let dy = (x.y - a.y) - (y.y - b.y);
            max_dx = max_dx.max(dx.abs());
            let ds = (x.hscale - y.hscale).abs();
            if dx.abs() > TOL || dy.abs() > TOL || ds > 1e-4 {
                misses += 1;
                if first.is_none() {
                    let after_font = k > 0 && pdf.fonts[a.glyphs[k - 1].font].name != pdf.fonts[x.font].name;
                    let what = if after_font { " after-italic" } else { "" };
                    let ctx: String = a.glyphs.iter().skip(k.saturating_sub(4)).take(6).map(|g| txt(pdf, g)).collect();
                    let scale = if ds > 1e-4 { format!(" scale {:.3} vs {:.3}", x.hscale, y.hscale) } else { String::new() };
                    let dys = if dy.abs() > TOL { format!(" dy {dy:+.4}") } else { String::new() };
                    first = Some((format!("positions: line {i} glyph {k} dx {dx:+.4}{dys}{scale}{what} ({ctx:?})"), i));
                    first_dx = if ds > 1e-4 { 1.0 } else { dx.abs() };
                }
            }
        }
    }
    if p.lines.len() != lines.len() {
        misses += 1000 * (p.lines.len() as i64 - lines.len() as i64).unsigned_abs() as usize;
        if first.is_none() {
            first = Some((format!("breaks: {} lines vs {}", p.lines.len(), lines.len()), n));
        }
    }
    match first {
        None => Cmp { ok: true, why: String::new(), bad_line: None, max_dx, misses: 0, text: String::new(), forbid: None, first_dx: 0.0 },
        Some((why, i)) => Cmp { ok: false, why, bad_line: Some(i), max_dx, misses, text: String::new(), forbid: None, first_dx },
    }
}

pub fn print(r: &Report, json: bool) {
    let total = r.paras.len();
    let proven = r.paras.iter().filter(|(_, o)| o.proven).count();
    let lines_all: usize = r.para_lines.iter().sum();
    let lines_proven: usize = r.paras.iter().filter(|(_, o)| o.proven).map(|(i, _)| r.para_lines[*i]).sum();
    let words_all: usize = r.words.iter().sum();
    let words_proven: usize = r.paras.iter().filter(|(_, o)| o.proven).map(|(i, _)| r.words[*i]).sum();
    let mut reasons: BTreeMap<String, usize> = BTreeMap::new();
    for (_, o) in &r.paras {
        if !o.proven {
            *reasons.entry(reason_class(&o.reason)).or_default() += 1;
        }
    }
    if json {
        let esc = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"").replace('\u{1}', "\\\\").replace('\u{3}', "}").replace('\n', " ");
        let mut s = format!(
            "{{\"file\":\"{}\",\"pages\":{},\"paras\":{},\"proven\":{},\"lines\":{},\"lines_proven\":{},\"words\":{},\"words_proven\":{},\"doc_lines\":{},\"other_lines\":{},\"tex_runs\":{},\"ms_total\":{:.1},\"ms_tex\":{:.1},\"reasons\":{{",
            esc(&r.file), r.pages, total, proven, lines_all, lines_proven, words_all, words_proven, r.doc_lines, r.other_lines, r.tex_runs, r.ms_total, r.ms_tex
        );
        s += &reasons.iter().map(|(k, v)| format!("\"{}\":{}", esc(k), v)).collect::<Vec<_>>().join(",");
        s += "},\"detail\":[";
        s += &r
            .paras
            .iter()
            .map(|(i, o)| format!("{{\"i\":{},\"lines\":{},\"proven\":{},\"reason\":\"{}\",\"tries\":{},\"max_dx\":{:.4}}}", i, r.para_lines[*i], o.proven, esc(&o.reason), o.tries, o.max_dx))
            .collect::<Vec<_>>()
            .join(",");
        s += "]}";
        println!("{s}");
        return;
    }
    println!(
        "{}: {} pages, {}/{} paragraphs proven ({:.1}%), lines {}/{}, words {}/{}; {} TeX runs, {:.0} ms ({:.0} in TeX)",
        r.file, r.pages, proven, total, 100.0 * proven as f64 / total.max(1) as f64, lines_proven, lines_all, words_proven, words_all,
        r.tex_runs, r.ms_total, r.ms_tex
    );
    println!("  geometry: {}", r.geometry);
    for (k, v) in &reasons {
        println!("  {v:4}  {k}");
    }
    for (i, o) in &r.paras {
        println!("¶{i} {} tries={} max_dx={:.4} {}", if o.proven { "PROVEN" } else { "no" }, o.tries, o.max_dx, o.reason);
    }
}

pub fn reason_class(r: &str) -> String {
    let r = r.split(':').next().unwrap_or(r);
    let r = r.split(" (").next().unwrap_or(r);
    if r.starts_with("unmapped glyph") {
        return "unmapped glyph".into();
    }
    if r.starts_with("font ") {
        return "font not found".into();
    }
    r.to_string()
}

/// Where the reproduction ended line `bad` (its first line that differs), as a glyph index of the original
/// paragraph, if that is a break the original didn't take: a space (tie it) or inside a word (don't hyphenate it).
fn my_break(tg: &Gen, pdf: &Pdf, repro: &Pdf, p: &Para, lines: &[Line], hyp: &Hyp, bad: usize) -> Option<(usize, bool)> {
    let meta = tg.item_meta(p, hyp);
    let glyphs: Vec<&crate::pdf::Glyph> = p.lines.iter().flat_map(|l| l.glyphs.iter()).collect();
    let flat: Vec<usize> = (0..glyphs.len()).filter(|&i| !meta[i].1).collect();
    let same = |x: &crate::pdf::Glyph, y: &crate::pdf::Glyph| x.code == y.code && pdf.fonts[x.font].name == repro.fonts[y.font].name;
    let mut k = 0;
    let mut hyphenated = false;
    for (j, l) in lines.iter().enumerate().take(bad + 1) {
        for (gi, g) in l.glyphs.iter().enumerate() {
            if k < flat.len() && same(glyphs[flat[k]], g) {
                k += 1;
            } else if gi + 1 == l.glyphs.len() && crate::layout::glyph_text(&repro.fonts[g.font], g.code) == "-" {
                if j == bad {
                    hyphenated = true;
                }
            } else {
                return None;
            }
        }
    }
    let at = *flat.get(k)?;
    // Not a break of the original (its line starts) — those are never forbidden.
    let mut n = 0;
    for l in &p.lines {
        if n == at {
            return None;
        }
        n += l.glyphs.len();
    }
    if hyphenated {
        let mut w = at;
        while w > 0 && meta[w].0 == 0 {
            w -= 1;
        }
        Some((w, false))
    } else if meta[at].0 == 1 {
        Some((at, true))
    } else {
        None
    }
}

/// The recovered source in ordinary LaTeX: private catcodes undone, specials escaped, font switches as the
/// macros the preamble defines.
pub fn to_latex(src: &str) -> String {
    let mut out = String::new();
    let mut chars = src.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1}' => {
                // A control sequence: a word, or one non-letter char.
                let mut name = String::new();
                while let Some(&n) = chars.peek() {
                    if n.is_ascii_alphabetic() {
                        name.push(n);
                        chars.next();
                    } else {
                        break;
                    }
                }
                if name.is_empty() {
                    if let Some(n) = chars.next() {
                        out.push('\\');
                        out.push(n);
                    }
                } else {
                    match name.as_str() {
                        "sp" => out.push('^'),
                        "sb" => out.push('_'),
                        _ => {
                            out.push('\\');
                            out.push_str(&name);
                        }
                    }
                }
            }
            '\u{2}' => out.push('{'),
            '\u{3}' => out.push('}'),
            '\\' => out.push_str("\\textbackslash{}"),
            '{' | '}' | '%' | '$' | '&' | '#' | '_' => {
                out.push('\\');
                out.push(c);
            }
            '~' => out.push_str("\\textasciitilde{}"),
            '^' => out.push_str("\\textasciicircum{}"),
            c => out.push(c),
        }
    }
    out.replace("{}{}", "{}")
}

pub fn write_tex(r: &Report, doc: &Doc) -> String {
    let mut s = String::from("% Recovered by pdfsource. Each paragraph is either proven (re-typeset identically) or approximate.\n");
    s += &format!("% {}\n\\documentclass[{}]{{article}}\n\\usepackage[T1,OT1]{{fontenc}}\\usepackage{{amsmath,amssymb}}\n{}\n\\begin{{document}}\n", r.file, if doc.body_size * 72.27 / 72.0 < 10.5 { "10pt" } else if doc.body_size * 72.27 / 72.0 < 11.5 { "11pt" } else { "12pt" }, r.fonts_tex);
    for (i, o) in &r.paras {
        let p = &doc.paras[*i];
        s += &format!("\n% ¶{i} page {} lines {}: {}\n", p.lines[0].page, p.lines.len(), if o.proven && o.pre.ends_with(",bm") == r.paras.iter().filter(|(_, x)| x.proven).all(|(_, x)| x.pre.ends_with(",bm")) { "proven".into() } else if o.proven { format!("proven (with LaTeX setup {})", o.pre) } else { format!("approximate ({})", o.reason) });
        if !o.source.is_empty() {
            s += &to_latex(&o.source);
            s += "\n";
        }
    }
    s += "\n\\end{document}\n";
    s
}

/// An indented block's geometry from its page column: the same right edge, the margin snapped to a nice length
/// (lists: \leftmargin), so hsize = the column's − the margin (as LaTeX's list environments compute it).
fn derive_blocks(doc: &Doc, hsize: &mut HashMap<i64, i64>, lefts: &mut HashMap<i64, i64>) {
    for s in &doc.columns[doc.n_main..] {
        // Geometry is keyed by the left edge: a page column with the same edge keeps its own.
        if doc.columns[..doc.n_main].iter().any(|c| ckey2(c.left, c.right) == ckey2(s.left, s.right)) {
            continue;
        }
        let Some(host) = doc.columns[..doc.n_main].iter().filter(|c| (c.right - s.right).abs() < 0.5 && c.left < s.left).max_by(|a, b| a.left.partial_cmp(&b.left).unwrap()) else { continue };
        let hl = *lefts.get(&ckey2(host.left, host.right)).unwrap_or(&texgen::sp(host.left));
        let hh = *hsize.get(&ckey2(host.left, host.right)).unwrap_or(&texgen::sp(host.right - host.left));
        let m0 = texgen::sp(s.left - host.left);
        let m = (m0 - 80..=m0 + 80).min_by_key(|v| (texgen::nice_rank(*v), (v - m0).abs())).unwrap_or(m0);
        lefts.insert(ckey2(s.left, s.right), hl + m);
        hsize.insert(ckey2(s.left, s.right), hh - m);
    }
}

/// Glyphs inside a paragraph's region that aren't in its lines (an accent split off, an overlay): the comparison
/// wouldn't see them, so the paragraph can't be proven.
fn strays(doc: &Doc, p: &Para) -> Option<String> {
    for part in p.lines.chunk_by(|a, b| a.page == b.page && a.left == b.left) {
        let first = &part[0];
        let last = &part[part.len() - 1];
        let (top, bottom) = (first.y + 0.7 * first.size, last.y - 0.25 * last.size);
        let (x0, x1) = (first.left - 0.5 * first.size, first.right + 0.5 * first.size);
        for l in doc.lines.iter().filter(|l| l.page == first.page) {
            if part.iter().any(|q| (q.y - l.y).abs() < 0.001 && (q.x0 - l.x0).abs() < 0.001) {
                continue;
            }
            for g in &l.glyphs {
                let cx = g.x + g.adv / 2.0;
                if g.y < top && g.y > bottom && cx > x0 && cx < x1 && part.iter().all(|q| (q.y - g.y).abs() > 0.3 * q.size || cx < q.x0 || cx > q.x1) {
                    return Some(format!("stray glyphs: a glyph at y {:.2} inside the paragraph", g.y));
                }
            }
        }
    }
    None
}
