import Foundation

@main
struct PreviewScenarioTests {
  @MainActor
  static func main() async {
    await TestSuite.run(cases)
  }

  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("arguments", arguments),
      .init("missingXcode", missingXcode),
      .init("emptyInventory", emptyInventory),
      .init("blockedDeviceActions", blockedDeviceActions),
    ]
  }

  static func arguments() throws {
    for args in [["SimStore"], ["SimStore", "-AppleLanguages", "(zh-Hans)"]] {
      try require(
        try PreviewScenario.parse(args) == nil, "Normal launches must not enable previews.")
    }
    for mode in PreviewScenario.allCases.map(\.rawValue) {
      let parsed = try PreviewScenario.parse([
        "SimStore", "-AppleLanguages", "(zh-Hans)", "--preview", mode,
      ])
      try require(parsed?.rawValue == mode, "A valid preview mode must be recognized.")
    }
    for args in [["SimStore", "--preview"], ["SimStore", "--preview", "unknown"]] {
      do {
        _ = try PreviewScenario.parse(args)
      } catch { continue }
      throw failure("Invalid preview arguments must be rejected.")
    }
  }

  static func missingXcode() async throws {
    let calls = CommandCalls()
    do {
      _ = try await PreviewScenario.noXcode.discover(installedXcodeURL: nil) { _, _ in
        calls.record()
        throw failure("A forced missing-Xcode preview must not run any commands.")
      }
      throw failure("The missing-Xcode preview must require installation.")
    } catch {
      try require(
        error as? SimulatorDiscoveryError == .xcodeNotInstalled,
        "The missing-Xcode preview must report the installation state.")
    }
    try require(calls.count == 0, "The missing-Xcode preview queried the host toolchain.")
  }

  static func emptyInventory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SimStore Preview \(UUID().uuidString)")
    let xcode = root.appendingPathComponent("Xcode Beta.app")
    let developer = xcode.appendingPathComponent("Contents/Developer")
    let manager = xcode.appendingPathComponent("Contents/Applications/DeviceHub.app")
    try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: manager, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let info = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundlePackageType": "APPL",
      ],
      format: .xml, options: 0)
    try info.write(to: xcode.appendingPathComponent("Contents/Info.plist"))

    let calls = CommandCalls()
    let snapshot = try await PreviewScenario.noSimulators.discover(installedXcodeURL: nil) {
      executable, args in
      calls.record()
      try require(
        executable == "/usr/bin/xcode-select" && args == ["--print-path"],
        "The empty-inventory preview must not call the real simctl command.")
      return Data("\(developer.path)\n".utf8)
    }
    try require(snapshot.devices.isEmpty, "The preview must return an empty device inventory.")
    try require(calls.count == 1, "The selected developer directory must still be queried.")
    try require(
      snapshot.developerDirectory.path == developer.path, "The selected developer path was lost.")
    try require(snapshot.xcodeURL.path == xcode.path, "The selected Xcode application was lost.")
    try require(
      snapshot.deviceManager?.url.path == manager.path,
      "The empty-inventory preview must preserve Device Hub discovery.")

    let incompatible = try await PreviewScenario.incompatible.discover(installedXcodeURL: nil) {
      executable, args in
      try require(
        executable == "/usr/bin/xcode-select" && args == ["--print-path"],
        "The incompatible preview must not query real simulator devices.")
      return Data("\(developer.path)\n".utf8)
    }
    try require(
      incompatible.devices == [
        SimulatorDevice(
          id: "00000000-0000-0000-0000-000000000001", name: "iPhone 8", runtime: "12.0",
          state: .booted)
      ],
      "The incompatible preview must provide a running old device without a local runtime.")
    try require(
      incompatible.deviceManager?.url.path == manager.path,
      "The incompatible preview must retain the selected Xcode's device manager.")

    do {
      _ = try await PreviewScenario.noSimulators.discover(installedXcodeURL: nil) { _, _ in
        Data("/Library/Developer/CommandLineTools\n".utf8)
      }
      throw failure("An empty-inventory preview must still require a full Xcode installation.")
    } catch {
      try require(
        error as? SimulatorDiscoveryError == .xcodeNotInstalled,
        "Missing Xcode must not be disguised as an empty simulator list.")
    }
    do {
      _ = try await PreviewScenario.noSimulators.discover(installedXcodeURL: xcode) { _, _ in
        throw failure("Toolchain configuration failed")
      }
      throw failure("An empty-inventory preview must preserve toolchain errors.")
    } catch {
      try require(
        (error as NSError).domain == "PreviewScenarioTests"
          && error.localizedDescription == "Toolchain configuration failed",
        "The original toolchain failure was not preserved.")
    }
  }

  static func blockedDeviceActions() throws {
    do {
      try PreviewScenario.rejectDeviceAction()
    } catch let error as CocoaError {
      try require(
        error.code == .featureUnsupported, "Device actions in the preview must fail as unsupported."
      )
    }
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  static func failure(_ message: String) -> NSError {
    NSError(domain: "PreviewScenarioTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

private final class CommandCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int { lock.withLock { value } }
  func record() { lock.withLock { value += 1 } }
}
