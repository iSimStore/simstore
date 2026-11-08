import Foundation

@main
struct SimulatorDiscoveryTests {
  @MainActor
  static func main() async {
    await TestSuite.run(cases)
  }

  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("emptyInventory", emptyInventory),
      .init("availableIOSDevices", availableIOSDevices),
      .init("powerStates", powerStates),
      .init("malformedInventory", malformedInventory),
      .init("deviceManagerLocations", deviceManagerLocations),
      .init("xcodeInstallationStates", xcodeInstallationStates),
    ]
  }

  static func emptyInventory() throws {
    let devices = try SimulatorDiscovery.decodeDevices(Data(#"{"devices": {}}"#.utf8))
    try require(devices.isEmpty, "An empty inventory should contain no devices.")
  }

  static func availableIOSDevices() throws {
    let data = Data(
      #"""
      {"devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
          {"udid": "PHONE", "name": "iPhone 17 Pro", "state": "Shutdown", "isAvailable": true},
          {"udid": "UNAVAILABLE", "name": "Old iPhone", "state": "Shutdown", "isAvailable": false}
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
          {"udid": "TABLET", "name": "iPad Air", "state": "Booted", "isAvailable": true}
        ],
        "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [
          {"udid": "TV", "name": "Apple TV", "state": "Booted", "isAvailable": true}
        ]
      }}
      """#.utf8)
    let devices = try SimulatorDiscovery.decodeDevices(data)
    try require(
      Set(devices.map(\.id)) == ["PHONE", "TABLET"],
      "Only available iOS devices should be included.")
    try require(
      devices.first(where: { $0.id == "PHONE" })?.runtime == "27.1",
      "The runtime version should come from its runtime identifier.")
    try require(
      devices.first(where: { $0.id == "PHONE" })?.state == .shutdown,
      "A shut-down simulator must still count as an available device.")
    try require(
      devices.first(where: { $0.id == "TABLET" })?.state == .booted,
      "The device's power state should be preserved.")
  }

  static func malformedInventory() throws {
    for response in [
      "not JSON", "{}", #"{"devices": []}"#,
      #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-1":[{"name":"Incomplete"}]}}"#,
    ] {
      do {
        _ = try SimulatorDiscovery.decodeDevices(Data(response.utf8))
      } catch {
        continue
      }
      throw failure("An invalid response must fail instead of being interpreted as no simulators.")
    }
  }

  static func powerStates() throws {
    let known: [(String, SimulatorState)] = [
      ("Shutdown", .shutdown), ("Booting", .booting), ("Booted", .booted),
      ("Shutting Down", .shuttingDown), ("Unknown", .unknown),
    ]
    for (value, state) in known {
      let decoded = try JSONDecoder().decode(
        SimulatorState.self, from: JSONEncoder().encode(value))
      try require(decoded == state, "Recognize every supported simctl state spelling.")
    }
    for value in ["FutureState", "", "booted"] {
      let data = try JSONSerialization.data(withJSONObject: [
        "devices": [
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            ["udid": "FUTURE", "name": "iPhone", "state": value, "isAvailable": true]
          ]
        ]
      ])
      let devices = try SimulatorDiscovery.decodeDevices(data)
      try require(
        devices.count == 1 && devices.first?.state == .unknown,
        "Keep an available device when simctl returns an unfamiliar state.")
    }
    try require(
      !SimulatorState.unknown.canStart && !SimulatorState.unknown.canShutdown
        && !SimulatorState.unknown.isTransitioning
        && !SimulatorState.unknown.canPerformPowerAction,
      "Unknown states must not enable power actions or polling.")
    try require(
      SimulatorState.booting.canStart && SimulatorState.booting.isTransitioning
        && !SimulatorState.booting.canPerformPowerAction,
      "An existing boot can be awaited without enabling a duplicate startup button.")
    for value in ["null", "true", "42"] {
      do {
        _ = try JSONDecoder().decode(SimulatorState.self, from: Data(value.utf8))
      } catch is DecodingError { continue }
      throw failure("A non-string state must remain a malformed inventory error.")
    }
  }

  static func deviceManagerLocations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SimStore Discovery \(UUID().uuidString)")
    let xcode = root.appendingPathComponent("Xcode Beta.app")
    let developer = xcode.appendingPathComponent("Contents/Developer")
    try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let discovery = SimulatorDiscovery(developerDirectory: developer, devices: [])
    try require(
      discovery.deviceManager?.name == nil,
      "A missing application must not be offered as available.")

    let legacy = developer.appendingPathComponent("Applications/Simulator.app")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try require(
      discovery.deviceManager?.name == "Simulator",
      "Older Xcode installations should use Simulator.")
    try require(
      discovery.deviceManager?.url.path == legacy.path,
      "Simulator must belong to the selected Xcode.")

    let modern = xcode.appendingPathComponent("Contents/Applications/DeviceHub.app")
    try FileManager.default.createDirectory(at: modern, withIntermediateDirectories: true)
    try require(
      discovery.deviceManager?.name == "Device Hub", "Device Hub should be preferred when present.")
    try require(
      discovery.deviceManager?.url.path == modern.path,
      "Device Hub must belong to the selected Xcode, including paths with spaces.")
  }

  static func xcodeInstallationStates() async throws {
    for hasCommandLineTools in [false, true] {
      do {
        _ = try await SimulatorDiscovery.scan(installedXcodeURL: nil) { _, _ in
          if hasCommandLineTools { return Data("/Library/Developer/CommandLineTools\n".utf8) }
          throw failure("No developer directory selected")
        }
        throw failure("Missing Xcode should require installation.")
      } catch {
        try require(
          (error as? SimulatorDiscoveryError) == .xcodeNotInstalled,
          "Command Line Tools alone must not be treated as a full Xcode installation.")
      }
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SimStore Xcode \(UUID().uuidString)")
    let xcode = root.appendingPathComponent("Xcode Beta.app")
    let developer = xcode.appendingPathComponent("Contents/Developer")
    try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let info = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundlePackageType": "APPL",
      ], format: .xml, options: 0)
    try info.write(to: xcode.appendingPathComponent("Contents/Info.plist"))

    do {
      _ = try await SimulatorDiscovery.scan(installedXcodeURL: xcode) { executable, _ in
        if executable.hasSuffix("xcode-select") {
          return Data("/Library/Developer/CommandLineTools\n".utf8)
        }
        throw failure("Xcode tools not selected")
      }
      throw failure(
        "An unconfigured toolchain must not be interpreted as an empty device inventory.")
    } catch {
      try require(
        error.localizedDescription == "Xcode tools not selected",
        "Installed Xcode with unavailable tools should report the setup error, not ask for installation again."
      )
    }

    let snapshot = try await SimulatorDiscovery.scan(installedXcodeURL: nil) { executable, _ in
      if executable.hasSuffix("xcode-select") { return Data("\(developer.path)\n".utf8) }
      return Data(#"{"devices": {}}"#.utf8)
    }
    try require(
      snapshot.devices.isEmpty,
      "A valid selected Xcode with no devices should produce an empty inventory.")
    try require(
      snapshot.xcodeURL.path == xcode.path,
      "The selected Xcode should be recognized even if Launch Services has not registered it.")
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  static func failure(_ message: String) -> NSError {
    NSError(
      domain: "SimulatorDiscoveryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
