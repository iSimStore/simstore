import AppKit

struct PreparedSelfUpdate: Sendable {
  let directory: URL

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

struct SelfUpdater: Sendable {
  typealias Progress = @MainActor @Sendable (AppInstallationPhase) -> Void
  var application = Bundle.main.bundleURL
  var bundleID = AppConfiguration.applicationIdentifier
  var reportURL = SelfUpdater.failureReportURL
  var download: AppDownload.Fetch = {
    try await AppDownload.fetch(from: $0, to: $1, progress: $2)
  }

  static var failureReportURL: URL {
    AppConfiguration.cacheDirectory.appending(component: "update-error.json")
  }

  func prepare(
    _ release: SelfUpdateRelease, progress: @escaping Progress
  ) async throws -> PreparedSelfUpdate {
    let application = application.resolvingSymlinksInPath().standardizedFileURL
    let parent = application.deletingLastPathComponent()
    guard FileManager.default.isWritableFile(atPath: parent.path),
      application.pathExtension == "app",
      !application.pathComponents.contains("AppTranslocation")
    else { throw SelfUpdateError.notWritable }
    let directory = parent.appending(component: ".simstore-update-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var prepared = false
    defer { if !prepared { try? FileManager.default.removeItem(at: directory) } }
    let archive = directory.appending(component: AppConfiguration.archiveName)
    await progress(.downloading(0))
    try await AppDownload.fetch(
      from: AppConfiguration.updateAssetURL(
        tag: release.tag, filename: AppConfiguration.archiveName),
      to: archive, using: download
    ) { bytes in
      progress(.downloading(bytes))
    }
    try Task.checkCancellation()
    await progress(.verifying)
    let preparation = Task.detached(priority: .userInitiated) {
      try AppPackage.verify(archive, size: release.size, sha256: release.sha256)
      await progress(.extracting)
      let payload = try AppPackage.extract(archive, to: directory.appending(component: "payload"))
      try SelfUpdatePackage.validate(payload, release: release, bundleID: bundleID)
      try Task.checkCancellation()
      let current = try SelfUpdateBuild.read(at: application)
      let request = SelfUpdateRequest(
        application: application, bundleID: bundleID, currentRevision: current.revision,
        parentPID: getpid(), release: release, reportURL: reportURL,
        language: Bundle.main.preferredLocalizations.first ?? "en")
      try JSONEncoder().encode(request).write(
        to: directory.appending(component: SelfUpdateRequest.filename), options: .atomic)
      // Run the current version's assistant, independently of the bundle being replaced.
      try FileManager.default.copyItem(
        at: application.appending(path: "Contents/Helpers/SimStoreUpdater"),
        to: directory.appending(component: "SimStoreUpdater"))
      try FileManager.default.removeItem(at: archive)
    }
    try await withTaskCancellationHandler {
      try await preparation.value
    } onCancel: {
      preparation.cancel()
    }
    try Task.checkCancellation()
    prepared = true
    return PreparedSelfUpdate(directory: directory)
  }

  @MainActor
  static func restart(_ prepared: PreparedSelfUpdate) async throws {
    let process = Process()
    let directory = prepared.directory
    let request = try JSONDecoder().decode(
      SelfUpdateRequest.self,
      from: Data(contentsOf: directory.appending(component: SelfUpdateRequest.filename)))
    process.executableURL = directory.appending(component: "SimStoreUpdater")
    process.arguments = [directory.path]
    process.standardInput = FileHandle.nullDevice
    let log = directory.appending(component: "helper.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    do {
      while !FileManager.default.fileExists(atPath: directory.appending(component: "ready").path) {
        guard process.isRunning else {
          throw reportedFailure(at: request.reportURL, fallback: .helperFailed)
        }
        guard ContinuousClock.now < deadline else {
          throw SelfUpdateError.helperFailed
        }
        try await Task.sleep(for: .milliseconds(50))
      }
    } catch {
      if process.isRunning { process.terminate() }
      throw error
    }
    NSApplication.shared.terminate(nil)
    // If another action prevents termination, the assistant times out without changing the app.
    while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
    throw reportedFailure(at: request.reportURL, fallback: .quitTimedOut)
  }

  private static func reportedFailure(at url: URL, fallback: SelfUpdateError) -> NSError {
    NSError(
      domain: "SelfUpdate", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: SelfUpdateInstallation.consumeFailure(at: url)
          ?? fallback.localizedDescription
      ])
  }
}
