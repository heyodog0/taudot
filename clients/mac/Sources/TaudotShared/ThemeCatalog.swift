// Every editor theme, in the groups Settings ▸ Editor shows: Built-in (ours and the shipped ones), Rex (when Rex is
// installed), Imported (Ghostty or iTerm2 files the user added, kept in Application Support, removable).
import Foundation

public enum ThemeCatalog {
  public struct Group: Identifiable {
    public var id: String { name }
    public let name: String
    public let themes: [Theme]
  }

  public static var groups: [Group] {
    var out = [Group(name: "Built-in", themes: Theme.builtIn + ShippedThemes.all)]
    let rex = RexThemes.all()
    if !rex.isEmpty { out.append(Group(name: "Rex", themes: rex)) }
    let imp = imported()
    if !imp.isEmpty { out.append(Group(name: "Imported", themes: imp)) }
    return out
  }

  /// A shipped, Rex or imported theme by id (Theme.named looks in the built-in list first).
  public static func find(_ id: String) -> Theme? {
    if let t = ShippedThemes.all.first(where: { $0.id == id }) { return t }
    if id.hasPrefix("rex-") { return RexThemes.all().first { $0.id == id } }
    if id.hasPrefix("imported-") { return imported().first { $0.id == id } }
    return nil
  }

  // MARK: imported

  /// `~/Library/Application Support/taudot/themes` ($TAUDOT_THEMES_DIR for tests).
  public static var folder: URL {
    if let d = ProcessInfo.processInfo.environment["TAUDOT_THEMES_DIR"] { return URL(fileURLWithPath: d) }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("taudot/themes")
  }

  public struct ImportError: Error, CustomStringConvertible {
    public var description: String
  }

  /// Import a Ghostty theme or an iTerm2 `.itermcolors` file. The file is copied as it is; its name (without the
  /// extension) is the theme's name.
  @discardableResult
  public static func importTheme(from url: URL) throws -> Theme {
    let data = try Data(contentsOf: url)
    guard let p = ThemeFiles.parse(data) else {
      throw ImportError(description: "\(url.lastPathComponent) isn't a Ghostty theme or an iTerm2 .itermcolors file")
    }
    let name = url.deletingPathExtension().lastPathComponent
    let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let ext = url.pathExtension.isEmpty ? "ghostty" : url.pathExtension
    let dest = folder.appendingPathComponent(slug + "." + ext)
    try? FileManager.default.removeItem(at: dest)
    try data.write(to: dest)
    return Theme.from(p, id: "imported-" + slug, name: name)
  }

  public static func remove(_ id: String) {
    guard id.hasPrefix("imported-") else { return }
    let slug = String(id.dropFirst("imported-".count))
    for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    where f.deletingPathExtension().lastPathComponent == slug {
      try? FileManager.default.removeItem(at: f)
    }
  }

  public static func imported() -> [Theme] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { f in
      guard let d = try? Data(contentsOf: f), let p = ThemeFiles.parse(d) else { return nil }
      let slug = f.deletingPathExtension().lastPathComponent
      let name = slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
      return Theme.from(p, id: "imported-" + slug, name: name)
    }
  }
}
