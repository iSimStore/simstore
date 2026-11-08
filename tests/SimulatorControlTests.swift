import Foundation

@main
struct SimulatorControlTests {
  @MainActor
  static func main() async {
    await TestSuite.run(cases)
  }

  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("bootCommand", bootCommand),
      .init("commandFailure", commandFailure),
      .init("cancelledBeforeBoot", cancelledBeforeBoot),
      .init("cancelledDuringBoot", cancelledDuringBoot),
      .init("shutdownCommand", shutdownCommand),
      .init("shutdownFailureAndCancellation", shutdownFailureAndCancellation),
      .init("presentationRequests", presentationRequests),
    ]
  }

  @MainActor
  static func bootCommand() async throws {
    let deviceID = "0E67E0B9-7C5B-44E6-954C-B2AB9B955E9F"
    try await SimulatorControl.boot(deviceID) { executable, arguments in
      try require(executable == "/usr/bin/xcrun", "Boot should use the selected Xcode's tools.")
      try require(
        arguments == ["simctl", "bootstatus", deviceID, "-b"],
        "Boot should target the exact selected UDID and wait until it is ready.")
      try require(!Thread.isMainThread, "Waiting for boot must not block the main thread.")
      return Data()
    }
  }

  static func commandFailure() async throws {
    let expected = failure("Simulator runtime is unavailable.")
    do {
      try await SimulatorControl.boot("DEVICE") { _, _ in throw expected }
    } catch {
      try require(
        (error as NSError) == expected,
        "A failed boot should preserve the command's diagnostic instead of reporting success.")
      return
    }
    throw failure("A failed boot command must throw.")
  }

  static func cancelledBeforeBoot() async throws {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await SimulatorControl.boot("DEVICE") { _, _ in
        throw failure("An already cancelled request must not invoke simctl.")
      }
    }
    do {
      try await task.value
    } catch is CancellationError {
      return
    }
    throw failure("An already cancelled boot must throw CancellationError.")
  }

  static func cancelledDuringBoot() async throws {
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    let task = Task {
      try await SimulatorControl.boot("DEVICE") { _, _ in
        started.signal()
        try require(
          finish.wait(timeout: .now() + 5) == .success,
          "The test must release the simulated boot command.")
        return Data()
      }
    }
    let didStart = await Task.detached {
      waitForCommand(started)
    }.value
    task.cancel()
    finish.signal()
    try require(didStart, "The command must begin before testing in-flight cancellation.")
    do {
      try await task.value
    } catch is CancellationError {
      return
    }
    throw failure("Cancellation during boot must not be reported as success.")
  }

  static func waitForCommand(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 5) == .success
  }

  static func shutdownCommand() async throws {
    let id = "0E67E0B9-7C5B-44E6-954C-B2AB9B955E9F"
    try await SimulatorControl.shutdown(id) { executable, arguments in
      try require(executable == Command.xcrunExecutable, "Use the common xcrun wrapper.")
      try require(
        arguments == ["simctl", "shutdown", id], "Shut down only the exact requested UDID.")
      try require(!Thread.isMainThread, "Shutdown must not block the UI.")
      return Data()
    }
  }

  static func shutdownFailureAndCancellation() async throws {
    let expected = failure("Shutdown failed")
    do {
      try await SimulatorControl.shutdown("DEVICE") { _, _ in throw expected }
      throw failure("Shutdown failure must throw.")
    } catch {
      try require((error as NSError) == expected, "Preserve the shutdown diagnostic.")
    }
    let canceled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await SimulatorControl.shutdown("DEVICE") { _, _ in
        throw failure("An already canceled shutdown must not invoke simctl.")
      }
    }
    do {
      try await canceled.value
      throw failure("An already canceled shutdown must throw.")
    } catch is CancellationError {}
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    let task = Task {
      try await SimulatorControl.shutdown("DEVICE") { _, _ in
        started.signal()
        try require(finish.wait(timeout: .now() + 5) == .success, "Release the shutdown command.")
        return Data()
      }
    }
    let didStart = await Task.detached { waitForCommand(started) }.value
    task.cancel()
    finish.signal()
    try require(didStart, "Wait for the shutdown command before canceling.")
    do {
      try await task.value
      throw failure("Canceled shutdown must not be reported as successful.")
    } catch is CancellationError {}
  }

  static func presentationRequests() throws {
    let managerURL = URL(
      fileURLWithPath: "/Applications/Selected Xcode.app/Contents/Applications/DeviceHub.app")
    let deviceID = "target & other=invalid"
    let hub = try SimulatorPresenter.request(
      deviceID: deviceID, manager: ("Device Hub", managerURL))
    try require(
      hub.applicationURL == managerURL && hub.arguments.isEmpty && hub.urls.count == 1,
      "Open Device Hub from the selected Xcode.")
    let url = URLComponents(url: hub.urls[0], resolvingAgainstBaseURL: false)!
    try require(
      url.scheme == "devices" && url.host == "device" && url.path == "/open",
      "Use the device-opening route.")
    try require(
      url.queryItems == [URLQueryItem(name: "id", value: deviceID)],
      "Encode the exact target as one query parameter.")
    let simulatorURL = URL(
      fileURLWithPath:
        "/Applications/Selected Xcode.app/Contents/Developer/Applications/Simulator.app")
    let legacy = try SimulatorPresenter.request(
      deviceID: deviceID, manager: ("Simulator", simulatorURL))
    try require(
      legacy.applicationURL == simulatorURL && legacy.urls.isEmpty
        && legacy.arguments == ["-CurrentDeviceUDID", deviceID],
      "Pass the target device to legacy Simulator without shell expansion.")
    do {
      _ = try SimulatorPresenter.request(deviceID: deviceID, manager: nil)
    } catch { return }
    throw failure("A missing simulator application must be reported.")
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  static func failure(_ message: String) -> NSError {
    NSError(
      domain: "SimulatorControlTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
