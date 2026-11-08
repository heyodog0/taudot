// The text of an included PDF figure, for txp-render's `glyphs` verb (glyphs.c): figures are drawn whole by Core
// Graphics, so their characters come from PDFKit. Copyright (c) 2026 the Taudot authors. MIT License.
import Foundation
import PDFKit

private var cache: [String: (mtime: Date, boxes: [Float], text: [CChar])] = [:]

/// Page `page` (1-based) of the PDF at `path`: its visible characters, as boxes (x0 y0 x1 y1 in the page's PDF space,
/// y up; 4 floats each) and, per character, its text then its font's name, each NUL-terminated. Both buffers are
/// malloc'd for the caller to free. Returns the count, 0 when there is no text or no such page.
@_cdecl("taudot_figure_chars")
public func taudot_figure_chars(_ path: UnsafePointer<CChar>, _ page: Int32,
                                _ boxesOut: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                                _ textOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
  let p = String(cString: path)
  let mtime = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast
  let key = "\(page)\u{0}\(p)"
  var entry = cache[key].flatMap { $0.mtime == mtime ? $0 : nil }
  if entry == nil {
    var boxes: [Float] = [], text: [CChar] = []
    if let doc = PDFDocument(url: URL(fileURLWithPath: p)), Int(page) >= 1, Int(page) <= doc.pageCount,
       let pg = doc.page(at: Int(page) - 1), let attr = pg.attributedString {
      let s = attr.string as NSString
      var i = 0
      while i < s.length {
        let r = s.rangeOfComposedCharacterSequence(at: i)
        let ch = s.substring(with: r)
        i = r.location + r.length
        if ch.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { continue }
        let b = pg.characterBounds(at: r.location)
        if b.isEmpty || b.isNull { continue }
        let font = (attr.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont)?.fontName ?? "figure"
        boxes += [Float(b.minX), Float(b.minY), Float(b.maxX), Float(b.maxY)]
        text += ch.utf8CString
        text += font.utf8CString
      }
    }
    entry = (mtime, boxes, text)
    cache[key] = entry
  }
  let e = entry!
  let n = e.boxes.count / 4
  guard n > 0 else { return 0 }
  let bp = malloc(e.boxes.count * 4)!.assumingMemoryBound(to: Float.self)
  e.boxes.withUnsafeBufferPointer { bp.update(from: $0.baseAddress!, count: e.boxes.count) }
  let tp = malloc(e.text.count)!.assumingMemoryBound(to: CChar.self)
  e.text.withUnsafeBufferPointer { tp.update(from: $0.baseAddress!, count: e.text.count) }
  boxesOut.pointee = bp
  textOut.pointee = tp
  return Int32(n)
}
