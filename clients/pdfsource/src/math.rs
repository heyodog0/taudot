//! Inline math in a paragraph: which glyphs are math, and TeX math source for a span of them (nuclei with one
//! level of scripts). TeX decides the spacing between atoms; the proof checks the classes chosen here.

use crate::pdf::{Font, Glyph};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MathFont {
    /// cmmi: math italic (OML)
    Italic,
    /// cmmib: bold math italic
    BoldItalic,
    /// cmsy: symbols (OMS)
    Symbols,
    /// cmex: extensions
    Ext,
    /// cmr in math: digits, operators, upright Greek
    Roman,
    /// cmbx in math (\mathbf)
    Bold,
    /// msbm (\mathbb and AMS symbols B)
    Msbm,
    /// msam (AMS symbols A)
    Msam,
    /// cmtt/cmss... in math: not handled
    Other,
}

/// The math role of a font by its PostScript name, if it is a TeX math font (or CM roman that may be math).
pub fn math_font(f: &Font) -> Option<MathFont> {
    let n = f.name.to_ascii_uppercase();
    let fam: String = n.chars().take_while(|c| c.is_ascii_alphabetic()).collect();
    Some(match fam.as_str() {
        "CMMI" => MathFont::Italic,
        "CMMIB" => MathFont::BoldItalic,
        "CMSY" | "CMBSY" => MathFont::Symbols,
        "CMEX" => MathFont::Ext,
        "CMR" => MathFont::Roman,
        "CMBX" => MathFont::Bold,
        "MSBM" => MathFont::Msbm,
        "MSAM" => MathFont::Msam,
        _ => return None,
    })
}

const GREEK: [&str; 29] = [
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi",
    "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega", "varepsilon", "vartheta", "varpi", "varrho",
    "varsigma", "varphi",
];
const UGREEK: [&str; 11] = ["Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega"];

const OMS: [&str; 128] = [
    "-", "\\cdot", "\\times", "\\ast", "\\div", "\\diamond", "\\pm", "\\mp", "\\oplus", "\\ominus", "\\otimes",
    "\\oslash", "\\odot", "\\bigcirc", "\\circ", "\\bullet", "\\asymp", "\\equiv", "\\subseteq", "\\supseteq", "\\leq",
    "\\geq", "\\preceq", "\\succeq", "\\sim", "\\approx", "\\subset", "\\supset", "\\ll", "\\gg", "\\prec", "\\succ",
    "\\leftarrow", "\\rightarrow", "\\uparrow", "\\downarrow", "\\leftrightarrow", "\\nearrow", "\\searrow", "\\simeq",
    "\\Leftarrow", "\\Rightarrow", "\\Uparrow", "\\Downarrow", "\\Leftrightarrow", "\\nwarrow", "\\swarrow", "\\propto",
    "\\prime", "\\infty", "\\in", "\\ni", "\\bigtriangleup", "\\bigtriangledown", "\\not", "\\mapstochar", "\\forall",
    "\\exists", "\\neg", "\\emptyset", "\\Re", "\\Im", "\\top", "\\bot", "\\aleph", "A", "B", "C", "D", "E", "F", "G",
    "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "\\cup", "\\cap",
    "\\uplus", "\\wedge", "\\vee", "\\vdash", "\\dashv", "\\lfloor", "\\rfloor", "\\lceil", "\\rceil", "\\{", "\\}",
    "\\langle", "\\rangle", "|", "\\|", "\\updownarrow", "\\Updownarrow", "\\backslash", "\\wr", "\\surd", "\\amalg",
    "\\nabla", "\\smallint", "\\sqcup", "\\sqcap", "\\sqsubseteq", "\\sqsupseteq", "\\S", "\\dagger", "\\ddagger", "\\P",
    "\\clubsuit", "\\diamondsuit", "\\heartsuit", "\\spadesuit",
];

/// TeX math source for one glyph, or None if not handled.
pub fn token(mf: MathFont, code: u32) -> Option<String> {
    let c = code;
    let ch = char::from_u32(c).unwrap_or('?');
    Some(match mf {
        MathFont::Italic | MathFont::BoldItalic => {
            let t = match c {
                0..=10 => format!("\\var{}", UGREEK[c as usize]),
                11..=39 => format!("\\{}", GREEK[(c - 11) as usize]),
                48..=57 => return None, // oldstyle digits
                58 => ".".into(),
                59 => ",".into(),
                60 => "<".into(),
                61 => "/".into(),
                62 => ">".into(),
                63 => "\\star".into(),
                64 => "\\partial".into(),
                65..=90 | 97..=122 => ch.to_string(),
                96 => "\\ell".into(),
                123 => "\\imath".into(),
                124 => "\\jmath".into(),
                125 => "\\wp".into(),
                _ => return None,
            };
            if mf == MathFont::BoldItalic { format!("\\boldsymbol{{{t}}}") } else { t }
        }
        MathFont::Symbols => {
            let t = OMS.get(c as usize)?.to_string();
            if (65..=90).contains(&c) { format!("\\mathcal{{{t}}}") } else { t }
        }
        MathFont::Roman => match c {
            0..=10 => format!("\\{}", UGREEK[c as usize]),
            48..=57 => ch.to_string(),
            40 | 41 | 43 | 61 | 91 | 93 | 59 | 58 | 33 | 63 => ch.to_string(),
            // \% in math: \chardef'd to "25, whose mathcode is "0025 (cmr)
            37 => "\\%".into(),
            65..=90 | 97..=122 => format!("\\mathrm{{{ch}}}"),
            _ => return None,
        },
        MathFont::Bold => match c {
            65..=90 | 97..=122 | 48..=57 => format!("\\mathbf{{{ch}}}"),
            0..=10 => format!("\\mathbf{{\\{}}}", UGREEK[c as usize]),
            _ => return None,
        },
        // Text-style big operators (cmex 0x46..0x60, the even ones; display ones are a size larger).
        MathFont::Ext => match c {
            // Big delimiters (\big..\Bigg sizes, also what \left/\right pick): written \left/\right, sides fixed
            // later for the symmetric ones.
            0x00 | 0x10 | 0x12 | 0x20 => "\\left(".into(),
            0x01 | 0x11 | 0x13 | 0x21 => "\\right)".into(),
            0x02 | 0x14 | 0x22 | 0x68 => "\\left[".into(),
            0x03 | 0x15 | 0x23 | 0x69 => "\\right]".into(),
            0x04 | 0x16 | 0x24 | 0x6A => "\\left\\lfloor ".into(),
            0x05 | 0x17 | 0x25 | 0x6B => "\\right\\rfloor ".into(),
            0x06 | 0x18 | 0x26 | 0x6C => "\\left\\lceil ".into(),
            0x07 | 0x19 | 0x27 | 0x6D => "\\right\\rceil ".into(),
            0x08 | 0x1A | 0x28 | 0x6E => "\\left\\{".into(),
            0x09 | 0x1B | 0x29 | 0x6F => "\\right\\}".into(),
            0x0A | 0x1C | 0x2A | 0x44 => "\\left\\langle ".into(),
            0x0B | 0x1D | 0x2B | 0x45 => "\\right\\rangle ".into(),
            0x0C => "\\PSamb|".into(),
            0x0D => "\\PSamb\\|".into(),
            0x46 => "\\bigsqcup".into(),
            0x48 => "\\oint".into(),
            0x4A => "\\bigodot".into(),
            0x4C => "\\bigoplus".into(),
            0x4E => "\\bigotimes".into(),
            0x50 => "\\sum".into(),
            0x51 => "\\prod".into(),
            0x52 => "\\int".into(),
            0x53 => "\\bigcup".into(),
            0x54 => "\\bigcap".into(),
            0x55 => "\\biguplus".into(),
            0x56 => "\\bigwedge".into(),
            0x57 => "\\bigvee".into(),
            0x60 => "\\coprod".into(),
            // Display-style sizes.
            0x47 => "\\bigsqcup".into(),
            0x49 => "\\oint".into(),
            0x4B => "\\bigodot".into(),
            0x4D => "\\bigoplus".into(),
            0x4F => "\\bigotimes".into(),
            0x58 => "\\sum".into(),
            0x59 => "\\prod".into(),
            0x5A => "\\int".into(),
            0x5B => "\\bigcup".into(),
            0x5C => "\\bigcap".into(),
            0x5D => "\\biguplus".into(),
            0x5E => "\\bigwedge".into(),
            0x5F => "\\bigvee".into(),
            0x61 => "\\coprod".into(),
            _ => return None,
        },
        MathFont::Msbm => match c {
            65..=90 => format!("\\mathbb{{{ch}}}"),
            _ => return None,
        },
        _ => return None,
    })
}

/// Math source for a span of glyphs on one line (baseline `y0`, text size `size0`): nuclei on the baseline, smaller
/// glyphs above or below attached as superscripts or subscripts. Err: why not.
/// `text` gives a glyph of a text font its font macro and its input characters (for `\mbox` inside math).
pub fn span_source(fonts: &[Font], glyphs: &[Glyph], y0: f64, size0: f64, text: &dyn Fn(&Glyph) -> Option<(String, String)>) -> Result<String, String> {
    resolve_delims(&span_source_raw(fonts, glyphs, y0, size0, text)?)
}

/// `\left`/`\right` for the symmetric delimiters (`|`, `\|`): a `\right` where one is open. Err if unbalanced.
fn resolve_delims(s: &str) -> Result<String, String> {
    let mut out = String::new();
    let mut depth = 0i32;
    let mut rest = s;
    loop {
        let next = [("\\left", 1), ("\\right", -1), ("\\PSamb", 0)].iter().filter_map(|(t, d)| rest.find(t).map(|i| (i, *t, *d))).min_by_key(|e| e.0);
        let Some((i, t, d)) = next else { break };
        out.push_str(&rest[..i]);
        // \leftarrow, \rightarrow... aren't delimiters.
        let after = &rest[i + t.len()..];
        if d != 0 && after.starts_with(|c: char| c.is_ascii_alphabetic() && !after.starts_with("lfloor") && !after.starts_with("lceil") && !after.starts_with("langle") && !after.starts_with("rfloor") && !after.starts_with("rceil") && !after.starts_with("rangle")) {
            out.push_str(t);
            rest = after;
            continue;
        }
        let d = if d == 0 { if depth > 0 { -1 } else { 1 } } else { d };
        out.push_str(if d > 0 { "\\left" } else { "\\right" });
        depth += d;
        if depth < 0 {
            return Err("math: big delimiter".into());
        }
        rest = after;
    }
    out.push_str(rest);
    if depth != 0 {
        return Err("math: big delimiter".into());
    }
    Ok(out)
}

fn span_source_raw(fonts: &[Font], glyphs: &[Glyph], y0: f64, size0: f64, text: &dyn Fn(&Glyph) -> Option<(String, String)>) -> Result<String, String> {
    #[derive(Default)]
    struct Atom {
        nuc: String,
        sup: String,
        sub: String,
        /// The \mbox a text glyph last went into (where, font): the next one of that font joins it if it touches.
        text_in: Option<(u8, String)>,
    }
    let mut atoms: Vec<Atom> = vec![];
    let mut accent: Option<&str> = None;
    let mut end: Option<f64> = None; // right end of what's set so far
    let mut last_end = f64::MIN;
    for g in glyphs {
        let f = &fonts[g.font];
        let Some(mf) = math_font(f) else {
            // Text in math (\mbox, \text, \textsubscript): a box of the text font, its glyphs that touch together.
            let Some((cs, chars)) = text(g) else { return Err("math: text font in math".into()) };
            let touching = g.x - last_end < 0.05 * size0;
            let script = g.size < size0 - 0.01 && (g.y - y0).abs() > 0.01;
            if !script && ((g.y - y0).abs() > 0.01 || (g.size - size0).abs() > 0.01) {
                return Err("math: text font in math".into());
            }
            let place = if !script { 0u8 } else if g.y > y0 { 1 } else { 2 };
            if script && atoms.is_empty() {
                atoms.push(Atom { nuc: "{}".into(), ..Default::default() });
            }
            let join = touching && atoms.last().is_some_and(|a| a.text_in.as_ref().is_some_and(|t| t.0 == place && t.1 == cs));
            if !script && !join {
                atoms.push(Atom::default());
            }
            let a = atoms.last_mut().unwrap();
            let slot = match place { 0 => &mut a.nuc, 1 => &mut a.sup, _ => &mut a.sub };
            // (\textsc, \textbf... end with an italic correction, \check@icr: \/ before the box closes)
            if join {
                slot.truncate(slot.len() - 3);
                slot.push_str(&chars);
                slot.push_str("\\/}");
            } else {
                slot.push_str(&format!("\\mbox{{\\{cs}{{}}{chars}\\/}}"));
            }
            a.text_in = Some((place, cs));
            last_end = g.x + g.adv;
            end = Some(end.map_or(g.x + g.adv, |e: f64| e.max(g.x + g.adv)));
            continue;
        };
        last_end = g.x + g.adv;
        // A math accent: a text-size accent glyph above the baseline; it comes just before its nucleus.
        // (Over a letter no taller than the x-height it sits on the baseline itself, TeX §738.)
        if (g.size - size0).abs() < 0.01 && g.y > y0 - 0.01 && (g.y > y0 + 0.01 || mf == MathFont::Roman) {
            let a = match (mf, g.code) {
                (MathFont::Roman, 126) => Some("tilde"),
                (MathFont::Roman, 94) => Some("hat"),
                (MathFont::Roman, 22) => Some("bar"),
                (MathFont::Roman, 95) => Some("dot"),
                (MathFont::Roman, 127) => Some("ddot"),
                (MathFont::Roman, 20) => Some("check"),
                (MathFont::Roman, 21) => Some("breve"),
                (MathFont::Roman, 19) => Some("acute"),
                (MathFont::Roman, 18) => Some("grave"),
                (MathFont::Italic, 126) => Some("vec"),
                _ => None,
            };
            if a.is_some() {
                accent = a;
                continue;
            }
        }
        let t = token(mf, g.code).ok_or_else(|| if mf == MathFont::Ext { "math: big delimiter".to_string() } else { format!("math: glyph {} in {}", g.code, f.name) })?;
        // Big operators sit on the math axis, not the baseline: at text size they are nuclei wherever they are.
        let on_base = ((g.y - y0).abs() < 0.01 || mf == MathFont::Ext) && (g.size - size0).abs() < 0.01;
        if on_base {
            // A gap of a quad or two (plus the mu glue TeX puts between the atoms): \quad, \qquad in the source.
            let em = size0 * 1.00003;
            if let Some(e) = end {
                let gap = g.x - e;
                for (k, q) in [(2.0, "\\qquad"), (1.0, "\\quad")] {
                    let r = gap - k * em;
                    if r > -0.05 && r < 5.0 / 18.0 * em + 0.05 {
                        atoms.push(Atom { nuc: q.into(), ..Default::default() });
                        break;
                    }
                }
            }
            let nuc = match accent.take() { Some(a) => format!("\\{a}{{{t}}}"), None => t };
            atoms.push(Atom { nuc, ..Default::default() });
        } else if g.size < size0 - 0.01 {
            if atoms.is_empty() {
                atoms.push(Atom { nuc: "{}".into(), ..Default::default() });
            }
            let a = atoms.last_mut().unwrap();
            a.text_in = None;
            let s = if g.y > y0 { &mut a.sup } else { &mut a.sub };
            if t == "\\prime" && g.y > y0 && s.is_empty() {
                // x' is x^{\prime}
            }
            s.push_str(&t);
            if t.starts_with('\\') && t.chars().last().is_some_and(|c| c.is_ascii_alphabetic()) {
                s.push(' ');
            }
        } else {
            return Err("math: off-baseline glyph at text size".into());
        }
        end = Some(end.map_or(g.x + g.adv, |e: f64| e.max(g.x + g.adv)));
    }
    // Operator names set in roman letters (\log, \exp, \max...): one atom (an Op: TeX spaces it).
    const OPS: [&str; 32] = ["arccos", "arcsin", "arctan", "arg", "cos", "cosh", "cot", "coth", "csc", "deg", "det", "dim", "exp", "gcd", "hom", "inf", "ker", "lg", "lim", "liminf", "limsup", "ln", "log", "max", "min", "Pr", "sec", "sin", "sinh", "sup", "tan", "tanh"];
    let mut ops: Vec<Atom> = vec![];
    let mut k = 0;
    while k < atoms.len() {
        let letter = |a: &Atom| a.nuc.strip_prefix("\\mathrm{").and_then(|r| r.strip_suffix('}')).filter(|c| c.len() == 1).map(|c| c.to_string());
        let mut run = String::new();
        let mut m = k;
        while m < atoms.len() {
            let Some(c) = letter(&atoms[m]) else { break };
            run.push_str(&c);
            m += 1;
            if !atoms[m - 1].sup.is_empty() || !atoms[m - 1].sub.is_empty() {
                break;
            }
        }
        // The whole run of letters is an operator name ("softmax" is not \max).
        if let Some(op) = OPS.iter().find(|o| **o == run) {
            let last = k + op.len() - 1;
            let (sup, sub) = (std::mem::take(&mut atoms[last].sup), std::mem::take(&mut atoms[last].sub));
            ops.push(Atom { nuc: format!("\\{op}"), sup, sub, ..Default::default() });
            k = last + 1;
            continue;
        }
        // Not one: keep the whole run as it is.
        for a in atoms[k..m.max(k + 1)].iter_mut() {
            ops.push(std::mem::take(a));
        }
        k = m.max(k + 1);
    }
    let atoms = ops;
    // Three dots in a row are \ldots or \cdots (an inner atom: TeX puts thin spaces around them).
    let mut merged: Vec<Atom> = vec![];
    for a in atoms {
        let n = merged.len();
        let dots = |x: &Atom, d: &str| x.nuc == d && x.sup.is_empty() && x.sub.is_empty();
        if n >= 2 && a.sup.is_empty() && a.sub.is_empty() {
            for (d, cmd) in [(".", "\\ldots"), ("\\cdot", "\\cdots")] {
                if dots(&a, d) && dots(&merged[n - 1], d) && dots(&merged[n - 2], d) {
                    merged.truncate(n - 2);
                    merged.push(Atom { nuc: cmd.into(), ..Default::default() });
                    break;
                }
            }
            if merged.len() != n - 1 { merged.push(a); }
        } else {
            merged.push(a);
        }
    }
    let mut out = String::new();
    for a in merged {
        out.push_str(&a.nuc);
        if a.nuc.starts_with('\\') && a.nuc.chars().last().is_some_and(|c| c.is_ascii_alphabetic()) && a.sup.is_empty() && a.sub.is_empty() {
            out.push(' ');
        }
        if !a.sub.is_empty() {
            out.push_str(&format!("_{{{}}}", a.sub.trim_end()));
        }
        if !a.sup.is_empty() {
            out.push_str(&format!("^{{{}}}", a.sup.trim_end()));
        }
    }
    Ok(out)
}

/// Big operators that take limits above and below in display style (not the integrals).
fn takes_limits(mf: MathFont, code: u32) -> bool {
    mf == MathFont::Ext && matches!(code, 0x46 | 0x47 | 0x4A..=0x51 | 0x53..=0x61) && !matches!(code, 0x52 | 0x5A | 0x48 | 0x49)
}

/// Math source for a displayed formula from all its glyphs (PDF order) and the rules near it: fractions (a rule with
/// a numerator above and a denominator below), big operators with limits, and the rest as in `span_source` on the
/// main baseline. Err: why not.
pub fn display_source(fonts: &[Font], glyphs: &[Glyph], rules: &[crate::pdf::Rule], size0: f64) -> Result<String, String> {
    let n = glyphs.len();
    let cx = |g: &Glyph| g.x + g.adv / 2.0;
    // Group of each glyph: none, or the index of its fraction / operator.
    let mut group: Vec<Option<usize>> = vec![None; n];
    // Fractions, narrowest first (so an inner one is taken before the one around it; nesting isn't handled).
    let mut rs: Vec<&crate::pdf::Rule> = rules.iter().collect();
    rs.sort_by(|a, b| (a.x1 - a.x0).partial_cmp(&(b.x1 - b.x0)).unwrap());
    struct Frac {
        num: Vec<usize>,
        den: Vec<usize>,
    }
    let mut fracs: Vec<Frac> = vec![];
    // 0 fraction, 1 radical (num = [the sign], den = radicand), 2 overline (den), 3 underline (num).
    let mut kinds: Vec<u8> = vec![];
    for r in &rs {
        let mut f = Frac { num: vec![], den: vec![] };
        for (i, g) in glyphs.iter().enumerate() {
            if group[i].is_some() || cx(g) < r.x0 || cx(g) > r.x1 {
                continue;
            }
            if g.y > r.y1 && g.y < r.y1 + 2.0 * size0 {
                f.num.push(i);
            } else if g.y < r.y0 && g.y > r.y0 - 2.5 * size0 {
                f.den.push(i);
            }
        }
        // A radical: the surd ends where the rule starts (cmsy's, or cmex's bigger ones).
        let surd = (0..n).find(|&i| {
            let g = &glyphs[i];
            group[i].is_none() && matches!((math_font(&fonts[g.font]), g.code), (Some(MathFont::Symbols), 112) | (Some(MathFont::Ext), 0x70..=0x74)) && (g.x + g.adv - r.x0).abs() < 0.05
        });
        if let Some(sv) = surd {
            f.num.clear();
            f.num.push(sv); // the sign itself, marked by kind below
        }
        let kind = if surd.is_some() { 1 } else if f.num.is_empty() && !f.den.is_empty() { 2 } else if f.den.is_empty() && !f.num.is_empty() { 3 } else if f.num.is_empty() { return Err("math: a rule alone".into()) } else { 0 };
        kinds.push(kind);
        let id = fracs.len();
        for &i in f.num.iter().chain(&f.den) {
            group[i] = Some(id);
        }
        fracs.push(f);
    }
    // The main baseline: the most common baseline of the text-size glyphs left.
    let mut hist: std::collections::HashMap<i64, usize> = Default::default();
    for (i, g) in glyphs.iter().enumerate() {
        if group[i].is_none() && (g.size - size0).abs() < 0.01 && math_font(&fonts[g.font]) != Some(MathFont::Ext) {
            *hist.entry((g.y * 100.0).round() as i64).or_default() += 1;
        }
    }
    let y0 = match hist.into_iter().max_by_key(|e| (e.1, -e.0)) {
        Some((k, _)) => k as f64 / 100.0,
        None => fracs.first().map(|f| {
            // Only fractions: the axis is between; any baseline glyph decides. Use the rule's position later.
            let _ = f;
            0.0
        }).ok_or("math: no baseline")?,
    };
    // Big operators with limits: script-size glyphs above or below the operator, centred on it.
    let mut ops: Vec<(usize, Vec<usize>, Vec<usize>)> = vec![]; // (op glyph, above, below)
    for (i, g) in glyphs.iter().enumerate() {
        let Some(mf) = math_font(&fonts[g.font]) else { continue };
        if group[i].is_some() || !takes_limits(mf, g.code) {
            continue;
        }
        let (mut up, mut down) = (vec![], vec![]);
        // Limits are as wide as they need: take each side's run of small glyphs whose middle is the operator's.
        for side in [true, false] {
            let cand: Vec<usize> = (0..n).filter(|&k| k != i && group[k].is_none() && glyphs[k].size < size0 - 0.01 && if side { glyphs[k].y > y0 + 0.9 * size0 } else { glyphs[k].y < y0 - 0.6 * size0 }).collect();
            // Glyphs of one limit sit on one baseline: the one nearest the operator.
            let Some(by) = cand.iter().map(|&k| glyphs[k].y).fold(None, |b: Option<f64>, y| Some(match b { None => y, Some(b) => if side { b.min(y) } else { b.max(y) } })) else { continue };
            let mut row: Vec<usize> = cand.into_iter().filter(|&k| (glyphs[k].y - by).abs() < 0.6 * glyphs[k].size).collect();
            row.sort_by(|&a, &b| glyphs[a].x.partial_cmp(&glyphs[b].x).unwrap());
            // Split into runs; keep the run centred on the operator.
            let mut runs: Vec<Vec<usize>> = vec![];
            for k in row {
                match runs.last_mut() {
                    Some(r) if glyphs[k].x - (glyphs[*r.last().unwrap()].x + glyphs[*r.last().unwrap()].adv) < 0.5 * size0 => r.push(k),
                    _ => runs.push(vec![k]),
                }
            }
            if let Some(r) = runs.into_iter().find(|r| {
                let (a, b) = (glyphs[r[0]].x, glyphs[*r.last().unwrap()].x + glyphs[*r.last().unwrap()].adv);
                ((a + b) / 2.0 - cx(g)).abs() < 0.3
            }) {
                if side { up = r } else { down = r }
            }
        }
        if up.is_empty() && down.is_empty() {
            continue;
        }
        let id = fracs.len() + ops.len();
        group[i] = Some(id);
        for &k in up.iter().chain(&down) {
            group[k] = Some(id);
        }
        ops.push((i, up, down));
    }
    let sub = |ix: &[usize]| -> Result<String, String> {
        let mut v: Vec<Glyph> = ix.iter().map(|&k| glyphs[k].clone()).collect();
        v.sort_by(|a, b| a.x.partial_cmp(&b.x).unwrap());
        // The part's own baseline: its largest glyphs'.
        let big = v.iter().map(|g| g.size).fold(0.0, f64::max);
        let by = v.iter().filter(|g| (g.size - big).abs() < 0.01).map(|g| g.y).fold(f64::MAX, f64::min);
        span_source_raw(fonts, &v, by, big, &|_| None)
    };
    let mut out = String::new();
    let mut seg: Vec<Glyph> = vec![];
    let mut done = vec![false; fracs.len() + ops.len()];
    for i in 0..n {
        match group[i] {
            None => seg.push(glyphs[i].clone()),
            Some(id) if !done[id] => {
                done[id] = true;
                if !seg.is_empty() {
                    out.push_str(&span_source_raw(fonts, &seg, y0, size0, &|_| None)?);
                    seg.clear();
                }
                if id < fracs.len() {
                    let f = &fracs[id];
                    match kinds[id] {
                        0 => out.push_str(&format!("\\frac{{{}}}{{{}}}", sub(&f.num)?, sub(&f.den)?)),
                        1 => out.push_str(&format!("\\sqrt{{{}}}", sub(&f.den)?)),
                        2 => out.push_str(&format!("\\overline{{{}}}", sub(&f.den)?)),
                        _ => out.push_str(&format!("\\underline{{{}}}", sub(&f.num)?)),
                    }
                } else {
                    let (o, up, down) = &ops[id - fracs.len()];
                    let g = &glyphs[*o];
                    out.push_str(&token(math_font(&fonts[g.font]).unwrap(), g.code).unwrap());
                    if !down.is_empty() {
                        out.push_str(&format!("_{{{}}}", sub(down)?));
                    }
                    if !up.is_empty() {
                        out.push_str(&format!("^{{{}}}", sub(up)?));
                    }
                    out.push(' ');
                }
            }
            _ => {}
        }
    }
    if !seg.is_empty() {
        out.push_str(&span_source_raw(fonts, &seg, y0, size0, &|_| None)?);
    }
    resolve_delims(&out)
}
