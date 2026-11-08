//! Glyph names (Adobe's and TeX fonts' own) to text.

pub fn ascii_name(c: char) -> &'static str {
    match c {
        '!' => "exclam", '"' => "quotedbl", '#' => "numbersign", '$' => "dollar", '%' => "percent",
        '&' => "ampersand", '\'' => "quoteright", '(' => "parenleft", ')' => "parenright", '*' => "asterisk",
        '+' => "plus", ',' => "comma", '-' => "hyphen", '.' => "period", '/' => "slash", ':' => "colon",
        ';' => "semicolon", '<' => "less", '=' => "equal", '>' => "greater", '?' => "question", '@' => "at",
        '[' => "bracketleft", '\\' => "backslash", ']' => "bracketright", '^' => "asciicircum",
        '_' => "underscore", '`' => "quoteleft", '{' => "braceleft", '|' => "bar", '}' => "braceright",
        '~' => "asciitilde", _ => "",
    }
}

const DIGITS: [&str; 10] = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];

/// Unicode text of a glyph name, "" if unknown.
pub fn name_text(n: &str) -> String {
    let n = n.split('.').next().unwrap_or(n); // "a.sc" → "a"
    if n.chars().count() == 1 && n.chars().all(|c| c.is_ascii_alphabetic()) {
        return n.to_string();
    }
    if let Some(d) = DIGITS.iter().position(|d| *d == n) {
        return d.to_string();
    }
    for c in (0x21u8..0x7f).map(|b| b as char) {
        if !ascii_name(c).is_empty() && ascii_name(c) == n {
            return c.to_string();
        }
    }
    if let Some(h) = n.strip_prefix("uni") {
        if h.len() % 4 == 0 && h.len() > 0 {
            let u: Vec<u16> = (0..h.len() / 4).filter_map(|i| u16::from_str_radix(&h[i * 4..i * 4 + 4], 16).ok()).collect();
            return String::from_utf16_lossy(&u);
        }
    }
    if let Some(h) = n.strip_prefix('u') {
        if (4..=6).contains(&h.len()) {
            if let Some(c) = u32::from_str_radix(h, 16).ok().and_then(char::from_u32) {
                return c.to_string();
            }
        }
    }
    let s = match n {
        "ff" => "ff", "fi" => "fi", "fl" => "fl", "ffi" => "ffi", "ffl" => "ffl",
        "quotedblleft" => "\u{201c}", "quotedblright" => "\u{201d}", "quoteleft" => "\u{2018}",
        "quoteright" => "\u{2019}", "endash" => "\u{2013}", "emdash" => "\u{2014}", "dotlessi" => "\u{131}",
        "dotlessj" => "\u{237}", "germandbls" => "ß", "ae" => "æ", "AE" => "Æ", "oe" => "œ", "OE" => "Œ",
        "oslash" => "ø", "Oslash" => "Ø", "exclamdown" => "¡", "questiondown" => "¿", "dieresis" => "\u{a8}",
        "acute" => "\u{b4}", "grave" => "`", "circumflex" => "^", "tilde" => "~", "macron" => "\u{af}",
        "breve" => "\u{2d8}", "dotaccent" => "\u{2d9}", "ring" => "\u{2da}", "caron" => "\u{2c7}",
        "hungarumlaut" => "\u{2dd}", "cedilla" => "\u{b8}", "ogonek" => "\u{2db}", "bullet" => "•",
        "dagger" => "†", "daggerdbl" => "‡", "section" => "§", "paragraph" => "¶", "periodcentered" => "·",
        "quotedblbase" => "„", "quotesinglbase" => "‚", "guillemotleft" => "«", "guillemotright" => "»",
        "guilsinglleft" => "‹", "guilsinglright" => "›", "ellipsis" => "…", "trademark" => "™",
        "copyright" => "©", "registered" => "®", "degree" => "°", "minus" => "−", "multiply" => "×",
        "divide" => "÷", "sterling" => "£", "yen" => "¥", "cent" => "¢", "florin" => "ƒ", "perthousand" => "‰",
        "fraction" => "⁄", "quotesingle" => "'", "visiblespace" => "␣", "lslash" => "ł", "Lslash" => "Ł",
        "eth" => "ð", "Eth" => "Ð", "thorn" => "þ", "Thorn" => "Þ",
        _ => "",
    };
    if !s.is_empty() {
        return s.to_string();
    }
    // Accented letters with Adobe names: "eacute", "Udieresis".
    for (acc, comb) in [("acute", '\u{301}'), ("grave", '\u{300}'), ("dieresis", '\u{308}'), ("circumflex", '\u{302}'),
        ("tilde", '\u{303}'), ("cedilla", '\u{327}'), ("caron", '\u{30c}'), ("ring", '\u{30a}'), ("macron", '\u{304}')]
    {
        if let Some(b) = n.strip_suffix(acc) {
            if b.len() == 1 {
                return format!("{b}{comb}");
            }
        }
    }
    String::new()
}

pub fn digit_name(c: char) -> &'static str {
    DIGITS[(c as u8 - b'0') as usize]
}
