import Foundation

enum SelfUpdateInstallerTests {
  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("installer.preparation", preparation),
      .init("installer.cancellation", cancellation),
      .init("installer.replacement", replacement),
      .init("installer.timeout", timeout),
    ]
  }

  @MainActor
  static func preparation() async throws {
    let directory = try SelfUpdateFixtures.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let release = try SelfUpdateFixtures.release()
    let old = try SelfUpdateFixtures.bundle(
      in: directory.appending(component: "current app ' 测试"), release: release)
    let new = try SelfUpdateFixtures.bundle(
      in: directory.appending(component: "new"), release: release)
    let archive = try SelfUpdateFixtures.archive(new, in: directory)
    let record = try SelfUpdateFixtures.archivedRelease(archive, release: release)
    var updater = SelfUpdater(
      application: old, bundleID: SelfUpdateFixtures.bundleID,
      reportURL: directory.appending(component: "error.json"))
    updater.download = { url, destination, progress in
      guard
        url
          == AppConfiguration.updateAssetURL(
            tag: record.tag, filename: AppConfiguration.archiveName)
      else {
        throw SelfUpdateFixtures.failure("Use the fixed release archive URL.")
      }
      try FileManager.default.copyItem(at: archive, to: destination)
      for step in 1...10_000 { progress(Int64(step) * record.size / 10_000) }
    }
    var phases: [AppInstallationPhase] = []
    let prepared = try await updater.prepare(record) { phases.append($0) }
    defer { prepared.remove() }
    try SelfUpdateFixtures.require(
      prepared.directory.deletingLastPathComponent() == old.deletingLastPathComponent(),
      "Stage on the destination volume.")
    try SelfUpdateFixtures.require(
      phases.contains(.verifying) && phases.contains(.extracting),
      "Report download and preparation phases.")
    let downloads = phases.prefix {
      if case .downloading = $0 { return true }
      return false
    }
    try SelfUpdateFixtures.require(
      downloads.count <= 10 && downloads.last == .downloading(record.size)
        && phases.dropFirst(downloads.count).allSatisfy {
          if case .downloading = $0 { return false }
          return true
        },
      "Coalesce self-update progress and deliver the final byte count before verification.")
    try SelfUpdatePackage.validate(
      SelfUpdateRequest.payload(in: prepared.directory), release: record,
      bundleID: SelfUpdateFixtures.bundleID)
    try SelfUpdateFixtures.require(
      FileManager.default.isExecutableFile(
        atPath: prepared.directory.appending(component: "SimStoreUpdater").path),
      "Copy the current assistant before quitting.")
    let request = try JSONDecoder().decode(
      SelfUpdateRequest.self,
      from: Data(contentsOf: prepared.directory.appending(component: SelfUpdateRequest.filename)))
    try SelfUpdateFixtures.require(
      request.parentPID == getpid() && request.application == old,
      "Wait for the actual parent and replace its actual path.")
    do {
      _ = try await updater.prepare(release) { _ in }
      throw SelfUpdateFixtures.failure("A wrong archive size must fail before handoff.")
    } catch AppPackage.Failure.sizeMismatch {}
    let remaining = try FileManager.default.contentsOfDirectory(
      at: old.deletingLastPathComponent(), includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix(".simstore-update-") }
    try SelfUpdateFixtures.require(
      remaining.map(\.path) == [prepared.directory.path],
      "A failed preparation must remove its staging directory.")
  }

  @MainActor
  static func cancellation() async throws {
    let directory = try SelfUpdateFixtures.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let release = try SelfUpdateFixtures.release()
    let old = try SelfUpdateFixtures.bundle(in: directory, release: release)
    var updater = SelfUpdater(application: old, bundleID: SelfUpdateFixtures.bundleID)
    updater.download = { _, destination, progress in
      try Data("partial download".utf8).write(to: destination)
      progress(1)
      try await Task.sleep(for: .seconds(60))
    }
    var downloading = false
    let task = Task { try await updater.prepare(release) { _ in downloading = true } }
    try await SelfUpdateFixtures.eventually { downloading }
    task.cancel()
    do {
      _ = try await task.value
      throw SelfUpdateFixtures.failure("Cancel must interrupt the download.")
    } catch is CancellationError {}
    let children = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    try SelfUpdateFixtures.require(
      children.map(\.path) == [old.path],
      "Cancel must preserve the original and remove partial downloads.")
  }

  @MainActor
  static func replacement() async throws {
    for shouldFail in [false, true] {
      let directory = try SelfUpdateFixtures.directory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let oldRelease = try SelfUpdateFixtures.release([
        "tag": "0.1.0", "version": "0.1.0", "revision": String(repeating: "a", count: 40),
      ])
      let newRelease = try SelfUpdateFixtures.release()
      let application = try SelfUpdateFixtures.bundle(in: directory, release: oldRelease)
      let work = directory.appending(component: ".simstore-update-\(UUID())")
      _ = try SelfUpdateFixtures.bundle(
        in: work.appending(component: "payload"), release: newRelease)
      let request = SelfUpdateRequest(
        application: application, bundleID: SelfUpdateFixtures.bundleID,
        currentRevision: oldRelease.revision, parentPID: 2, release: newRelease,
        reportURL: directory.appending(component: "error.json"))
      do {
        try await SelfUpdateInstallation.replace(request: request, directory: work) { path in
          try SelfUpdateFixtures.require(
            try SelfUpdateBuild.read(at: path).version == "0.2.0",
            "Launch the replaced app at its original path.")
          try SelfUpdateFixtures.require(
            try SelfUpdateBuild.read(at: SelfUpdateRequest.payload(in: work)).version == "0.1.0",
            "Keep the previous bundle until launch succeeds.")
          if shouldFail { throw SelfUpdateFixtures.failure("Injected launch failure") }
        }
        try SelfUpdateFixtures.require(!shouldFail, "A failed launch must fail the update.")
      } catch SelfUpdateError.launchFailed {
        try SelfUpdateFixtures.require(shouldFail, "Do not fail a successful launch.")
      }
      try SelfUpdateFixtures.require(
        try SelfUpdateBuild.read(at: application).version == (shouldFail ? "0.1.0" : "0.2.0"),
        "A failed launch must restore the previous version atomically.")
    }
  }

  static func timeout() async throws {
    do {
      try await SelfUpdateInstallation.waitForExit(getpid(), timeout: .milliseconds(75))
      throw SelfUpdateFixtures.failure(
        "Never replace the bundle while its process is still running.")
    } catch SelfUpdateError.quitTimedOut {}
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["0.1"]
    try process.run()
    try await SelfUpdateInstallation.waitForExit(process.processIdentifier, timeout: .seconds(2))
  }
}
