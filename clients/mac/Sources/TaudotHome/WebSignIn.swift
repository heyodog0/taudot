// "Sign in here": Overleaf's own /login page in a sheet, with a private cookie store. Once the page lands on the
// dashboard (/project), the session cookie is handed to the engine (`account.login` with `source: webview`).
import AppKit
import WebKit

@MainActor final class WebSignIn: NSObject, WKNavigationDelegate {
  let panel: NSWindow
  private let web: WKWebView
  private let server: URL
  private let status = NSTextField(labelWithString: "")
  /// The session cookie (`name=value`) once the user is signed in.
  var onCookie: ((String) -> Void)?
  var onCancel: (() -> Void)?
  private var done = false
  /// Tests: fill in and send the login form with these (email, password).
  var autofill: (String, String)?

  init(server: URL) {
    self.server = server
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 640), configuration: config)
    panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    super.init()
    web.navigationDelegate = self
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
    cancel.keyEquivalent = "\u{1b}"
    status.textColor = .secondaryLabelColor
    status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    status.lineBreakMode = .byTruncatingTail
    let bar = NSStackView(views: [status, cancel])
    bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let col = NSStackView(views: [web, bar])
    col.orientation = .vertical
    col.spacing = 0
    panel.contentView = col
    web.translatesAutoresizingMaskIntoConstraints = false
    web.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
    status.stringValue = "Google and other single sign-on may refuse an embedded sign-in; use your browser’s session then."
    web.load(URLRequest(url: server.appendingPathComponent("login")))
  }

  @objc private func cancel() {
    done = true
    onCancel?()
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !done, let url = webView.url, url.host == server.host else { return }
    if url.path == "/login", let (email, password) = autofill {
      autofill = nil
      let js = """
        const f = document.querySelector('form'); f.querySelector('input[name=email]').value = \(jsString(email));
        f.querySelector('input[name=password]').value = \(jsString(password)); f.querySelector('button[type=submit]').click();
        """
      webView.evaluateJavaScript(js)
      return
    }
    // Overleaf sends a signed-in user from /login to /project.
    guard url.path == "/project" || url.path.hasPrefix("/project/") else { return }
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self, !self.done else { return }
      let names = ["overleaf_session2", "overleaf.sid", "sharelatex.sid"]
      if let c = cookies.first(where: { names.contains($0.name) && (self.server.host ?? "").hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }) {
        self.done = true
        self.status.stringValue = "Signed in; checking the session…"
        self.onCookie?("\(c.name)=\(c.value)")
      }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    status.stringValue = error.localizedDescription
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    status.stringValue = error.localizedDescription
  }

  private func jsString(_ s: String) -> String {
    let d = try? JSONSerialization.data(withJSONObject: [s])
    return d.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "''"
  }
}
