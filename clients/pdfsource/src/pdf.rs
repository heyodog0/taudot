//! A PDF page as positioned glyphs: the text operators run as a viewer runs them, with each glyph's font, code,
//! glyph name, Unicode text, origin and advance in PDF user space (points, y up).

use lopdf::content::Content;
use lopdf::{Dictionary, Document, Object, ObjectId};
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct Font {
    /// PostScript name without the subset tag (`CMR10`, `NimbusRomNo9L-Regu`).
    pub name: String,
    pub subtype: String,
    /// Advance per code in 1/1000 text space units (Type 1/TrueType `/Widths`).
    pub widths: HashMap<u32, f64>,
    pub missing_width: f64,
    /// Glyph name per code, from `/Encoding` (base + differences) or the Type 1 program's built-in encoding.
    pub names: HashMap<u32, String>,
    /// Text per code from `/ToUnicode`.
    pub unicode: HashMap<u32, String>,
    pub two_byte: bool,
}

#[derive(Debug, Clone)]
pub struct Glyph {
    pub font: usize,
    pub code: u32,
    /// Origin in user space.
    pub x: f64,
    pub y: f64,
    /// Advance along the baseline, user space.
    pub adv: f64,
    /// Effective size: Tf size times the vertical scale of Tm·CTM.
    pub size: f64,
    /// Horizontal scale relative to vertical (Tz and expanded fonts' matrices); 1 for plain text.
    pub hscale: f64,
    /// Colour operators painted since the previous glyph (e.g. `0 g 0 G` from a link's colour push and pop).
    pub pre: String,
    /// x of the text line matrix (the last Td) in sp, as pdfTeX tracks its PDF position (`pdf_h`).
    pub line_h: i64,
}

#[derive(Debug, Clone)]
pub struct Rule {
    pub x0: f64,
    pub y0: f64,
    pub x1: f64,
    pub y1: f64,
}

#[derive(Debug, Default)]
pub struct Page {
    pub number: usize,
    pub width: f64,
    pub height: f64,
    pub glyphs: Vec<Glyph>,
    /// Filled rectangles (TeX rules) and stroked lines, as boxes.
    pub rules: Vec<Rule>,
    /// Painted things that aren't text or rules (paths, images, forms): their count, for the report.
    pub graphics: usize,
}

pub struct Pdf {
    pub doc: Document,
    pub fonts: Vec<Font>,
    font_ids: HashMap<ObjectId, usize>,
    pub producer: String,
    /// Page number → object (the page tree walked once).
    pages: std::collections::BTreeMap<u32, ObjectId>,
}

fn num(o: &Object) -> f64 {
    match o {
        Object::Integer(i) => *i as f64,
        Object::Real(r) => *r as f64,
        _ => 0.0,
    }
}

fn name_of(o: &Object) -> String {
    match o {
        Object::Name(n) => String::from_utf8_lossy(n).into_owned(),
        Object::String(s, _) => String::from_utf8_lossy(s).into_owned(),
        _ => String::new(),
    }
}

type M = [f64; 6];
fn mul(a: &M, b: &M) -> M {
    [
        a[0] * b[0] + a[1] * b[2],
        a[0] * b[1] + a[1] * b[3],
        a[2] * b[0] + a[3] * b[2],
        a[2] * b[1] + a[3] * b[3],
        a[4] * b[0] + a[5] * b[2] + b[4],
        a[4] * b[1] + a[5] * b[3] + b[5],
    ]
}
const ID: M = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];

impl Pdf {
    pub fn open(path: &str) -> Result<Pdf, String> {
        let doc = Document::load(path).map_err(|e| format!("{path}: {e}"))?;
        let mut producer = String::new();
        if let Ok(info) = doc.trailer.get(b"Info") {
            let info = match info {
                Object::Reference(r) => doc.get_object(*r).ok(),
                o => Some(o),
            };
            if let Some(Object::Dictionary(d)) = info {
                if let Ok(p) = d.get(b"Producer") {
                    producer = name_of(p);
                }
            }
        }
        let pages = doc.get_pages();
        Ok(Pdf { doc, fonts: vec![], font_ids: HashMap::new(), producer, pages })
    }

    pub fn page_count(&self) -> usize {
        self.pages.len()
    }

    fn deref<'a>(&'a self, o: &'a Object) -> &'a Object {
        match o {
            Object::Reference(r) => self.doc.get_object(*r).unwrap_or(o),
            _ => o,
        }
    }

    fn dict<'a>(&'a self, o: &'a Object) -> Option<&'a Dictionary> {
        match self.deref(o) {
            Object::Dictionary(d) => Some(d),
            Object::Stream(s) => Some(&s.dict),
            _ => None,
        }
    }

    fn stream_bytes(&self, o: &Object) -> Option<Vec<u8>> {
        match self.deref(o) {
            Object::Stream(s) => Some(s.decompressed_content().unwrap_or_else(|_| s.content.clone())),
            _ => None,
        }
    }

    fn load_font(&mut self, id: Option<ObjectId>, d: &Dictionary) -> usize {
        if let Some(id) = id {
            if let Some(&i) = self.font_ids.get(&id) {
                return i;
            }
        }
        let mut f = Font {
            name: String::new(),
            subtype: d.get(b"Subtype").map(name_of).unwrap_or_default(),
            widths: HashMap::new(),
            missing_width: 0.0,
            names: HashMap::new(),
            unicode: HashMap::new(),
            two_byte: false,
        };
        let base = d.get(b"BaseFont").map(name_of).unwrap_or_default();
        f.name = match base.find('+') {
            Some(6) => base[7..].to_string(),
            _ => base.clone(),
        };
        if f.subtype == "Type0" {
            f.two_byte = true;
        }
        let first = d.get(b"FirstChar").map(num).unwrap_or(0.0) as u32;
        if let Ok(w) = d.get(b"Widths") {
            if let Object::Array(a) = self.deref(w) {
                for (i, v) in a.iter().enumerate() {
                    f.widths.insert(first + i as u32, num(self.deref(v)));
                }
            }
        }
        let fd = d.get(b"FontDescriptor").ok().and_then(|o| self.dict(o)).cloned();
        if let Some(fd) = &fd {
            f.missing_width = fd.get(b"MissingWidth").map(num).unwrap_or(0.0);
            // Built-in encoding of an embedded Type 1 program (cleartext part).
            if let Ok(ff) = fd.get(b"FontFile") {
                if let Some(bytes) = self.stream_bytes(ff) {
                    parse_type1_encoding(&bytes, &mut f.names);
                }
            }
        }
        if let Ok(enc) = d.get(b"Encoding") {
            match self.deref(enc) {
                Object::Name(n) => {
                    let base = String::from_utf8_lossy(n).into_owned();
                    f.names = base_encoding(&base);
                }
                Object::Dictionary(ed) => {
                    if let Ok(b) = ed.get(b"BaseEncoding") {
                        f.names = base_encoding(&name_of(b));
                    }
                    if let Ok(Object::Array(diffs)) = ed.get(b"Differences").map(|o| self.deref(o)) {
                        let mut code = 0u32;
                        for v in diffs {
                            match self.deref(v) {
                                Object::Integer(i) => code = *i as u32,
                                Object::Name(n) => {
                                    f.names.insert(code, String::from_utf8_lossy(n).into_owned());
                                    code += 1;
                                }
                                _ => {}
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        if let Ok(tu) = d.get(b"ToUnicode") {
            if let Some(bytes) = self.stream_bytes(tu) {
                parse_cmap(&bytes, &mut f.unicode);
            }
        }
        self.fonts.push(f);
        let i = self.fonts.len() - 1;
        if let Some(id) = id {
            self.font_ids.insert(id, i);
        }
        i
    }

    pub fn page(&mut self, number: usize) -> Result<Page, String> {
        let pid = *self.pages.get(&(number as u32)).ok_or("no such page")?;
        let pd = self.doc.get_dictionary(pid).map_err(|e| e.to_string())?.clone();
        let mut page = Page { number, ..Default::default() };
        let mb = self.inherited(&pd, b"MediaBox");
        if let Some(Object::Array(a)) = mb.as_ref() {
            let v: Vec<f64> = a.iter().map(|o| num(self.deref(o))).collect();
            if v.len() == 4 {
                page.width = v[2] - v[0];
                page.height = v[3] - v[1];
            }
        }
        let content = self.doc.get_page_content(pid).map_err(|e| e.to_string())?;
        let res = self.inherited(&pd, b"Resources");
        let res = res.as_ref().and_then(|o| self.dict(o)).cloned().unwrap_or_default();
        self.run(&content, &res, ID, &mut page, 0);
        Ok(page)
    }

    fn inherited(&self, d: &Dictionary, key: &[u8]) -> Option<Object> {
        let mut d = d.clone();
        for _ in 0..32 {
            if let Ok(v) = d.get(key) {
                return Some(self.deref(v).clone());
            }
            let parent = d.get(b"Parent").ok()?.clone();
            d = self.dict(&parent)?.clone();
        }
        None
    }

    fn fonts_of(&mut self, res: &Dictionary) -> HashMap<Vec<u8>, usize> {
        let mut out = HashMap::new();
        let fd = match res.get(b"Font").ok().and_then(|o| self.dict(o)) {
            Some(d) => d.clone(),
            None => return out,
        };
        for (k, v) in fd.iter() {
            let id = if let Object::Reference(r) = v { Some(*r) } else { None };
            if let Some(d) = self.dict(v).cloned() {
                let i = self.load_font(id, &d);
                out.insert(k.clone(), i);
            }
        }
        out
    }

    fn run(&mut self, content: &[u8], res: &Dictionary, ctm0: M, page: &mut Page, depth: usize) {
        let fast = fast_ops(content);
        if std::env::var("PDFSOURCE_CHECKOPS").is_ok() {
            if let (Some(f), Ok(c)) = (&fast, Content::decode(content)) {
                if format!("{f:?}") != format!("{:?}", c.operations) {
                    eprintln!("fast_ops differs from lopdf on a stream of {} bytes", content.len());
                }
            }
        }
        let ops = match fast {
            Some(o) => o,
            None => match Content::decode(content) {
                Ok(c) => c.operations,
                Err(_) => return,
            },
        };
        let fonts = self.fonts_of(res);
        let xobjects = res.get(b"XObject").ok().and_then(|o| self.dict(o)).cloned().unwrap_or_default();
        let mut ctm = ctm0;
        let mut stack: Vec<(M, Option<usize>, f64, f64, f64, f64, f64)> = vec![];
        let (mut tm, mut tlm) = (ID, ID);
        let mut font: Option<usize> = None;
        let (mut size, mut tc, mut tw, mut tz, mut tl, mut rise) = (0.0, 0.0, 0.0, 1.0, 0.0, 0.0);
        let mut path: Vec<(f64, f64)> = vec![];
        let mut rects: Vec<[f64; 4]> = vec![];
        let mut pending = String::new();
        let mut pdf_h: i64 = 0;
        for op in ops {
            let a: Vec<f64> = op.operands.iter().map(num).collect();
            let g = |i: usize| a.get(i).copied().unwrap_or(0.0);
            match op.operator.as_str() {
                "q" => stack.push((ctm, font, size, tc, tw, tz, tl)),
                "Q" => {
                    if let Some(s) = stack.pop() {
                        (ctm, font, size, tc, tw, tz, tl) = s;
                    }
                }
                "cm" => ctm = mul(&[g(0), g(1), g(2), g(3), g(4), g(5)], &ctm),
                "BT" => {
                    pending.clear();
                    pdf_h = 0;
                    tm = ID;
                    tlm = ID;
                }
                "Tf" => {
                    size = g(1);
                    font = op.operands.first().and_then(|n| match n {
                        Object::Name(n) => fonts.get(n).copied(),
                        _ => None,
                    });
                }
                "Tc" => tc = g(0),
                "Tw" => tw = g(0),
                "Tz" => tz = g(0) / 100.0,
                "TL" => tl = g(0),
                "Ts" => rise = g(0),
                "Td" | "TD" => {
                    if op.operator == "TD" {
                        tl = -g(1);
                    }
                    tlm = mul(&[1.0, 0.0, 0.0, 1.0, g(0), g(1)], &tlm);
                    tm = tlm;
                    pdf_h += printed_sp(g(0));
                }
                "Tm" => {
                    tlm = [g(0), g(1), g(2), g(3), g(4), g(5)];
                    pdf_h = printed_sp(g(4));
                    tm = tlm;
                }
                "T*" => {
                    tlm = mul(&[1.0, 0.0, 0.0, 1.0, 0.0, -tl], &tlm);
                    tm = tlm;
                }
                "Tj" | "TJ" | "'" | "\"" => {
                    if op.operator == "'" || op.operator == "\"" {
                        if op.operator == "\"" {
                            tw = g(0);
                            tc = g(1);
                        }
                        tlm = mul(&[1.0, 0.0, 0.0, 1.0, 0.0, -tl], &tlm);
                        tm = tlm;
                    }
                    let Some(fi) = font else { continue };
                    let items: Vec<Object> = match op.operator.as_str() {
                        "TJ" => match op.operands.first() {
                            Some(Object::Array(a)) => a.clone(),
                            _ => vec![],
                        },
                        _ => op.operands.last().cloned().into_iter().collect(),
                    };
                    for it in items {
                        match it {
                            Object::String(s, _) => {
                                let f = &self.fonts[fi];
                                let codes: Vec<u32> = if f.two_byte {
                                    s.chunks(2).map(|c| ((c[0] as u32) << 8) | *c.get(1).unwrap_or(&0) as u32).collect()
                                } else {
                                    s.iter().map(|&b| b as u32).collect()
                                };
                                for code in codes {
                                    let f = &self.fonts[fi];
                                    let w0 = f.widths.get(&code).copied().unwrap_or(f.missing_width) / 1000.0;
                                    let trm = mul(&[size * tz, 0.0, 0.0, size, 0.0, rise], &mul(&tm, &ctm));
                                    let vs = (trm[2] * trm[2] + trm[3] * trm[3]).sqrt();
                                    let hs = (trm[0] * trm[0] + trm[1] * trm[1]).sqrt();
                                    let space = if code == 32 && !f.two_byte { tw } else { 0.0 };
                                    let tx = (w0 * size + tc + space) * tz;
                                    let adv_m = mul(&[1.0, 0.0, 0.0, 1.0, tx, 0.0], &mul(&tm, &ctm));
                                    let ox = adv_m[4] - (trm[4]);
                                    let oy = adv_m[5] - (trm[5] - rise * 0.0);
                                    page.glyphs.push(Glyph {
                                        font: fi,
                                        code,
                                        x: trm[4],
                                        y: trm[5],
                                        adv: (ox * ox + oy * oy).sqrt(),
                                        size: vs,
                                        hscale: if vs > 0.0 { hs / vs } else { 1.0 },
                                        pre: std::mem::take(&mut pending).trim_end().to_string(),
                                        line_h: pdf_h,
                                    });
                                    tm = mul(&[1.0, 0.0, 0.0, 1.0, tx, 0.0], &tm);
                                }
                            }
                            o => {
                                let tj = num(&o);
                                tm = mul(&[1.0, 0.0, 0.0, 1.0, -tj / 1000.0 * size * tz, 0.0], &tm);
                            }
                        }
                    }
                }
                "m" | "l" => {
                    let p = apply(&ctm, g(0), g(1));
                    path.push(p);
                }
                "c" | "v" | "y" => {
                    path.push(apply(&ctm, g(a.len().saturating_sub(2)), g(a.len().saturating_sub(1))));
                    path.push((f64::NAN, f64::NAN));
                }
                "re" => {
                    let p0 = apply(&ctm, g(0), g(1));
                    let p1 = apply(&ctm, g(0) + g(2), g(1) + g(3));
                    rects.push([p0.0.min(p1.0), p0.1.min(p1.1), p0.0.max(p1.0), p0.1.max(p1.1)]);
                }
                "f" | "F" | "f*" | "B" | "B*" | "b" | "b*" | "S" | "s" => {
                    let straight = !path.iter().any(|p| p.0.is_nan());
                    if !rects.is_empty() && path.is_empty() && op.operator.starts_with(['f', 'F']) {
                        for r in &rects {
                            page.rules.push(Rule { x0: r[0], y0: r[1], x1: r[2], y1: r[3] });
                        }
                    } else if op.operator == "S" && straight && path.len() == 2 && rects.is_empty() {
                        let (p, q) = (path[0], path[1]);
                        page.rules.push(Rule { x0: p.0.min(q.0), y0: p.1.min(q.1), x1: p.0.max(q.0), y1: p.1.max(q.1) });
                    } else {
                        page.graphics += 1;
                    }
                    path.clear();
                    rects.clear();
                }
                "n" => {
                    path.clear();
                    rects.clear();
                }
                "Do" => {
                    let Some(Object::Name(n)) = op.operands.first() else { continue };
                    let Ok(xo) = xobjects.get(n) else { continue };
                    let xo = self.deref(xo).clone();
                    if let Object::Stream(s) = &xo {
                        let sub = s.dict.get(b"Subtype").map(name_of).unwrap_or_default();
                        if sub == "Form" && depth < 8 {
                            let m = match s.dict.get(b"Matrix") {
                                Ok(Object::Array(a)) if a.len() == 6 => {
                                    let v: Vec<f64> = a.iter().map(num).collect();
                                    [v[0], v[1], v[2], v[3], v[4], v[5]]
                                }
                                _ => ID,
                            };
                            let r = s.dict.get(b"Resources").ok().and_then(|o| self.dict(o)).cloned().unwrap_or(res.clone());
                            let bytes = s.decompressed_content().unwrap_or_else(|_| s.content.clone());
                            let before = page.glyphs.len();
                            self.run(&bytes, &r, mul(&m, &ctm), page, depth + 1);
                            // A form's glyphs belong to a figure, not to the text.
                            for gl in &mut page.glyphs[before..] {
                                gl.size = -gl.size.abs();
                            }
                            page.graphics += 1;
                        } else {
                            page.graphics += 1;
                        }
                    }
                }
                "g" | "G" | "rg" | "RG" | "k" | "K" | "cs" | "CS" | "sc" | "SC" | "scn" | "SCN" => {
                    for o in &op.operands {
                        match o {
                            Object::Integer(i) => pending += &format!("{i} "),
                            Object::Real(r) => pending += &format!("{r} "),
                            Object::Name(n) => pending += &format!("/{} ", String::from_utf8_lossy(n)),
                            _ => {}
                        }
                    }
                    pending += &op.operator;
                    pending.push(' ');
                }
                "BI" | "sh" => page.graphics += 1,
                _ => {}
            }
        }
    }
}

fn apply(m: &M, x: f64, y: f64) -> (f64, f64) {
    (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])
}

fn parse_type1_encoding(bytes: &[u8], names: &mut HashMap<u32, String>) {
    let end = bytes.windows(7).position(|w| w == b"eexec\r" || w == b"eexec\n").unwrap_or(bytes.len().min(65536));
    let text = String::from_utf8_lossy(&bytes[..end]);
    if text.contains("/Encoding StandardEncoding") {
        *names = base_encoding("StandardEncoding");
        return;
    }
    let mut toks = text.split_whitespace().peekable();
    while let Some(t) = toks.next() {
        if t == "dup" {
            let (Some(c), Some(n)) = (toks.next(), toks.peek().copied()) else { break };
            if let (Ok(c), Some(n)) = (c.parse::<u32>(), n.strip_prefix('/')) {
                names.insert(c, n.to_string());
            }
        }
    }
}

fn hex(s: &str) -> Option<u32> {
    u32::from_str_radix(s.trim_matches(|c| c == '<' || c == '>'), 16).ok()
}

fn utf16(s: &str) -> String {
    let h = s.trim_matches(|c| c == '<' || c == '>');
    let units: Vec<u16> = (0..h.len() / 4).filter_map(|i| u16::from_str_radix(&h[i * 4..i * 4 + 4], 16).ok()).collect();
    String::from_utf16_lossy(&units)
}

fn parse_cmap(bytes: &[u8], out: &mut HashMap<u32, String>) {
    let text = String::from_utf8_lossy(bytes);
    let toks: Vec<&str> = text.split_whitespace().collect();
    let mut i = 0;
    while i < toks.len() {
        match toks[i] {
            "beginbfchar" => {
                i += 1;
                while i + 1 < toks.len() && toks[i] != "endbfchar" {
                    if let Some(c) = hex(toks[i]) {
                        out.insert(c, utf16(toks[i + 1]));
                    }
                    i += 2;
                }
            }
            "beginbfrange" => {
                i += 1;
                while i + 2 < toks.len() && toks[i] != "endbfrange" {
                    let (lo, hi) = (hex(toks[i]), hex(toks[i + 1]));
                    if toks[i + 2].starts_with('[') {
                        let mut j = i + 2;
                        let mut c = lo.unwrap_or(0);
                        loop {
                            let t = toks[j].trim_start_matches('[');
                            let done = t.ends_with(']');
                            out.insert(c, utf16(t.trim_end_matches(']')));
                            c += 1;
                            j += 1;
                            if done || j >= toks.len() {
                                break;
                            }
                        }
                        i = j;
                        continue;
                    } else if let (Some(lo), Some(hi)) = (lo, hi) {
                        let base: Vec<u16> = utf16(toks[i + 2]).encode_utf16().collect();
                        for c in lo..=hi.min(lo + 65535) {
                            let mut u = base.clone();
                            if let Some(last) = u.last_mut() {
                                *last += (c - lo) as u16;
                            }
                            out.insert(c, String::from_utf16_lossy(&u));
                        }
                    }
                    i += 3;
                }
            }
            _ => i += 1,
        }
    }
}

fn base_encoding(name: &str) -> HashMap<u32, String> {
    let mut m = HashMap::new();
    // Printable ASCII is the same in Standard and WinAnsi for letters, digits and most punctuation.
    for c in 0x20u32..0x7f {
        let n = match c {
            0x20 => "space".to_string(),
            0x27 => if name == "StandardEncoding" { "quoteright" } else { "quotesingle" }.to_string(),
            0x60 => if name == "StandardEncoding" { "quoteleft" } else { "grave" }.to_string(),
            _ => {
                let ch = char::from_u32(c).unwrap();
                match ch {
                    '0'..='9' => crate::glyphs::digit_name(ch).to_string(),
                    c if c.is_ascii_alphabetic() => c.to_string(),
                    c => crate::glyphs::ascii_name(c).to_string(),
                }
            }
        };
        m.insert(c, n);
    }
    m
}

/// 100 bp in sp (exact).
pub const ONE_HUNDRED_BP: i64 = 6578176;

/// The sp pdfTeX adds to its PDF position for a printed number of bp (3 decimals): `scaled_out` of
/// `divide_scaled`. It is the integer next to the printed value on the side of the exact (unprinted) length;
/// not knowing that here, take the nearest.
pub fn printed_sp(v: f64) -> i64 {
    let n = (v * 1000.0).round() as i64;
    let t = n as f64 * ONE_HUNDRED_BP as f64 / 100000.0;
    t.round() as i64
}

/// pdfTeX's `divide_scaled(s, one_hundred_bp, 5)`: (printed thousandths of a bp, scaled_out).
pub fn divide_scaled_bp(s: i64) -> (i64, i64) {
    let (sign, s) = if s < 0 { (-1, -s) } else { (1, s) };
    let m = ONE_HUNDRED_BP;
    let mut q = s / m;
    let mut r = s % m;
    for _ in 0..5 {
        q = 10 * q + (10 * r) / m;
        r = (10 * r) % m;
    }
    if 2 * r >= m {
        q += 1;
        r -= m;
    }
    (sign * q, sign * (s - r / 100000))
}

/// Content stream operations, as `Content::decode` gives them, for the subset pdfTeX writes (numbers, names, strings,
/// arrays of those, operators); anything else (comments, dictionaries, inline images, NUL or form feed outside a
/// string, references) returns None and the caller uses lopdf's parser. Several times faster on large batches.
pub fn fast_ops(b: &[u8]) -> Option<Vec<lopdf::content::Operation>> {
    let mut ops = vec![];
    let mut operands = vec![];
    let mut i = 0;
    let ws = |c: u8| c == b' ' || c == b'\t' || c == b'\r' || c == b'\n';
    while i < b.len() {
        let c = b[i];
        if ws(c) {
            i += 1;
            continue;
        }
        if c.is_ascii_alphabetic() || c == b'*' || c == b'\'' || c == b'"' {
            let s = i;
            while i < b.len() && (b[i].is_ascii_alphabetic() || b[i] == b'*' || b[i] == b'\'' || b[i] == b'"') {
                i += 1;
            }
            let w = &b[s..i];
            match w {
                b"true" | b"false" | b"null" | b"BI" => return None,
                _ => {}
            }
            ops.push(lopdf::content::Operation { operator: String::from_utf8(w.to_vec()).ok()?, operands: std::mem::take(&mut operands) });
            continue;
        }
        let (o, n) = fast_operand(b, i, 0)?;
        operands.push(o);
        i = n;
    }
    // Trailing operands without an operator: lopdf stops before them.
    Some(ops)
}

fn fast_operand(b: &[u8], mut i: usize, depth: usize) -> Option<(Object, usize)> {
    let c = b[i];
    match c {
        b'0'..=b'9' | b'+' | b'-' | b'.' => {
            let s = i;
            if c == b'+' || c == b'-' {
                i += 1;
            }
            let d0 = i;
            while i < b.len() && b[i].is_ascii_digit() {
                i += 1;
            }
            let int_digits = i - d0;
            if i < b.len() && b[i] == b'.' {
                i += 1;
                let f0 = i;
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                if int_digits == 0 && i == f0 {
                    return None;
                }
                let v: f32 = std::str::from_utf8(&b[s..i]).ok()?.parse().ok()?;
                Some((Object::Real(v), i))
            } else {
                if int_digits == 0 {
                    return None;
                }
                let v: i64 = std::str::from_utf8(&b[s..i]).ok()?.parse().ok()?;
                Some((Object::Integer(v), i))
            }
        }
        b'/' => {
            i += 1;
            let s = i;
            while i < b.len() && !b" \t\n\r\0\x0C()<>[]{}/%".contains(&b[i]) {
                if b[i] == b'#' {
                    return None;
                }
                i += 1;
            }
            Some((Object::Name(b[s..i].to_vec()), i))
        }
        b'(' => {
            let mut out = vec![];
            let mut level = 0usize;
            i += 1;
            loop {
                let c = *b.get(i)?;
                match c {
                    b'\\' => {
                        i += 1;
                        let e = *b.get(i)?;
                        match e {
                            b'0'..=b'7' => {
                                let mut v: u16 = 0;
                                let mut k = 0;
                                while k < 3 && i < b.len() && (b'0'..=b'7').contains(&b[i]) {
                                    v = v * 8 + (b[i] - b'0') as u16;
                                    i += 1;
                                    k += 1;
                                }
                                out.push(v as u8);
                                continue;
                            }
                            b'\r' => {
                                i += 1;
                                if b.get(i) == Some(&b'\n') {
                                    i += 1;
                                }
                                continue;
                            }
                            b'\n' => {}
                            b'n' => out.push(b'\n'),
                            b'r' => out.push(b'\r'),
                            b't' => out.push(b'\t'),
                            b'b' => out.push(0x08),
                            b'f' => out.push(0x0C),
                            _ => out.push(e),
                        }
                        i += 1;
                    }
                    b'(' => {
                        level += 1;
                        out.push(c);
                        i += 1;
                    }
                    b')' => {
                        i += 1;
                        if level == 0 {
                            break;
                        }
                        level -= 1;
                        out.push(c);
                    }
                    _ => {
                        out.push(c);
                        i += 1;
                    }
                }
            }
            Some((Object::String(out, lopdf::StringFormat::Literal), i))
        }
        b'<' => {
            if b.get(i + 1) == Some(&b'<') {
                return None;
            }
            i += 1;
            let mut out = vec![];
            let mut half = false;
            loop {
                let c = *b.get(i)?;
                i += 1;
                if c == b'>' {
                    break;
                }
                if b" \t\n\r\0\x0C".contains(&c) {
                    continue;
                }
                let v = (c as char).to_digit(16)? as u8;
                if half {
                    *out.last_mut().unwrap() |= v;
                } else {
                    out.push(v << 4);
                }
                half = !half;
            }
            Some((Object::String(out, lopdf::StringFormat::Hexadecimal), i))
        }
        b'[' if depth < 4 => {
            i += 1;
            let mut v = vec![];
            loop {
                while i < b.len() && b" \t\n\r".contains(&b[i]) {
                    i += 1;
                }
                let c = *b.get(i)?;
                if c == b']' {
                    i += 1;
                    break;
                }
                if c.is_ascii_alphabetic() {
                    return None;
                }
                let (o, n) = fast_operand(b, i, depth + 1)?;
                v.push(o);
                i = n;
            }
            Some((Object::Array(v), i))
        }
        _ => None,
    }
}
