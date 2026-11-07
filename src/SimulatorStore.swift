import Foundation
import Observation

@MainActor
@Observable
final class SimulatorStore {
  private enum RefreshOutcome {
    case succeeded
    case failed
    case ownerCancelled
  }

  private(set) var result: Result<SimulatorDiscovery, Error>?
  private(set) var isChecking = false
  private(set) var refreshError: String?
  private(set) var selectedDeviceID: String?
  private(set) var startingDeviceIDs: Set<String> = []
  private(set) var shuttingDownDeviceIDs: Set<String> = []
  var startError: String?
  var shutdownError: String?

  @ObservationIgnored
  private let discover: @MainActor () async throws -> SimulatorDiscovery
  @ObservationIgnored
  private let boot: @Sendable (String) async throws -> Void
  @ObservationIgnored
  private let shutdown: @Sendable (String) async throws -> Void
  @ObservationIgnored
  private var refreshWaiters: [CheckedContinuation<RefreshOutcome, Never>] = []

  init(
    discover: @escaping @MainActor () async throws -> SimulatorDiscovery,
    shutdown: @escaping @Sendable (String) async throws -> Void = {
      try await SimulatorControl.shutdown($0)
    },
    boot: @escaping @Sendable (String) async throws -> Void
  ) {
    self.discover = discover
    self.boot = boot
    self.shutdown = shutdown
  }

  private var snapshot: SimulatorDiscovery? {
    guard case .success(let discovery) = result else { return nil }
    return discovery
  }

  var discovery: SimulatorDiscovery? {
    guard let snapshot else { return nil }
    return SimulatorDiscovery(
      developerDirectory: snapshot.developerDirectory,
      devices: snapshot.devices.map { device in
        let state: SimulatorState
        if shuttingDownDeviceIDs.contains(device.id) {
          state = .shuttingDown
        } else if startingDeviceIDs.contains(device.id) {
          state = .booting
        } else {
          return device
        }
        return SimulatorDevice(
          id: device.id, name: device.name, runtime: device.runtime, state: state)
      })
  }

  var selectedDevice: SimulatorDevice? {
    discovery?.devices.first { $0.id == selectedDeviceID }
  }

  func selectDevice(_ id: String) {
    guard discovery?.devices.contains(where: { $0.id == id }) == true else { return }
    selectedDeviceID = id
  }

  @discardableResult
  func refresh() async -> Bool {
    guard !Task.isCancelled else { return false }
    guard !isChecking else {
      let outcome = await waitForRefresh()
      guard !Task.isCancelled else { return false }
      switch outcome {
      case .succeeded: return true
      case .failed: return false
      case .ownerCancelled: return await refresh()
      }
    }
    var outcome = RefreshOutcome.failed
    isChecking = true
    defer {
      isChecking = false
      let waiters = refreshWaiters
      refreshWaiters.removeAll()
      // Only cancellation of the owning task lets active waiters retry the scan.
      let sharedOutcome: RefreshOutcome = Task.isCancelled ? .ownerCancelled : outcome
      for waiter in waiters { waiter.resume(returning: sharedOutcome) }
    }
    do {
      let discovery = try await discover()
      try Task.checkCancellation()
      result = .success(discovery)
      refreshError = nil
      if !discovery.devices.contains(where: { $0.id == selectedDeviceID }) {
        let devices = self.discovery?.devices ?? []
        selectedDeviceID =
          devices.first(where: { $0.state == .booted })?.id ?? devices.first?.id
      }
      outcome = .succeeded
      return true
    } catch is CancellationError {
      return false
    } catch {
      guard !Task.isCancelled else { return false }
      refreshError = error.localizedDescription
      if snapshot == nil { result = .failure(error) }
      return false
    }
  }

  @discardableResult
  func startDevice(_ id: String) async -> Bool {
    guard let device = snapshot?.devices.first(where: { $0.id == id }),
      device.state.canStart,
      !shuttingDownDeviceIDs.contains(device.id),
      startingDeviceIDs.insert(device.id).inserted
    else { return false }
    startError = nil
    defer { startingDeviceIDs.remove(device.id) }
    do {
      try await boot(device.id)
      guard try await refreshAfterControl() else { return false }
      return snapshot?.devices.contains(where: { $0.id == device.id && $0.state == .booted })
        == true
    } catch is CancellationError {
      return false
    } catch {
      startError = String(
        localized: "Couldn’t start \(device.name).\n\(error.localizedDescription)")
      return false
    }
  }

  @discardableResult
  func shutdownDevice(_ id: String) -> Task<Bool, Never>? {
    guard let device = snapshot?.devices.first(where: { $0.id == id }), device.state.canShutdown,
      !startingDeviceIDs.contains(device.id), shuttingDownDeviceIDs.insert(device.id).inserted
    else { return nil }
    shutdownError = nil
    return Task { [self] in
      defer { shuttingDownDeviceIDs.remove(device.id) }
      do {
        try Task.checkCancellation()
        try await shutdown(device.id)
        guard try await refreshAfterControl() else { return false }
        return snapshot?.devices.contains(where: { $0.id == device.id && $0.state == .shutdown })
          == true
      } catch is CancellationError {
        return false
      } catch {
        shutdownError = String(
          localized: "Couldn’t shut down \(device.name).\n\(error.localizedDescription)")
        return false
      }
    }
  }

  private func refreshAfterControl() async throws -> Bool {
    try Task.checkCancellation()
    // A scan begun before the operation completed may contain the previous power state.
    if isChecking { _ = await waitForRefresh() }
    try Task.checkCancellation()
    let refreshed = await refresh()
    try Task.checkCancellation()
    return refreshed
  }

  private func waitForRefresh() async -> RefreshOutcome {
    await withCheckedContinuation { continuation in
      refreshWaiters.append(continuation)
    }
  }
}
