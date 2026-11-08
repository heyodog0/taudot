// The words on part of a page, with their boxes. TeXpresso's display list has the glyphs and their positions but no
// text for XeTeX output (dvi_prim.c shows each glyph with Unicode 0), so the words are read off our own render of the
// rows with Vision's text recognition, which is accurate on clean typeset text.
import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import Vision

enum PageText {
  /// Pixels per PDF point for the render read by Vision: 10 pt text is ~30 px tall.
  static let scale = 4.0

  /// The words in `image`, a render of `region` (page points) at `scale`. Each whitespace-separated token is split
  /// into its runs of letters and digits ("WordsPlay-generated" → two words, as `WordMatch.sourceWords` splits them);
  /// a token ending with a hyphen keeps it on its last run (a word broken at the end of a typeset line).
  static func words(_ image: TileImage, region: CGRect, scale: Double) -> [(raw: String, rect: CGRect)] {
    var pb: Unmanaged<CVPixelBuffer>?
    guard CVPixelBufferCreateWithIOSurface(nil, image.surface as IOSurfaceRef, nil, &pb) == kCVReturnSuccess,
      let buffer = pb?.takeRetainedValue()
    else { return [] }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    do { try VNImageRequestHandler(cvPixelBuffer: buffer).perform([req]) } catch { return [] }
    let w = Double(image.width) / scale, h = Double(image.height) / scale
    func toPage(_ r: CGRect) -> CGRect {  // Vision: normalised, origin bottom-left
      CGRect(x: region.minX + r.minX * w, y: region.minY + (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
    }
    var out: [(String, CGRect)] = []
    for obs in req.results ?? [] {
      guard let c = obs.topCandidates(1).first else { continue }
      let s = c.string
      for tok in s.split(whereSeparator: \.isWhitespace) {
        var runs: [Range<String.Index>] = []
        var start: String.Index?
        var i = tok.startIndex
        while i < tok.endIndex {
          let ch = tok[i]
          let wordy = ch.isLetter || ch.isNumber || ((ch == "'" || ch == "\u{2019}") && start != nil)
          if wordy { if start == nil { start = i } } else if let s0 = start { runs.append(s0..<i); start = nil }
          i = tok.index(after: i)
        }
        if let s0 = start { runs.append(s0..<tok.endIndex) }
        let hyphen = tok.hasSuffix("-") || tok.hasSuffix("\u{2010}")
        // Vision can answer a part of a token with the whole token's box: then split that box by character position
        let whole = runs.count > 1 ? (try? c.boundingBox(for: tok.startIndex..<tok.endIndex)?.boundingBox) : nil
        let n = Double(tok.count)
        for (k, r) in runs.enumerated() {
          guard var box = try? c.boundingBox(for: r)?.boundingBox else { continue }
          if let whole, box.width > whole.width * 0.9 {
            let a = Double(tok.distance(from: tok.startIndex, to: r.lowerBound)) / n
            let b = Double(tok.distance(from: tok.startIndex, to: r.upperBound)) / n
            box = CGRect(x: whole.minX + whole.width * a, y: whole.minY, width: whole.width * (b - a), height: whole.height)
          }
          var raw = String(tok[r])
          if hyphen && k == runs.count - 1 { raw += "-" }
          out.append((raw, toPage(box)))
        }
      }
    }
    return out
  }
}
