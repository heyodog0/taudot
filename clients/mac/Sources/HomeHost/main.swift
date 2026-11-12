// The home window alone: sign in and browse projects without the rest of the app. Opening a project prints its
// folder. Environment:
//   TAUDOT_SOCKET   the engine socket (default ~/.taudot/engine.sock)
//   TAUDOT_SERVER   the Overleaf server (default https://www.overleaf.com)
//   TAUDOT_APPEARANCE=dark|light
//   TAUDOT_HOME_SHOT=/path/prefix   screenshots in the background, then quit: <prefix>-signed-out.png or
//                    <prefix>-list.png (and <prefix>-cloning.png with TAUDOT_HOME_STAGE=cloning)
//   TAUDOT_HOME_SHOT_REGION=1 (with TAUDOT_ONSCREEN=1): capture the screen region, so the glass shows what's behind
//   TAUDOT_HOME_TEST=open:<name>|new:<name>   an end-to-end run, printing what happened, then quit
// Shots and tests run in the background: no Dock icon, never active, the window off every screen. Controls then
// draw inactive. TAUDOT_ONSCREEN=1 (opt-in, rare: docs/developing.md) puts the window on screen, behind the
// others, and Tests/home_shots.sh brings it forward for the active look.
import AppKit
import TaudotHome
import TaudotShared

// TEXSYNC_* variables (names before the rename) still work (Compat.swift).
Compat.envFallback()

let env = ProcessInfo.processInfo.environment
let shot = env["TAUDOT_HOME_SHOT"]
let app = NSApplication.shared
let background = shot != nil || env["TAUDOT_HOME_TEST"] != nil
let onscreen = env["TAUDOT_ONSCREEN"] == "1"
app.setActivationPolicy(!background ? .regular : onscreen ? .accessory : .prohibited)
if let a = env["TAUDOT_APPEARANCE"] { app.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }

@MainActor final class Host: NSObject, NSApplicationDelegate {
  var home: HomeWindow!

  func applicationDidFinishLaunching(_ n: Notification) {
    let main = NSMenu()
    let item = NSMenuItem()
    main.addItem(item)
    let m = NSMenu()
    m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = m
    let edit = NSMenuItem()
    main.addItem(edit)
    let e = NSMenu(title: "Edit")
    e.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    e.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    e.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    e.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.submenu = e
    app.mainMenu = main

    let sock = Compat.engineSocket()
    home = HomeWindow(socket: URL(fileURLWithPath: sock))
    home.closesOnOpen = false
    home.onOpen = { print("open \($0.path)"); fflush(stdout) }
    if let test = env["TAUDOT_HOME_TEST"] {
      // TAUDOT_HOME_TEST=open:<project name> (sign in with $TAUDOT_HOME_COOKIE first if needed): open it as a
      // double-click does, print the folder, quit.
      runTest(test)
      return
    }
    if let shot {
      home.window.setContentSize(NSSize(width: 780, height: 520))
      home.onState = { [weak self] s in self?.shoot(s, shot) }
      showForRun()
    } else {
      home.show()
      app.activate()
    }
  }

  func runTest(_ test: String) {
    // TAUDOT_HOME_TEST=new:<name> makes a project (blank) instead, then opens it the same way.
    let creating = test.hasPrefix("new:")
    let name = String(test.drop { $0 != ":" }.dropFirst())
    var created = false
    var signedInOnce = false
    home.onOpenFrom = { [self] url, rect in
      print("open \(url.path)")
      print("from \(rect.map { NSStringFromRect($0) } ?? "nil") window \(NSStringFromRect(home.window.frame))")
      fflush(stdout)
      app.terminate(nil)
    }
    home.onState = { [self] s in
      switch s {
      case "signedOut" where !signedInOnce && env["TAUDOT_HOME_PASSWORD"] != nil:
        // Through the "Sign in here" web view, filling in Overleaf's own login form.
        signedInOnce = true
        home.webSignIn(autofill: (env["TAUDOT_HOME_EMAIL"] ?? "", env["TAUDOT_HOME_PASSWORD"] ?? ""))
      case "signedOut" where !signedInOnce:
        signedInOnce = true
        Task { if let e = await home.signIn(cookie: env["TAUDOT_HOME_COOKIE"] ?? "") { print("error \(e)"); app.terminate(nil) } }
      case "projects" where creating:
        if !created { created = true; home.createProject(name, template: "blank") }
      case "projects":
        guard let p = home.projects.first(where: { $0.name == name }) else { print("no project \(name)"); app.terminate(nil); return }
        print("opening \(p.name) local=\(p.localFolder ?? "none")"); fflush(stdout)
        home.open(p)
      case "error", "signedOut":
        print("state \(s)"); app.terminate(nil)
      default: break
      }
    }
    showForRun()
  }

  func showForRun() {
    if onscreen {
      home.show()
      home.window.orderBack(nil)
    } else {
      home.showOffscreen()
    }
  }

  var shotDone = false

  func shoot(_ state: String, _ prefix: String) {
    guard !shotDone, state == "signedOut" || state == "projects" || state == "error" else { return }
    shotDone = true
    let name = state == "signedOut" ? "signed-out" : state == "error" ? "error" : "list"
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
      capture("\(prefix)-\(name).png")
      if state == "projects", env["TAUDOT_HOME_STAGE"] == "cloning" {
        home.stageCloning()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
          capture("\(prefix)-cloning.png")
          app.terminate(nil)
        }
      } else {
        app.terminate(nil)
      }
    }
  }

  func capture(_ path: String) {
    if onscreen {
      // Opt-in: glass and tinted buttons draw inactive in a background app, so Tests/home_shots.sh brings this one
      // forward (macOS 14+ won't let it take focus itself). Wait up to 4 s for that.
      let until = Date().addingTimeInterval(4)
      while !app.isActive && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
      home.window.makeKeyAndOrderFront(nil)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    if onscreen, env["TAUDOT_HOME_SHOT_REGION"] == "1", let screen = NSScreen.screens.first {
      // The glass as it looks: the screen region under the window, what's behind it included (a window capture
      // shows the glass over nothing).
      let r = home.window.frame
      let y = screen.frame.maxY - r.maxY
      p.arguments = ["-x", "-R\(Int(r.minX)),\(Int(y)),\(Int(r.width)),\(Int(r.height))", path]
    } else {
      p.arguments = ["-x", "-o", "-l\(home.window.windowNumber)", path]
    }
    try? p.run()
    p.waitUntilExit()
    print("shot \(path)")
    fflush(stdout)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let host = Host()
app.delegate = host
app.run()
