// A small immediate-mode Metal renderer: rects (solid, rounded, shadow, undercurl...) and atlas glyphs, in device
// pixels with the origin at the top left, batched by clip rect. Shared by Neovim mode's grid (TaudotNeovim) and the
// native editor's Metal text (TaudotEditor/Metal).
import Metal
import IOSurface
import QuartzCore
import simd

public struct RectInstance {
  public var rect: SIMD4<Float>
  public var color: SIMD4<Float>
  public var params: SIMD4<Float>
  public init(rect: SIMD4<Float>, color: SIMD4<Float>, params: SIMD4<Float>) { self.rect = rect; self.color = color; self.params = params }
}

public struct GlyphInstance {
  public var rect: SIMD4<Float>
  public var uv: SIMD4<Float>
  public var color: SIMD4<Float>
  public var flags: SIMD4<Float>
  public init(rect: SIMD4<Float>, uv: SIMD4<Float>, color: SIMD4<Float>, flags: SIMD4<Float>) { self.rect = rect; self.uv = uv; self.color = color; self.flags = flags }
}

public enum RectKind: Float { case solid = 0, rounded = 1, shadow = 2, undercurl = 3, dotted = 4, dashed = 5 }

struct Uniforms {
  var viewport: SIMD2<Float>
  var pad: SIMD2<Float> = .zero
  var clip: SIMD4<Float>
  var clipRadius: Float
  var pad2: SIMD3<Float> = .zero
}

@inline(__always) public func rgba(_ c: UInt32, _ a: Float = 1) -> SIMD4<Float> {
  SIMD4(Float((c >> 16) & 0xff) / 255, Float((c >> 8) & 0xff) / 255, Float(c & 0xff) / 255, a)
}

/// What the renderer samples glyphs from (Neovim mode's cell atlas, the native editor's glyph atlas).
public protocol GlyphTexture: AnyObject {
  var texture: MTLTexture { get }
}

@MainActor public final class Renderer {
  public let device: MTLDevice
  let queue: MTLCommandQueue
  let rectPipeline: MTLRenderPipelineState
  let glyphPipeline: MTLRenderPipelineState
  let inflight = DispatchSemaphore(value: 3)
  var rectBuffers: [MTLBuffer] = []
  var glyphBuffers: [MTLBuffer] = []
  var frameIndex = 0

  public var rects: [RectInstance] = []
  public var glyphs: [GlyphInstance] = []
  struct Batch { var glyph: Bool; var clip: SIMD4<Float>; var radius: Float; var start: Int; var count: Int }
  var batches: [Batch] = []
  var clip = SIMD4<Float>(0, 0, 1e6, 1e6)
  var clipRadius: Float = 0
  var viewport = SIMD2<Float>(1, 1)

  /// The queue and pipelines of a device, made once: compiling the shaders takes tens of ms on the main thread, and
  /// every editor view (and the Neovim grid) has a renderer.
  private struct Shared { let queue: MTLCommandQueue; let rect: MTLRenderPipelineState; let glyph: MTLRenderPipelineState }
  private static var shared: [UInt64: Shared] = [:]

  private static func shared(_ device: MTLDevice) -> Shared? {
    if let s = shared[device.registryID] { return s }
    guard let queue = device.makeCommandQueue() else { return nil }
    do {
      let lib = try device.makeLibrary(source: shaderSource, options: nil)
      func pipe(_ v: String, _ f: String) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: v)
        d.fragmentFunction = lib.makeFunction(name: f)
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one
        ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: d)
      }
      let s = Shared(queue: queue, rect: try pipe("rectVertex", "rectFragment"), glyph: try pipe("glyphVertex", "glyphFragment"))
      shared[device.registryID] = s
      return s
    } catch {
      print("Taudot: Metal setup failed: \(error)")
      return nil
    }
  }

  public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
    guard let device, let s = Renderer.shared(device) else { return nil }
    self.device = device
    self.queue = s.queue
    rectPipeline = s.rect
    glyphPipeline = s.glyph
  }

  // MARK: building a frame

  public func begin(viewport w: Float, _ h: Float) {
    rects.removeAll(keepingCapacity: true)
    glyphs.removeAll(keepingCapacity: true)
    batches.removeAll(keepingCapacity: true)
    viewport = SIMD2(w, h)
    clip = SIMD4(0, 0, w, h)
    clipRadius = 0
  }

  public func setClip(_ x: Float, _ y: Float, _ w: Float, _ h: Float, radius: Float = 0) {
    clip = SIMD4(x, y, w, h)
    clipRadius = radius
  }

  public func resetClip() { clip = SIMD4(0, 0, viewport.x, viewport.y); clipRadius = 0 }

  @inline(__always) public func note(glyph: Bool) {
    if let last = batches.last, last.glyph == glyph, last.clip == clip, last.radius == clipRadius {
      batches[batches.count - 1].count += 1
    } else {
      batches.append(Batch(glyph: glyph, clip: clip, radius: clipRadius, start: glyph ? glyphs.count - 1 : rects.count - 1, count: 1))
    }
  }

  public func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ color: SIMD4<Float>, kind: RectKind = .solid,
                   _ a: Float = 0, _ b: Float = 0) {
    rects.append(RectInstance(rect: SIMD4(x, y, w, h), color: color, params: SIMD4(kind.rawValue, a, b, 0)))
    note(glyph: false)
  }

  public func appendRects(_ rs: ArraySlice<RectInstance>, dx: Float, dy: Float) {
    for var r in rs { r.rect.x += dx; r.rect.y += dy; rects.append(r); note(glyph: false) }
  }

  /// A glyph: `rect` on screen and `uv` in the atlas, both in pixels; `colorGlyph` draws the atlas's own colours.
  @inline(__always) public func glyph(rect: SIMD4<Float>, uv: SIMD4<Float>, color: SIMD4<Float>, colorGlyph: Bool) {
    glyphs.append(GlyphInstance(rect: rect, uv: uv, color: color, flags: SIMD4(colorGlyph ? 1 : 0, 0, 0, 0)))
    note(glyph: true)
  }

  public func appendGlyphs(_ gs: ArraySlice<GlyphInstance>, dx: Float, dy: Float) {
    for var g in gs { g.rect.x += dx; g.rect.y += dy; glyphs.append(g); note(glyph: true) }
  }

  // MARK: drawing

  func buffer(_ pool: inout [MTLBuffer], _ i: Int, bytes: Int) -> MTLBuffer {
    while pool.count <= i { pool.append(device.makeBuffer(length: 1 << 16, options: .storageModeShared)!) }
    if pool[i].length < bytes { pool[i] = device.makeBuffer(length: max(bytes, pool[i].length * 2), options: .storageModeShared)! }
    return pool[i]
  }

  /// Encode the frame into `texture` and return the committed-to-be command buffer (not yet committed).
  func encode(into texture: MTLTexture, atlas: GlyphTexture, clear: SIMD4<Float>) -> MTLCommandBuffer {
    inflight.wait()
    let slot = frameIndex % 3
    frameIndex += 1
    let rb = buffer(&rectBuffers, slot, bytes: max(rects.count, 1) * MemoryLayout<RectInstance>.stride)
    let gb = buffer(&glyphBuffers, slot, bytes: max(glyphs.count, 1) * MemoryLayout<GlyphInstance>.stride)
    rects.withUnsafeBytes { rb.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    glyphs.withUnsafeBytes { if $0.count > 0 { gb.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: 1)
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
    let tw = texture.width, th = texture.height
    var current: Bool? = nil
    for b in batches {
      if current != b.glyph {
        enc.setRenderPipelineState(b.glyph ? glyphPipeline : rectPipeline)
        enc.setVertexBuffer(b.glyph ? gb : rb, offset: 0, index: 0)
        if b.glyph { enc.setFragmentTexture(atlas.texture, index: 0) }
        current = b.glyph
      }
      var u = Uniforms(viewport: viewport, clip: b.clip, clipRadius: b.radius)
      let x0 = max(0, min(tw, Int(b.clip.x.rounded(.down)))), y0 = max(0, min(th, Int(b.clip.y.rounded(.down))))
      let x1 = max(x0, min(tw, Int((b.clip.x + b.clip.z).rounded(.up)))), y1 = max(y0, min(th, Int((b.clip.y + b.clip.w).rounded(.up))))
      if x1 <= x0 || y1 <= y0 { continue }
      enc.setScissorRect(MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
      enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
      enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
      enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: b.count, baseInstance: b.start)
    }
    enc.endEncoding()
    let sem = inflight
    cb.addCompletedHandler { _ in sem.signal() }
    return cb
  }

  /// Encode and present on a CAMetalLayer. `clear` is the background. Calls `presented` with the presentation time.
  public func end(layer: CAMetalLayer, atlas: GlyphTexture, clear: SIMD4<Float>,
                  completed: (@Sendable (CFTimeInterval) -> Void)? = nil,
                  presented: (@Sendable (CFTimeInterval) -> Void)? = nil) {
    guard let drawable = layer.nextDrawable() else { return }
    let cb = encode(into: drawable.texture, atlas: atlas, clear: clear)
    if let completed { cb.addCompletedHandler { _ in completed(CACurrentMediaTime()) } }
    if let presented { drawable.addPresentedHandler { d in presented(d.presentedTime) } }
    if layer.presentsWithTransaction {
      cb.commit()
      cb.waitUntilScheduled()
      drawable.present()
    } else {
      cb.present(drawable)
      cb.commit()
    }
  }

  /// Encode into `surface` and wait for the GPU, so the caller can hand the finished surface to Core Animation.
  public func end(surface: FrameSurface, atlas: GlyphTexture, clear: SIMD4<Float>) {
    let cb = encode(into: surface.texture, atlas: atlas, clear: clear)
    cb.commit()
    cb.waitUntilCompleted()
  }
}

/// An IOSurface with a Metal texture on it: a frame the editor renders and then sets as its layer's contents.
public final class FrameSurface {
  public let surface: IOSurface
  public let texture: MTLTexture
  public init?(device: MTLDevice, width: Int, height: Int) {
    guard width > 0, height > 0, let s = IOSurface(properties: [
      .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: 0x4247_5241 /* 'BGRA' */,
    ]) else { return nil }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    d.usage = [.renderTarget]
    d.storageMode = .shared
    guard let t = device.makeTexture(descriptor: d, iosurface: unsafeBitCast(s, to: IOSurfaceRef.self), plane: 0) else { return nil }
    surface = s; texture = t
  }
  public var inUse: Bool { surface.isInUse }
}
