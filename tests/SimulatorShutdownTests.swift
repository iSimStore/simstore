import Foundation

extension SimulatorStoreTests {
  @MainActor
  static var shutdownCases: [TestSuite.Case] {
    [
      .init("shutdown.shuttingDownAndSelectionChanges", shuttingDownAndSelectionChanges),
      .init("shutdown.independentShutdowns", independentShutdowns),
      .init("shutdown.shutdownWithOverlappingRefresh", shutdownWithOverlappingRefresh),
      .init("shutdown.shutdownFailuresAndCancellation", shutdownFailuresAndCancellation),
      .init("shutdown.confirmedShutdownAndInvalidStates", confirmedShutdownAndInvalidStates),
      .init("shutdown.mutuallyExclusivePowerOperations", mutuallyExclusivePowerOperations),
    ]
  }

  private static func shuttingDownAndSelectionChanges() async throws {
    let fixture = Inventory([device("A", state: .booted), device("B", state: .booted)])
    let probe = PowerProbe()
    let store = SimulatorStore(
      discover: fixture.scan, shutdown: { try await probe.run($0) }, boot: { _ in })
    await store.refresh()
    guard let job = store.shutdownDevice("A") else {
      throw failure("Accept an idle running device.")
    }
    try require(
      store.shuttingDownDeviceIDs == ["A"] && store.selectedDevice?.state == .shuttingDown,
      "Reserve shutdown synchronously and prevent app operations before the first await.")
    try require(
      store.shutdownDevice("A") == nil, "Repeated clicks cannot issue a duplicate shutdown.")
    try require(
      await store.startDevice("A") == false, "Do not boot a simulator while shutdown is pending.")
    try await eventually { await probe.calls == ["A"] }
    await store.refresh()
    try require(
      store.selectedDevice?.state == .shuttingDown,
      "A stale Booted scan cannot re-enable app operations during shutdown.")
    store.selectDevice("B")
    fixture.devices = [device("A"), device("B", state: .booted)]
    await probe.finish("A")
    try require(await job.value, "Confirm shutdown from the fresh inventory.")
    try require(
      store.selectedDeviceID == "B" && store.shuttingDownDeviceIDs.isEmpty,
      "Completion must preserve a later device selection and clear only its own progress.")
    try require(
      store.discovery?.devices.first?.state == .shutdown, "Show the confirmed power state.")
    try require(store.shutdownDevice("A") == nil, "Do not shut down an already stopped simulator.")
  }

  private static func independentShutdowns() async throws {
    let fixture = Inventory([device("A", state: .booted), device("B", state: .booted)])
    let probe = PowerProbe()
    let store = SimulatorStore(
      discover: fixture.scan, shutdown: { try await probe.run($0) }, boot: { _ in })
    await store.refresh()
    guard let a = store.shutdownDevice("A"), let b = store.shutdownDevice("B") else {
      throw failure("Different devices may shut down independently.")
    }
    try await eventually { await probe.calls.count == 2 }
    try require(store.shuttingDownDeviceIDs == ["A", "B"], "Track each shutdown separately.")
    fixture.devices = [device("A"), device("B", state: .booted)]
    await probe.finish("A")
    try require(await a.value, "Confirm the first device independently.")
    try require(
      store.shuttingDownDeviceIDs == ["B"]
        && store.discovery?.devices.last?.state == .shuttingDown,
      "One completed shutdown cannot clear another device's progress.")
    fixture.devices = [device("A"), device("B")]
    await probe.finish("B")
    try require(await b.value && store.shuttingDownDeviceIDs.isEmpty, "Complete both shutdowns.")
  }

  private static func shutdownWithOverlappingRefresh() async throws {
    let fixture = Inventory([device("A", state: .booted)])
    let probe = PowerProbe()
    let store = SimulatorStore(
      discover: fixture.scan, shutdown: { try await probe.run($0) }, boot: { _ in })
    await store.refresh()
    guard let shutdown = store.shutdownDevice("A") else { throw failure("Begin shutdown.") }
    try await eventually { await probe.calls == ["A"] }
    fixture.deferNextScan = true
    let refresh = Task { await store.refresh() }
    try await eventually { fixture.pendingScan != nil }
    await probe.finish("A")
    fixture.devices = [device("A")]
    fixture.finishScan(with: [device("A", state: .booted)])
    _ = await refresh.value
    try require(await shutdown.value, "Do not use a scan begun before shutdown completed.")
    try require(
      fixture.calls == 3 && store.selectedDevice?.state == .shutdown,
      "Read a new inventory after the overlapping scan.")
  }

  private static func shutdownFailuresAndCancellation() async throws {
    for canceled in [false, true] {
      let fixture = Inventory([device("A", state: .booted)])
      let store = SimulatorStore(
        discover: fixture.scan,
        shutdown: { _ in
          if canceled { throw CancellationError() }
          throw failure("Shutdown denied")
        }, boot: { _ in })
      await store.refresh()
      guard let job = store.shutdownDevice("A") else { throw failure("Begin shutdown.") }
      try require(
        await job.value == false && store.shuttingDownDeviceIDs.isEmpty,
        "Failure and cancellation must not report success or leave progress stuck.")
      try require(
        store.selectedDevice?.state == .booted, "A failed command cannot imply Shutdown.")
      if canceled {
        try require(store.shutdownError == nil, "Keep cancellation silent.")
      } else {
        try require(
          store.shutdownError?.contains("iPhone A") == true
            && store.shutdownError?.contains("Shutdown denied") == true,
          "Identify the affected simulator and preserve the command's diagnostic.")
      }
    }
    let fixture = Inventory([device("A", state: .booted)])
    let probe = PowerProbe()
    let store = SimulatorStore(
      discover: fixture.scan, shutdown: { try await probe.run($0) }, boot: { _ in })
    await store.refresh()
    guard let job = store.shutdownDevice("A") else { throw failure("Begin shutdown.") }
    job.cancel()
    try require(
      await job.value == false && store.shutdownError == nil, "Cancel before invoking a command.")
    try require(await probe.calls.isEmpty, "An already canceled request cannot invoke shutdown.")
  }

  private static func confirmedShutdownAndInvalidStates() async throws {
    for state in [SimulatorState.shutdown, .booting, .shuttingDown, .unknown] {
      let fixture = Inventory([device("A", state: state)])
      let store = SimulatorStore(
        discover: fixture.scan, shutdown: { _ in throw failure("Unexpected shutdown") },
        boot: { _ in })
      await store.refresh()
      try require(
        store.shutdownDevice("A") == nil && store.shutdownDevice("missing") == nil,
        "Only a known, fully booted device can shut down.")
    }
    for refreshed in [[device("A", state: .booted)], [device("A", state: .shuttingDown)], []] {
      let fixture = Inventory([device("A", state: .booted)])
      let probe = PowerProbe()
      let store = SimulatorStore(
        discover: fixture.scan, shutdown: { try await probe.run($0) }, boot: { _ in })
      await store.refresh()
      guard let job = store.shutdownDevice("A") else { throw failure("Begin shutdown.") }
      try await eventually { await probe.calls == ["A"] }
      fixture.devices = refreshed
      await probe.finish("A")
      try require(
        await job.value == false,
        "Command success alone does not confirm a stopped or missing simulator.")
    }
  }

  private static func mutuallyExclusivePowerOperations() async throws {
    let fixture = Inventory([device("A")])
    let probe = PowerProbe()
    let store = SimulatorStore(
      discover: fixture.scan, shutdown: { _ in throw failure("Do not interrupt startup") },
      boot: { try await probe.run($0) })
    await store.refresh()
    let boot = Task { await store.startDevice("A") }
    try await eventually { await probe.calls == ["A"] }
    fixture.devices = [device("A", state: .booted)]
    await store.refresh()
    try require(
      store.selectedDevice?.state == .booting && store.shutdownDevice("A") == nil,
      "A Booted snapshot cannot allow shutdown or app installs before boot readiness finishes.")
    await probe.finish("A")
    try require(
      await boot.value && store.selectedDevice?.state == .booted,
      "Expose readiness after bootstatus completes.")
  }
}
