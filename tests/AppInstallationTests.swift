import Foundation

@main
@MainActor
struct AppInstallationTests {
  static func main() async {
    do {
      try AppPackageTests.run()
      try await AppDownloadTests.run()
      try await pipeline()
      try await preparationStopsBeforeFinalization()
      try await failureAndCleanup()
      try await perDeviceJobs()
      try await presentationFailures()
      try await cancellationDuringPreparation()
      try await installingCannotBeCanceled()
      try await stoppedDevice()
      try await uninstallJobs()
      try await uninstallFailure()
      try await recoveryPrompts()
      try await discoveryFailureDuringUninstall()
      try versionActions()
      try await replacementPipeline()
      try await replacementWhileSwitchingDevices()
      try await AppUpdateBatchTests.run()
      try await updateDuringInventoryRefresh()
      try await AppInstallButtonTests.run()
      print(
        "PASS: package verification, safe extraction, Simulator binaries, install/open, per-device jobs, cancellation, failures, and cleanup."
      )
    } catch {
      FileHandle.standardError.write(
        Data("Installation test failed: \(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  static func pipeline() async throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try archiveData(in: directory)
    let work = directory.appending(component: "work")
    let commands = InstallationCommands()
    let installer = AppInstaller(
      download: { url, destination, progress in
        try InstallationFixtures.require(
          url
            == AppConfiguration.assetURL(
              appID: "example", version: "1.0.0", filename: "example.app.tar.bz2"),
          "Download the selected version's stable release asset.")
        try data.write(to: destination)
        for step in 1...10_000 { progress(Int64(step) * Int64(data.count) / 10_000) }
      }, command: commands.run, temporaryDirectory: work)
    let version = InstallationFixtures.version(data: data)
    var phases: [AppInstallationPhase] = []
    try await installer.install(
      app: InstallationFixtures.app(version: version), version: version,
      on: InstallationFixtures.device
    ) {
      phases.append($0)
    }
    try InstallationFixtures.require(
      phases.contains(.verifying) && phases.contains(.extracting) && phases.contains(.installing),
      "Report preparation and installation stages.")
    let downloads = phases.prefix {
      if case .downloading = $0 { return true }
      return false
    }
    try InstallationFixtures.require(
      downloads.count <= 10 && downloads.last == .downloading(Int64(data.count))
        && phases.dropFirst(downloads.count).allSatisfy {
          if case .downloading = $0 { return false }
          return true
        },
      "Coalesce bursty download progress and deliver the final byte count before verification.")
    let installed = commands.calls.filter { $0.first == "simctl" }
    try InstallationFixtures.require(
      installed.count == 1 && installed[0].prefix(3) == ["simctl", "install", "device-A"],
      "Install once on the exact target device.")
    try InstallationFixtures.require(
      try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty,
      "Remove the archive and extracted app after installation.")
    try await installer.open(app: InstallationFixtures.app(), on: InstallationFixtures.device)
    try InstallationFixtures.require(
      commands.calls.last == ["simctl", "launch", "device-A", "org.example.App"],
      "Open the installed app on its target device.")
  }

  static func preparationStopsBeforeFinalization() async throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try archiveData(in: directory)
    let version = InstallationFixtures.version(data: data)
    let expected = InstallationFixtures.failure("Bundle validation failed")
    for cancelled in [false, true] {
      let work = directory.appending(component: cancelled ? "canceled" : "rejected")
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let handoff = work.appending(component: "handoff")
      let pipeline = PackagePipeline(
        size: version.size, sha256: version.sha256,
        download: { _, destination, _ in try data.write(to: destination) })
      do {
        _ = try await pipeline.prepare(
          from: URL(string: "https://example.com/archive")!,
          archive: work.appending(component: "archive.tar.bz2"),
          extractingTo: work.appending(component: "contents"), progress: { _ in },
          validate: { bundle in
            try AppPackage.validate(bundle, app: InstallationFixtures.app(), version: version)
            if cancelled {
              withUnsafeCurrentTask { $0?.cancel() }
            } else {
              throw expected
            }
          },
          afterValidation: { try Data().write(to: handoff) })
        throw InstallationFixtures.failure("Rejected or canceled preparation must fail.")
      } catch is CancellationError {
        try InstallationFixtures.require(cancelled, "Preserve validation failures.")
      } catch {
        try InstallationFixtures.require(
          !cancelled && error as NSError == expected, "Preserve the validation error unchanged.")
      }
      try InstallationFixtures.require(
        !FileManager.default.fileExists(atPath: handoff.path),
        "Failed or canceled bundle validation must not finalize a package for handoff.")
    }
  }

  static func failureAndCleanup() async throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try archiveData(in: directory)
    let work = directory.appending(component: "work")
    for mode in 0..<4 {
      let commands = InstallationCommands(failsInstallation: mode == 3)
      let installer = AppInstaller(
        download: { _, destination, _ in
          if mode == 0 { throw InstallationFixtures.failure("Download failed") }
          var bytes = data
          if mode == 1 { bytes.removeLast() }
          if mode == 2 { bytes[bytes.count - 1] ^= 0xFF }
          try bytes.write(to: destination)
        }, command: commands.run, temporaryDirectory: work)
      do {
        try await installer.install(
          app: InstallationFixtures.app(), version: InstallationFixtures.version(data: data),
          on: InstallationFixtures.device
        ) { _ in }
        throw InstallationFixtures.failure(
          "A failed download, verification, or install must fail the pipeline.")
      } catch {
        if mode < 3 {
          try InstallationFixtures.require(
            commands.calls.isEmpty, "Unverified data must not be extracted or installed.")
        } else {
          try InstallationFixtures.require(
            error.localizedDescription == "Install failed", "Preserve simctl failure diagnostics.")
        }
      }
      try InstallationFixtures.require(
        try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty,
        "Clean temporary files on every failure path.")
    }
  }

  static func perDeviceJobs() async throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try archiveData(in: directory)
    let gate = InstallationDownloadGate(data: data)
    let commands = InstallationCommands()
    let inventory = InstalledAppsStore(load: { _ in [] })
    await inventory.refresh(for: InstallationFixtures.device)
    var shownDevices: [SimulatorDevice] = []
    var openedDevices: [String] = []
    let store = AppInstallationStore(
      installer: AppInstaller(
        download: { try await gate.download($0, $1, $2) }, command: commands.run,
        temporaryDirectory: directory.appending(component: "work")),
      showDevice: { device in
        try InstallationFixtures.require(
          commands.calls.last == ["simctl", "launch", device.id, "org.example.App"],
          "Present the target device only after its app has launched.")
        shownDevices.append(device)
      },
      didInstall: { inventory.recordInstallation($0, deviceID: $1) },
      didOpen: { _, deviceID in openedDevices.append(deviceID) })
    let version = InstallationFixtures.version(data: data)
    let app = InstallationFixtures.app(version: version)
    let a = InstallationFixtures.device
    let b = SimulatorDevice(id: "device-B", name: a.name, runtime: a.runtime, state: a.state)
    store.install(app: app, version: version, on: a)
    try await gate.waitForCount(1)
    store.install(app: app, version: version, on: a)
    store.install(app: app, version: version, on: b)
    try await gate.waitForCount(2)
    try InstallationFixtures.require(
      await gate.count == 2, "Do not duplicate a job for the same app and device.")
    await gate.report(0, bytes: 100)
    await gate.report(0, bytes: 50)
    try await InstallationFixtures.eventually {
      store.phase(appID: app.id, deviceID: a.id) == .downloading(100)
    }
    await gate.finish(1)
    try await InstallationFixtures.eventually { store.phase(appID: app.id, deviceID: b.id) == nil }
    try InstallationFixtures.require(
      inventory.bundleIDs == [],
      "Installing on another simulator must not alter the selected inventory.")
    store.cancel(appID: app.id, deviceID: a.id)
    try InstallationFixtures.require(
      store.phase(appID: app.id, deviceID: a.id) == .canceling,
      "Keep a canceled operation visible until its cleanup finishes.")
    await gate.finish(0)
    try await InstallationFixtures.eventually { store.phase(appID: app.id, deviceID: a.id) == nil }
    try InstallationFixtures.require(
      store.error(appID: app.id, deviceID: a.id) == nil,
      "Cancellation is not an installation error.")
    store.install(app: app, version: version, on: a)
    try await gate.waitForCount(3)
    await gate.report(0, bytes: 999)
    try await Task.sleep(for: .milliseconds(10))
    try InstallationFixtures.require(
      store.phase(appID: app.id, deviceID: a.id) == .downloading(0),
      "Ignore late progress from an earlier attempt.")
    await gate.finish(2)
    try await InstallationFixtures.eventually { store.phase(appID: app.id, deviceID: a.id) == nil }
    try InstallationFixtures.require(
      inventory.isInstalled(bundleID: app.bundleID, deviceID: a.id) == true,
      "A successful install updates the selected inventory immediately.")
    try InstallationFixtures.require(
      inventory.application(bundleID: app.bundleID, deviceID: a.id)?.version == version.version,
      "Publish the version that was actually installed.")
    let installedDevices = commands.calls.filter { $0.prefix(2) == ["simctl", "install"] }.map {
      $0[2]
    }
    try InstallationFixtures.require(
      installedDevices == [b.id, a.id],
      "Cancellation and simulator changes must not retarget an operation.")
    store.open(app: app, on: b)
    try await InstallationFixtures.eventually { store.phase(appID: app.id, deviceID: b.id) == nil }
    try InstallationFixtures.require(
      commands.calls.last == ["simctl", "launch", b.id, app.bundleID],
      "Launch on the requested device.")
    try InstallationFixtures.require(shownDevices == [b], "Present the original launch target.")
    try InstallationFixtures.require(
      openedDevices == [b.id] && store.openedApp == .init(appID: app.id, deviceID: b.id),
      "Publish a successful open only after presenting its target.")
  }

  static func presentationFailures() async throws {
    for launchFails in [true, false] {
      let commands = InstallationCommands(failsLaunch: launchFails)
      var didShow = false
      var didOpen = false
      let store = AppInstallationStore(
        installer: AppInstaller(command: commands.run),
        showDevice: { _ in
          didShow = true
          throw InstallationFixtures.failure("Presentation failed")
        }, didOpen: { _, _ in didOpen = true })
      let app = InstallationFixtures.app()
      let device = InstallationFixtures.device
      store.open(app: app, on: device)
      try await InstallationFixtures.eventually {
        store.phase(appID: app.id, deviceID: device.id) == nil
      }
      try InstallationFixtures.require(
        didShow != launchFails, "Do not change apps after a failed launch.")
      try InstallationFixtures.require(
        !didOpen && store.openedApp == nil,
        "A failed launch or presentation must preserve the card and details for retry.")
      try InstallationFixtures.require(
        store.error(appID: app.id, deviceID: device.id)
          == (launchFails ? "Launch failed" : "Presentation failed"),
        "Preserve launch and presentation failures and permit retry.")
    }
  }

  static func cancellationDuringPreparation() async throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try archiveData(in: directory)
    let commands = InstallationCommands(blocksExtraction: true)
    let work = directory.appending(component: "work")
    let store = AppInstallationStore(
      installer: AppInstaller(
        download: { _, destination, _ in
          try data.write(to: destination)
        }, command: commands.run, temporaryDirectory: work), showDevice: { _ in })
    let app = InstallationFixtures.app()
    let device = InstallationFixtures.device
    store.install(app: app, version: InstallationFixtures.version(data: data), on: device)
    try InstallationFixtures.require(
      await Task.detached { commands.waitForStart() }.value,
      "Start preparation before canceling.")
    store.cancel(appID: app.id, deviceID: device.id)
    commands.finish.signal()
    try await InstallationFixtures.eventually {
      store.phase(appID: app.id, deviceID: device.id) == nil
    }
    try InstallationFixtures.require(
      !commands.calls.contains { $0.first == "simctl" },
      "A canceled preparation must not install anything.")
    try InstallationFixtures.require(
      try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty,
      "Remove canceled preparation files.")
  }

  static func installingCannotBeCanceled() async throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try archiveData(in: directory)
    let commands = InstallationCommands(blocksInstallation: true)
    var installed = false
    let store = AppInstallationStore(
      installer: AppInstaller(
        download: { _, destination, _ in
          try data.write(to: destination)
        }, command: commands.run, temporaryDirectory: directory.appending(component: "work")),
      showDevice: { _ in },
      didInstall: { _, _ in installed = true })
    let app = InstallationFixtures.app()
    let device = InstallationFixtures.device
    store.install(app: app, version: InstallationFixtures.version(data: data), on: device)
    try InstallationFixtures.require(
      await Task.detached { commands.waitForStart() }.value,
      "Wait until simctl starts installing.")
    store.cancel(appID: app.id, deviceID: device.id)
    try InstallationFixtures.require(
      store.phase(appID: app.id, deviceID: device.id) == .installing,
      "Once simctl starts, allow installation to finish.")
    commands.finish.signal()
    try await InstallationFixtures.eventually {
      store.phase(appID: app.id, deviceID: device.id) == nil
    }
    try InstallationFixtures.require(
      installed, "Record a confirmed installation even after a late cancellation request.")
  }

  static func stoppedDevice() async throws {
    let stopped = SimulatorDevice(id: "stopped", name: "iPhone", runtime: "27.0", state: .shutdown)
    let commands = InstallationCommands()
    let store = AppInstallationStore(
      installer: AppInstaller(
        download: { _, _, _ in throw InstallationFixtures.failure("Unexpected download") },
        command: commands.run), showDevice: { _ in })
    let app = InstallationFixtures.app()
    store.install(app: app, version: app.latestVersion, on: stopped)
    try await InstallationFixtures.eventually {
      store.phase(appID: app.id, deviceID: stopped.id) == nil
    }
    try InstallationFixtures.require(
      store.error(appID: app.id, deviceID: stopped.id)
        == SimulatorApplicationsError.notRunning.localizedDescription && commands.calls.isEmpty,
      "A stopped simulator must fail before downloading or running simctl.")
    store.open(app: app, on: stopped)
    try await InstallationFixtures.eventually {
      store.phase(appID: app.id, deviceID: stopped.id) == nil
    }
    try InstallationFixtures.require(
      store.error(appID: app.id, deviceID: stopped.id) != nil && commands.calls.isEmpty,
      "Report launch failures without claiming success.")
  }

  static func uninstallJobs() async throws {
    let commands = InstallationCommands(blocksUninstallation: true)
    let app = InstallationFixtures.app()
    let device = InstallationFixtures.device
    let inventory = InstalledAppsStore(load: { _ in
      [SimulatorApplication(bundleID: app.bundleID, version: "0.9.0", isUserApplication: true)]
    })
    await inventory.refresh(for: device)
    let store = AppInstallationStore(
      installer: AppInstaller(command: commands.run), showDevice: { _ in },
      didUninstall: { inventory.recordUninstallation(bundleID: $0, deviceID: $1) })
    store.uninstall(app: app, on: device)
    try InstallationFixtures.require(
      await Task.detached { commands.waitForStart() }.value, "Wait until uninstall starts.")
    store.uninstall(app: app, on: device)
    store.open(app: app, on: device)
    store.install(app: app, version: app.latestVersion, on: device)
    store.cancel(appID: app.id, deviceID: device.id)
    store.cancelOperations(deviceID: device.id)
    try InstallationFixtures.require(
      store.phase(appID: app.id, deviceID: device.id) == .uninstalling
        && commands.calls.count == 2,
      "Stopping device operations must not wait for, cancel, or duplicate an in-flight uninstall.")
    let other = SimulatorDevice(
      id: "device-B", name: device.name, runtime: device.runtime, state: .booted)
    await inventory.refresh(for: other)
    commands.finish.signal()
    try await InstallationFixtures.eventually {
      store.phase(appID: app.id, deviceID: device.id) == nil
    }
    try InstallationFixtures.require(
      store.uninstalledApp == .init(appID: app.id, deviceID: device.id)
        && commands.calls.last == ["simctl", "uninstall", device.id, app.bundleID],
      "A successful uninstall reports the original app and device.")
    try InstallationFixtures.require(
      inventory.isInstalled(bundleID: app.bundleID, deviceID: other.id) == true,
      "Switching simulators during uninstall must not remove the other device's app.")
    await inventory.refresh(for: device)
    store.uninstall(app: app, on: device)
    commands.finish.signal()
    try await InstallationFixtures.eventually {
      store.phase(appID: app.id, deviceID: device.id) == nil
    }
    try InstallationFixtures.require(
      inventory.bundleIDs == [],
      "Remove the app from the selected inventory after confirmed success.")
  }

  static func uninstallFailure() async throws {
    let commands = InstallationCommands(failsUninstallation: true)
    let app = InstallationFixtures.app()
    let device = InstallationFixtures.device
    var removed = false
    let store = AppInstallationStore(
      installer: AppInstaller(command: commands.run), showDevice: { _ in },
      didUninstall: { _, _ in removed = true })
    for attempt in 1...2 {
      store.uninstall(app: app, on: device)
      try await InstallationFixtures.eventually {
        store.phase(appID: app.id, deviceID: device.id) == nil
      }
      try InstallationFixtures.require(
        !removed && store.uninstalledApp == nil
          && store.error(appID: app.id, deviceID: device.id) == "Uninstall failed",
        "Failed uninstall must retain the app and details, preserve diagnostics, and permit retry.")
      try InstallationFixtures.require(
        commands.calls.count == attempt * 2, "Each retry must recheck the target.")
    }
  }

  static func recoveryPrompts() async throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try archiveData(in: directory)
    let version = InstallationFixtures.version(data: data)
    let app = InstallationFixtures.app(version: version)
    let device = InstallationFixtures.device
    for action in ["install", "launch", "uninstall"] {
      let monitor = SimulatorOperationMonitor(wait: {})
      let gate = InstallationDownloadGate(data: data)
      let commands = InstallationCommands(
        blocksInstallation: action == "install", blocksLaunch: action == "launch",
        blocksUninstallation: action == "uninstall")
      defer { commands.finish.signal() }
      let store = AppInstallationStore(
        installer: AppInstaller(
          download: { try await gate.download($0, $1, $2) }, command: commands.run,
          temporaryDirectory: directory.appending(component: "work")),
        showDevice: { _ in }, operationMonitor: monitor)
      switch action {
      case "install":
        store.install(app: app, version: version, on: device)
        try await gate.waitForCount(1)
        try InstallationFixtures.require(
          monitor.prompt == nil, "A download must not suggest shutting down a healthy simulator.")
        await gate.finish(0)
      case "launch": store.open(app: app, on: device)
      default: store.uninstall(app: app, on: device)
      }
      try InstallationFixtures.require(
        await Task.detached { commands.waitForStart() }.value, "Wait for the simulator command.")
      try await InstallationFixtures.eventually { monitor.prompt?.device.id == device.id }
      commands.finish.signal()
      try await InstallationFixtures.eventually {
        store.phase(appID: app.id, deviceID: device.id) == nil
      }
      try InstallationFixtures.require(
        monitor.prompt == nil && store.error(appID: app.id, deviceID: device.id) == nil,
        "A completed simulator command must clear its recovery prompt and finish normally.")
    }
  }

  static func discoveryFailureDuringUninstall() async throws {
    @MainActor
    final class DiscoveryState { var shouldFail = false }
    let state = DiscoveryState()
    let device = InstallationFixtures.device
    let simulators = SimulatorStore(
      discover: {
        if state.shouldFail { throw InstallationFixtures.failure("Temporary discovery failure") }
        return SimulatorDiscovery(
          developerDirectory: URL(fileURLWithPath: "/Xcode.app/Contents/Developer"),
          devices: [device])
      }, boot: { _ in })
    let monitor = SimulatorOperationMonitor(wait: {})
    let commands = InstallationCommands(blocksUninstallation: true)
    defer { commands.finish.signal() }
    let store = AppInstallationStore(
      installer: AppInstaller(command: commands.run), showDevice: { _ in },
      operationMonitor: monitor)
    await simulators.refresh()
    monitor.synchronize(with: simulators.discovery?.devices)
    store.uninstall(app: InstallationFixtures.app(), on: device)
    try InstallationFixtures.require(
      await Task.detached { commands.waitForStart() }.value, "Wait for the blocked uninstall.")
    try await InstallationFixtures.eventually { monitor.prompt?.device.id == device.id }
    let prompt = monitor.prompt
    state.shouldFail = true
    await simulators.refresh()
    try InstallationFixtures.require(
      simulators.discovery?.devices == [device] && simulators.refreshError != nil,
      "A failed scan must retain the inventory and report its warning.")
    monitor.synchronize(with: simulators.discovery?.devices)
    try InstallationFixtures.require(
      monitor.prompt == prompt, "A failed scan must preserve the blocked operation's prompt.")
    state.shouldFail = false
    await simulators.refresh()
    monitor.synchronize(with: simulators.discovery?.devices)
    let inventory = InstalledAppsStore(load: { _ in [] }, operationMonitor: monitor)
    await inventory.refresh(for: simulators.selectedDevice!)
    try InstallationFixtures.require(
      simulators.selectedDevice?.state == .booted && monitor.prompt == prompt
        && store.phase(appID: "example", deviceID: device.id) == .uninstalling,
      "Retrying discovery and refreshing apps cannot lose the original stalled operation.")
    commands.finish.signal()
    try await InstallationFixtures.eventually {
      store.phase(appID: "example", deviceID: device.id) == nil
    }
    try InstallationFixtures.require(
      monitor.prompt == nil, "Clear the preserved prompt when the original operation completes.")
  }

  static func updateDuringInventoryRefresh() async throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try archiveData(in: directory)
    let version = InstallationFixtures.version(data: data, number: "1.0.0")
    let app = InstallationFixtures.app(version: version)
    let device = InstallationFixtures.device
    let probe = RefreshUpdateInventory(bundleID: app.bundleID)
    let inventory = InstalledAppsStore(load: { _ in try await probe.load() })
    await inventory.refresh(for: device)
    let refresh = Task { await inventory.refresh(for: device) }
    try await probe.waitForPending()
    try InstallationFixtures.require(
      inventory.application(bundleID: app.bundleID, deviceID: device.id)?.version == "0.9.0",
      "Retain the older version for display while the authoritative refresh is pending.")
    let commands = InstallationCommands()
    let store = AppInstallationStore(
      installer: AppInstaller(
        download: { _, destination, _ in try data.write(to: destination) },
        command: commands.run, temporaryDirectory: directory.appending(component: "work")),
      showDevice: { _ in },
      didReplace: { inventory.recordReplacement($0, deviceID: $1) })
    store.updateAll(
      in: AppCatalog(schemaVersion: 1, apps: [app]), installedApps: inventory, on: device)
    try await InstallationFixtures.eventually {
      store.updateBatch(deviceID: device.id)?.isRunning != true
    }
    let installs = commands.calls.filter { $0.prefix(2) == ["simctl", "install"] }.count
    try InstallationFixtures.require(inventory.isLoading, "Keep the refresh pending for the test.")
    try InstallationFixtures.require(
      installs == 0 && store.updateBatch(deviceID: device.id) == nil,
      "Do not start Update All from a retained snapshot before refresh completes.")
    await probe.finish()
    await refresh.value
    try InstallationFixtures.require(
      store.error(appID: app.id, deviceID: device.id) == nil,
      "Use a valid package and installation pipeline.")
    let actualAction = AppInstallationAction.forVersion(
      version, installed: inventory.application(bundleID: app.bundleID, deviceID: device.id),
      allowsChanges: true)
    store.updateAll(
      in: AppCatalog(schemaVersion: 1, apps: [app]), installedApps: inventory, on: device)
    try InstallationFixtures.require(
      actualAction == .downgrade && actualAction.needsConfirmation
        && store.updateBatch(deviceID: device.id) == nil,
      "The refreshed newer version requires downgrade confirmation and cannot enter Update All.")
  }

  static func versionActions() throws {
    let version = InstallationFixtures.version()
    let cases: [(String?, AppInstallationAction)] = [
      ("0.9.0", .update), ("1.0", .open), ("2.0.0", .downgrade), (nil, .replace),
      ("1.0-beta", .replace),
    ]
    for (installedVersion, expected) in cases {
      let installed = SimulatorApplication(
        bundleID: "org.example.App", version: installedVersion, isUserApplication: true)
      try InstallationFixtures.require(
        AppInstallationAction.forVersion(version, installed: installed, allowsChanges: true)
          == expected,
        "Choose an action that accurately describes replacing the installed version.")
      try InstallationFixtures.require(
        AppInstallationAction.forVersion(version, installed: installed, allowsChanges: false)
          == .open,
        "Installed cards keep Open rather than silently replacing an app.")
    }
    let system = SimulatorApplication(
      bundleID: "com.apple.Example", version: "0.9.0", isUserApplication: false)
    try InstallationFixtures.require(
      AppInstallationAction.forVersion(version, installed: system, allowsChanges: true) == .open,
      "Do not offer version replacement for system applications.")
  }

  static func replacementPipeline() async throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try archiveData(in: directory)
    let app = InstallationFixtures.app(version: InstallationFixtures.version(data: data))
    let device = InstallationFixtures.device
    for fails in [false, true] {
      let commands = InstallationCommands(failsInstallation: fails)
      let inventory = InstalledAppsStore(load: { _ in
        [SimulatorApplication(bundleID: app.bundleID, version: "0.9.0", isUserApplication: true)]
      })
      await inventory.refresh(for: device)
      var freshInstall = false
      let store = AppInstallationStore(
        installer: AppInstaller(
          download: { _, destination, _ in try data.write(to: destination) }, command: commands.run,
          temporaryDirectory: directory.appending(component: "work")),
        showDevice: { _ in }, didInstall: { _, _ in freshInstall = true },
        didReplace: { inventory.recordReplacement($0, deviceID: $1) })
      store.replace(app: app, version: app.latestVersion, on: device)
      try await InstallationFixtures.eventually {
        store.phase(appID: app.id, deviceID: device.id) == nil
      }
      let simulatorCommands = commands.calls.filter { $0.first == "simctl" }
      try InstallationFixtures.require(
        simulatorCommands.count == 1
          && simulatorCommands[0].prefix(3) == ["simctl", "install", device.id],
        "Replace through simctl install without an uninstall or erase step.")
      try InstallationFixtures.require(
        !freshInstall, "Replacement must not be recorded as a new Discover installation.")
      try InstallationFixtures.require(
        inventory.application(bundleID: app.bundleID, deviceID: device.id)?.version
          == (fails ? "0.9.0" : "1.0.0"),
        "Only a successful replacement may change the installed version.")
      try InstallationFixtures.require(
        (store.error(appID: app.id, deviceID: device.id) != nil) == fails,
        "Report failed replacements and retain the old installed version for retry.")
    }
  }

  static func replacementWhileSwitchingDevices() async throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try archiveData(in: directory)
    let version = InstallationFixtures.version(data: data)
    let app = InstallationFixtures.app(version: version)
    let a = InstallationFixtures.device
    let b = SimulatorDevice(id: "device-B", name: a.name, runtime: a.runtime, state: a.state)
    let gate = InstallationDownloadGate(data: data)
    let commands = InstallationCommands()
    let inventory = InstalledAppsStore(load: { _ in
      [SimulatorApplication(bundleID: app.bundleID, version: "0.9.0", isUserApplication: true)]
    })
    await inventory.refresh(for: a)
    var completedDevices: [String] = []
    let store = AppInstallationStore(
      installer: AppInstaller(
        download: { try await gate.download($0, $1, $2) }, command: commands.run,
        temporaryDirectory: directory.appending(component: "work")), showDevice: { _ in },
      didReplace: { application, deviceID in
        completedDevices.append(deviceID)
        inventory.recordReplacement(application, deviceID: deviceID)
      })
    store.replace(app: app, version: version, on: a)
    try await gate.waitForCount(1)
    await inventory.refresh(for: b)
    store.replace(app: app, version: version, on: a)
    store.install(app: app, version: version, on: a)
    store.uninstall(app: app, on: a)
    try InstallationFixtures.require(
      await gate.count == 1, "Replacement shares the existing per-app/device job lock.")
    await gate.finish(0)
    try await InstallationFixtures.eventually { store.phase(appID: app.id, deviceID: a.id) == nil }
    try InstallationFixtures.require(
      completedDevices == [a.id] && commands.calls.last?.prefix(3) == ["simctl", "install", a.id],
      "A background update must complete on its captured device.")
    try InstallationFixtures.require(
      inventory.deviceID == b.id
        && inventory.application(bundleID: app.bundleID, deviceID: b.id)?.version == "0.9.0",
      "A completed update on the previous device cannot replace the selected device's version.")
  }

  static func archiveData(in directory: URL) throws -> Data {
    try Data(
      contentsOf: InstallationFixtures.archive(InstallationFixtures.entries(), in: directory))
  }
}

private final class InstallationCommands: @unchecked Sendable {
  let started = DispatchSemaphore(value: 0)
  let finish = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var recorded: [[String]] = []
  private let blocksExtraction: Bool
  private let blocksInstallation: Bool
  private let failsInstallation: Bool
  private let failsLaunch: Bool
  private let blocksLaunch: Bool
  private let blocksUninstallation: Bool
  private let failsUninstallation: Bool

  init(
    blocksExtraction: Bool = false, blocksInstallation: Bool = false,
    failsInstallation: Bool = false, failsLaunch: Bool = false, blocksLaunch: Bool = false,
    blocksUninstallation: Bool = false, failsUninstallation: Bool = false
  ) {
    self.blocksExtraction = blocksExtraction
    self.blocksInstallation = blocksInstallation
    self.failsInstallation = failsInstallation
    self.failsLaunch = failsLaunch
    self.blocksLaunch = blocksLaunch
    self.blocksUninstallation = blocksUninstallation
    self.failsUninstallation = failsUninstallation
  }

  var calls: [[String]] { lock.withLock { recorded } }

  func waitForStart() -> Bool { started.wait(timeout: .now() + 5) == .success }

  func run(_ executable: String, _ arguments: [String]) throws -> Data {
    try InstallationFixtures.require(
      !Thread.isMainThread, "Package commands and simctl must not block the UI.")
    lock.withLock { recorded.append(arguments) }
    if executable == "/usr/bin/tar" {
      if blocksExtraction && arguments.first == "-tjf" { try block() }
      return try Command.run(executable, arguments: arguments)
    }
    try InstallationFixtures.require(
      executable == "/usr/bin/xcrun" && arguments.first == "simctl",
      "Use the common simctl wrapper.")
    if arguments[1] == "install" {
      try InstallationFixtures.require(
        FileManager.default.fileExists(atPath: arguments[3] + "/Info.plist"),
        "Keep the verified app until simctl finishes.")
      if blocksInstallation { try block() }
      if failsInstallation { throw InstallationFixtures.failure("Install failed") }
    }
    if arguments[1] == "launch" {
      if blocksLaunch { try block() }
      if failsLaunch { throw InstallationFixtures.failure("Launch failed") }
    }
    if arguments[1] == "listapps" {
      return Data(
        "{ \"org.example.App\" = { ApplicationType = User; CFBundleShortVersionString = \"0.9.0\"; }; }"
          .utf8)
    }
    if arguments[1] == "uninstall" {
      if blocksUninstallation { try block() }
      if failsUninstallation { throw InstallationFixtures.failure("Uninstall failed") }
    }
    return Data("org.example.App: 1234\n".utf8)
  }

  private func block() throws {
    started.signal()
    try InstallationFixtures.require(
      finish.wait(timeout: .now() + 5) == .success, "Release the blocked command.")
  }
}

private actor InstallationDownloadGate {
  private let data: Data
  private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
  private var progress: [AppDownload.Progress] = []
  var count: Int { progress.count }

  init(data: Data) { self.data = data }

  func download(_ url: URL, _ destination: URL, _ callback: @escaping AppDownload.Progress)
    async throws
  {
    let index = count
    progress.append(callback)
    await withCheckedContinuation { pending[index] = $0 }
    try data.write(to: destination)
  }

  func finish(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
  func report(_ index: Int, bytes: Int64) { progress[index](bytes) }

  func waitForCount(_ expected: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while count < expected {
      guard ContinuousClock.now < deadline else {
        throw InstallationFixtures.failure("A download did not start.")
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}

actor RefreshUpdateInventory {
  let bundleID: String
  private var calls = 0
  private var pending: CheckedContinuation<[SimulatorApplication], Never>?
  init(bundleID: String) { self.bundleID = bundleID }
  func load() async throws -> [SimulatorApplication] {
    calls += 1
    if calls == 1 {
      return [SimulatorApplication(bundleID: bundleID, version: "0.9.0", isUserApplication: true)]
    }
    return await withCheckedContinuation { pending = $0 }
  }
  func waitForPending() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while pending == nil {
      guard ContinuousClock.now < deadline else {
        throw InstallationFixtures.failure("Wait for background inventory refresh.")
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
  func finish(version: String = "2.0.0") {
    pending?.resume(returning: [
      SimulatorApplication(bundleID: bundleID, version: version, isUserApplication: true)
    ])
    pending = nil
  }
}
