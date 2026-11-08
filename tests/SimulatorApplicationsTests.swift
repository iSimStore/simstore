import Foundation

@main
struct SimulatorApplicationsTests {
  @MainActor
  static func main() async {
    await TestSuite.run(cases)
  }

  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("decodeFormats", decodeFormats),
      .init("readInstalledBundleVersion", readInstalledBundleVersion),
      .init("rejectInvalidResponses", rejectInvalidResponses),
      .init("querySelectedDevice", querySelectedDevice),
      .init("preserveCommandFailure", preserveCommandFailure),
      .init("rejectStoppedDevices", rejectStoppedDevices),
      .init("rejectUnknownActions", rejectUnknownActions),
      .init("cancelledBeforeQuery", cancelledBeforeQuery),
      .init("cancelledDuringQuery", cancelledDuringQuery),
      .init("uninstallSelectedUserApp", uninstallSelectedUserApp),
      .init("protectOtherApps", protectOtherApps),
    ]
  }

  static let device = SimulatorDevice(
    id: "1140AE85-B348-46DB-AD13-2B18AAD499B4", name: "iPhone Test", runtime: "27.0",
    state: .booted)

  static let listing = Data(
    """
    {
      "com.example.First" = {
        ApplicationType = User;
        CFBundleIdentifier = "com.example.First";
        CFBundleShortVersionString = "1.2.3";
        Path = "/Users/test/Devices/1140AE85/data/Containers/Bundle/Application/ABC/First.app";
      };
      "com.apple.mobilesafari" = {
        ApplicationType = System;
        CFBundleIdentifier = "com.apple.mobilesafari";
      };
    }
    """.utf8)

  static func decodeFormats() throws {
    let decoded = try SimulatorApplications.decodeApplications(listing)
    try require(
      decoded.first { $0.bundleID == "com.example.First" }
        == SimulatorApplication(
          bundleID: "com.example.First", version: "1.2.3", isUserApplication: true),
      "Read the installed version and user status from the simulator, without consulting the catalog."
    )
    try require(
      decoded.first { $0.bundleID == "com.apple.mobilesafari" }
        == SimulatorApplication(
          bundleID: "com.apple.mobilesafari", version: nil, isUserApplication: false),
      "System apps and missing versions must remain distinguishable from user apps.")
    let expected: Set<String> = ["com.example.First", "com.apple.mobilesafari"]
    try require(
      Set(try SimulatorApplications.decodeApplications(listing).map(\.bundleID)) == expected,
      "Decode actual simctl-style OpenStep dictionaries, including system apps.")
    let applications = [
      "com.example.First": ["CFBundleIdentifier": "com.example.First"],
      "com.apple.mobilesafari": ["ApplicationType": "System"],
    ]
    for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
      let data = try PropertyListSerialization.data(
        fromPropertyList: applications, format: format, options: 0)
      try require(
        Set(try SimulatorApplications.decodeApplications(data).map(\.bundleID)) == expected,
        "Accept XML and binary property lists without depending on output formatting.")
    }
    try require(
      try SimulatorApplications.decodeApplications(Data("{}".utf8)).isEmpty,
      "An empty dictionary is a successful empty inventory.")
  }

  static func uninstallSelectedUserApp() async throws {
    let probe = UninstallProbe(listing: listing)
    try await SimulatorApplications.uninstall("com.example.First", on: device, command: probe.run)
    try require(
      probe.calls == [
        ["simctl", "listapps", device.id],
        ["simctl", "uninstall", device.id, "com.example.First"],
      ],
      "Recheck the exact target inventory before uninstalling on the captured UDID.")
    let failureProbe = UninstallProbe(listing: listing, failsUninstall: true)
    do {
      try await SimulatorApplications.uninstall(
        "com.example.First", on: device, command: failureProbe.run)
    } catch {
      try require(
        error.localizedDescription == "Uninstall failed", "Preserve uninstall diagnostics.")
      return
    }
    throw failure("A failed uninstall must not report success.")
  }

  static func protectOtherApps() async throws {
    for bundleID in ["com.apple.mobilesafari", "com.example.Missing", "com.example.Unknown"] {
      let data =
        bundleID == "com.example.Unknown"
        ? Data("{ \"com.example.Unknown\" = { CFBundleShortVersionString = \"1.0\"; }; }".utf8)
        : listing
      let probe = UninstallProbe(listing: data)
      do {
        try await SimulatorApplications.uninstall(bundleID, on: device, command: probe.run)
      } catch SimulatorApplicationsError.notUserApplication {
        try require(
          probe.calls.count == 1, "Never uninstall system, missing, or unclassified apps.")
        continue
      }
      throw failure("Uninstall requires a fresh explicit User application type.")
    }
    let stopped = SimulatorDevice(
      id: device.id, name: device.name, runtime: device.runtime, state: .shutdown)
    let probe = UninstallProbe(listing: listing)
    do {
      try await SimulatorApplications.uninstall(
        "com.example.First", on: stopped, command: probe.run)
    } catch SimulatorApplicationsError.notRunning {
      try require(probe.calls.isEmpty, "Do not query or uninstall on a stopped device.")
      return
    }
    throw failure("A stopped simulator must reject uninstall.")
  }

  static func readInstalledBundleVersion() throws {
    let directory = URL.temporaryDirectory.appending(
      component: "simstore-app-versions-\(UUID().uuidString)")
    let bundle = directory.appending(component: "Installed App.app")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let info: [String: String] = [
      "CFBundleIdentifier": "com.example.First", "CFBundleShortVersionString": "0.8.3-beta",
      "CFBundleVersion": "12345",
    ]
    let file = bundle.appending(component: "Info.plist")
    try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(
      to: file)
    for location in [["Path": bundle.path], ["Bundle": bundle.absoluteString]] {
      var properties = location
      properties["ApplicationType"] = "User"
      properties["CFBundleVersion"] = "12345"
      let data = try PropertyListSerialization.data(
        fromPropertyList: ["com.example.First": properties], format: .xml, options: 0)
      let app = try SimulatorApplications.decodeApplications(data).first
      try require(
        app?.version == "0.8.3-beta",
        "Read the installed bundle's short version when listapps only reports a build number.")
      try FileManager.default.removeItem(at: file)
      try require(
        try SimulatorApplications.decodeApplications(data).first?.version == nil,
        "An unreadable bundle must remain installed with an unknown version; never substitute the build number."
      )
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
        to: file)
    }
    var other = info
    other["CFBundleIdentifier"] = "com.example.Other"
    try PropertyListSerialization.data(fromPropertyList: other, format: .xml, options: 0).write(
      to: file)
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["com.example.First": ["Path": bundle.path]], format: .xml, options: 0)
    try require(
      try SimulatorApplications.decodeApplications(data).first?.version == nil,
      "A different app at a stale path must not supply this app's installed version.")
  }

  static func rejectInvalidResponses() throws {
    let array = try PropertyListSerialization.data(
      fromPropertyList: ["com.example.First"], format: .xml, options: 0)
    for data in [
      Data([0x00, 0xFF]), Data("{".utf8), array,
      Data("{ \"com.example.First\" = scalar; }".utf8), Data("{ \"\" = {}; }".utf8),
    ] {
      do {
        _ = try SimulatorApplications.decodeApplications(data)
      } catch { continue }
      throw failure(
        "Malformed, non-dictionary, and invalid app entries must not mean no installed apps.")
    }
  }

  @MainActor
  static func querySelectedDevice() async throws {
    let identifiers = try await SimulatorApplications.installedApps(on: device) {
      executable, arguments in
      try require(executable == "/usr/bin/xcrun", "Resolve the tool through the system xcrun.")
      try require(
        arguments == ["simctl", "listapps", device.id],
        "Query the exact selected UDID, without booted aliases or unsupported JSON flags.")
      try require(!Thread.isMainThread, "The synchronous tool must not block the main thread.")
      return listing
    }
    try require(
      Set(identifiers.map(\.bundleID)) == ["com.example.First", "com.apple.mobilesafari"],
      "Return installed identifiers from the selected simulator.")
  }

  static func preserveCommandFailure() async throws {
    let expected = failure("Simulator service is unavailable.")
    do {
      _ = try await SimulatorApplications.installedApps(on: device) { _, _ in throw expected }
    } catch {
      try require(
        (error as NSError) == expected,
        "A query failure must preserve its diagnostic rather than return an empty inventory.")
      return
    }
    throw failure("A failed installed-app query must throw.")
  }

  static func rejectStoppedDevices() async throws {
    for state in [SimulatorState.shutdown, .booting, .shuttingDown, .unknown] {
      let stopped = SimulatorDevice(
        id: device.id, name: device.name, runtime: device.runtime, state: state)
      do {
        _ = try await SimulatorApplications.installedApps(on: stopped) { _, _ in
          throw failure("A non-booted simulator must not invoke a live app query.")
        }
      } catch SimulatorApplicationsError.notRunning {
        continue
      }
      throw failure("A non-booted simulator must have an unknown inventory.")
    }
  }

  static func rejectUnknownActions() async throws {
    let unknown = SimulatorDevice(
      id: device.id, name: device.name, runtime: device.runtime, state: .unknown)
    let command: Command.Runner = { _, _ in
      throw failure("An unknown simulator state must not invoke an app command.")
    }
    do {
      try await SimulatorApplications.install(
        URL(fileURLWithPath: "/Example.app"), on: unknown, command: command)
      throw failure("An unknown simulator state must reject installation.")
    } catch SimulatorApplicationsError.notRunning {}
    do {
      try await SimulatorApplications.launch("com.example.First", on: unknown, command: command)
      throw failure("An unknown simulator state must reject launching an app.")
    } catch SimulatorApplicationsError.notRunning {}
  }

  static func cancelledBeforeQuery() async throws {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await SimulatorApplications.installedApps(on: device) { _, _ in
        throw failure("An already cancelled query must not invoke simctl.")
      }
    }
    do {
      _ = try await task.value
    } catch is CancellationError {
      return
    }
    throw failure("An already cancelled query must throw CancellationError.")
  }

  static func cancelledDuringQuery() async throws {
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    let task = Task {
      try await SimulatorApplications.installedApps(on: device) { _, _ in
        started.signal()
        try require(
          finish.wait(timeout: .now() + 5) == .success,
          "The test must release the in-flight app query.")
        return listing
      }
    }
    let didStart = await Task.detached { waitForQuery(started) }.value
    task.cancel()
    finish.signal()
    try require(didStart, "The app query must start before testing in-flight cancellation.")
    do {
      _ = try await task.value
    } catch is CancellationError {
      return
    }
    throw failure("Cancellation during an app query must not publish its inventory.")
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  static func waitForQuery(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 5) == .success
  }

  static func failure(_ message: String) -> NSError {
    NSError(
      domain: "SimulatorApplicationsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

private final class UninstallProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String]] = []
  let listing: Data
  let failsUninstall: Bool

  init(listing: Data, failsUninstall: Bool = false) {
    self.listing = listing
    self.failsUninstall = failsUninstall
  }

  var calls: [[String]] { lock.withLock { recorded } }

  func run(_ executable: String, _ arguments: [String]) throws -> Data {
    guard executable == "/usr/bin/xcrun", !Thread.isMainThread else {
      throw NSError(domain: "UninstallProbe", code: 1)
    }
    lock.withLock { recorded.append(arguments) }
    if arguments[1] == "listapps" { return listing }
    if failsUninstall {
      throw NSError(
        domain: "UninstallProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Uninstall failed"]
      )
    }
    return Data()
  }
}
