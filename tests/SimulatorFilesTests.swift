import AppKit
import SwiftUI

@main
@MainActor
struct SimulatorFilesTests {
  static func main() {
    NSApplication.shared.setActivationPolicy(.regular)
    Task { @MainActor in
      do {
        try await verifyFiles()
        print(
          "PASS: selected-device local files, shutdown access, iPhone/iPad labels, and native button actions."
        )
        exit(EXIT_SUCCESS)
      } catch {
        FileHandle.standardError.write(Data("Simulator files test failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }
    NSApplication.shared.run()
  }

  private static func verifyFiles() async throws {
    let manager = FileManager.default
    let root = URL(fileURLWithPath: manager.currentDirectoryPath)
      .appending(path: "build/files-test-\(UUID())")
    defer { try? manager.removeItem(at: root) }
    let window = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 400, height: 100),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    defer { window.close() }
    var opened: [URL] = []
    for (index, state) in [SimulatorState.booted, .shutdown].enumerated() {
      let dataPath = root.appending(component: "device-\(index)")
      let groups = dataPath.appending(path: "Containers/Shared/AppGroup")
      // A different provider with the same folder name must never be selected.
      _ = try container(in: groups, name: "photos", identifier: "group.com.apple.Photos")
      let directory = try container(
        in: groups, name: "local-\(UUID())", identifier: "group.com.apple.FileProvider.LocalStorage"
      )
      try Data("user document".utf8).write(to: directory.appending(component: "Example.txt"))
      try require(
        try SimulatorFiles.directory(in: dataPath).path == directory.path,
        "Resolve the local provider by metadata, not the container UUID or another provider.")
      // Device names can be customized; the model identifier determines the label.
      let device = SimulatorDevice(
        id: "device-\(index)", name: "My Test Device", runtime: "27.0", state: state,
        dataPath: dataPath,
        deviceTypeIdentifier: index == 0
          ? "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
          : "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB")
      let host = NSHostingView(
        rootView: SimulatorFilesButton(
          device: device,
          open: {
            opened.append($0)
            return true
          }))
      window.contentView = host
      try await eventually { button(in: host) != nil }
      let button = button(in: host)!
      try require(button.isEnabled, "Local files must remain accessible after shutdown.")
      try require(
        device.localFilesTitle == (index == 0 ? "On My iPhone" : "On My iPad"),
        "Use the actual model even when the device is renamed.")
      button.performClick(nil)
      try await eventually { opened.count == index + 1 && button.isEnabled }
      try require(
        opened.last?.path == directory.path,
        "The button must open only the selected device's folder.")
      try require(
        try String(contentsOf: directory.appending(component: "Example.txt"), encoding: .utf8)
          == "user document", "Opening the folder must preserve its contents.")
      try manager.removeItem(at: directory)
      try expectUnavailable(dataPath)
    }
    try expectUnavailable(nil)
    let uninitialized = root.appending(component: "uninitialized")
    try expectUnavailable(uninitialized)
    try require(
      !manager.fileExists(atPath: uninitialized.path), "Do not create simulator containers.")
  }

  private static func container(in groups: URL, name: String, identifier: String) throws -> URL {
    let container = groups.appending(component: name)
    let directory = container.appending(component: "File Provider Storage")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let metadata = try PropertyListSerialization.data(
      fromPropertyList: ["MCMMetadataIdentifier": identifier], format: .binary, options: 0)
    try metadata.write(
      to: container.appending(component: ".com.apple.mobile_container_manager.metadata.plist"))
    return directory
  }

  private static func expectUnavailable(_ dataPath: URL?) throws {
    do {
      _ = try SimulatorFiles.directory(in: dataPath)
    } catch SimulatorFilesError.unavailable {
      return
    }
    throw failure("Missing local storage must produce an actionable error.")
  }

  private static func button(in view: NSView) -> NSButton? {
    if let button = view as? NSButton { return button }
    return view.subviews.lazy.compactMap { button(in: $0) }.first
  }

  private static func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw failure("Timed out waiting for the native button action.")
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "SimulatorFilesTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
