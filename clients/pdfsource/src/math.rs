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
            65..=90 | 97..=122 => format!("\\mathrm{{{ch}}}"),
            _ => return None,
        },
        MathFont::Bold => match c {
            65..=90 | 97..=122 | 48..=57 => format!("\\mathbf{{{ch}}}"),
            0..=10 => format!("\\mathbf{{\\{}}}", UGREEK[c as usize]),
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
pub fn span_source(fonts: &[Font], glyphs: &[Glyph], y0: f64, size0: f64) -> Result<String, String> {
    #[derive(Default)]
    struct Atom {
        nuc: String,
        sup: String,
        sub: String,
    }
    let mut atoms: Vec<Atom> = vec![];
    for g in glyphs {
        let f = &fonts[g.font];
        let Some(mf) = math_font(f) else { return Err("math: text font in math".into()) };
        if mf == MathFont::Ext {
            return Err("math: big operator or delimiter".into());
        }
        let t = token(mf, g.code).ok_or_else(|| format!("math: glyph {} in {}", g.code, f.name))?;
        let on_base = (g.y - y0).abs() < 0.01 && (g.size - size0).abs() < 0.01;
        if on_base {
            atoms.push(Atom { nuc: t, ..Default::default() });
        } else if g.size < size0 - 0.01 {
            if atoms.is_empty() {
                atoms.push(Atom { nuc: "{}".into(), ..Default::default() });
            }
            let a = atoms.last_mut().unwrap();
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
    }
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
