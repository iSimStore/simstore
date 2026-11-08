import Foundation

@main
@MainActor
struct InstalledAppsStoreTests {
  @MainActor
  static func main() async {
    await TestSuite.run(cases)
  }

  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("filteringAndRefresh", filteringAndRefresh),
      .init("switchingDevices", switchingDevices),
      .init("staleErrors", staleErrors),
      .init("cancellationAndCoalescing", cancellationAndCoalescing),
      .init("refreshedDeviceState", refreshedDeviceState),
      .init("recordingInstallationDuringRefresh", recordingInstallationDuringRefresh),
      .init("retainInstalledAppsForCurrentVisit", retainInstalledAppsForCurrentVisit),
      .init("installedVersionsAndMatching", installedVersionsAndMatching),
      .init("recordingUninstallationDuringRefresh", recordingUninstallationDuringRefresh),
      .init("updateFilteringAndRetention", updateFilteringAndRetention),
      .init("recoveryDuringRefresh", recoveryDuringRefresh),
    ]
  }

  static func recoveryDuringRefresh() async throws {
    let probe = InventoryProbe()
    let monitor = SimulatorOperationMonitor(wait: {})
    let store = InstalledAppsStore(
      load: { try await probe.load($0) }, operationMonitor: monitor)
    let selected = device("A")
    let refresh = Task { await store.refresh(for: selected) }
    try await eventually { await probe.calls.count == 1 }
    try await eventually { monitor.prompt?.device.id == selected.id }
    await probe.finish(0, with: .success(["io.example.Installed"]))
    await refresh.value
    try require(
      monitor.prompt == nil && !store.isLoading && store.bundleIDs == ["io.example.Installed"],
      "A recovered app-list query must clear its prompt and publish the real inventory.")
  }

  static func filteringAndRefresh() async throws {
    let probe = InventoryProbe()
    let store = InstalledAppsStore(load: { try await probe.load($0) })
    let selected = device("A")
    let catalog = catalog()
    try require(store.discoverableApps(in: catalog, for: "A") == nil, "Unknown is not uninstalled.")
    let initial = Task { await store.refresh(for: selected) }
    try await eventually { await probe.calls.count == 1 }
    try require(
      store.deviceID == "A" && store.bundleIDs == nil && store.isLoading,
      "A pending query must not expose an empty installation set.")
    try require(!store.canInstall(on: selected), "Wait for the first confirmed inventory.")
    await probe.finish(0, with: .success(["io.example.Installed", "io.example.UNKNOWN"]))
    await initial.value
    try require(
      store.discoverableApps(in: catalog, for: "A")?.map(\.id) == ["available"],
      "Exclude installed apps by their case-insensitive Bundle ID, regardless of version.")
    try require(
      store.discoverableApps(in: catalog, for: "B") == nil,
      "A snapshot may only filter its own simulator.")
    let previous = store.applications
    try require(store.canInstall(on: selected), "A successful inventory enables installations.")
    let failed = Task { await store.refresh(for: selected) }
    try await eventually { await probe.calls.count == 2 }
    try require(
      store.applications == previous && store.isLoading
        && store.discoverableApps(in: catalog, for: "A")?.map(\.id) == ["available"],
      "Keep the current collection visible while refreshing the same simulator.")
    try require(
      !store.canInstall(on: selected), "A retained inventory is only for display during refresh.")
    await probe.finish(1, with: .failure(failure("Cannot read installed apps")))
    await failed.value
    try require(
      store.error == "Cannot read installed apps" && !store.isLoading && store.bundleIDs == nil,
      "A failed query must report an error without claiming no apps are installed.")
    let retry = Task { await store.refresh(for: selected) }
    try await eventually { await probe.calls.count == 3 }
    await probe.finish(2, with: .success([]))
    await retry.value
    try require(
      store.error == nil && store.bundleIDs == []
        && store.discoverableApps(in: catalog, for: "A")?.count == catalog.apps.count,
      "A confirmed empty installation set exposes the full catalog and clears the prior error.")
    let externalInstall = Task { await store.refresh(for: selected) }
    try await eventually { await probe.calls.count == 4 }
    try require(
      store.bundleIDs == [] && store.isLoading,
      "A confirmed empty collection must remain visible during a background refresh.")
    await probe.finish(3, with: .success(["io.example.Available"]))
    await externalInstall.value
    try require(
      store.discoverableApps(in: catalog, for: "A")?.map(\.id) == ["installed", "case-variant"],
      "A later query must reflect apps installed outside SimStore.")
  }

  static func switchingDevices() async throws {
    let probe = InventoryProbe()
    let store = InstalledAppsStore(load: { try await probe.load($0) })
    let a = Task { await store.refresh(for: device("A")) }
    try await eventually { await probe.calls.count == 1 }
    let b = Task { await store.refresh(for: device("B")) }
    try await eventually { await probe.calls.count == 2 }
    try require(
      store.deviceID == "B" && store.bundleIDs == nil && store.isLoading,
      "Two identically named simulators must keep separate installation inventories.")
    await probe.finish(1, with: .success(["io.example.B"]))
    await b.value
    await probe.finish(0, with: .success(["io.example.A"]))
    await a.value
    try require(
      store.deviceID == "B" && store.bundleIDs == ["io.example.B"] && !store.isLoading,
      "A late response from the previous simulator must not replace the current snapshot.")
    let oldA = Task { await store.refresh(for: device("A")) }
    try await eventually { await probe.calls.count == 3 }
    let newB = Task { await store.refresh(for: device("B")) }
    try await eventually { await probe.calls.count == 4 }
    await probe.finish(2, with: .success(["io.example.Stale"]))
    await oldA.value
    try require(
      store.deviceID == "B" && store.bundleIDs == nil && store.isLoading,
      "Completing an old query must not clear the new simulator's loading state.")
    await probe.finish(3, with: .success(["io.example.New"]))
    await newB.value
  }

  static func staleErrors() async throws {
    let probe = InventoryProbe()
    let store = InstalledAppsStore(load: { try await probe.load($0) })
    let a = Task { await store.refresh(for: device("A")) }
    try await eventually { await probe.calls.count == 1 }
    let b = Task { await store.refresh(for: device("B")) }
    try await eventually { await probe.calls.count == 2 }
    await probe.finish(1, with: .success(["io.example.B"]))
    await b.value
    await probe.finish(0, with: .failure(failure("Old simulator failed")))
    await a.value
    try require(
      store.error == nil && store.bundleIDs == ["io.example.B"],
      "A stale simulator's error must not hide the current simulator's valid inventory.")
  }

  static func cancellationAndCoalescing() async throws {
    let probe = InventoryProbe()
    let store = InstalledAppsStore(load: { try await probe.load($0) })
    let selected = device("A")
    let first = Task { await store.refresh(for: selected) }
    try await eventually { await probe.calls.count == 1 }
    var joined = false
    let second = Task {
      joined = true
      await store.refresh(for: selected)
    }
    try await eventually { joined }
    try require(await probe.calls.count == 1, "Coalesce simultaneous queries of the same device.")
    first.cancel()
    await probe.finish(0, with: .success(["io.example.Cancelled"]))
    await first.value
    try await eventually { await probe.calls.count == 2 }
    try require(
      store.isLoading && store.bundleIDs == nil && store.error == nil,
      "An active joining caller must retry after the canceled query without showing a false result."
    )
    await probe.finish(1, with: .success(["io.example.Active"]))
    await second.value
    try require(
      store.bundleIDs == ["io.example.Active"], "The active retry must produce its result.")
    let canceled = Task { await store.refresh(for: selected) }
    try await eventually { await probe.calls.count == 3 }
    canceled.cancel()
    await probe.finish(2, with: .success(["io.example.Cancelled"]))
    await canceled.value
    try require(
      !store.isLoading && store.bundleIDs == ["io.example.Active"] && store.error == nil,
      "A canceled refresh must preserve the last confirmed inventory, without publishing its response."
    )
    try require(
      !store.canInstall(on: selected), "Canceling a refresh cannot revalidate its cached versions.")
    let retry = Task { await store.refresh(for: selected) }
    try await eventually { await probe.calls.count == 4 }
    await probe.finish(3, with: .success([]))
    await retry.value
    try require(store.bundleIDs == [], "A canceled query must not prevent a later retry.")
  }

  static func refreshedDeviceState() async throws {
    let probe = InventoryProbe()
    let store = InstalledAppsStore(load: { try await probe.load($0) })
    let stopped = Task { await store.refresh(for: device("A", state: .shutdown)) }
    try await eventually { await probe.calls.count == 1 }
    let booted = Task { await store.refresh(for: device("A", state: .booted)) }
    try await eventually { await probe.calls.count == 2 }
    await probe.finish(1, with: .success(["io.example.New"]))
    await booted.value
    await probe.finish(0, with: .success(["io.example.Old"]))
    await stopped.value
    try require(
      store.bundleIDs == ["io.example.New"],
      "A device state change must query afresh rather than join an older shutdown query.")
    let shuttingDown = Task { await store.refresh(for: device("A", state: .shuttingDown)) }
    try await eventually { await probe.calls.count == 3 }
    try require(
      store.bundleIDs == nil && store.isLoading,
      "A power-state change must clear the previous running-device inventory.")
    await probe.finish(2, with: .failure(failure("Simulator is shutting down")))
    await shuttingDown.value
  }

  static func device(_ id: String, state: SimulatorState = .booted) -> SimulatorDevice {
    SimulatorDevice(id: id, name: "iPhone 17 Pro", runtime: "27.0", state: state)
  }

  static func recordingInstallationDuringRefresh() async throws {
    let probe = InventoryProbe()
    let store = InstalledAppsStore(load: { try await probe.load($0) })
    let first = Task { await store.refresh(for: device("A")) }
    try await eventually { await probe.calls.count == 1 }
    store.recordInstallation(application("org.example.WrongDevice"), deviceID: "B")
    store.recordInstallation(application("org.example.New"), deviceID: "A")
    try require(
      store.bundleIDs == nil,
      "An installation must not turn an unknown inventory into a complete snapshot.")
    await probe.finish(0, with: .success([]))
    await first.value
    try require(
      store.bundleIDs == ["org.example.New"],
      "Merge successful installs into an older in-flight inventory response.")
    try require(
      store.isInstalled(bundleID: "org.example.NEW", deviceID: "A") == true,
      "Match installed bundle IDs without case sensitivity.")
    let next = Task { await store.refresh(for: device("A")) }
    try await eventually { await probe.calls.count == 2 }
    await probe.finish(1, with: .success([]))
    await next.value
    try require(
      store.bundleIDs == [], "A later authoritative refresh must reflect external uninstalls.")
  }

  nonisolated static func application(_ bundleID: String, version: String? = "0.9.0")
    -> SimulatorApplication
  {
    SimulatorApplication(bundleID: bundleID, version: version, isUserApplication: true)
  }

  static func catalog() -> AppCatalog {
    let version = CatalogVersion(
      version: "1.0.0", minSimulatorOS: "16.0", sha256: String(repeating: "a", count: 64),
      size: 1000, revision: String(repeating: "b", count: 40),
      recipeRevision: String(repeating: "c", count: 40), time: 1_793_544_257)
    let apps = [
      ("installed", "io.example.Installed"), ("available", "io.example.Available"),
      ("case-variant", "io.example.Unknown"),
    ].map { id, bundleID in
      CatalogApp(
        id: id, name: "Example", bundleID: bundleID,
        repository: URL(string: "https://github.com/example/app")!, license: "MIT",
        description: ["en": "An example app."], categories: ["utilities"], versions: [version])
    }
    return AppCatalog(schemaVersion: 1, apps: apps)
  }

  static func retainInstalledAppsForCurrentVisit() async throws {
    let current = catalog()
    let store = InstalledAppsStore(load: { _ in
      [application("io.example.Installed"), application("io.example.Available")]
    })
    await store.refresh(for: device("A"))
    try require(
      store.discoverableApps(in: current, for: "A")?.map(\.id) == ["case-variant"],
      "Hide apps installed before this visit.")
    store.recordInstallation(application("io.example.AVAILABLE"), deviceID: "A")
    try require(
      store.discoverableApps(in: current, for: "A")?.map(\.id) == ["available", "case-variant"],
      "Keep newly installed apps in their original catalog order.")
    try require(
      store.isInstalled(bundleID: "io.example.Available", deviceID: "A") == true,
      "The retained card must offer Open.")
    store.removeRecentInstallation(bundleID: "io.example.Available", deviceID: "B")
    try require(
      store.discoverableApps(in: current, for: "A")?.map(\.id) == ["available", "case-variant"],
      "Opening on another device must not remove this device's card.")
    await store.refresh(for: device("A"))
    try require(
      store.discoverableApps(in: current, for: "A")?.map(\.id) == ["available", "case-variant"],
      "Automatic inventory refresh must retain the current visit.")
    store.removeRecentInstallation(bundleID: "io.example.AVAILABLE", deviceID: "A")
    try require(
      store.discoverableApps(in: current, for: "A")?.map(\.id) == ["case-variant"],
      "Remove a successfully opened app from the current visit.")
    store.recordInstallation(application("io.example.Available"), deviceID: "A")
    store.clearRecentInstallations()
    try require(
      store.discoverableApps(in: current, for: "A")?.map(\.id) == ["case-variant"],
      "Explicit catalog refresh clears retained installations.")
    store.recordInstallation(application("io.example.Available"), deviceID: "A")
    await store.refresh(for: device("B"))
    await store.refresh(for: device("A"))
    try require(
      store.discoverableApps(in: current, for: "A")?.map(\.id) == ["case-variant"],
      "Switching simulators begins a new visit.")
  }

  static func installedVersionsAndMatching() async throws {
    let store = InstalledAppsStore(load: { device in
      [
        application("IO.EXAMPLE.INSTALLED", version: device.id == "A" ? "0.8.2" : "2.0-beta"),
        application("io.example.Unknown", version: nil),
        SimulatorApplication(
          bundleID: "com.apple.mobilesafari", version: "27.0", isUserApplication: false),
        application("org.example.NotInCatalog", version: "4.0"),
      ]
    })
    let current = catalog()
    await store.refresh(for: device("A"))
    try require(
      store.installedApps(in: current, for: "A")?.map(\.id) == ["installed", "case-variant"],
      "Show only matching catalog apps, without unrelated or preinstalled Apple apps.")
    try require(
      store.application(bundleID: "io.example.Installed", deviceID: "A")?.version == "0.8.2",
      "Keep the actual older installed version rather than the catalog's latest version.")
    try require(
      store.application(bundleID: "io.example.Unknown", deviceID: "A")?.version == nil,
      "A missing installed version must remain unknown.")
    try require(
      store.installedApps(in: current, for: "B") == nil
        && store.application(bundleID: "io.example.Installed", deviceID: "B") == nil,
      "Never expose one simulator's installed version as another simulator's version.")
    await store.refresh(for: device("B"))
    try require(
      store.application(bundleID: "io.example.Installed", deviceID: "B")?.version == "2.0-beta",
      "Display arbitrary upstream version strings without forcing catalog version syntax.")
  }

  static func recordingUninstallationDuringRefresh() async throws {
    let probe = InventoryProbe()
    let store = InstalledAppsStore(load: { try await probe.load($0) })
    let pending = Task { await store.refresh(for: device("A")) }
    try await eventually { await probe.calls.count == 1 }
    store.recordUninstallation(bundleID: "IO.EXAMPLE.INSTALLED", deviceID: "A")
    store.recordUninstallation(bundleID: "io.example.Available", deviceID: "B")
    await probe.finish(0, with: .success(["io.example.Installed", "io.example.Available"]))
    await pending.value
    try require(
      store.bundleIDs == ["io.example.Available"],
      "A confirmed uninstall must override an older in-flight inventory response on the same device."
    )
    store.recordInstallation(application("io.example.INSTALLED", version: "1.1.0"), deviceID: "A")
    store.recordUninstallation(bundleID: "io.example.installed", deviceID: "A")
    try require(
      store.discoverableApps(in: catalog(), for: "A")?.map(\.id) == ["installed", "case-variant"],
      "Uninstall removes a retained Open card and makes the app installable in Discover again.")
    let next = Task { await store.refresh(for: device("A")) }
    try await eventually { await probe.calls.count == 2 }
    store.recordUninstallation(bundleID: "io.example.Installed", deviceID: "A")
    store.recordInstallation(application("io.example.Installed", version: "1.2.0"), deviceID: "A")
    await probe.finish(1, with: .success(["io.example.Installed"]))
    await next.value
    try require(
      store.application(bundleID: "io.example.Installed", deviceID: "A")?.version == "1.2.0",
      "The latest completed mutation wins when an app is reinstalled during a refresh.")
  }

  static func updateFilteringAndRetention() async throws {
    let current = catalog()
    let store = InstalledAppsStore(load: { device in
      [
        application("IO.EXAMPLE.INSTALLED", version: device.id == "A" ? "0.8.0" : "2.0.0"),
        application("io.example.Available", version: nil),
        SimulatorApplication(
          bundleID: "io.example.Unknown", version: "0.8.0", isUserApplication: false),
      ]
    })
    try require(
      store.updatableApps(in: current, for: device("A")) == nil,
      "Unknown inventories must not claim no updates.")
    await store.refresh(for: device("A"))
    try require(
      store.updatableApps(in: current, for: device("A"))?.map(\.id) == ["installed"],
      "Offer updates only for matching user apps with comparable older versions.")
    try require(
      store.updatableApps(in: current, for: device("A"), includingRecent: false)?.count == 1,
      "The sidebar count includes pending compatible updates.")
    try require(
      store.updatableApps(in: current, for: device("B")) == nil
        && store.updatableApps(in: current, for: device("A", state: .shutdown)) == nil,
      "Updates belong to a known running device.")
    store.recordReplacement(application("io.example.INSTALLED", version: "1.0.0"), deviceID: "A")
    try require(
      store.updatableApps(in: current, for: device("A"))?.map(\.id) == ["installed"],
      "Retain a completed update for Open in the current visit.")
    try require(
      store.updatableApps(in: current, for: device("A"), includingRecent: false)?.isEmpty == true,
      "A completed update retained for Open must not inflate the sidebar count.")
    try require(
      store.discoverableApps(in: current, for: "A")?.isEmpty == true,
      "Updating an existing app must not expose it as newly installed in Discover.")
    store.removeRecentInstallation(bundleID: "io.example.installed", deviceID: "B")
    try require(
      store.updatableApps(in: current, for: device("A"))?.count == 1,
      "Another device's Open must not remove this card.")
    store.removeRecentInstallation(bundleID: "io.example.installed", deviceID: "A")
    try require(
      store.updatableApps(in: current, for: device("A"))?.isEmpty == true,
      "A successful Open removes a completed update.")
    store.recordReplacement(application("io.example.Installed", version: "1.0.0"), deviceID: "A")
    store.clearRecentInstallations()
    try require(
      store.updatableApps(in: current, for: device("A"))?.isEmpty == true,
      "Explicit refresh or navigation ends retained updates.")
    store.recordReplacement(application("io.example.Installed", version: "2.0.0"), deviceID: "A")
    try require(
      store.updatableApps(in: current, for: device("A"))?.isEmpty == true,
      "A newer installed version must not create a downgrade card.")
    await store.refresh(for: device("B"))
    try require(
      store.updatableApps(in: current, for: device("B"))?.isEmpty == true,
      "A device with a newer app has no update.")

    let probe = InventoryProbe()
    let pendingStore = InstalledAppsStore(load: { try await probe.load($0) })
    let pending = Task { await pendingStore.refresh(for: device("A")) }
    try await eventually { await probe.calls.count == 1 }
    pendingStore.recordReplacement(
      application("io.example.Installed", version: "1.0.0"), deviceID: "A")
    await probe.finish(0, with: .success(["io.example.Installed"]))
    await pending.value
    try require(
      pendingStore.application(bundleID: "io.example.Installed", deviceID: "A")?.version == "1.0.0",
      "An older query cannot roll back the version from a completed update.")
  }

  static func eventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw failure("An async operation timed out.") }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  static func failure(_ message: String) -> NSError {
    NSError(
      domain: "InstalledAppsStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

private actor InventoryProbe {
  private(set) var calls: [SimulatorDevice] = []
  private var pending: [Int: CheckedContinuation<[SimulatorApplication], Error>] = [:]

  func load(_ device: SimulatorDevice) async throws -> [SimulatorApplication] {
    let index = calls.count
    calls.append(device)
    return try await withCheckedThrowingContinuation { pending[index] = $0 }
  }

  func finish(_ index: Int, with result: Result<Set<String>, Error>) {
    pending.removeValue(forKey: index)?.resume(
      with: result.map {
        $0.map { SimulatorApplication(bundleID: $0, version: "0.9.0", isUserApplication: true) }
      })
  }
}
