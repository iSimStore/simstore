import Foundation
import Observation

@MainActor
enum AppUpdateBatchTests {
  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("queue.selectionAndSerialExecution", selectionAndSerialExecution),
      .init("queue.failureAndRetry", failureAndRetry),
      .init("queue.cancellation", cancellation),
      .init("queue.cancellationDuringInstall", cancellationDuringInstall),
      .init("queue.separateDevices", separateDevices),
      .init("queue.shutdownWhileDownloading", shutdownWhileDownloading),
      .init("queue.observableBatchLifecycle", observableBatchLifecycle),
      .init(
        "queue.refusedInstallationsReleaseReservations", refusedInstallationsReleaseReservations),
    ]
  }

  private static func selectionAndSerialExecution() async throws {
    let fixture = try BatchFixture(ids: [
      "alpha", "bravo", "current", "future", "unknown", "system", "missing",
    ])
    defer { fixture.remove() }
    let downloads = BatchDownloads(data: fixture.data)
    let commands = BatchCommands()
    let inventory = InstalledAppsStore(load: { _ in
      fixture.apps.filter { $0.id != "missing" }.map { app in
        SimulatorApplication(
          bundleID: app.bundleID,
          version: app.id == "unknown" ? nil : app.id == "current" ? "2.0.0" : "0.9.0",
          isUserApplication: app.id != "system")
      }
    })
    let store = fixture.store(downloads: downloads, commands: commands, inventory: inventory)
    let device = InstallationFixtures.device
    var apps = fixture.apps
    let future = CatalogVersion(
      version: "2.0.0", minSimulatorOS: "28.0", sha256: apps[0].latestVersion.sha256,
      size: apps[0].latestVersion.size, revision: apps[0].latestVersion.revision,
      recipeRevision: apps[0].latestVersion.recipeRevision, time: 0)
    apps[0] = BatchFixture.app(id: "alpha", versions: [future, apps[0].latestVersion])
    apps[3] = BatchFixture.app(id: "future", versions: [future])
    let catalog = AppCatalog(schemaVersion: 1, apps: apps)
    store.updateAll(in: catalog, installedApps: inventory, on: device)
    try InstallationFixtures.require(
      store.updateBatch(deviceID: device.id) == nil, "An unknown inventory cannot start a batch.")
    await inventory.refresh(for: device)
    try InstallationFixtures.require(
      store.pendingUpdates(in: catalog, installedApps: inventory, on: device).map(\.id) == [
        "alpha", "bravo",
      ],
      "Only installed user apps with newer compatible versions may be queued.")
    store.updateAll(in: catalog, installedApps: inventory, on: device)
    let firstID = store.updateBatch(deviceID: device.id)?.id
    try InstallationFixtures.require(
      store.updateBatch(deviceID: device.id)?.isRunning == true
        && store.updateBatch(deviceID: "another-device") == nil
        && ["alpha", "bravo"].allSatisfy {
          store.phase(appID: $0, deviceID: "another-device") == nil
        },
      "Queued updates must create a running batch and reserve apps only on their own device.")
    try InstallationFixtures.require(
      store.phase(appID: "bravo", deviceID: device.id) == .queued,
      "Reserve queued apps before returning to the UI.")
    try InstallationFixtures.require(
      store.activeUpdateVersion(appID: "alpha", deviceID: device.id)?.version == "1.0.0",
      "Rows and details must retain the selected update's version, size, and checksum while queued."
    )
    store.updateAll(in: catalog, installedApps: inventory, on: device)
    store.install(app: apps[1], version: apps[1].latestVersion, on: device)
    store.replace(app: apps[1], version: apps[1].latestVersion, on: device)
    store.open(app: apps[1], on: device)
    store.uninstall(app: apps[1], on: device)
    try await downloads.waitForCount(1)
    let initialDownloads = await downloads.count
    try InstallationFixtures.require(
      store.updateBatch(deviceID: device.id)?.id == firstID && initialDownloads == 1,
      "Repeated Update All and per-app actions must not duplicate reserved jobs.")
    try InstallationFixtures.require(
      await downloads.urls.first
        == AppConfiguration.assetURL(
          appID: "alpha", version: "1.0.0", filename: "alpha.app.tar.bz2"),
      "Use the compatible historical build rather than the incompatible latest build.")
    await downloads.finish(0)
    try await downloads.waitForCount(2)
    try InstallationFixtures.require(
      commands.installs.count == 1 && store.updateBatch(deviceID: device.id)?.updated == 1,
      "The next download starts only after the previous installation has finished.")
    await downloads.finish(1)
    try await finished(store, device.id)
    try InstallationFixtures.require(
      store.updateBatch(deviceID: device.id)?.isRunning == false
        && ["alpha", "bravo"].allSatisfy { store.phase(appID: $0, deviceID: device.id) == nil },
      "Completed batches must stop running and release every member's operation slot.")
    try InstallationFixtures.require(
      store.updateBatch(deviceID: device.id)?.updated == 2
        && store.updateBatch(deviceID: device.id)?.completed == 2,
      "Report every successful update.")
    try InstallationFixtures.require(
      store.pendingUpdates(in: catalog, installedApps: inventory, on: device).isEmpty,
      "Successful updates must immediately update the installed inventory.")
    try InstallationFixtures.require(
      store.activeUpdateVersion(appID: "alpha", deviceID: device.id) == nil,
      "Completed jobs return to the current catalog rather than pinning an old build.")
    try InstallationFixtures.require(
      commands.installs.allSatisfy { $0.deviceID == device.id }, "Keep the captured target device.")
    try fixture.requireClean()
    let stopped = SimulatorDevice(
      id: device.id, name: device.name, runtime: device.runtime, state: .shutdown)
    try InstallationFixtures.require(
      store.pendingUpdates(in: catalog, installedApps: inventory, on: stopped).isEmpty,
      "A stopped simulator cannot be updated.")
  }

  private static func failureAndRetry() async throws {
    let fixture = try BatchFixture(ids: ["alpha", "bravo", "charlie"])
    defer { fixture.remove() }
    let downloads = BatchDownloads(data: fixture.data, blocked: false, failures: ["alpha"])
    let commands = BatchCommands(failures: ["bravo"])
    let inventory = fixture.inventory()
    let device = InstallationFixtures.device
    await inventory.refresh(for: device)
    let store = fixture.store(downloads: downloads, commands: commands, inventory: inventory)
    store.updateAll(in: fixture.catalog, installedApps: inventory, on: device)
    try await finished(store, device.id)
    let result = store.updateBatch(deviceID: device.id)
    try InstallationFixtures.require(
      result?.updated == 1 && result?.failed == 2 && result?.canceled == 0,
      "Download and installation failures must not prevent later apps from updating.")
    try InstallationFixtures.require(
      result?.failures.map(\.app.id) == ["alpha", "bravo"], "Keep each failed app's diagnostic.")
    try InstallationFixtures.require(
      inventory.application(bundleID: fixture.apps[0].bundleID, deviceID: device.id)?.version
        == "0.9.0"
        && inventory.application(bundleID: fixture.apps[1].bundleID, deviceID: device.id)?.version
          == "0.9.0",
      "A failed update must preserve the installed version.")
    try fixture.requireClean()
    await downloads.clearFailures()
    commands.clearFailures()
    store.updateAll(in: fixture.catalog, installedApps: inventory, on: device)
    try await finished(store, device.id)
    try InstallationFixtures.require(
      store.updateBatch(deviceID: device.id)?.updated == 2
        && store.updateBatch(deviceID: device.id)?.failed == 0,
      "Update All must retry only the remaining updates.")
    try InstallationFixtures.require(
      await downloads.appIDs == ["alpha", "bravo", "charlie", "alpha", "bravo"],
      "Do not reinstall a successful batch member on retry.")
    try fixture.requireClean()
  }

  private static func cancellation() async throws {
    let fixture = try BatchFixture(ids: ["alpha", "bravo", "charlie"])
    defer { fixture.remove() }
    let downloads = BatchDownloads(data: fixture.data)
    let commands = BatchCommands()
    let inventory = fixture.inventory()
    let device = InstallationFixtures.device
    await inventory.refresh(for: device)
    let store = fixture.store(downloads: downloads, commands: commands, inventory: inventory)
    store.updateAll(in: fixture.catalog, installedApps: inventory, on: device)
    try await downloads.waitForCount(1)
    store.cancel(appID: "bravo", deviceID: device.id)
    try InstallationFixtures.require(
      store.phase(appID: "bravo", deviceID: device.id) == nil,
      "Canceling a queued app must release it immediately.")
    store.replace(app: fixture.apps[1], version: fixture.apps[1].latestVersion, on: device)
    try await downloads.waitForCount(2)
    store.cancelAllUpdates(deviceID: device.id)
    try InstallationFixtures.require(
      store.updateBatch(deviceID: device.id)?.isRunning == true
        && store.updateBatch(deviceID: device.id)?.isStopping == true,
      "Canceling must keep the batch running until active operations finish cleaning up.")
    try InstallationFixtures.require(
      store.phase(appID: "alpha", deviceID: device.id) == .canceling
        && store.phase(appID: "charlie", deviceID: device.id) == nil,
      "Stop the active download and immediately remove the remaining queue.")
    try InstallationFixtures.require(
      store.phase(appID: "bravo", deviceID: device.id) == .downloading(0),
      "Cancel All must not cancel a separate manual retry of a previously canceled queue entry.")
    await downloads.finish(0)
    try await finished(store, device.id)
    try InstallationFixtures.require(
      store.updateBatch(deviceID: device.id)?.canceled == 3 && commands.installs.isEmpty,
      "Cancellation must not install an unfinished download or start later queue entries.")
    await downloads.finish(1)
    try await InstallationFixtures.eventually {
      store.phase(appID: "bravo", deviceID: device.id) == nil
    }
    try InstallationFixtures.require(
      commands.installs.count == 1 && commands.installs.first?.appID == "bravo",
      "The independent manual update must finish normally.")
    store.dismissUpdateBatch(deviceID: device.id)
    try InstallationFixtures.require(
      store.updateBatch(deviceID: device.id) == nil, "Finished batch results can be dismissed.")
    try fixture.requireClean()
  }

  private static func cancellationDuringInstall() async throws {
    let fixture = try BatchFixture(ids: ["alpha", "bravo"])
    defer { fixture.remove() }
    let downloads = BatchDownloads(data: fixture.data)
    let commands = BatchCommands(blocking: "alpha")
    defer { commands.finish.signal() }
    let inventory = fixture.inventory()
    let device = InstallationFixtures.device
    await inventory.refresh(for: device)
    let store = fixture.store(downloads: downloads, commands: commands, inventory: inventory)
    store.updateAll(in: fixture.catalog, installedApps: inventory, on: device)
    try await downloads.waitForCount(1)
    await downloads.finish(0)
    try await InstallationFixtures.eventually { commands.installs.count == 1 }
    store.cancelOperations(deviceID: device.id)
    try InstallationFixtures.require(
      store.phase(appID: "alpha", deviceID: device.id) == .installing
        && store.updateBatch(deviceID: device.id)?.isStopping == true,
      "Stopping device operations must leave the in-flight install alone and stop its queue.")
    commands.finish.signal()
    try await finished(store, device.id)
    try InstallationFixtures.require(
      store.updateBatch(deviceID: device.id)?.updated == 1
        && store.updateBatch(deviceID: device.id)?.canceled == 1,
      "Keep a completed installation and cancel only the pending update.")
    try InstallationFixtures.require(
      await downloads.count == 1, "Do not download the next app after stopping device operations.")
  }

  private static func separateDevices() async throws {
    let fixture = try BatchFixture(ids: ["alpha", "bravo"])
    defer { fixture.remove() }
    let downloads = BatchDownloads(data: fixture.data)
    let commands = BatchCommands()
    let inventory = fixture.inventory()
    let a = InstallationFixtures.device
    let b = SimulatorDevice(id: "device-B", name: "iPad", runtime: a.runtime, state: .booted)
    await inventory.refresh(for: a)
    let store = fixture.store(downloads: downloads, commands: commands, inventory: inventory)
    store.updateAll(in: fixture.catalog, installedApps: inventory, on: a)
    try await downloads.waitForCount(1)
    await inventory.refresh(for: b)
    store.updateAll(in: fixture.catalog, installedApps: inventory, on: b)
    try await downloads.waitForCount(2)
    await downloads.finish(1)
    try await downloads.waitForCount(3)
    await downloads.finish(2)
    try await finished(store, b.id)
    try InstallationFixtures.require(
      store.updateBatch(deviceID: a.id)?.isRunning == true,
      "Different simulators keep independent batches.")
    for app in fixture.apps {
      inventory.recordReplacement(
        SimulatorApplication(bundleID: app.bundleID, version: "9.0.0", isUserApplication: true),
        deviceID: b.id)
    }
    await downloads.finish(0)
    try await downloads.waitForCount(4)
    await downloads.finish(3)
    try await finished(store, a.id)
    try InstallationFixtures.require(
      commands.installs.map(\.deviceID) == [b.id, b.id, a.id, a.id],
      "Switching devices cannot retarget an active or queued update.")
    try InstallationFixtures.require(
      inventory.deviceID == b.id
        && inventory.applications?.allSatisfy { $0.version == "9.0.0" } == true,
      "Background completion must not overwrite the selected device's inventory.")
    try fixture.requireClean()
  }

  private static func shutdownWhileDownloading() async throws {
    let fixture = try BatchFixture(ids: ["alpha", "bravo", "manual"])
    defer { fixture.remove() }
    let downloads = BatchDownloads(data: fixture.data)
    let commands = BatchCommands()
    let inventory = fixture.inventory()
    let power = BatchSimulator()
    let simulators = SimulatorStore(
      discover: {
        SimulatorDiscovery(
          developerDirectory: URL(fileURLWithPath: "/Xcode.app/Contents/Developer"),
          devices: [await power.device])
      }, shutdown: { try await power.shutdown($0) }, boot: { _ in })
    await simulators.refresh()
    let device = simulators.selectedDevice!
    await inventory.refresh(for: device)
    let store = fixture.store(downloads: downloads, commands: commands, inventory: inventory)
    let catalog = AppCatalog(schemaVersion: 1, apps: Array(fixture.apps.prefix(2)))
    store.updateAll(in: catalog, installedApps: inventory, on: device)
    try await downloads.waitForCount(1)
    let manual = fixture.apps[2]
    store.install(app: manual, version: manual.latestVersion, on: device)
    try await downloads.waitForCount(2)
    let other = SimulatorDevice(
      id: "device-B", name: "iPhone B", runtime: device.runtime, state: .booted)
    store.install(app: manual, version: manual.latestVersion, on: other)
    try await downloads.waitForCount(3)

    guard let shutdown = simulators.shutdownDevice(device.id) else {
      throw InstallationFixtures.failure("Accept shutdown during app downloads.")
    }
    store.cancelOperations(deviceID: device.id)
    try InstallationFixtures.require(
      store.phase(appID: "alpha", deviceID: device.id) == .canceling
        && store.phase(appID: "bravo", deviceID: device.id) == nil
        && store.phase(appID: "manual", deviceID: device.id) == .canceling,
      "Cancel both batch and manual downloads and release queued apps immediately.")
    try InstallationFixtures.require(
      await shutdown.value && simulators.selectedDevice?.state == .shutdown,
      "Shutdown must complete before canceled downloads finish cleaning up.")
    try InstallationFixtures.require(
      store.phase(appID: "manual", deviceID: other.id) == .downloading(0),
      "Shutting down one simulator cannot cancel another simulator's downloads.")
    await downloads.finish(0)
    await downloads.finish(1)
    try await finished(store, device.id)
    try await InstallationFixtures.eventually {
      store.phase(appID: "manual", deviceID: device.id) == nil
    }
    try InstallationFixtures.require(
      await downloads.count == 3 && commands.installs.isEmpty
        && store.updateBatch(deviceID: device.id)?.canceled == 2,
      "A confirmed shutdown cannot download the next queued app or install canceled packages.")

    await downloads.finish(2)
    try await InstallationFixtures.eventually {
      store.phase(appID: "manual", deviceID: other.id) == nil
    }
    try InstallationFixtures.require(
      commands.installs.count == 1 && commands.installs.first?.deviceID == other.id,
      "The other simulator's installation must finish normally.")
    try fixture.requireClean()
  }

  private static func observableBatchLifecycle() async throws {
    let fixture = try BatchFixture(ids: ["alpha", "bravo"])
    defer { fixture.remove() }
    let downloads = BatchDownloads(data: fixture.data)
    let commands = BatchCommands()
    let inventory = fixture.inventory()
    let device = InstallationFixtures.device
    await inventory.refresh(for: device)
    let store = fixture.store(downloads: downloads, commands: commands, inventory: inventory)
    let appeared = DispatchSemaphore(value: 0)
    withObservationTracking {
      _ = store.updateBatch(deviceID: device.id)
    } onChange: {
      appeared.signal()
    }
    store.updateAll(in: fixture.catalog, installedApps: inventory, on: device)
    try InstallationFixtures.require(
      notified(appeared), "Observing the installation store must reveal a new batch.")
    try await downloads.waitForCount(1)
    let id = store.updateBatch(deviceID: device.id)?.id
    store.dismissUpdateBatch(deviceID: device.id)
    try InstallationFixtures.require(
      store.updateBatch(deviceID: device.id)?.id == id, "Do not dismiss a running batch.")
    let progressed = DispatchSemaphore(value: 0)
    withObservationTracking {
      _ = store.updateBatch(deviceID: device.id)?.completed
    } onChange: {
      progressed.signal()
    }
    await downloads.finish(0)
    try await downloads.waitForCount(2)
    try InstallationFixtures.require(
      notified(progressed) && store.updateBatch(deviceID: device.id)?.updated == 1,
      "Batch progress must remain observable through the installation store.")
    let completed = DispatchSemaphore(value: 0)
    withObservationTracking {
      _ = store.activeUpdateVersion(appID: "bravo", deviceID: device.id)
    } onChange: {
      completed.signal()
    }
    await downloads.finish(1)
    try await finished(store, device.id)
    try InstallationFixtures.require(
      notified(completed) && store.activeUpdateVersion(appID: "bravo", deviceID: device.id) == nil,
      "An observed version must be released when the queue finishes.")
    let dismissed = DispatchSemaphore(value: 0)
    withObservationTracking {
      _ = store.updateBatch(deviceID: device.id)
    } onChange: {
      dismissed.signal()
    }
    store.dismissUpdateBatch(deviceID: device.id)
    try InstallationFixtures.require(
      notified(dismissed) && store.updateBatch(deviceID: device.id) == nil,
      "Dismissing completed results must update observers.")
    try fixture.requireClean()
  }

  private static func refusedInstallationsReleaseReservations() async throws {
    let queue = AppUpdateQueue()
    let items = ["alpha", "bravo"].map {
      let version = InstallationFixtures.version()
      return AppUpdateBatch.Item(
        app: BatchFixture.app(id: $0, versions: [version]), version: version)
    }
    var reserved: Set<String> = []
    var attempted: [String] = []
    queue.start(
      items: items, deviceID: "device-A", reserve: { reserved.insert($0.id) },
      install: { item, _ in
        attempted.append(item.id)
        return nil
      },
      release: { reserved.remove($0.id) })
    try InstallationFixtures.require(
      reserved == ["alpha", "bravo"], "Reserve every member before starting the queue.")
    try await InstallationFixtures.eventually {
      queue.batch(deviceID: "device-A")?.isRunning == false
    }
    try InstallationFixtures.require(
      reserved.isEmpty && attempted == ["alpha", "bravo"]
        && queue.batch(deviceID: "device-A")?.canceled == 2,
      "Refused installations must release their reservations and allow the queue to finish.")
  }

  nonisolated private static func notified(_ signal: DispatchSemaphore) -> Bool {
    signal.wait(timeout: .now()) == .success
  }

  private static func finished(_ store: AppInstallationStore, _ deviceID: String) async throws {
    try await InstallationFixtures.eventually {
      store.updateBatch(deviceID: deviceID)?.isRunning == false
    }
  }
}

private actor BatchSimulator {
  private var state = SimulatorState.booted

  var device: SimulatorDevice {
    SimulatorDevice(id: "device-A", name: "iPhone", runtime: "27.0", state: state)
  }

  func shutdown(_ id: String) throws {
    try InstallationFixtures.require(id == "device-A", "Shut down only the selected simulator.")
    state = .shutdown
  }
}

private struct BatchFixture: Sendable {
  let directory: URL
  let apps: [CatalogApp]
  let data: [String: Data]
  var catalog: AppCatalog { AppCatalog(schemaVersion: 1, apps: apps) }

  init(ids: [String]) throws {
    directory = try InstallationFixtures.temporaryDirectory()
    var apps: [CatalogApp] = []
    var data: [String: Data] = [:]
    for id in ids {
      let entries = [
        InstallationFixtures.Entry(path: "Example.app/", type: 53, mode: 0o755),
        InstallationFixtures.Entry(
          path: "Example.app/Info.plist",
          data: try InstallationFixtures.info(bundleID: "org.example.Bulk.\(id)")),
        InstallationFixtures.Entry(
          path: "Example.app/Example", data: InstallationFixtures.machO(), mode: 0o755),
      ]
      let bytes = try Data(contentsOf: InstallationFixtures.archive(entries, in: directory))
      apps.append(Self.app(id: id, versions: [InstallationFixtures.version(data: bytes)]))
      data[id] = bytes
    }
    self.apps = apps
    self.data = data
  }

  static func app(id: String, versions: [CatalogVersion]) -> CatalogApp {
    CatalogApp(
      id: id, name: id, bundleID: "org.example.Bulk.\(id)",
      repository: URL(string: "https://example.com/\(id)")!, license: "MIT",
      description: ["en": "An app."], categories: ["utilities"], versions: versions)
  }

  @MainActor
  func inventory() -> InstalledAppsStore {
    InstalledAppsStore(load: { _ in
      apps.map {
        SimulatorApplication(bundleID: $0.bundleID, version: "0.9.0", isUserApplication: true)
      }
    })
  }

  @MainActor
  func store(downloads: BatchDownloads, commands: BatchCommands, inventory: InstalledAppsStore)
    -> AppInstallationStore
  {
    AppInstallationStore(
      installer: AppInstaller(
        download: { try await downloads.fetch($0, $1, $2) }, command: commands.run,
        temporaryDirectory: directory.appending(component: "work")), showDevice: { _ in },
      didReplace: { inventory.recordReplacement($0, deviceID: $1) })
  }

  func requireClean() throws {
    try InstallationFixtures.require(
      try FileManager.default.contentsOfDirectory(
        atPath: directory.appending(component: "work").path
      ).isEmpty,
      "Clean every batch member's temporary data.")
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor BatchDownloads {
  let data: [String: Data]
  let blocked: Bool
  private var failures: Set<String>
  private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
  private(set) var urls: [URL] = []
  var count: Int { urls.count }
  var appIDs: [String] {
    urls.map { $0.lastPathComponent.replacingOccurrences(of: ".app.tar.bz2", with: "") }
  }

  init(data: [String: Data], blocked: Bool = true, failures: Set<String> = []) {
    self.data = data
    self.blocked = blocked
    self.failures = failures
  }

  func fetch(_ url: URL, _ destination: URL, _ progress: @escaping AppDownload.Progress)
    async throws
  {
    let index = count
    urls.append(url)
    let id = appIDs[index]
    if failures.contains(id) { throw InstallationFixtures.failure("Download failed: \(id)") }
    if blocked { await withCheckedContinuation { pending[index] = $0 } }
    try Task.checkCancellation()
    guard let bytes = data[id] else {
      throw InstallationFixtures.failure("Unexpected download: \(url)")
    }
    progress(Int64(bytes.count))
    try bytes.write(to: destination)
  }

  func clearFailures() { failures = [] }
  func finish(_ index: Int) { pending.removeValue(forKey: index)?.resume() }

  func waitForCount(_ expected: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while count < expected {
      guard ContinuousClock.now < deadline else {
        throw InstallationFixtures.failure("A queued update did not start.")
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}

private final class BatchCommands: @unchecked Sendable {
  struct Install {
    let appID: String
    let deviceID: String
  }
  let finish = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private let blocking: String?
  private var failures: Set<String>
  private var recorded: [Install] = []
  var installs: [Install] { lock.withLock { recorded } }

  init(failures: Set<String> = [], blocking: String? = nil) {
    self.failures = failures
    self.blocking = blocking
  }

  func clearFailures() { lock.withLock { failures = [] } }

  func run(_ executable: String, _ arguments: [String]) throws -> Data {
    try InstallationFixtures.require(!Thread.isMainThread, "Batch commands must not block the UI.")
    if executable == "/usr/bin/tar" { return try Command.run(executable, arguments: arguments) }
    try InstallationFixtures.require(
      executable == "/usr/bin/xcrun" && arguments.prefix(2) == ["simctl", "install"],
      "Update through simctl install without uninstalling or erasing app data.")
    let info =
      try PropertyListSerialization.propertyList(
        from: Data(
          contentsOf: URL(fileURLWithPath: arguments[3]).appending(component: "Info.plist")),
        format: nil) as! [String: Any]
    let id = (info["CFBundleIdentifier"] as! String).split(separator: ".").last.map(String.init)!
    lock.withLock { recorded.append(Install(appID: id, deviceID: arguments[2])) }
    if blocking == id {
      try InstallationFixtures.require(
        finish.wait(timeout: .now() + 5) == .success, "Release the blocked batch installation.")
    }
    if lock.withLock({ failures.contains(id) }) {
      throw InstallationFixtures.failure("Install failed: \(id)")
    }
    return Data()
  }
}
