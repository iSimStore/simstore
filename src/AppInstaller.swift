import Foundation

struct AppInstaller: Sendable {
  typealias Download = AppDownload.Fetch
  typealias Progress = PackagePipeline.Progress

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
    let pipeline = PackagePipeline(
      size: version.size, sha256: version.sha256, download: download, command: command)
    let bundle = try await pipeline.prepare(
      from: url, archive: archive, extractingTo: directory.appending(component: "contents"),
      progress: progress, validate: { try AppPackage.validate($0, app: app, version: version) })
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
