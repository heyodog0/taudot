// The project folder as the sidebar's Files tab shows it: what is hidden, in what order (pure, testable).
import Foundation
import TaudotShared

/// What the tree leaves out: taudot's own files, .git, .DS_Store, TeX build files (a .pdf only at the top level:
/// in a folder it's a figure), and what the project's .gitignore ignores.
public struct FileFilter: Sendable {
  public static let hiddenNames: Set<String> = [".git", ".DS_Store", ".svn", ".hg"]
  public static let buildExtensions: Set<String> = [
    "aux", "log", "synctex", "out", "bbl", "blg", "fls", "fdb_latexmk", "xdv", "toc", "lof", "lot", "nav", "snm",
    "vrb", "bcf", "run.xml", "synctex.gz", "synctex(busy)", "dvi",
  ]
  public var rules: [Rule]

  /// One .gitignore line: a glob, for directories only (trailing /), anchored to the root (a / before its end).
  public struct Rule: Sendable, Equatable {
    public var glob: String
    public var dirOnly: Bool
    public var anchored: Bool
    public var negated: Bool
  }

  public init(gitignore: String = "") {
    rules = gitignore.split(whereSeparator: \.isNewline).compactMap { raw in
      var l = String(raw).trimmingCharacters(in: .whitespaces)
      guard !l.isEmpty, !l.hasPrefix("#") else { return nil }
      var neg = false
      if l.hasPrefix("!") { neg = true; l.removeFirst() }
      var dir = false
      if l.hasSuffix("/") { dir = true; l.removeLast() }
      var anchored = l.contains("/")
      if l.hasPrefix("/") { l.removeFirst(); anchored = true }
      if l.hasPrefix("**/") { l.removeFirst(3); anchored = false }
      guard !l.isEmpty else { return nil }
      return Rule(glob: l, dirOnly: dir, anchored: anchored, negated: neg)
    }
  }

  /// The filter for a folder: its .gitignore, if any.
  public init(root: URL) {
    self.init(gitignore: (try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? "")
  }

  /// `rel`: the path from the project root ("figs/a.png"). Its parents are assumed shown.
  public func hides(_ rel: String, isDirectory: Bool) -> Bool {
    let name = (rel as NSString).lastPathComponent
    if Self.hiddenNames.contains(name) || Compat.isOwnFile(name) { return true }
    if !isDirectory {
      let lower = name.lowercased()
      for e in Self.buildExtensions where lower.hasSuffix("." + e) { return true }
      if lower.hasSuffix(".pdf") && !rel.contains("/") { return true }
    }
    var ignored = false
    for r in rules where !r.dirOnly || isDirectory {
      let hit = r.anchored ? Self.glob(r.glob, rel) : Self.glob(r.glob, name)
      if hit { ignored = !r.negated }
    }
    return ignored
  }

  /// fnmatch-style: * and ? within a path component, [..] classes.
  static func glob(_ pattern: String, _ s: String) -> Bool {
    fnmatch(pattern, s, FNM_PATHNAME) == 0
  }
}

/// Folders first, then names as Finder sorts them ("fig2" before "fig10").
public func fileOrder(_ a: (name: String, isDirectory: Bool), _ b: (name: String, isDirectory: Bool)) -> Bool {
  if a.isDirectory != b.isDirectory { return a.isDirectory }
  return a.name.localizedStandardCompare(b.name) == .orderedAscending
}

/// A file or folder in the tree. Children load when first asked for.
public final class FileNode: NSObject, @unchecked Sendable {
  public let url: URL
  public let rel: String
  public let isDirectory: Bool
  public weak var parent: FileNode?
  var loaded: [FileNode]?
  public var name: String { url.lastPathComponent }

  init(url: URL, rel: String, isDirectory: Bool, parent: FileNode?) {
    self.url = url
    self.rel = rel
    self.isDirectory = isDirectory
    self.parent = parent
  }

  public enum Kind: Equatable { case folder, tex, bib, image, style, other }
  public var kind: Kind {
    if isDirectory { return .folder }
    switch url.pathExtension.lowercased() {
    case "tex", "ltx": return .tex
    case "bib": return .bib
    case "png", "jpg", "jpeg", "gif", "pdf", "eps", "svg", "tif", "tiff", "bmp", "webp", "heic": return .image
    case "cls", "sty", "bst", "clo", "def": return .style
    default: return .other
    }
  }
  /// The SF Symbol for its kind.
  public var symbol: String {
    switch kind {
    case .folder: return "folder"
    case .tex: return "doc.text"
    case .bib: return "books.vertical"
    case .image: return "photo"
    case .style: return "gearshape"
    case .other: return "doc"
    }
  }
}

/// The tree under a root folder.
public final class FileTree {
  public let root: FileNode
  public private(set) var filter: FileFilter

  public init(root url: URL) {
    let u = url.standardizedFileURL
    root = FileNode(url: u, rel: "", isDirectory: true, parent: nil)
    filter = FileFilter(root: u)
  }

  public func children(_ node: FileNode) -> [FileNode] {
    if let c = node.loaded { return c }
    let fm = FileManager.default
    let names = (try? fm.contentsOfDirectory(atPath: node.url.path)) ?? []
    var out: [FileNode] = []
    for n in names {
      let u = node.url.appendingPathComponent(n)
      var dir: ObjCBool = false
      guard fm.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
      let rel = node.rel.isEmpty ? n : node.rel + "/" + n
      if filter.hides(rel, isDirectory: dir.boolValue) { continue }
      out.append(FileNode(url: u, rel: rel, isDirectory: dir.boolValue, parent: node))
    }
    out.sort { fileOrder(($0.name, $0.isDirectory), ($1.name, $1.isDirectory)) }
    node.loaded = out
    return out
  }

  /// Forget what was read (the folder changed on disk). The .gitignore is read again too.
  public func invalidate() {
    root.loaded = nil
    filter = FileFilter(root: root.url)
  }

  /// The node at a path from the root, loading folders on the way; nil if hidden or absent.
  public func node(rel: String) -> FileNode? {
    if rel.isEmpty { return root }
    var n = root
    for part in rel.split(separator: "/") {
      guard let next = children(n).first(where: { $0.name == part }) else { return nil }
      n = next
    }
    return n
  }

  /// The path from the root of a file URL inside it, or nil.
  public func rel(of url: URL) -> String? {
    let p = url.standardizedFileURL.resolvingSymlinksInPath().path
    let r = root.url.resolvingSymlinksInPath().path
    if p == r { return "" }
    guard p.hasPrefix(r + "/") else { return nil }
    return String(p.dropFirst(r.count + 1))
  }
}

/// The sidebar's order of paths from the root (FileRow.build): in each folder its files, then its folders, by name.
public func sidebarOrder(_ a: String, _ b: String) -> Bool {
  let pa = a.split(separator: "/").map(String.init), pb = b.split(separator: "/").map(String.init)
  var i = 0
  while i < pa.count - 1 && i < pb.count - 1 && pa[i] == pb[i] { i += 1 }
  guard i < pa.count, i < pb.count else { return pa.count < pb.count }
  let da = i < pa.count - 1, db = i < pb.count - 1  // component i is a folder
  if da != db { return db }
  if pa[i] == pb[i] { return pa.count < pb.count }
  return fileOrder((pa[i], false), (pb[i], false))
}
