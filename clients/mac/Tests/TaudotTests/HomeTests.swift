// The home window's list model (TaudotHome/ProjectList.swift) and its rows.
import Foundation
import Testing
@testable import TaudotHome

private let homeNow = Date(timeIntervalSince1970: 1_793_700_000)  // 2026-11-03

private func p(_ id: String, _ name: String, owner: String = "Alice", level: String = "owner", ago: Double? = 3600,
               archived: Bool = false, trashed: Bool = false, local: String? = nil, opened: Double? = nil) -> HomeProject {
  HomeProject(id: id, name: name, ownerName: owner, lastUpdated: ago.map { homeNow.addingTimeInterval(-$0) }, accessLevel: level,
              archived: archived, trashed: trashed, localFolder: local, lastOpened: opened.map { homeNow.addingTimeInterval(-$0) })
}

private let homeSample = [
  p("1", "Thesis", ago: 60),
  p("2", "beta paper", owner: "Bob", level: "readWrite", ago: 86400 * 3),
  p("3", "Alpha notes", ago: 7200, local: "/x/Alpha-notes", opened: 10),
  p("4", "Old grant", owner: "Carol", level: "readOnly", ago: 86400 * 40, archived: true),
  p("5", "Scratch", ago: 100, trashed: true, local: "/x/Scratch", opened: 5),
  p("6", "Émile draft", owner: "Bob", level: "readAndWrite", ago: nil, local: "/x/Emile", opened: 50),
]

@Test func decodesTheEngineShape() {
  let j: [String: Any] = ["id": "abc", "name": "Paper", "owner": ["id": "u", "name": "Alice Example", "email": "a@x"],
    "last_updated": "2026-11-03T13:45:04.380Z", "last_updated_by": ["name": "Bob"], "access_level": "readWrite",
    "archived": false, "trashed": false, "local_folder": "/Users/me/Overleaf/Paper", "last_opened": NSNumber(value: 1_793_713_568_480)]
  let h = HomeProject(json: j)!
  #expect(h.ownerName == "Alice Example" && h.ownerLabel == "Alice Example" && !h.isMine)
  #expect(h.lastUpdated == ProjectList.parseDate("2026-11-03T13:45:04.380Z"))
  #expect(h.lastUpdated != nil)
  #expect(h.lastUpdatedBy == "Bob" && h.isLocal)
  #expect(abs(h.lastOpened!.timeIntervalSince1970 - 1_793_713_568.48) < 0.01)
  let bare = HomeProject(json: ["id": "x", "name": "N", "access_level": "owner", "owner": NSNull(), "last_updated_by": NSNull()])!
  #expect(bare.ownerLabel == "You" && bare.lastUpdated == nil && bare.lastUpdatedBy == nil && !bare.isLocal)
  #expect(HomeProject(json: ["name": "no id"]) == nil)
}

@Test func filtersMatchOverleafsDashboard() {
  let ids = { (f: ProjectFilter) in Set(ProjectList.visible(homeSample, ProjectQuery(filter: f)).map(\.id)) }
  #expect(ids(.all) == ["1", "2", "3", "6"])
  #expect(ids(.mine) == ["1", "3"])
  #expect(ids(.shared) == ["2", "6"])
  #expect(ids(.archived) == ["4"])
  #expect(ids(.trashed) == ["5"])
}

@Test func sorts() {
  let order = { (k: ProjectSortKey, asc: Bool) in ProjectList.visible(homeSample, ProjectQuery(sort: k, ascending: asc)).map(\.id) }
  // Newest first by default; a project without a date goes last.
  #expect(order(.lastModified, false) == ["1", "3", "2", "6"])
  #expect(order(.lastModified, true) == ["6", "2", "3", "1"])
  // Names compare like Finder: case-insensitive.
  #expect(order(.name, true) == ["3", "2", "6", "1"])
  #expect(order(.name, false) == ["1", "6", "2", "3"])
  // Owner sorts by what the column shows ("You" for mine); ties by name.
  #expect(order(.owner, true) == ["2", "6", "3", "1"])
}

@Test func searchesNamesAndOwners() {
  let ids = { (s: String) in ProjectList.visible(homeSample, ProjectQuery(search: s)).map(\.id) }
  #expect(ids("PAPER") == ["2"])
  #expect(ids("emile") == ["6"], "diacritics don't matter")
  #expect(Set(ids("bob")) == ["2", "6"], "owner names match too")
  #expect(ids("bob draft") == ["6"], "every word must match")
  #expect(ids("grant").isEmpty, "archived ones only under Archived")
  #expect(ProjectList.visible(homeSample, ProjectQuery(filter: .archived, search: "grant")).map(\.id) == ["4"])
  #expect(ids("  ").count == 4)
}

@Test func recentAndLocalMarks() {
  // Opened on this Mac, newest first; trashed ones left out.
  #expect(ProjectList.recent(homeSample).map(\.id) == ["3", "6"])
  #expect(ProjectList.recent(homeSample, limit: 1).map(\.id) == ["3"])
  #expect(ProjectList.recent([p("1", "a", local: "/x")]).isEmpty, "local but never opened by the engine")
}

@MainActor @Test func rowsPutRecentFirst() {
  let rows = ProjectsView.rows(homeSample, ProjectQuery())
  guard case .header("Recent") = rows[0], case .project(let r, true) = rows[1], case .header("All Projects") = rows[3] else {
    Issue.record("\(rows)"); return
  }
  #expect(r.id == "3")
  #expect(rows.count == 4 + 4)
  // Searching or another filter: no Recent section.
  #expect(ProjectsView.rows(homeSample, ProjectQuery(search: "a")).allSatisfy { if case .project(_, false) = $0 { true } else { false } })
  #expect(ProjectsView.rows(homeSample, ProjectQuery(filter: .mine)).count == 2)
  #expect(ProjectsView.rows([p("1", "a")], ProjectQuery()).count == 1)
}

@Test func relativeDates() {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(identifier: "UTC")!
  let r = { (ago: Double) in ProjectList.relative(homeNow.addingTimeInterval(-ago), now: homeNow, calendar: cal) }
  #expect(r(10) == "just now")
  #expect(r(60) == "a minute ago")
  #expect(r(60 * 42) == "42 minutes ago")
  #expect(r(3600) == "an hour ago")
  #expect(r(86400 * 1.2) == "yesterday")
  #expect(r(86400 * 4) == "4 days ago")
  #expect(r(86400 * 30) == "4 Oct")
  #expect(r(86400 * 400) == "29 Sept 2025" || r(86400 * 400) == "29 Sep 2025")
  #expect(ProjectList.relative(nil) == "—")
}

@Test func cloneFolders() {
  #expect(ProjectList.folderName("My Paper: draft 2") == "My-Paper-draft-2")
  #expect(ProjectList.folderName("  ") == "overleaf-project")
  #expect(ProjectList.folderName("Grüße") == "Grüße")
  let root = URL(fileURLWithPath: "/Users/me/Overleaf")
  let taken: Set<String> = ["/Users/me/Overleaf/Thesis", "/Users/me/Overleaf/Thesis-2"]
  #expect(ProjectList.cloneFolder(root: root, name: "Thesis") { taken.contains($0.path) }.path == "/Users/me/Overleaf/Thesis-3")
  #expect(ProjectList.cloneFolder(root: root, name: "New") { taken.contains($0.path) }.path == "/Users/me/Overleaf/New")
  #expect(ProjectList.abbreviate(NSHomeDirectory() + "/Overleaf/x") == "~/Overleaf/x")
}

@MainActor @Test func signInErrorsAreShort() {
  let e = "no logged-in Overleaf session found in a browser:\n  chrome: no Overleaf session cookie for www.overleaf.com in 2 profile(s)\n  arc: not installed (x missing)\n  safari: reading x (give the terminal Full Disk Access)\nLog in to https://www.overleaf.com in your browser, or paste the session cookie"
  let s = SignInView.explain(e)
  #expect(s.hasPrefix("No signed-in Overleaf session was found"))
  #expect(s.contains("Chrome: no Overleaf session cookie") && s.contains("Safari:") && !s.contains("arc:") && !s.contains("Arc:"))
  #expect(SignInView.explain("the session for x has expired\nmore") == "The session for x has expired")
}

@Test func lastModifiedLeavesOutYou() {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(identifier: "UTC")!
  var p = HomeProject(id: "x", name: "x", lastUpdated: homeNow.addingTimeInterval(-3600), lastUpdatedBy: "Ryan Truong", lastUpdatedById: "me")
  #expect(ProjectList.modified(p, me: "me", now: homeNow, calendar: cal) == "an hour ago")
  #expect(ProjectList.modified(p, me: "other", now: homeNow, calendar: cal) == "an hour ago by Ryan Truong")
  p.lastUpdatedBy = nil
  #expect(ProjectList.modified(p, me: "other", now: homeNow, calendar: cal) == "an hour ago")
}
