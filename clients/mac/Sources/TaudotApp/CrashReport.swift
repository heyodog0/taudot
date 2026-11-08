// After a crash: on the next launch, the newest crash report macOS wrote for Taudot (~/Library/Logs/DiagnosticReports,
// taudot-app-*.ips) is read and shown in plain words: what went wrong (the exception and its reason), and where (the
// crashed thread's frames in Taudot's own code), with buttons to copy the summary or show the full report in Finder.
// Each report is shown once.
//
// Exceptions: AppKit catches an Objective-C exception raised during event handling, logs it and carries on. Inside a
// Swift task that leaves the concurrency runtime pointing at a finished task, and the app crashed seconds later
// somewhere unrelated (2026-11-06: opening a .sty). NSApplicationCrashOnExceptions makes it crash at the exception
// instead, so the report names the real cause.
import AppKit

@MainActor enum CrashReport {
  static let seenKey = "taudot.crashReportSeen"

  /// Crash at the exception, not later (see above). Called before the app runs.
  static func crashOnExceptions() {
    UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
  }

  static var reportsDir: URL {
    // (TAUDOT_CRASH_DIR: checks use a folder of their own)
    if let d = ProcessInfo.processInfo.environment["TAUDOT_CRASH_DIR"] { return URL(fileURLWithPath: d) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
  }

  /// The unseen report and its summary, then marked seen. Only once it reads (A25): one macOS is still writing when
  /// the app is opened again right after a crash is left for the next launch, not lost.
  static func next() -> (url: URL, text: String)? {
    guard let url = unseen(), let text = summary(url) else { return nil }
    UserDefaults.standard.set(url.lastPathComponent, forKey: seenKey)
    return (url, text)
  }

  /// The newest Taudot crash report not shown yet (on the first launch with this code: only one from the last day).
  static func unseen() -> URL? {
    let fm = FileManager.default
    let files = ((try? fm.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
      .filter { $0.lastPathComponent.hasPrefix("taudot-app-") && $0.pathExtension == "ips" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
    guard let newest = files.first else { return nil }
    guard let seen = UserDefaults.standard.string(forKey: seenKey) else {
      // never run before: only a crash from the last day is news
      let age = (try? newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow }
      return (age ?? .infinity) < 86400 ? newest : nil
    }
    return newest.lastPathComponent > seen ? newest : nil
  }

  /// The report in plain words: when, what, why (the exception's reason when there is one), and where.
  static func summary(_ url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8), let nl = text.firstIndex(of: "\n"),
      let d = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: nl)...].utf8)) as? [String: Any]
    else { return nil }
    var out: [String] = []
    if let t = d["captureTime"] as? String { out.append("When: \(t)") }
    if let v = (d["bundleInfo"] as? [String: Any])?["CFBundleVersion"] as? String { out.append("Build: \(v)") }
    let ex = d["exception"] as? [String: Any]
    let type = [ex?["type"] as? String, ex?["signal"] as? String].compactMap { $0 }.joined(separator: " / ")
    if !type.isEmpty { out.append("What: \(type)" + ((ex?["subtype"] as? String).map { " (\($0))" } ?? "")) }
    // the exception's own words (an NSException's reason, a Swift fatal error's message)
    var why: [String] = []
    for (_, v) in d["asi"] as? [String: Any] ?? [:] { for s in v as? [String] ?? [] where !s.contains("abort() called") { why.append(s) } }
    if let ei = d["exceptionReason"] as? [String: Any], let r = ei["composed_message"] as? String { why.append(r) }
    for w in why { out.append("Why: \(w.trimmingCharacters(in: .whitespacesAndNewlines))") }
    // where: the crashed thread, else the exception's backtrace; Taudot's frames, a few system ones for context
    let images = (d["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
    func frames(_ fs: [[String: Any]]) -> [String] {
      fs.prefix(40).compactMap { f in
        let img = (f["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0] : nil } ?? "?"
        guard let sym = f["symbol"] as? String else { return nil }
        let place = (f["sourceFile"] as? String).map { " (\(($0 as NSString).lastPathComponent):\(f["sourceLine"] as? Int ?? 0))" } ?? ""
        return "  \(img.hasPrefix("taudot") ? "▸" : " ") \(sym)\(place)  [\(img)]"
      }
    }
    if let bt = d["lastExceptionBacktrace"] as? [[String: Any]], !bt.isEmpty {
      out.append("Where the exception was raised:")
      out += frames(bt)
    } else if let i = d["faultingThread"] as? Int, let ths = d["threads"] as? [[String: Any]], i < ths.count,
      let fs = ths[i]["frames"] as? [[String: Any]]
    {
      out.append("Where it crashed (thread \(i)):")
      out += frames(fs)
    }
    out.append("Full report: \(url.path)")
    return out.joined(separator: "\n")
  }

  /// On launch (not in background runs): the unseen report, if any, in a window of its own.
  static func showIfAny() {
    guard !backgroundRun, let (url, text) = next() else { return }
    let a = NSAlert()
    a.alertStyle = .warning
    a.messageText = "Taudot quit unexpectedly last time"
    a.informativeText = "Here's what the crash report says. Copy it and send it along to get it fixed."
    let scroll = NSTextView.scrollableTextView()
    scroll.frame = NSRect(x: 0, y: 0, width: 620, height: 260)
    if let tv = scroll.documentView as? NSTextView {
      tv.string = text
      tv.isEditable = false
      tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    }
    a.accessoryView = scroll
    a.addButton(withTitle: "Copy Report")
    a.addButton(withTitle: "Show in Finder")
    a.addButton(withTitle: "Close")
    switch a.runModal() {
    case .alertFirstButtonReturn:
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    case .alertSecondButtonReturn:
      NSWorkspace.shared.activateFileViewerSelecting([url])
    default: break
    }
  }
}
