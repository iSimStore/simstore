import AppKit
import CoreFoundation
import Darwin

@main
@MainActor
struct SelfUninstallTests {
  static func main() async {
    do {
      guard CommandLine.arguments.count == 2 else { throw failure("Expected the built app path.") }
      try cleanupScope()
      try await processStopWait()
      try await confirmation()
      try await helperIntegration(source: URL(fileURLWithPath: CommandLine.arguments[1]))
      print(
        "PASS: uninstall confirmation, scoped cleanup, helper validation, failure recovery, and final process kill."
      )
    } catch {
      FileHandle.standardError.write(
        Data("Self-uninstall test failed: \(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  private static func cleanupScope() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "org.example.Uninstall"
    let application = root.appending(component: "SimStore fixture.app")
    try writeInfo(["CFBundleIdentifier": identifier], application: application)
    let library = root.appending(component: "Library")
    let temporary = root.appending(component: "temporary")
    let plan = try SelfUninstallPlan(
      application: application, bundleID: identifier, library: library, temporary: temporary)
    for path in try plan.dataPaths() { try marker(at: path) }
    let byHost = library.appending(path: "Preferences/ByHost/\(identifier).\(UUID()).plist")
    let download = temporary.appending(component: "\(identifier)-\(UUID())")
    let update = root.appending(component: ".simstore-update-\(UUID())")
    let orphan = temporary.appending(component: "\(identifier).uninstall-\(UUID())")
    for path in [byHost, download, update, orphan] { try marker(at: path) }
    let work = temporary.appending(component: "\(identifier).uninstall-\(UUID())")
    let otherUpdate = root.appending(component: ".simstore-update-\(UUID())")
    try marker(at: work)
    try FileManager.default.createDirectory(at: otherUpdate, withIntermediateDirectories: true)
    try JSONEncoder().encode(["application": root.appending(component: "Other.app")]).write(
      to: otherUpdate.appending(component: "request.json"))
    let unrelated = [
      library.appending(path: "Caches/another-app"),
      library.appending(path: "Preferences/ByHost/\(identifier).beta.\(UUID()).plist"),
      temporary.appending(component: "\(identifier)-notes"),
      temporary.appending(component: "\(identifier).beta-\(UUID())"),
      root.appending(component: ".simstore-update-notes"),
      otherUpdate,
    ]
    for path in unrelated { try marker(at: path) }
    let cache = library.appending(path: "Caches/\(identifier)")
    try FileManager.default.removeItem(at: cache)
    let external = root.appending(component: "unrelated target")
    try marker(at: external)
    try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: external)
    let removed = try plan.dataPaths(excluding: work)
    try plan.removeData(excluding: work)
    for path in removed { try require(!exists(path), "Remove owned data at \(path.path).") }
    for path in unrelated + [work, external, application] {
      try require(
        exists(path),
        "Keep unrelated files, symlink targets, the helper, and app until final cleanup.")
    }
    try plan.removeData(excluding: work)
    for id in ["", "../Uninstall", ".", "..", "org.example/Uninstall"] {
      do {
        _ = try SelfUninstallPlan(
          application: application, bundleID: id, library: library, temporary: temporary)
        throw failure("Reject invalid application identifiers.")
      } catch is SelfUninstallError {}
    }
  }

  private static func processStopWait() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    let pid = process.processIdentifier
    defer {
      if process.isRunning {
        kill(pid, SIGCONT)
        process.terminate()
      }
    }
    var started = false
    let waiting = Task {
      started = true
      try await SelfUninstallation.waitUntilStopped(pid, timeout: .seconds(2))
    }
    try await eventually { started }
    try require(kill(pid, SIGSTOP) == 0, "Stop the owned child while its status is being awaited.")
    do {
      try await waiting.value
    } catch {
      throw failure("Waiting for process suspension must leave the main actor responsive.")
    }
    try require(isStopped(pid), "Confirm suspension before allowing cleanup to proceed.")
    try require(kill(pid, SIGCONT) == 0, "Resume the child before testing unsuccessful waits.")
    try await eventually { !isStopped(pid) }
    do {
      try await SelfUninstallation.waitUntilStopped(pid, timeout: .milliseconds(30))
      throw failure("A process that does not stop must reach the suspension deadline.")
    } catch SelfUninstallError.helperFailed {}
    var cancelStarted = false
    let canceled = Task {
      cancelStarted = true
      try await SelfUninstallation.waitUntilStopped(pid)
    }
    try await eventually { cancelStarted }
    canceled.cancel()
    do {
      try await canceled.value
      throw failure("Canceling a suspension wait must throw CancellationError.")
    } catch is CancellationError {}
    try require(
      process.isRunning && !isStopped(pid),
      "Unsuccessful waits must leave the running child intact.")
  }

  private static func isStopped(_ pid: Int32) -> Bool {
    var info = proc_bsdinfo()
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
      > 0
      && info.pbi_status == SSTOP
  }

  private static func confirmation() async throws {
    NSApplication.shared.setActivationPolicy(.regular)
    var calls = 0
    var prepared = false
    let controller = SelfUninstallController(
      application: URL(fileURLWithPath: "/Example/SimStore.app"),
      uninstall: { calls += 1 })
    let cancel = clickWhenShown("Cancel")
    controller.confirm { prepared = true }
    cancel.invalidate()
    try require(
      calls == 0 && !prepared && !controller.isRunning,
      "Cancel must leave the app and data untouched.")
    let uninstall = clickWhenShown("Uninstall")
    controller.confirm { prepared = true }
    uninstall.invalidate()
    try await eventually { !controller.isRunning }
    try require(calls == 1 && prepared, "Only explicit confirmation may invoke uninstall.")

    var reported = false
    let failed = SelfUninstallController(uninstall: { throw failure("Fixture uninstall failure") })
    let accept = clickWhenShown("Uninstall")
    let dismiss = clickWhenShown("OK") { reported = true }
    failed.confirm()
    try await eventually { !failed.isRunning }
    accept.invalidate()
    dismiss.invalidate()
    try require(reported, "A failed uninstall must report an error and allow another attempt.")
  }

  private static func clickWhenShown(_ title: String, clicked: @escaping @MainActor () -> Void = {})
    -> Timer
  {
    let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
      let didClick = MainActor.assumeIsolated {
        @MainActor
        func find(_ view: NSView) -> NSButton? {
          if let button = view as? NSButton, button.title == title { return button }
          return view.subviews.lazy.compactMap { find($0) }.first
        }
        if let view = NSApplication.shared.modalWindow?.contentView, let button = find(view) {
          clicked()
          button.performClick(nil)
          return true
        }
        return false
      }
      if didClick { timer.invalidate() }
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    return timer
  }

  private static func helperIntegration(source: URL) async throws {
    for shouldFail in [false, true] {
      let root = try directory()
      let identifier = "org.example.SimStoreUninstall.\(UUID())"
      let application = root.appending(component: "SimStore fixture.app")
      try FileManager.default.copyItem(at: source, to: application)
      let infoURL = application.appending(path: "Contents/Info.plist")
      var info =
        try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil)
        as! [String: Any]
      info["CFBundleIdentifier"] = identifier
      try writeInfo(info, application: application)
      let config = NSWorkspace.OpenConfiguration()
      config.createsNewApplicationInstance = true
      config.allowsRunningApplicationSubstitution = false
      let running = try await NSWorkspace.shared.openApplication(
        at: application, configuration: config)
      let plan = try SelfUninstallPlan(application: application, bundleID: identifier)
      var locked: URL?
      defer {
        if let locked {
          try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
        }
        kill(running.processIdentifier, SIGCONT)
        if !running.isTerminated { running.forceTerminate() }
        try? SelfUninstallation.clearPreferences(identifier)
        try? plan.removeData()
        try? FileManager.default.removeItem(at: root)
      }
      try require(running.bundleIdentifier == identifier, "Run only the isolated app copy.")
      let defaults = UserDefaults(suiteName: identifier)!
      defaults.set("uninstall fixture", forKey: "marker")
      try require(defaults.synchronize(), "Write isolated preferences.")
      let cache = plan.library.appending(path: "Caches/\(identifier)")
      let state = plan.library.appending(path: "Saved Application State/\(identifier).savedState")
      let download = plan.temporary.appending(component: "\(identifier)-\(UUID())")
      let update = root.appending(component: ".simstore-update-\(UUID())")
      for path in [cache, state, download, update] { try marker(at: path) }
      let protected = cache.appending(component: "marker")
      if shouldFail {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: protected.path)
        locked = protected
      }
      if !shouldFail {
        let rejected = try await runHelper(
          application: application, identifier: identifier, parentPID: getpid(), language: "zh-Hans"
        )
        defer { try? FileManager.default.removeItem(at: rejected.directory) }
        try require(
          rejected.status != 0 && !running.isTerminated && exists(cache),
          "An unrelated PID cannot authorize removal of the app or data.")
        let message = try JSONDecoder().decode(
          String.self, from: Data(contentsOf: rejected.directory.appending(component: "error.json"))
        )
        try require(
          message.contains("无法验证"),
          "Localize assistant validation errors using the app's resources.")
      }
      let result = try await runHelper(
        application: application, identifier: identifier, parentPID: running.processIdentifier)
      defer { try? FileManager.default.removeItem(at: result.directory) }
      if shouldFail {
        try require(
          result.status != 0 && !running.isTerminated && exists(application),
          "A cleanup failure must keep the app and process available.")
        var process = proc_bsdinfo()
        _ = proc_pidinfo(
          running.processIdentifier, PROC_PIDTBSDINFO, 0, &process,
          Int32(MemoryLayout.size(ofValue: process)))
        try require(process.pbi_status != SSTOP, "Resume the original app after cleanup fails.")
        try require(
          exists(result.directory.appending(component: "error.json")),
          "Return the cleanup failure to the app.")
      } else {
        try await eventually { running.isTerminated }
        try require(result.status == 0, "The uninstall helper must finish successfully.")
        for path in [application, cache, state, download, update, result.directory] {
          try require(
            !exists(path),
            "Remove the app, data, staging, and helper before ending the target process.")
        }
        try await Task.sleep(for: .milliseconds(200))
        CFPreferencesSynchronize(
          identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try require(
          CFPreferencesCopyAppValue("marker" as CFString, identifier as CFString) == nil,
          "Remove preferences from the daemon as well as the plist file.")
        try require(
          !exists(plan.library.appending(path: "Preferences/\(identifier).plist")),
          "Do not recreate the preference file after the app exits.")
      }
    }
  }

  private static func runHelper(
    application: URL, identifier: String, parentPID: Int32, language: String = "en"
  ) async throws -> (directory: URL, status: Int32) {
    let directory = URL.temporaryDirectory.appending(component: "\(identifier).uninstall-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let helper = directory.appending(component: "SimStoreUpdater")
    try FileManager.default.copyItem(
      at: application.appending(path: "Contents/Helpers/SimStoreUpdater"), to: helper)
    try JSONEncoder().encode(
      SelfUninstallRequest(
        application: application, bundleID: identifier, parentPID: parentPID, language: language)
    ).write(
      to: directory.appending(component: "request.json"))
    let process = Process()
    process.executableURL = helper
    process.arguments = ["--uninstall", directory.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    try await eventually { !process.isRunning }
    return (directory, process.terminationStatus)
  }

  private static func directory() throws -> URL {
    let result = URL.temporaryDirectory.appending(component: "self-uninstall-test-\(UUID())")
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    return result
  }

  private static func writeInfo(_ info: [String: Any], application: URL) throws {
    try FileManager.default.createDirectory(
      at: application.appending(component: "Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
      to: application.appending(path: "Contents/Info.plist"))
  }

  private static func marker(at url: URL) throws {
    if ["plist", "binarycookies"].contains(url.pathExtension) {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("marker".utf8).write(to: url)
    } else {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data("marker".utf8).write(to: url.appending(component: "marker"))
    }
  }

  private static func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
      || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private static func eventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        throw failure("Timed out waiting for uninstall behavior.")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private static func require(_ value: Bool, _ message: String) throws {
    if !value { throw failure(message) }
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "SelfUninstallTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
