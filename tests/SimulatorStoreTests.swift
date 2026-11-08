import Foundation
import Observation

@main
@MainActor
struct SimulatorStoreTests {
  @MainActor
  static func main() async {
    await TestSuite.run(cases)
  }

  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("selectionAndRefresh", selectionAndRefresh),
      .init("initialFailureAndEmptyInventory", initialFailureAndEmptyInventory),
      .init("cancelledRefreshKeepsInventory", cancelledRefreshKeepsInventory),
      .init("sharedScanRetriesAfterOwnerCancellation", sharedScanRetriesAfterOwnerCancellation),
      .init("sharedScanDoesNotRetryCancelledWaiters", sharedScanDoesNotRetryCancelledWaiters),
      .init("sharedScanReportsFailure", sharedScanReportsFailure),
      .init(
        "sharedScanKeepsOutcomeAfterLateCancellation", sharedScanKeepsOutcomeAfterLateCancellation),
      .init("controlRequiresSuccessfulRefresh", controlRequiresSuccessfulRefresh),
      .init("startingAndSelectionChanges", startingAndSelectionChanges),
      .init("independentStarts", independentStarts),
      .init("overlappingRefresh", overlappingRefresh),
      .init("startFailureAndCancellation", startFailureAndCancellation),
      .init("startupRequiresConfirmedReadiness", startupRequiresConfirmedReadiness),
      .init("failedBootAfterBootedPoll", failedBootAfterBootedPoll),
    ] + shutdownCases
  }

  static func selectionAndRefresh() async throws {
    let fixture = Inventory([device("A"), device("B", state: .booted)])
    let store = SimulatorStore(discover: fixture.scan, boot: { _ in })
    await store.refresh()
    try require(store.selectedDeviceID == "B", "Prefer an already booted simulator initially.")
    store.selectDevice("A")
    store.selectDevice("missing")
    await store.refresh()
    try require(store.selectedDeviceID == "A", "Keep an existing selection across refreshes.")
    fixture.error = failure("Discovery failed")
    await store.refresh()
    try require(
      store.discovery?.devices == fixture.devices && store.refreshError == "Discovery failed",
      "Keep the last valid inventory and expose a refresh warning.")
    try require(store.selectedDeviceID == "A", "Keep the selection through a discovery error.")
    fixture.error = nil
    fixture.devices = [device("C"), device("B", state: .booted)]
    await store.refresh()
    try require(store.refreshError == nil, "A successful retry clears the warning.")
    try require(
      store.selectedDeviceID == "B", "Replace a disappeared selection with a booted device.")
    fixture.devices = []
    await store.refresh()
    try require(
      store.selectedDevice == nil && store.selectedDeviceID == nil, "Clear an empty selection.")
    fixture.devices = [device("D"), device("E")]
    await store.refresh()
    try require(store.selectedDeviceID == "D", "Choose the first device when none is booted.")
  }

  static func initialFailureAndEmptyInventory() async throws {
    let fixture = Inventory([])
    fixture.error = SimulatorDiscoveryError.xcodeNotInstalled
    let store = SimulatorStore(discover: fixture.scan, boot: { _ in })
    try require(await store.refresh() == false, "Report a failed initial scan.")
    guard case .failure(let error) = store.result else {
      throw failure("An initial failure still needs the setup/error screen.")
    }
    try require(
      error as? SimulatorDiscoveryError == .xcodeNotInstalled && store.discovery == nil,
      "Keep the original error when no successful inventory is available.")
    fixture.error = nil
    try require(await store.refresh(), "Recover with a valid empty inventory.")
    fixture.error = failure("Temporary scan failure")
    try require(await store.refresh() == false, "Report a failed refresh after an empty scan.")
    try require(
      store.discovery?.devices.isEmpty == true && store.refreshError != nil,
      "An empty successful inventory is also retained through a failed refresh.")
    fixture.error = nil
    fixture.devices = [device("A", state: .booted)]
    try require(await store.refresh(), "Retry discovery after a failure.")
    try require(
      store.selectedDeviceID == "A" && store.refreshError == nil,
      "A successful retry replaces the inventory and clears the warning.")
    fixture.devices = []
    try require(await store.refresh(), "Accept a successful empty scan.")
    try require(
      store.discovery?.devices.isEmpty == true && store.selectedDeviceID == nil,
      "A successful empty scan must clear devices from the previous inventory.")
  }

  static func cancelledRefreshKeepsInventory() async throws {
    let fixture = Inventory([device("A", state: .booted)])
    let store = SimulatorStore(discover: fixture.scan, boot: { _ in })
    await store.refresh()
    fixture.deferNextScan = true
    let refresh = Task { await store.refresh() }
    try await eventually { fixture.pendingScan != nil }
    refresh.cancel()
    fixture.finishScan(with: [device("B", state: .booted)])
    try require(await refresh.value == false, "A canceled scan cannot confirm fresh data.")
    try require(
      store.selectedDeviceID == "A" && store.discovery?.devices == fixture.devices
        && store.refreshError == nil && !store.isChecking,
      "Cancellation must preserve the inventory and selection without showing an error.")
  }

  static func sharedScanReportsFailure() async throws {
    for error in [failure("Shared discovery failure") as Error, CancellationError()] {
      try await sharedScanReportsFailure(error)
    }
  }

  static func sharedScanRetriesAfterOwnerCancellation() async throws {
    for retryFails in [false, true] {
      let fixture = Inventory([device("A", state: .booted)])
      let store = SimulatorStore(discover: fixture.scan, boot: { _ in })
      await store.refresh()
      fixture.deferNextScan = true
      let owner = Task { await store.refresh() }
      try await eventually { fixture.pendingScan != nil }
      var joined = 0
      let waiters = (0..<3).map { _ in
        Task {
          joined += 1
          return await store.refresh()
        }
      }
      try await eventually { joined == 3 }
      waiters[0].cancel()
      owner.cancel()
      fixture.deferNextScan = true
      fixture.finishScan(with: [device("B", state: .booted)])
      try require(await owner.value == false, "A cancelled owner must not report success.")
      try require(await waiters[0].value == false, "A cancelled waiter must not retry.")
      try await eventually { fixture.calls == 3 && fixture.pendingScan != nil }
      try require(
        store.selectedDeviceID == "A" && store.discovery?.devices == fixture.devices
          && store.refreshError == nil && store.isChecking,
        "Keep the previous inventory and selection while active waiters retry a cancelled scan.")
      if retryFails {
        fixture.pendingScan?.resume(throwing: failure("Retry failed"))
        fixture.pendingScan = nil
      } else {
        fixture.finishScan(with: [device("B", state: .booted)])
      }
      for waiter in waiters.dropFirst() {
        try require(
          await waiter.value == !retryFails, "Active waiters must report the retry's outcome.")
      }
      try require(
        fixture.calls == 3 && !store.isChecking,
        "Active waiters must share one retry and stop after it succeeds or fails.")
      try require(
        store.selectedDeviceID == (retryFails ? "A" : "B")
          && store.discovery?.devices
            == (retryFails ? fixture.devices : [device("B", state: .booted)])
          && store.refreshError == (retryFails ? "Retry failed" : nil),
        "Publish a successful retry or preserve the previous inventory with the retry failure.")
    }
  }

  static func sharedScanDoesNotRetryCancelledWaiters() async throws {
    let fixture = Inventory([])
    let store = SimulatorStore(discover: fixture.scan, boot: { _ in })
    fixture.deferNextScan = true
    let owner = Task { await store.refresh() }
    try await eventually { fixture.pendingScan != nil }
    var joined = false
    let waiter = Task {
      joined = true
      return await store.refresh()
    }
    try await eventually { joined }
    owner.cancel()
    waiter.cancel()
    fixture.finishScan(with: [device("A")])
    try require(await owner.value == false, "The cancelled owner cannot publish an inventory.")
    try require(await waiter.value == false, "The cancelled waiter cannot retry discovery.")
    try require(
      fixture.calls == 1 && store.result == nil && store.refreshError == nil && !store.isChecking,
      "Cancelling all callers must stop discovery without publishing data or an error.")
  }

  static func sharedScanReportsFailure(_ error: Error) async throws {
    let fixture = Inventory([device("A", state: .booted)])
    let store = SimulatorStore(discover: fixture.scan, boot: { _ in })
    await store.refresh()
    fixture.deferNextScan = true
    let owner = Task { await store.refresh() }
    try await eventually { fixture.pendingScan != nil }
    var joined = false
    let waiter = Task {
      joined = true
      return await store.refresh()
    }
    try await eventually { joined }
    fixture.pendingScan?.resume(throwing: error)
    fixture.pendingScan = nil
    let ownerRefreshed = await owner.value
    let waiterRefreshed = await waiter.value
    try require(
      !ownerRefreshed && !waiterRefreshed && fixture.calls == 2
        && store.discovery?.devices == fixture.devices
        && store.refreshError == (error is CancellationError ? nil : error.localizedDescription),
      "All callers must observe a shared scan failure while keeping the last successful snapshot.")
  }

  static func sharedScanKeepsOutcomeAfterLateCancellation() async throws {
    for scanFails in [false, true] {
      let fixture = Inventory([device("A", state: .booted)])
      let store = SimulatorStore(discover: fixture.scan, boot: { _ in })
      await store.refresh()
      fixture.deferNextScan = true
      let owner = Task { await store.refresh() }
      try await eventually { fixture.pendingScan != nil }
      var joined = false
      let waiter = Task {
        joined = true
        return await store.refresh()
      }
      try await eventually { joined }
      // Cancel as the completed scan clears its observable progress state.
      withObservationTracking {
        _ = store.isChecking
      } onChange: {
        owner.cancel()
      }
      if scanFails {
        let error = failure("Completed scan failed")
        fixture.error = error
        fixture.pendingScan?.resume(throwing: error)
        fixture.pendingScan = nil
      } else {
        fixture.finishScan(with: [device("B", state: .booted)])
      }
      try require(await owner.value == !scanFails, "The owner must report the completed scan.")
      try require(owner.isCancelled, "Cancel the owner during completion cleanup.")
      try require(
        await waiter.value == !scanFails, "The waiter must receive the completed outcome.")
      try require(
        fixture.calls == 2 && !store.isChecking,
        "Cancellation after a scan's outcome is established must not trigger another scan.")
      try require(
        store.selectedDeviceID == (scanFails ? "A" : "B")
          && store.refreshError == (scanFails ? "Completed scan failed" : nil),
        "Keep the completed scan's inventory and diagnostic after late cancellation.")
    }
  }

  static func controlRequiresSuccessfulRefresh() async throws {
    let errors: [Error] = [failure("Cannot confirm simulator state"), CancellationError()]
    for starting in [true, false] {
      for error in errors {
        let fixture = Inventory([device("A", state: starting ? .shutdown : .booted)])
        let probe = PowerProbe()
        let store = SimulatorStore(
          discover: fixture.scan, shutdown: { try await probe.run($0) },
          boot: { try await probe.run($0) })
        await store.refresh()
        let job: Task<Bool, Never>
        if starting {
          job = Task { await store.startDevice("A") }
        } else {
          guard let shutdown = store.shutdownDevice("A") else { throw failure("Begin shutdown.") }
          job = shutdown
        }
        try await eventually { await probe.calls == ["A"] }
        let completedState: SimulatorState = starting ? .booted : .shutdown
        fixture.devices = [device("A", state: completedState)]
        await store.refresh()
        fixture.error = error
        await probe.finish()
        try require(
          await job.value == false && store.selectedDevice?.state == completedState
            && store.refreshError
              == (error is CancellationError ? nil : error.localizedDescription),
          "A retained snapshot must not confirm a control operation after a failed or canceled final scan."
        )
      }
    }
  }

  static func startingAndSelectionChanges() async throws {
    let fixture = Inventory([device("A"), device("B")])
    let probe = PowerProbe()
    let store = SimulatorStore(discover: fixture.scan, boot: { try await probe.run($0) })
    await store.refresh()
    let startup = Task { await store.startDevice("A") }
    try await eventually { await probe.calls == ["A"] }
    try require(
      store.selectedDevice?.state == .booting, "Expose startup progress for the selected device.")
    try require(
      await store.startDevice("A") == false, "A duplicate start must not report success.")
    try require(await probe.calls == ["A"], "Repeated clicks must not start a device twice.")
    store.selectDevice("B")
    try require(
      store.selectedDevice?.state != .booting, "Startup progress must follow its own device.")
    try require(
      store.startingDeviceIDs == ["A"], "Changing selection must not lose startup tracking.")
    fixture.devices = [device("A", state: .booted), device("B")]
    await probe.finish()
    try require(
      await startup.value, "A successful boot confirmed by inventory should report success.")
    try require(
      store.selectedDeviceID == "B", "Startup completion must preserve a later selection.")
    try require(
      store.discovery?.devices.first?.state == .booted,
      "Read startup state from a fresh inventory.")
    try require(store.startingDeviceIDs.isEmpty, "Clear progress after startup.")
    try require(fixture.calls == 2, "Refresh the inventory after startup.")
    store.selectDevice("A")
    try require(
      await store.startDevice("A") == false, "An ignored start must not report success.")
    try require(await probe.calls == ["A"], "An already booted device needs no boot command.")
  }

  static func overlappingRefresh() async throws {
    let fixture = Inventory([device("A")])
    let probe = PowerProbe()
    let store = SimulatorStore(discover: fixture.scan, boot: { try await probe.run($0) })
    await store.refresh()
    let startup = Task { await store.startDevice("A") }
    try await eventually { await probe.calls == ["A"] }
    fixture.deferNextScan = true
    let refresh = Task { await store.refresh() }
    try await eventually { fixture.pendingScan != nil }
    let coalesced = Task { await store.refresh() }
    await Task.yield()
    try require(fixture.calls == 2, "Concurrent refreshes should share one scan.")
    await probe.finish()
    fixture.devices = [device("A", state: .booted)]
    fixture.finishScan(with: [device("A")])
    try require(await refresh.value, "The owner must report its successful scan.")
    try require(await coalesced.value, "A waiter must report the shared scan's success.")
    try require(
      await startup.value, "Fresh readiness after an overlapping scan should report success.")
    try require(
      fixture.calls == 3, "Startup must request a scan newer than any in-flight inventory.")
    try require(
      store.selectedDevice?.state == .booted, "An old scan must not hide successful startup.")
    try require(
      !store.isChecking && store.selectedDevice?.state != .booting, "All progress must finish.")
  }

  static func independentStarts() async throws {
    let fixture = Inventory([device("A"), device("B", state: .booting)])
    let probe = PowerProbe()
    let store = SimulatorStore(discover: fixture.scan, boot: { try await probe.run($0) })
    await store.refresh()
    let first = Task { await store.startDevice("A") }
    try await eventually { await probe.calls == ["A"] }
    store.selectDevice("B")
    let second = Task { await store.startDevice("B") }
    try await eventually { await probe.calls == ["A", "B"] }
    try require(
      store.startingDeviceIDs == ["A", "B"], "Track each simulator's startup separately.")
    fixture.devices = [device("A", state: .booted), device("B", state: .booting)]
    await probe.finish("A")
    try require(await first.value, "Confirm the first simulator's startup independently.")
    try require(
      store.startingDeviceIDs == ["B"], "One startup must not clear another device's progress.")
    try require(
      store.selectedDevice?.state == .booting,
      "Keep progress for the currently selected simulator.")
    fixture.devices = [device("A", state: .booted), device("B", state: .booted)]
    await probe.finish("B")
    try require(await second.value, "Confirm the second simulator's startup independently.")
    try require(
      store.selectedDeviceID == "B" && store.startingDeviceIDs.isEmpty,
      "Finish both independent startups.")
  }

  static func startFailureAndCancellation() async throws {
    for cancelled in [false, true] {
      let fixture = Inventory([device("A")])
      let store = SimulatorStore(discover: fixture.scan) { _ in
        if cancelled { throw CancellationError() }
        throw failure("Could not start this simulator")
      }
      await store.refresh()
      try require(
        await store.startDevice("A") == false, "A failed or cancelled start must return false."
      )
      try require(
        store.startingDeviceIDs.isEmpty, "A failed or cancelled start must clear progress.")
      try require(
        store.selectedDevice?.state == .shutdown, "A failed command cannot imply Booted.")
      try require(fixture.calls == 1, "A failed boot should not imply a successful refresh.")
      if cancelled {
        try require(store.startError == nil, "Keep cancellation silent.")
      } else {
        try require(
          store.startError?.contains("iPhone A") == true
            && store.startError?.contains("Could not start this simulator") == true,
          "Identify the failed simulator and preserve the boot diagnostic.")
      }
    }
    for state in [SimulatorState.shuttingDown, .unknown] {
      let fixture = Inventory([device("A", state: state)])
      let store = SimulatorStore(discover: fixture.scan) { _ in
        throw failure("Do not start a device in an unavailable state")
      }
      await store.refresh()
      try require(
        await store.startDevice("A") == false && store.startError == nil,
        "Unknown and shutting-down devices must not receive a boot command.")
    }
  }

  static func startupRequiresConfirmedReadiness() async throws {
    for refreshedDevices in [[device("A")], [device("A", state: .booting)], []] {
      let fixture = Inventory([device("A")])
      let probe = PowerProbe()
      let store = SimulatorStore(discover: fixture.scan, boot: { try await probe.run($0) })
      await store.refresh()
      let startup = Task { await store.startDevice("A") }
      try await eventually { await probe.calls == ["A"] }
      fixture.devices = refreshedDevices
      await probe.finish()
      try require(
        await startup.value == false,
        "A successful command alone cannot confirm a missing or unready simulator.")
    }
  }

  static func failedBootAfterBootedPoll() async throws {
    let fixture = Inventory([device("A"), device("B")])
    let probe = PowerProbe()
    let store = SimulatorStore(discover: fixture.scan, boot: { try await probe.run($0) })
    await store.refresh()
    let startup = Task { await store.startDevice("A") }
    try await eventually { await probe.calls == ["A"] }
    store.selectDevice("B")
    fixture.devices = [device("A", state: .booted), device("B")]
    await store.refresh()
    await probe.fail("A", error: failure("Boot readiness failed"))
    try require(
      await startup.value == false, "Boot failure must override an intermediate Booted snapshot.")
    try require(
      store.selectedDeviceID == "B", "A startup error must preserve the user's later selection.")
    try require(
      store.startError?.contains("iPhone A") == true
        && store.startError?.contains("Boot readiness failed") == true,
      "Attribute the error to the device that was started, even after selection changes.")
  }

  static func device(_ id: String, state: SimulatorState = .shutdown) -> SimulatorDevice {
    SimulatorDevice(id: id, name: "iPhone \(id)", runtime: "27.0", state: state)
  }

  static func eventually(_ condition: () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while !(await condition()) {
      guard clock.now < deadline else { throw failure("Timed out waiting for an async operation") }
      await Task.yield()
    }
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  nonisolated static func failure(_ message: String) -> NSError {
    NSError(domain: "SimulatorStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  @MainActor
  final class Inventory {
    var devices: [SimulatorDevice]
    var error: Error?
    var calls = 0
    var deferNextScan = false
    var pendingScan: CheckedContinuation<SimulatorDiscovery, Error>?

    init(_ devices: [SimulatorDevice]) { self.devices = devices }

    func scan() async throws -> SimulatorDiscovery {
      calls += 1
      if let error { throw error }
      if deferNextScan {
        deferNextScan = false
        return try await withCheckedThrowingContinuation { pendingScan = $0 }
      }
      return snapshot(devices)
    }

    func finishScan(with devices: [SimulatorDevice]) {
      let continuation = pendingScan
      pendingScan = nil
      continuation?.resume(returning: snapshot(devices))
    }

    private func snapshot(_ devices: [SimulatorDevice]) -> SimulatorDiscovery {
      SimulatorDiscovery(
        developerDirectory: URL(fileURLWithPath: "/Xcode.app/Contents/Developer"), devices: devices)
    }
  }

  actor PowerProbe {
    private(set) var calls: [String] = []
    private var continuations: [String: CheckedContinuation<Void, Error>] = [:]

    func run(_ id: String) async throws {
      calls.append(id)
      try await withCheckedThrowingContinuation { continuations[id] = $0 }
    }

    func finish(_ id: String = "A") {
      continuations.removeValue(forKey: id)?.resume()
    }

    func fail(_ id: String, error: Error) {
      continuations.removeValue(forKey: id)?.resume(throwing: error)
    }
  }
}
