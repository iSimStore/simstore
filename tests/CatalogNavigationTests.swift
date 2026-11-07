import AppKit
import SwiftUI

@main
@MainActor
struct CatalogNavigationTests {
  static func main() async {
    do {
      NSApplication.shared.setActivationPolicy(.regular)
      let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/navigation-test-\(UUID())")
      defer { try? FileManager.default.removeItem(at: directory) }
      let probe = NavigationProbe()
      let client = CatalogClient(
        url: URL(string: "https://example.com/index.json")!,
        cacheURL: directory.appending(component: "index.json"),
        transport: { try await probe.fetch($0) })
      let host = NSHostingView(
        rootView: ContentView(
          discover: { try probe.scan() }, boot: { _ in throw failure("Unexpected boot") },
          shutdown: { _ in throw failure("Unexpected shutdown") }, catalogClient: client,
          loadInstalledApps: { await probe.installed(on: $0) }))
      let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 1180, height: 780),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      try await eventually { probe.pendingDownload != nil && search(in: host) != nil }
      let query = "Keep this search"
      let field = search(in: host)!
      field.stringValue = query
      field.delegate?.controlTextDidChange?(
        Notification(name: NSControl.textDidChangeNotification, object: field))
      probe.pendingDownload?.resume()
      probe.pendingDownload = nil
      try await eventually {
        category(in: host)?.itemTitles.contains("Utilities") == true
          && probe.inventoryCalls == ["A"]
          && views(NSTableView.self, in: host).contains(where: { $0.numberOfRows == 3 })
      }
      guard let sections = views(NSTableView.self, in: host).first(where: { $0.numberOfRows == 3 })
      else { throw failure("Expected the native library navigation list.") }
      choose("Utilities", in: category(in: host)!)
      try await eventually { category(in: host)?.titleOfSelectedItem == "Utilities" }
      let initialDownloads = probe.catalogCalls
      let initialQueries = probe.inventoryCalls
      for index in [1, 2, 0] {
        sections.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        try await eventually {
          sections.selectedRow == index
            && category(in: host)?.itemTitles.contains("Games") == (index != 0)
            && category(in: host)?.titleOfSelectedItem == "Utilities"
            && search(in: host)?.stringValue == query
        }
        try await checkNoRefresh(
          probe, downloads: initialDownloads, queries: initialQueries, in: host)
        print("Section \(index): downloads=\(probe.catalogCalls), queries=\(probe.inventoryCalls)")
        try require(
          probe.catalogCalls == initialDownloads && probe.inventoryCalls == initialQueries,
          "Switching sections must reuse the catalog and installed-app inventory.")
        try require(
          search(in: host)?.stringValue == query, "Keep the search when switching sections.")
        try require(
          category(in: host)?.titleOfSelectedItem == "Utilities",
          "Keep a category supported by the new section.")
      }
      sections.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
      try await eventually { category(in: host)?.itemTitles.contains("Games") == true }
      choose("Games", in: category(in: host)!)
      try await eventually { category(in: host)?.titleOfSelectedItem == "Games" }
      sections.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      try await eventually {
        category(in: host)?.titleOfSelectedItem == "All Apps"
          && search(in: host)?.stringValue == query
          && category(in: host)?.itemTitles.contains("Games") == false
      }
      try await checkNoRefresh(
        probe, downloads: initialDownloads, queries: initialQueries, in: host)

      try await eventually {
        views(NSTableView.self, in: host).contains(where: { $0.numberOfRows == 2 })
      }
      guard
        let simulators = views(NSTableView.self, in: host).first(where: { $0.numberOfRows == 2 })
      else { throw failure("Expected the simulator list.") }
      simulators.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
      try await eventually { probe.inventoryCalls == initialQueries + ["B"] }
      try await checkNoRefresh(
        probe, downloads: initialDownloads, queries: initialQueries + ["B"], in: host)
      NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
      try await eventually { probe.inventoryCalls == initialQueries + ["B", "B"] }
      try await checkNoRefresh(
        probe, downloads: initialDownloads, queries: initialQueries + ["B", "B"], in: host)
      try require(
        probe.catalogCalls == initialDownloads && search(in: host)?.stringValue == query,
        "Inventory refreshes must preserve the catalog and search.")

      probe.shouldFailScan = true
      NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
      try await eventually {
        probe.failedScans == 1 && probe.inventoryCalls == initialQueries + ["B", "B", "B"]
          && search(in: host)?.stringValue == query
          && views(NSTableView.self, in: host).contains(where: { $0.numberOfRows == 2 })
      }
      try await checkNoRefresh(
        probe, downloads: initialDownloads, queries: initialQueries + ["B", "B", "B"], in: host)
      probe.shouldFailScan = false
      NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
      try await eventually { probe.inventoryCalls == initialQueries + ["B", "B", "B", "B"] }
      try require(
        probe.catalogCalls == initialDownloads && search(in: host)?.stringValue == query,
        "Discovery failure and recovery must keep the browser, filters, and catalog alive.")
      print(
        "PASS: section and filter changes reuse data; device and activation refreshes still work."
      )
    } catch {
      FileHandle.standardError.write(
        Data("Catalog navigation test failed: \(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  private static func choose(_ title: String, in picker: NSPopUpButton) {
    picker.selectItem(withTitle: title)
    picker.menu?.performActionForItem(at: picker.indexOfSelectedItem)
  }

  private static func search(in view: NSView) -> NSTextField? {
    views(NSTextField.self, in: view).first {
      $0.isEditable && $0.placeholderString == "Search apps"
    }
  }

  private static func category(in view: NSView) -> NSPopUpButton? {
    views(NSPopUpButton.self, in: view).first { $0.itemTitles.contains("All Apps") }
  }

  private static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
  }

  private static func checkNoRefresh(
    _ probe: NavigationProbe, downloads: Int, queries: [String], in view: NSView
  ) async throws {
    // After the expected UI is ready, observe a short window for unwanted loading tasks.
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
    repeat {
      view.layoutSubtreeIfNeeded()
      try require(
        probe.catalogCalls == downloads && probe.inventoryCalls == queries,
        "Navigation and filters must not start extra catalog or inventory requests.")
      try await Task.sleep(for: .milliseconds(20))
    } while ContinuousClock.now < deadline
  }

  private static func eventually(_ condition: () -> Bool, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      guard ContinuousClock.now < deadline else {
        throw failure("Wait for catalog navigation UI at line \(line).")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  nonisolated private static func failure(_ message: String) -> NSError {
    NSError(
      domain: "CatalogNavigationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

@MainActor
private final class NavigationProbe {
  var catalogCalls = 0
  var inventoryCalls: [String] = []
  var pendingDownload: CheckedContinuation<Void, Never>?
  var shouldFailScan = false
  var failedScans = 0

  func scan() throws -> SimulatorDiscovery {
    if shouldFailScan {
      failedScans += 1
      throw NSError(
        domain: "CatalogNavigationTests", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Temporary discovery failure"])
    }
    return SimulatorDiscovery(
      developerDirectory: URL(fileURLWithPath: "/Developer"),
      devices: ["A", "B"].map {
        SimulatorDevice(id: $0, name: "iPhone \($0)", runtime: "27.0", state: .booted)
      })
  }

  func installed(on device: SimulatorDevice) -> [SimulatorApplication] {
    inventoryCalls.append(device.id)
    return [
      SimulatorApplication(
        bundleID: "org.example.installed", version: "0.9.0", isUserApplication: true),
      SimulatorApplication(
        bundleID: "org.example.installed-game", version: "0.9.0", isUserApplication: true),
    ]
  }

  func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
    catalogCalls += 1
    if catalogCalls == 1 { await withCheckedContinuation { pendingDownload = $0 } }
    let apps = ["installed", "installed-game", "discover"].map { id -> [String: Any] in
      [
        "id": id, "name": id, "bundleID": "org.example.\(id)",
        "repository": "https://example.com/app", "license": "MIT",
        "description": ["en": "An example app."],
        "categories": [id == "installed-game" ? "games" : "utilities"],
        "versions": [
          [
            "version": "1.0.0", "minSimulatorOS": "16.0", "size": 1,
            "sha256": String(repeating: "a", count: 64),
            "revision": String(repeating: "b", count: 40),
            "recipeRevision": String(repeating: "c", count: 40), "time": 0,
          ]
        ],
      ]
    }
    return (
      try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "apps": apps]),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}
