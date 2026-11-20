import Foundation

struct SimulatorApplication: Equatable, Sendable {
  let bundleID: String
  let version: String?
  let isUserApplication: Bool
}

enum SimulatorApplications {
  static func install(
    _ bundle: URL, on device: SimulatorDevice,
    command: @escaping Command.Runner = Command.run
  ) async throws {
    guard device.state == .booted else { throw SimulatorApplicationsError.notRunning }
    try Task.checkCancellation()
    try await Task.detached(priority: .userInitiated) {
      _ = try Command.simctl(["install", device.id, bundle.path], using: command)
    }.value
  }

  static func launch(
    _ bundleID: String, on device: SimulatorDevice,
    command: @escaping Command.Runner = Command.run
  ) async throws {
    guard device.state == .booted else { throw SimulatorApplicationsError.notRunning }
    try Task.checkCancellation()
    try await Task.detached(priority: .userInitiated) {
      _ = try Command.simctl(["launch", device.id, bundleID], using: command)
    }.value
  }

  static func uninstall(
    _ bundleID: String, on device: SimulatorDevice,
    command: @escaping Command.Runner = Command.run
  ) async throws {
    let applications = try await installedApps(on: device, command: command)
    guard
      applications.contains(where: {
        $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame && $0.isUserApplication
      })
    else { throw SimulatorApplicationsError.notUserApplication }
    try Task.checkCancellation()
    try await Task.detached(priority: .userInitiated) {
      _ = try Command.simctl(["uninstall", device.id, bundleID], using: command)
    }.value
  }

  static func installedApps(
    on device: SimulatorDevice,
    command: @escaping Command.Runner = Command.run
  ) async throws -> [SimulatorApplication] {
    guard device.state == .booted else { throw SimulatorApplicationsError.notRunning }
    try Task.checkCancellation()
    let applications = try await Task.detached(priority: .userInitiated) {
      let data = try Command.simctl(["listapps", device.id], using: command)
      return try decodeApplications(data)
    }.value
    try Task.checkCancellation()
    return applications
  }

  static func decodeApplications(_ data: Data) throws -> [SimulatorApplication] {
    guard
      let applications = try PropertyListSerialization.propertyList(
        from: data, format: nil) as? [String: [String: Any]],
      applications.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { throw SimulatorApplicationsError.invalidResponse }
    return applications.map { bundleID, properties in
      SimulatorApplication(
        bundleID: bundleID, version: installedVersion(properties, bundleID: bundleID),
        isUserApplication: properties["ApplicationType"] as? String == "User")
    }
  }

  private static func installedVersion(_ properties: [String: Any], bundleID: String) -> String? {
    let bundle: URL?
    if let path = properties["Path"] as? String, path.hasPrefix("/") {
      bundle = URL(fileURLWithPath: path)
    } else if let value = properties["Bundle"] as? String, let url = URL(string: value),
      url.isFileURL
    {
      bundle = url
    } else {
      bundle = nil
    }
    if let bundle, bundle.pathExtension == "app",
      let data = try? Data(contentsOf: bundle.appending(component: "Info.plist")),
      let info = (try? PropertyListSerialization.propertyList(from: data, format: nil))
        as? [String: Any],
      let identifier = info["CFBundleIdentifier"] as? String,
      identifier.caseInsensitiveCompare(bundleID) == .orderedSame,
      let version = nonemptyVersion(info["CFBundleShortVersionString"])
    {
      return version
    }
    return nonemptyVersion(properties["CFBundleShortVersionString"])
  }

  private static func nonemptyVersion(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let version = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return version.isEmpty ? nil : version
  }
}

enum SimulatorApplicationsError: LocalizedError {
  case notRunning
  case requiresIPad
  case invalidResponse
  case notUserApplication

  var errorDescription: String? {
    switch self {
    case .requiresIPad:
      String(
        localized: "This build is only available for iPad. Select an iPad simulator to install it.")
    case .notRunning:
      String(
        localized:
          "Start the simulator. SimStore will automatically check its installed apps.")
    case .invalidResponse:
      String(localized: "The simulator returned an invalid app list.")
    case .notUserApplication:
      String(
        localized:
          "Only installed user apps can be uninstalled. Refresh the app list and try again.")
    }
  }
}
