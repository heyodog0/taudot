// Without the engine: watch the folder and hand TeXpresso whole files when they are saved (it diffs them itself).
import CoreServices
import Foundation

@MainActor public final class FolderWatch {
  private var stream: FSEventStreamRef?
  private let folder: URL
  private let realFolder: String
  private let onChange: @MainActor (_ rel: String) -> Void

  public init(folder: URL, onChange: @escaping @MainActor (_ rel: String) -> Void) {
    self.folder = folder
    realFolder = folder.resolvingSymlinksInPath().path
    self.onChange = onChange
  }

  public func start() {
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    var c = FSEventStreamContext(version: 0, info: ctx, retain: nil, release: nil, copyDescription: nil)
    let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
      guard let info else { return }
      let me = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
      let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
      MainActor.assumeIsolated { for p in arr.prefix(n) { me.changed(p) } }
    }
    let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
    guard let s = FSEventStreamCreate(nil, cb, &c, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.03, flags)
    else { return }
    FSEventStreamSetDispatchQueue(s, .main)
    FSEventStreamStart(s)
    stream = s
  }

  private func changed(_ p: String) {
    // events carry real paths (/private/var/... for /var/...)
    let rel: String
    if p.hasPrefix(realFolder + "/") { rel = String(p.dropFirst(realFolder.count + 1)) }
    else if p.hasPrefix(folder.path + "/") { rel = String(p.dropFirst(folder.path.count + 1)) }
    else { return }
    guard rel.hasSuffix(".tex") || rel.hasSuffix(".bbl") || rel.hasSuffix(".sty") || rel.hasSuffix(".cls")
      || rel.hasSuffix(".bib") || rel.hasSuffix(".bst") else { return }
    onChange(rel)
  }

  public func stop() {
    guard let s = stream else { return }
    FSEventStreamStop(s)
    FSEventStreamInvalidate(s)
    FSEventStreamRelease(s)
    stream = nil
  }
}
