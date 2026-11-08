import Foundation

@main
struct CommandTests {
  @MainActor
  static func main() async {
    await TestSuite.run(cases)
  }

  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("argumentBytes", argumentBytes),
      .init("processFailures", processFailures),
      .init("wrapperArguments", wrapperArguments),
      .init("wrapperFailures", wrapperFailures),
      .init("cancelledBeforeLaunch", cancelledBeforeLaunch),
      .init("cancelledAfterLaunch", cancelledAfterLaunch),
    ]
  }

  static func argumentBytes() throws {
    let value = "A simulator 名称\n'quoted' ; $(echo unexpected) $HOME \\"
    let output = try Command.run("/usr/bin/printf", arguments: ["%s", value])
    try require(
      output == Data(value.utf8), "Arguments must reach the process without shell expansion.")
  }

  static func processFailures() throws {
    for (script, status, diagnostic) in [
      ("printf 'simulator tools unavailable' >&2; exit 9", 9, "simulator tools unavailable"),
      ("exit 7", 7, ""),
    ] {
      let error: NSError
      do {
        _ = try Command.run("/bin/sh", arguments: ["-c", script])
        throw failure("A nonzero exit must fail instead of returning output.")
      } catch let caught { error = caught as NSError }
      try require(error.domain == "Command" && error.code == status, "Preserve the exit status.")
      if diagnostic.isEmpty {
        try require(
          error.localizedDescription.contains("sh")
            && error.localizedDescription.contains(String(status)),
          "An empty diagnostic must identify the executable and exit status.")
      } else {
        try require(error.localizedDescription == diagnostic, "Preserve the command's stderr.")
      }
    }
  }

  static func wrapperArguments() throws {
    let output = Data("tool output".utf8)
    let arguments = ["--set", "/tmp/Devices with spaces", "list", "devices", "--json"]
    let xcrunOutput = try Command.xcrun(arguments) { executable, actual in
      try require(executable == "/usr/bin/xcrun", "Use the system Xcode tool resolver.")
      try require(actual == arguments, "Forward xcrun arguments without changing their boundaries.")
      return output
    }
    let simctlOutput = try Command.simctl(arguments) { executable, actual in
      try require(executable == "/usr/bin/xcrun", "Resolve simctl through xcrun.")
      try require(actual == ["simctl"] + arguments, "Prefix the simulator tool exactly once.")
      return output
    }
    try require(xcrunOutput == output && simctlOutput == output, "Return the original tool output.")
  }

  static func wrapperFailures() throws {
    let expected = failure("Selected toolchain is unavailable.")
    let runner: Command.Runner = { _, _ in throw expected }
    let wrappers: [([String], Command.Runner) throws -> Data] = [Command.xcrun, Command.simctl]
    for wrapper in wrappers {
      do {
        _ = try wrapper(["list"], runner)
      } catch {
        try require((error as NSError) == expected, "Forward the original tool error unchanged.")
        continue
      }
      throw failure("A failed tool command must throw.")
    }
  }

  static func cancelledBeforeLaunch() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appending(component: "must-not-exist")
    let task = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return try Command.run("/usr/bin/touch", arguments: [marker.path])
    }
    let result = await task.result
    try require(
      !FileManager.default.fileExists(atPath: marker.path),
      "An already canceled task must not launch a child process.")
    guard case .failure(is CancellationError) = result else {
      throw failure("Cancellation before launch must throw CancellationError.")
    }
  }

  static func cancelledAfterLaunch() async throws {
    for status in [0, 9] {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let started = directory.appending(component: "started")
      let release = directory.appending(component: "release")
      let task = Task.detached {
        try Command.run(
          "/bin/sh",
          arguments: [
            "-c",
            """
            printf started > "$1"
            attempts=0
            while [ ! -f "$2" ]; do
              attempts=$((attempts + 1))
              if [ "$attempts" -ge 300 ]; then exit 70; fi
              /bin/sleep 0.01
            done
            printf 'completed command'
            exit "$3"
            """,
            "CommandTests", started.path, release.path, String(status),
          ])
      }
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(3))
      while !FileManager.default.fileExists(atPath: started.path) && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      let didStart = FileManager.default.fileExists(atPath: started.path)
      task.cancel()
      try Data().write(to: release)
      let result = await task.result
      try require(didStart, "Start the child before canceling its owning task.")
      switch result {
      case .success(let output):
        try require(
          status == 0 && output == Data("completed command".utf8),
          "An in-flight command must finish and return its output after task cancellation.")
      case .failure(let error):
        let error = error as NSError
        try require(
          status != 0 && error.domain == "Command" && error.code == status
            && error.localizedDescription == "completed command",
          "An in-flight failure must preserve the process result after task cancellation.")
      }
    }
  }

  static func temporaryDirectory() throws -> URL {
    let directory = URL.temporaryDirectory.appending(component: "CommandTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  static func failure(_ message: String) -> NSError {
    NSError(domain: "CommandTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
