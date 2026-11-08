import CoreGraphics
import XCTest
@testable import TaudotRender

/// A hand-made list: one rule and one filled triangle, round-tripped through the reader and drawn.
final class ListTests: XCTestCase {
  func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24)] }
  func f(_ x: Float) -> [UInt8] { le32(x.bitPattern) }
  func rec(_ kind: UInt8, _ p: [UInt8]) -> [UInt8] { [kind] + le32(UInt32(p.count)) + p }

  func sample() -> [UInt8] {
    var b: [UInt8] = [0x54, 0x44, 0x4c, 0] + le32(1)
    b += rec(1, le32(0) + f(100) + f(50))
    b += rec(0x13, [10, 10, 30, 20].flatMap(f) + [0, 0, 0, 1].flatMap(f))
    let path: [UInt8] = le32(4) + le32(6) + Array("MLLZ".utf8) + [60, 10, 90, 10, 75, 40].flatMap(f)
    b += rec(0x11, [60, 10, 90, 40].flatMap(f) + [0] + [1, 0, 0, 1].flatMap(f) + [1, 0, 0, 1, 0, 0].flatMap(f) + path)
    b += rec(0x7e, [1, 2, 3])  // an unknown kind is skipped
    b += rec(0, [])
    return b
  }

  func testReadAndDraw() throws {
    let l = try PageList(bytes: sample())
    XCTAssertEqual(l.width, 100)
    XCTAssertEqual(l.ops.count, 3)
    let (img, st) = Drawer.raster(l, scale: 1)
    XCTAssertEqual(st.magenta, 0)
    XCTAssertEqual(img.width, 100)
    // the rule's pixel (y down: row 15) is black, a pixel outside is white
    let data = img.dataProvider!.data! as Data
    let bpr = img.bytesPerRow
    XCTAssertEqual(data[15 * bpr + 20 * 4], 0)
    XCTAssertEqual(data[5 * bpr + 20 * 4], 255)
    // the triangle (red), near its bottom vertex at (75, 38)
    XCTAssertEqual(data[35 * bpr + 75 * 4], 255)
    XCTAssertEqual(data[35 * bpr + 75 * 4 + 1], 0)
  }

  func testBadMagic() {
    XCTAssertThrowsError(try PageList(bytes: [1, 2, 3, 4, 5, 6, 7, 8]))
  }
}

final class SamplerTests: XCTestCase {
  func testWeightsSumToOne() {
    for (s, d) in [(1329, 713), (360, 341), (10, 37), (7, 7), (3, 1)] {
      let w = Sampler.weights(src: s, dst: d)
      XCTAssertEqual(w.count, d)
      for (k, ws) in w {
        XCTAssertEqual(ws.reduce(0, +), 1, accuracy: 1e-4, "\(s)→\(d)")
        XCTAssertTrue(k >= 0 && k + ws.count <= s)
      }
    }
  }

  func testHalvingAverages() {
    // 4×1 black, white, black, white → 2×1 mid grey
    let px: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255]
    let img = Sampler.make(px, 4, 1)!
    let r = Sampler.resample(img, w: 2, h: 1)!
    let d = r.dataProvider!.data! as Data
    XCTAssertEqual(Int(d[0]), 128, accuracy: 1)
    XCTAssertEqual(Int(d[4]), 128, accuracy: 1)
  }
}

final class HashTests: XCTestCase {
  func testImagesDifferingLateHashApart() {
    var a = Data(repeating: 7, count: 5_000_000), b = a
    b[4_999_990] = 8
    XCTAssertNotEqual(contentHash(a, seed: 1), contentHash(b, seed: 1))
    a[3] = 1
    XCTAssertNotEqual(contentHash(a, seed: 1), contentHash(b, seed: 1))
  }
}
