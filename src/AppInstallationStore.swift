import Foundation
import Observation

@MainActor
@Observable
final class AppInstallationStore {
  struct Key: Hashable {
    let appID: String
    let deviceID: String
  }

  private var phases: [Key: AppInstallationPhase] = [:]
  private var errors: [Key: String] = [:]
  private(set) var openedApp: Key?
  private(set) var uninstalledApp: Key?
  @ObservationIgnored private let installer: AppInstaller
  @ObservationIgnored private let operationMonitor: SimulatorOperationMonitor?
  @ObservationIgnored private var monitoredOperations: [Key: UUID] = [:]
  @ObservationIgnored private let didInstall: @MainActor (SimulatorApplication, String) -> Void
  @ObservationIgnored private let didReplace: @MainActor (SimulatorApplication, String) -> Void
  @ObservationIgnored private let didUninstall: @MainActor (String, String) -> Void
  @ObservationIgnored private let showDevice: @MainActor (SimulatorDevice) async throws -> Void
  @ObservationIgnored private let didOpen: @MainActor (String, String) -> Void
  @ObservationIgnored private var jobs: [Key: Task<Void, Never>] = [:]
  @ObservationIgnored private var requests: [Key: UUID] = [:]
  @ObservationIgnored private let updateQueue = AppUpdateQueue()

  init(
    installer: AppInstaller = AppInstaller(),
    showDevice: @escaping @MainActor (SimulatorDevice) async throws -> Void,
    didInstall: @escaping @MainActor (SimulatorApplication, String) -> Void = { _, _ in },
    didReplace: @escaping @MainActor (SimulatorApplication, String) -> Void = { _, _ in },
    didUninstall: @escaping @MainActor (String, String) -> Void = { _, _ in },
    didOpen: @escaping @MainActor (String, String) -> Void = { _, _ in },
    operationMonitor: SimulatorOperationMonitor? = nil
  ) {
    self.installer = installer
    self.didInstall = didInstall
    self.didReplace = didReplace
    self.didUninstall = didUninstall
    self.showDevice = showDevice
    self.didOpen = didOpen
    self.operationMonitor = operationMonitor
  }

  func phase(appID: String, deviceID: String) -> AppInstallationPhase? {
    phases[Key(appID: appID, deviceID: deviceID)]
  }

  func error(appID: String, deviceID: String) -> String? {
    errors[Key(appID: appID, deviceID: deviceID)]
  }

  func hasOperations(deviceID: String) -> Bool {
    phases.keys.contains { $0.deviceID == deviceID }
      || updateQueue.batch(deviceID: deviceID)?.isRunning == true
  }

  func install(app: CatalogApp, version: CatalogVersion, on device: SimulatorDevice) {
    startInstallation(app: app, version: version, on: device, completion: didInstall)
  }

  func replace(app: CatalogApp, version: CatalogVersion, on device: SimulatorDevice) {
    startInstallation(app: app, version: version, on: device, completion: didReplace)
  }

  @discardableResult
  private func startInstallation(
    app: CatalogApp, version: CatalogVersion, on device: SimulatorDevice,
    completion: @escaping @MainActor (SimulatorApplication, String) -> Void,
    fromQueue: Bool = false,
    finished: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }
  ) -> Task<Void, Never>? {
    let key = Key(appID: app.id, deviceID: device.id)
    guard jobs[key] == nil, phases[key] == nil || (fromQueue && phases[key] == .queued) else {
      return nil
    }
    let request = UUID()
    requests[key] = request
    errors[key] = nil
    phases[key] = .downloading(0)
    let job = Task { [self] in
      defer { finish(key) }
      do {
        try await installer.install(app: app, version: version, on: device) { [weak self] phase in
          guard let self, requests[key] == request, phases[key] != .canceling else { return }
          if case .downloading(let bytes) = phase, case .downloading(let previous) = phases[key] {
            phases[key] = .downloading(max(bytes, previous))
          } else if case .downloading = phase {
            return
          } else {
            phases[key] = phase
            if phase == .installing { monitor(key, on: device) }
          }
        }
        completion(
          SimulatorApplication(
            bundleID: app.bundleID, version: version.version, isUserApplication: true),
          device.id)
        finished(.success(()))
      } catch {
        if Task.isCancelled || error is CancellationError {
          finished(.failure(CancellationError()))
        } else {
          errors[key] = error.localizedDescription
          finished(.failure(error))
        }
      }
    }
    jobs[key] = job
    return job
  }

  func uninstall(app: CatalogApp, on device: SimulatorDevice) {
    let key = Key(appID: app.id, deviceID: device.id)
    guard jobs[key] == nil, phases[key] == nil else { return }
    uninstalledApp = nil
    errors[key] = nil
    phases[key] = .uninstalling
    monitor(key, on: device)
    jobs[key] = Task {
      defer { finish(key) }
      do {
        try await installer.uninstall(app: app, on: device)
        didUninstall(app.bundleID, device.id)
        uninstalledApp = key
      } catch {
        errors[key] = error.localizedDescription
      }
    }
  }

  func cancel(appID: String, deviceID: String) {
    let key = Key(appID: appID, deviceID: deviceID)
    if phases[key] == .queued {
      phases[key] = nil
      updateQueue.cancelQueued(appID: appID, deviceID: deviceID)
      return
    }
    guard phases[key]?.canCancel == true else { return }
    phases[key] = .canceling
    jobs[key]?.cancel()
  }

  func cancelOperations(deviceID: String) {
    cancelAllUpdates(deviceID: deviceID)
    for key in phases.keys.filter({ $0.deviceID == deviceID }) {
      cancel(appID: key.appID, deviceID: deviceID)
    }
  }

  func open(app: CatalogApp, on device: SimulatorDevice) {
    let key = Key(appID: app.id, deviceID: device.id)
    guard jobs[key] == nil, phases[key] == nil else { return }
    openedApp = nil
    errors[key] = nil
    phases[key] = .opening
    monitor(key, on: device)
    jobs[key] = Task {
      defer { finish(key) }
      do {
        try await installer.open(app: app, on: device)
        try await showDevice(device)
        didOpen(app.bundleID, device.id)
        openedApp = key
      } catch {
        errors[key] = error.localizedDescription
      }
    }
  }

  private func finish(_ key: Key) {
    if let operation = monitoredOperations.removeValue(forKey: key) {
      operationMonitor?.end(operation)
    }
    jobs[key] = nil
    requests[key] = nil
    phases[key] = nil
  }

  private func monitor(_ key: Key, on device: SimulatorDevice) {
    guard monitoredOperations[key] == nil else { return }
    monitoredOperations[key] = operationMonitor?.begin(on: device)
  }

  func updateBatch(deviceID: String) -> AppUpdateBatch? {
    updateQueue.batch(deviceID: deviceID)
  }

  func activeUpdateVersion(appID: String, deviceID: String) -> CatalogVersion? {
    updateQueue.activeVersion(appID: appID, deviceID: deviceID)
  }

  func pendingUpdates(
    in catalog: AppCatalog, installedApps: InstalledAppsStore, on device: SimulatorDevice
  ) -> [AppUpdateBatch.Item] {
    updateQueue.pendingUpdates(in: catalog, installedApps: installedApps, on: device) {
      phase(appID: $0, deviceID: device.id) != nil
    }
  }

  func updateAll(
    in catalog: AppCatalog, installedApps: InstalledAppsStore, on device: SimulatorDevice
  ) {
    updateQueue.start(
      items: pendingUpdates(in: catalog, installedApps: installedApps, on: device),
      deviceID: device.id,
      reserve: { item in
        let key = Key(appID: item.id, deviceID: device.id)
        errors[key] = nil
        phases[key] = .queued
      },
      install: { [self] item, finished in
        startInstallation(
          app: item.app, version: item.version, on: device, completion: didReplace,
          fromQueue: true, finished: finished)
      },
      release: { [self] item in
        let key = Key(appID: item.id, deviceID: device.id)
        if phases[key] == .queued { phases[key] = nil }
      })
  }

  func cancelAllUpdates(deviceID: String) {
    updateQueue.cancelAll(deviceID: deviceID) { cancel(appID: $0, deviceID: deviceID) }
  }

  func dismissUpdateBatch(deviceID: String) {
    updateQueue.dismiss(deviceID: deviceID)
  }
}
