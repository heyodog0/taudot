/// One line of LaTeX, read as what it typesets: a list of letters, each tied to the bytes of the source it came from.
/// Columns are UTF-8 byte offsets into the line (Neovim's columns).
///
/// It's a reading, not TeX: commands whose arguments typeset nothing of the source (`\cite`, `\ref`, `\label`,
/// `\begin`) are skipped whole, other commands drop their name and keep their argument's text (`\emph{word}` is
/// "word"), accents give their letter (`\'e` is "e"), maths keeps letters, digits, operators and Greek letters.
public struct SourceLine: Sendable {
  public enum Kind: UInt8, Sendable { case text, math, space }
  public enum ByteClass: UInt8, Sendable { case text, math, space, command, comment }

  public struct Token: Sendable, Equatable {
    public var letter: UInt32  // folded (see Letters)
    public var col: Int, end: Int  // the source bytes it came from
    public var kind: Kind
    public init(letter: UInt32, col: Int, end: Int, kind: Kind) {
      self.letter = letter; self.col = col; self.end = end; self.kind = kind
    }
  }

  public let text: String
  public private(set) var tokens: [Token] = []
  /// What each byte of the line is
  public private(set) var classes: [ByteClass]

  /// `math`: the line starts inside maths (a display environment opened on an earlier line).
  public init(_ text: String, math startInMath: Bool = false) {
    self.text = text
    let sc = text.unicodeScalars.map { $0.value }
    var offs: [Int] = []
    offs.reserveCapacity(sc.count + 1)
    var o = 0
    for u in text.unicodeScalars { offs.append(o); o += UTF8.width(u) }
    offs.append(o)
    classes = [ByteClass](repeating: .command, count: o)

    var toks: [Token] = []
    var cls = classes
    func mark(_ a: Int, _ b: Int, _ c: ByteClass) {
      for k in offs[a]..<offs[b] { cls[k] = c }
    }
    func emit(_ s: [UInt32], _ a: Int, _ b: Int, _ kind: Kind) {
      var folded: [UInt32] = []
      for u in s { Letters.fold(u, into: &folded) }
      for u in folded {
        let k: Kind = u == Letters.space ? .space : kind
        // spaces collapse: one space token for a run
        if k == .space, let last = toks.last, last.kind == .space, last.end == offs[a] {
          toks[toks.count - 1].end = offs[b]
          continue
        }
        toks.append(Token(letter: u, col: offs[a], end: offs[b], kind: k))
      }
      mark(a, b, kind == .math ? .math : (s.allSatisfy { $0 == 0x20 } ? .space : .text))
    }
    func isLetter(_ u: UInt32) -> Bool { (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) }
    func isSpace(_ u: UInt32) -> Bool { u == 0x20 || u == 0x9 }
    let n = sc.count
    /// End of a balanced group starting at `i` (which is `open`), or n
    func group(_ i: Int, _ open: UInt32, _ close: UInt32) -> Int {
      var depth = 0, j = i
      while j < n {
        if sc[j] == 0x5C { j += 2; continue }
        if sc[j] == open { depth += 1 }
        if sc[j] == close { depth -= 1; if depth == 0 { return j + 1 } }
        j += 1
      }
      return n
    }
    /// The letter an accent applies to, at `j` (after the accent command): `e`, `{e}`, `{\i}`. (letter, end)
    func accented(_ j0: Int) -> (UInt32, Int)? {
      var j = j0
      while j < n && isSpace(sc[j]) { j += 1 }
      guard j < n else { return nil }
      if sc[j] == 0x7B {
        let e = group(j, 0x7B, 0x7D)
        var k = j + 1
        if k < n && sc[k] == 0x5C && k + 1 < n && (sc[k + 1] == 0x69 || sc[k + 1] == 0x6A) { return (sc[k + 1], e) }
        while k < e - 1 && !isLetter(sc[k]) { k += 1 }
        return k < e - 1 ? (sc[k], e) : nil
      }
      if sc[j] == 0x5C && j + 1 < n && (sc[j + 1] == 0x69 || sc[j + 1] == 0x6A) { return (sc[j + 1], j + 2) }
      return isLetter(sc[j]) ? (sc[j], j + 1) : nil
    }

    var math = startInMath
    var brackets = Set<Int>()  // \item[..]'s brackets: the label shows, they don't
    var i = 0
    while i < n {
      let u = sc[i]
      if brackets.contains(i) { mark(i, i + 1, .command); i += 1; continue }
      let kind: Kind = math ? .math : .text
      switch u {
      case 0x25:  // % comment
        mark(i, n, .comment)
        i = n
      case 0x5C:  // backslash
        guard i + 1 < n else { mark(i, n, .command); i = n; break }
        let v = sc[i + 1]
        if isLetter(v) {
          var j = i + 1
          while j < n && isLetter(sc[j]) { j += 1 }
          let name = String(String.UnicodeScalarView(sc[(i + 1)..<j].compactMap(Unicode.Scalar.init)))
          if j < n && sc[j] == 0x2A { j += 1 }  // starred
          var k = j
          while k < n && isSpace(sc[k]) { k += 1 }  // TeX eats spaces after a command word
          if Self.letterAccents.contains(name), let (l, e) = accented(j) {
            emit([l], i, e, kind); i = e; break
          }
          if math, let g = Self.mathSymbols[name] {
            emit(g, i, j, .math); mark(j, k, .command); i = k; break
          }
          if let s = Self.named[name] {
            emit(s, i, j, kind); mark(j, k, .command); i = k; break
          }
          if let args = Self.hidden[name] {
            // optional [..] and `args` {..} groups typeset nothing of the source
            var e = k, left = args
            while e < n {
              while e < n && isSpace(sc[e]) { e += 1 }
              guard e < n else { break }
              if sc[e] == 0x5B { e = group(e, 0x5B, 0x5D); continue }
              if sc[e] == 0x7B && left > 0 { e = group(e, 0x7B, 0x7D); left -= 1; continue }
              break
            }
            mark(i, e, .command); i = e; break
          }
          // other commands keep their {..} arguments' text; a [..] option right after them is a setting, except
          // \item's label
          var e = k
          if e < n && sc[e] == 0x5B {
            let close = group(e, 0x5B, 0x5D)
            if name == "item" { brackets.insert(e); brackets.insert(close - 1) } else { e = close }
          }
          mark(i, e, .command); i = e
        } else {
          switch v {
          case 0x27, 0x60, 0x5E, 0x22, 0x7E, 0x3D, 0x2E:  // \' \` \^ \" \~ \= \.
            if let (l, e) = accented(i + 2) { emit([l], i, e, kind); i = e } else { mark(i, i + 2, .command); i += 2 }
          case 0x25, 0x26, 0x5F, 0x24, 0x23, 0x7B, 0x7D:  // \% \& \_ \$ \# \{ \}
            emit([v], i, i + 2, kind); i += 2
          case 0x20, 0x5C:  // "\ " and \\ (a line break)
            emit(math ? [] : [0x20], i, i + 2, kind); i += 2
          case 0x28, 0x5B:  // \( \[
            mark(i, i + 2, .command); math = true; i += 2
          case 0x29, 0x5D:  // \) \]
            mark(i, i + 2, .command); math = false; i += 2
          default:  // \, \; \! \- \/ ...
            mark(i, i + 2, .command); i += 2
          }
        }
      case 0x24:  // $ or $$
        let e = i + 1 < n && sc[i + 1] == 0x24 ? i + 2 : i + 1
        mark(i, e, .command); math.toggle(); i = e
      case 0x7B, 0x7D:
        mark(i, i + 1, .command); i += 1
      case 0x5E, 0x5F, 0x26, 0x23:  // ^ _ & #
        mark(i, i + 1, .command); i += 1
      case 0x7E:  // ~
        emit(math ? [] : [0x20], i, i + 1, kind); i += 1
      case 0x20, 0x9:
        var e = i
        while e < n && isSpace(sc[e]) { e += 1 }
        if math { mark(i, e, .space) } else { emit([0x20], i, e, .text) }
        i = e
      case 0x60 where !math:  // `` → “, ` → ‘
        if i + 1 < n && sc[i + 1] == 0x60 { emit([0x201C], i, i + 2, kind); i += 2 } else { emit([0x2018], i, i + 1, kind); i += 1 }
      case 0x27 where !math:  // '' → ”, ' → ’
        if i + 1 < n && sc[i + 1] == 0x27 { emit([0x201D], i, i + 2, kind); i += 2 } else { emit([0x2019], i, i + 1, kind); i += 1 }
      case 0x27:  // a prime
        emit([0x2019], i, i + 1, kind); i += 1
      case 0x2D where !math:  // -, --, ---
        var e = i
        while e < n && sc[e] == 0x2D && e - i < 3 { e += 1 }
        emit([[0x2D, 0x2013, 0x2014][e - i - 1]], i, e, kind); i = e
      default:
        emit([u], i, i + 1, kind); i += 1
      }
    }
    tokens = toks
    classes = cls
  }

  /// UTF-16 column → UTF-8 column
  public func utf8Column(utf16 c: Int) -> Int {
    let u16 = text.utf16
    guard let i = u16.index(u16.startIndex, offsetBy: c, limitedBy: u16.endIndex) else { return text.utf8.count }
    return text.utf8.distance(from: text.utf8.startIndex, to: i.samePosition(in: text.utf8) ?? text.utf8.endIndex)
  }

  // commands whose arguments typeset nothing of the source: name → number of {..} arguments to skip
  static let hidden: [String: Int] = [
    "cite": 1, "citep": 1, "citet": 1, "citealp": 1, "citealt": 1, "citeauthor": 1, "citeyear": 1, "citeyearpar": 1,
    "nocite": 1, "parencite": 1, "textcite": 1, "autocite": 1,
    "ref": 1, "eqref": 1, "autoref": 1, "cref": 1, "Cref": 1, "pageref": 1, "nameref": 1, "label": 1,
    "begin": 1, "end": 1, "includegraphics": 1, "input": 1, "include": 1, "bibliography": 1,
    "bibliographystyle": 1, "usepackage": 1, "documentclass": 1, "vspace": 1, "hspace": 1, "vskip": 0,
    "hskip": 0, "color": 1, "textcolor": 1, "colorbox": 1, "href": 1, "setlength": 2, "addtolength": 2,
    "newcommand": 2, "renewcommand": 2, "providecommand": 2, "newenvironment": 3, "setcounter": 2,
    "addcontentsline": 3, "phantom": 1, "hphantom": 1, "vphantom": 1, "linewidth": 0, "textwidth": 0,
    "footnotemark": 0, "centering": 0, "noindent": 0, "small": 0, "footnotesize": 0, "large": 0, "Large": 0,
    "bibitem": 1, "resizebox": 2, "scalebox": 1, "rule": 2, "url": 1,
  ]
  // commands that typeset known text
  static let named: [String: [UInt32]] = {
    let s: [String: String] = [
      "ldots": "...", "dots": "...", "textellipsis": "...", "LaTeX": "LaTeX", "TeX": "TeX", "textendash": "–",
      "textemdash": "—", "ss": "ß", "ae": "æ", "oe": "œ", "AE": "Æ", "OE": "Œ", "o": "ø", "O": "Ø", "aa": "å",
      "AA": "Å", "l": "ł", "L": "Ł", "i": "i", "j": "j", "textbackslash": "\\", "textasciitilde": "~",
      "textquoteright": "’", "textquoteleft": "‘", "S": "§", "P": "¶", "dag": "†", "ddag": "‡", "copyright": "©",
      "quad": " ", "qquad": " ", "newline": " ", "par": " ",
    ]
    return s.mapValues { $0.unicodeScalars.map(\.value) }
  }()
  // maths commands that typeset one symbol we can compare
  static let mathSymbols: [String: [UInt32]] = {
    let s: [String: String] = [
      "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ",
      "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
      "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ",
      "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
      "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω", "infty": "∞", "cdot": "⋅", "times": "×",
      "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "pm": "±", "in": "∈", "to": "→",
      "rightarrow": "→", "leftarrow": "←", "partial": "∂", "nabla": "∇", "approx": "≈", "sim": "∼",
      "ldots": "...", "cdots": "⋯", "mid": "|", "ell": "ℓ",
    ]
    return s.mapValues { $0.unicodeScalars.map(\.value) }
  }()
  static let letterAccents: Set<String> = ["c", "v", "u", "H", "k", "r", "d", "b", "t"]
}
