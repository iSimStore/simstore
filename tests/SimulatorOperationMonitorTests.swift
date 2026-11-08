import AppKit
import SwiftUI

@main
@MainActor
struct SimulatorOperationMonitorTests {
  @MainActor
  static func main() async {
    await TestSuite.run(cases)
  }

  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("finishedAndReplacedOperations", finishedAndReplacedOperations),
      .init("keepWaitingAndSeparateDevices", keepWaitingAndSeparateDevices),
      .init("powerStateChanges", powerStateChanges),
      .init("failedScanBeforeTimeout", failedScanBeforeTimeout),
      .init("nativeAlertActions", nativeAlertActions),
      .init("shutdownAfterDiscoveryFailure", shutdownAfterDiscoveryFailure),
    ]
  }

  private static func device(_ id: String, state: SimulatorState = .booted) -> SimulatorDevice {
    SimulatorDevice(id: id, name: "iPhone \(id)", runtime: "27.0", state: state)
  }

  private static func finishedAndReplacedOperations() async throws {
    let delay = MonitorDelay()
    let monitor = SimulatorOperationMonitor(wait: { try await delay.wait() })
    let first = monitor.begin(on: device("A"))
    try await eventually { await delay.count == 1 }
    try require(monitor.prompt == nil, "Do not prompt before the timeout.")
    monitor.end(first)
    let second = monitor.begin(on: device("A"))
    try await eventually { await delay.count == 2 }
    await delay.release(0)
    await delay.release(1)
    try await eventually { monitor.prompt?.id == second }
    monitor.end(first)
    try require(monitor.prompt?.id == second, "A late completion cannot dismiss a newer operation.")
    monitor.end(second)
    try require(monitor.prompt == nil, "Completing an operation must dismiss its prompt.")
  }

  private static func keepWaitingAndSeparateDevices() async throws {
    let delay = MonitorDelay()
    let monitor = SimulatorOperationMonitor(wait: { try await delay.wait() })
    let first = monitor.begin(on: device("A"))
    try await eventually { await delay.count == 1 }
    let repeated = monitor.begin(on: device("A"))
    try await eventually { await delay.count == 2 }
    let other = monitor.begin(on: device("B"))
    try await eventually { await delay.count == 3 }
    await delay.release(0)
    try await eventually { monitor.prompt?.id == first }
    let dismissed = monitor.prompt!
    monitor.keepWaiting(dismissed)
    await delay.release(1)
    await delay.release(2)
    try await eventually { monitor.prompt?.id == other }
    monitor.keepWaiting(dismissed)
    try require(monitor.prompt?.id == other, "A stale dismissal cannot mute another simulator.")
    monitor.end(first)
    monitor.end(repeated)
    monitor.end(other)
    let retry = monitor.begin(on: device("A"))
    try await eventually { await delay.count == 4 }
    await delay.release(3)
    try await eventually { monitor.prompt?.id == retry }
    monitor.end(retry)
  }

  private static func powerStateChanges() async throws {
    let delay = MonitorDelay()
    let monitor = SimulatorOperationMonitor(wait: { try await delay.wait() })
    let first = monitor.begin(on: device("A"))
    try await eventually { await delay.count == 1 }
    let other = monitor.begin(on: device("B"))
    try await eventually { await delay.count == 2 }
    monitor.synchronize(with: [device("A", state: .shuttingDown), device("B")])
    await delay.release(0)
    await delay.release(1)
    try await eventually { monitor.prompt?.id == other }
    monitor.end(first)
    monitor.synchronize(with: [])
    try require(monitor.prompt == nil, "A stopped or removed device must not retain a prompt.")
    let stopped = monitor.begin(on: device("C", state: .shutdown))
    monitor.end(stopped)
    try require(monitor.prompt == nil, "Do not monitor commands on a stopped simulator.")
  }

  private static func failedScanBeforeTimeout() async throws {
    let delay = MonitorDelay()
    let monitor = SimulatorOperationMonitor(wait: { try await delay.wait() })
    let operation = monitor.begin(on: device("A"))
    try await eventually { await delay.count == 1 }
    monitor.synchronize(with: nil)
    await delay.release(0)
    try await eventually { monitor.prompt?.id == operation }
    monitor.synchronize(with: nil)
    try require(
      monitor.prompt?.id == operation, "A failed scan cannot dismiss an existing recovery prompt.")
    monitor.synchronize(with: [])
    try require(monitor.prompt == nil, "A successful empty scan must still remove missing devices.")
  }

  private static func nativeAlertActions() async throws {
    NSApplication.shared.setActivationPolicy(.regular)
    let monitor = SimulatorOperationMonitor(wait: {})
    var shutdowns: [String] = []
    let host = NSHostingView(
      rootView: Text("Simulator recovery test")
        .frame(width: 600, height: 240)
        .modifier(
          SimulatorRecoveryAlert(
            monitor: monitor,
            shutdown: {
              shutdowns.append($0)
              return true
            })))
    let window = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 600, height: 240),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    let first = monitor.begin(on: device("A"))
    try await eventually { nativeButton("Keep Waiting") != nil }
    try require(
      visibleButtonTitles() == ["Keep Waiting", "Shut Down"],
      "Show exactly the two recovery actions, without template buttons, help, or suppression controls."
    )
    nativeButton("Keep Waiting")!.performClick(nil)
    try await eventually { monitor.prompt == nil && nativeButton("Keep Waiting") == nil }
    try require(shutdowns.isEmpty, "Keep Waiting must not shut down the simulator.")
    monitor.end(first)

    let second = monitor.begin(on: device("A"))
    try await eventually { nativeButton("Shut Down") != nil }
    nativeButton("Shut Down")!.performClick(nil)
    try await eventually { shutdowns == ["A"] && monitor.prompt == nil }
    monitor.end(second)
    try await eventually { nativeButton("Shut Down") == nil }

    let recovered = monitor.begin(on: device("B"))
    try await eventually { nativeButton("Keep Waiting") != nil }
    monitor.end(recovered)
    try await eventually { nativeButton("Keep Waiting") == nil }
    try require(shutdowns == ["A"], "A recovered operation must dismiss without shutting down.")

    let completing = monitor.begin(on: device("B"))
    try await eventually { nativeTextContains("iPhone B") }
    let queued = monitor.begin(on: device("C"))
    try await Task.sleep(for: .milliseconds(100))
    monitor.end(completing)
    try await eventually { nativeTextContains("iPhone C") }
    nativeButton("Shut Down")!.performClick(nil)
    try await eventually { shutdowns == ["A", "C"] }
    monitor.end(queued)
    try await eventually { nativeButton("Shut Down") == nil }

    let details = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.titled],
      backing: .buffered, defer: false)
    details.isReleasedWhenClosed = false
    window.beginSheet(details, completionHandler: { _ in })
    let covered = monitor.begin(on: device("D"))
    try await eventually { nativeButton("Keep Waiting") != nil }
    nativeButton("Keep Waiting")!.performClick(nil)
    try await eventually { monitor.prompt == nil && nativeButton("Keep Waiting") == nil }
    monitor.end(covered)
    try require(
      window.attachedSheet === details, "A recovery prompt must preserve the app details sheet.")
    window.endSheet(details)
    details.orderOut(nil)
    details.close()
  }

  private static func shutdownAfterDiscoveryFailure() async throws {
    @MainActor
    final class DiscoveryState {
      var shouldFail = false
      var rejectsShutdown = true
      var shutdownCalls: [String] = []
    }
    let state = DiscoveryState()
    let target = device("A")
    let simulators = SimulatorStore(
      discover: {
        if state.shouldFail { throw failure("Temporary discovery failure") }
        return SimulatorDiscovery(
          developerDirectory: URL(fileURLWithPath: "/Xcode.app/Contents/Developer"),
          devices: [target])
      },
      shutdown: { id in await MainActor.run { state.shutdownCalls.append(id) } },
      boot: { _ in })
    await simulators.refresh()
    let monitor = SimulatorOperationMonitor(wait: {})
    let host = NSHostingView(
      rootView: Text("Recovery during failed discovery")
        .frame(width: 600, height: 240)
        .modifier(
          SimulatorRecoveryAlert(
            monitor: monitor,
            shutdown: { id in
              guard !state.rejectsShutdown, simulators.shutdownDevice(id) != nil else {
                return false
              }
              monitor.stop(deviceID: id)
              return true
            })))
    let window = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 600, height: 240),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    let operation = monitor.begin(on: target)
    defer { monitor.end(operation) }
    try await eventually { nativeButton("Shut Down") != nil }
    state.shouldFail = true
    await simulators.refresh()
    monitor.synchronize(with: simulators.discovery?.devices)
    let original = monitor.prompt
    nativeButton("Shut Down")!.performClick(nil)
    try await eventually { nativeTextContains("Couldn’t Shut Down Simulator") }
    try require(
      state.shutdownCalls.isEmpty && monitor.prompt == original,
      "A rejected request must show feedback and preserve recovery without muting the device.")
    try require(
      visibleButtonTitles() == ["Keep Waiting", "Shut Down"],
      "The failure prompt must retain both waiting and retry actions.")
    state.rejectsShutdown = false
    nativeButton("Shut Down")!.performClick(nil)
    try await eventually { state.shutdownCalls == [target.id] }
    try await eventually { nativeButton("Shut Down") == nil }
    try require(
      monitor.prompt == nil && simulators.refreshError != nil,
      "The retained inventory permits shutdown recovery even while discovery is unavailable.")
  }

  private static func nativeTextContains(_ text: String) -> Bool {
    func contains(in view: NSView) -> Bool {
      if let field = view as? NSTextField, field.stringValue.contains(text) { return true }
      return view.subviews.contains { contains(in: $0) }
    }
    return NSApplication.shared.windows.filter(\.isVisible).contains {
      $0.contentView.map { contains(in: $0) } ?? false
    }
  }

  private static func visibleButtonTitles() -> [String] {
    func titles(in view: NSView) -> [String] {
      guard !view.isHiddenOrHasHiddenAncestor else { return [] }
      if let button = view as? NSButton { return [button.title] }
      return view.subviews.flatMap { titles(in: $0) }
    }
    return NSApplication.shared.windows.filter(\.isVisible).flatMap {
      $0.contentView.map { titles(in: $0) } ?? []
    }.sorted()
  }

  private static func nativeButton(_ title: String) -> NSButton? {
    func find(in view: NSView) -> NSButton? {
      if let button = view as? NSButton, button.title == title { return button }
      return view.subviews.lazy.compactMap { find(in: $0) }.first
    }
    return NSApplication.shared.windows.filter(\.isVisible).lazy.compactMap {
      $0.contentView.flatMap { find(in: $0) }
    }.first
  }

  private static func eventually(_ predicate: () async -> Bool, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await predicate()) {
      guard ContinuousClock.now < deadline else {
        throw failure("Timed out waiting for recovery state at line \(line).")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  private static func failure(_ message: String) -> NSError {
    NSError(
      domain: "OperationMonitorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

private actor MonitorDelay {
  private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
  private(set) var count = 0

  func wait() async throws {
    let index = count
    count += 1
    await withCheckedContinuation { pending[index] = $0 }
    try Task.checkCancellation()
  }

  func release(_ index: Int) {
    pending.removeValue(forKey: index)?.resume()
  }
}
