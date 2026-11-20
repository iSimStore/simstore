import Foundation
import Observation

@MainActor
@Observable
final class InstalledAppsStore {
  private(set) var deviceID: String?
  private(set) var applications: [SimulatorApplication]?
  var bundleIDs: Set<String>? { applications.map { Set($0.map(\.bundleID)) } }
  private(set) var isLoading = false
  private(set) var error: String?
  private var hasCurrentInventory = false
  private var recentInstallations: Set<String> = []
  private var recentReplacements: Set<String> = []

  @ObservationIgnored
  private let load: @Sendable (SimulatorDevice) async throws -> [SimulatorApplication]
  @ObservationIgnored
  private let operationMonitor: SimulatorOperationMonitor?
  @ObservationIgnored
  private var selectedDevice: SimulatorDevice?
  @ObservationIgnored
  private var request: Request?
  @ObservationIgnored
  private var installedDuringRefresh: [SimulatorApplication] = []
  @ObservationIgnored
  private var removedDuringRefresh: Set<String> = []

  init(
    load: @escaping @Sendable (SimulatorDevice) async throws -> [SimulatorApplication] = {
      try await SimulatorApplications.installedApps(on: $0)
    }, operationMonitor: SimulatorOperationMonitor? = nil
  ) {
    self.load = load
    self.operationMonitor = operationMonitor
  }

  func installedApps(in catalog: AppCatalog, for deviceID: String) -> [CatalogApp]? {
    guard self.deviceID == deviceID, let bundleIDs else { return nil }
    let installed = Set(bundleIDs.map { $0.lowercased() })
    return catalog.apps.filter { installed.contains($0.bundleID.lowercased()) }
  }

  func updatableApps(
    in catalog: AppCatalog, for device: SimulatorDevice, includingRecent: Bool = true
  ) -> [CatalogApp]? {
    guard device.state == .booted, self.deviceID == device.id, applications != nil else {
      return nil
    }
    return catalog.apps.filter { app in
      guard let installed = application(bundleID: app.bundleID, deviceID: device.id),
        installed.isUserApplication
      else { return false }
      if app.availableUpdate(
        from: installed.version, runtime: device.runtime, isIPad: device.isIPad) != nil
      {
        return true
      }
      return includingRecent && recentReplacements.contains(app.bundleID.lowercased())
        && app.latestCompatibleVersion(for: device.runtime, isIPad: device.isIPad)?.comparison(
          with: installed.version)
          == .orderedSame
    }
  }

  func application(bundleID: String, deviceID: String) -> SimulatorApplication? {
    guard self.deviceID == deviceID else { return nil }
    return applications?.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
  }

  func discoverableApps(in catalog: AppCatalog, for deviceID: String) -> [CatalogApp]? {
    guard self.deviceID == deviceID, let bundleIDs else { return nil }
    let installed = Set(bundleIDs.map { $0.lowercased() })
    return catalog.apps.filter {
      !installed.contains($0.bundleID.lowercased())
        || recentInstallations.contains($0.bundleID.lowercased())
    }
  }

  func clearRecentInstallations() {
    recentInstallations = []
    recentReplacements = []
  }

  func removeRecentInstallation(bundleID: String, deviceID: String) {
    guard self.deviceID == deviceID else { return }
    recentInstallations.remove(bundleID.lowercased())
    recentReplacements.remove(bundleID.lowercased())
  }

  func recordInstallation(_ application: SimulatorApplication, deviceID: String) {
    guard self.deviceID == deviceID else { return }
    mergeInstallation(application)
    recentInstallations.insert(application.bundleID.lowercased())
  }

  func recordReplacement(_ application: SimulatorApplication, deviceID: String) {
    guard self.deviceID == deviceID else { return }
    mergeInstallation(application)
    recentReplacements.insert(application.bundleID.lowercased())
  }

  private func mergeInstallation(_ application: SimulatorApplication) {
    let bundleID = application.bundleID.lowercased()
    installedDuringRefresh.removeAll { $0.bundleID.lowercased() == bundleID }
    installedDuringRefresh.append(application)
    removedDuringRefresh.remove(bundleID)
    applications?.removeAll { $0.bundleID.lowercased() == bundleID }
    applications?.append(application)
  }

  func recordUninstallation(bundleID: String, deviceID: String) {
    guard self.deviceID == deviceID else { return }
    let bundleID = bundleID.lowercased()
    installedDuringRefresh.removeAll { $0.bundleID.lowercased() == bundleID }
    removedDuringRefresh.insert(bundleID)
    recentInstallations.remove(bundleID)
    recentReplacements.remove(bundleID)
    applications?.removeAll { $0.bundleID.lowercased() == bundleID }
  }

  func isInstalled(bundleID: String, deviceID: String) -> Bool? {
    guard self.deviceID == deviceID, let bundleIDs else { return nil }
    return bundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
  }

  func canInstall(on device: SimulatorDevice) -> Bool {
    device.state == .booted && deviceID == device.id && hasCurrentInventory
      && applications != nil
  }

  func refresh(for device: SimulatorDevice) async {
    guard !Task.isCancelled else { return }
    if let pending = request, pending.device == device {
      let ownerWasCancelled = await withCheckedContinuation { pending.waiters.append($0) }
      if ownerWasCancelled && !Task.isCancelled && selectedDevice == device {
        await refresh(for: device)
      }
      return
    }
    let pending = Request(device: device)
    if selectedDevice?.id != device.id { clearRecentInstallations() }
    if selectedDevice != device { applications = nil }
    request = pending
    selectedDevice = device
    deviceID = device.id
    installedDuringRefresh = []
    removedDuringRefresh = []
    error = nil
    hasCurrentInventory = false
    isLoading = true
    let operation = operationMonitor?.begin(on: device)
    defer {
      if let operation { operationMonitor?.end(operation) }
      if request === pending {
        request = nil
        isLoading = false
      }
      for waiter in pending.waiters { waiter.resume(returning: Task.isCancelled) }
    }
    do {
      let installed = try await load(device)
      try Task.checkCancellation()
      if request === pending {
        let replaced = Set(installedDuringRefresh.map { $0.bundleID.lowercased() })
          .union(removedDuringRefresh)
        applications =
          installed.filter { !replaced.contains($0.bundleID.lowercased()) }
          + installedDuringRefresh
        hasCurrentInventory = true
      }
    } catch is CancellationError {
    } catch {
      if request === pending && !Task.isCancelled {
        applications = nil
        self.error = error.localizedDescription
      }
    }
  }

  private final class Request {
    let device: SimulatorDevice
    var waiters: [CheckedContinuation<Bool, Never>] = []

    init(device: SimulatorDevice) { self.device = device }
  }
}
