import Foundation

struct AppInstaller: Sendable {
  typealias Download = AppDownload.Fetch
  typealias Progress = @MainActor @Sendable (AppInstallationPhase) -> Void

  var download: Download = { try await AppDownload.fetch(from: $0, to: $1, progress: $2) }
  var command: Command.Runner = Command.run
  var temporaryDirectory = URL.temporaryDirectory

  func install(
    app: CatalogApp, version: CatalogVersion, on device: SimulatorDevice,
    progress: @escaping Progress
  ) async throws {
    guard device.state == .booted else { throw SimulatorApplicationsError.notRunning }
    try Task.checkCancellation()
    let directory = temporaryDirectory.appending(
      component: "\(AppConfiguration.applicationIdentifier)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appending(component: "app.tar.bz2")
    let url = AppConfiguration.assetURL(
      appID: app.id, version: version.version, filename: "\(app.id).app.tar.bz2")
    await progress(.downloading(0))
    try await AppDownload.fetch(from: url, to: archive, using: download) { bytes in
      progress(.downloading(bytes))
    }
    try Task.checkCancellation()
    await progress(.verifying)
    let preparation = Task.detached(priority: .userInitiated) {
      try AppPackage.verify(archive, version: version)
      try Task.checkCancellation()
      await progress(.extracting)
      let bundle = try AppPackage.extract(
        archive, to: directory.appending(component: "contents"), command: command)
      try AppPackage.validate(bundle, app: app, version: version)
      try Task.checkCancellation()
      return bundle
    }
    let bundle = try await withTaskCancellationHandler {
      try await preparation.value
    } onCancel: {
      preparation.cancel()
    }
    try Task.checkCancellation()
    await progress(.installing)
    try Task.checkCancellation()
    try await SimulatorApplications.install(bundle, on: device, command: command)
  }

  func open(app: CatalogApp, on device: SimulatorDevice) async throws {
    try await SimulatorApplications.launch(app.bundleID, on: device, command: command)
  }

  func uninstall(app: CatalogApp, on device: SimulatorDevice) async throws {
    try await SimulatorApplications.uninstall(app.bundleID, on: device, command: command)
  }
}
