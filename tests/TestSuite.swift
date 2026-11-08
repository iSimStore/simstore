import Foundation

@MainActor
enum TestSuite {
  struct Case {
    let name: String
    let action: @MainActor ([String]) async throws -> Void

    init(_ name: String, _ action: @escaping @MainActor () async throws -> Void) {
      self.name = name
      self.action = { _ in try await action() }
    }

    init(_ name: String, arguments action: @escaping @MainActor ([String]) async throws -> Void) {
      self.name = name
      self.action = action
    }
  }

  static func run(_ cases: [Case]) async {
    guard !cases.isEmpty, Set(cases.map(\.name)).count == cases.count,
      cases.allSatisfy({
        $0.name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
      })
    else { usageError("Test cases must have unique, nonempty identifier names.") }
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--list-tests" {
      guard arguments.count == 1 else { usageError("--list-tests takes no arguments.") }
      for test in cases { print(test.name) }
      return
    }
    let selected: [Case]
    if arguments.first == "--case" {
      guard arguments.count >= 2, let test = cases.first(where: { $0.name == arguments[1] }) else {
        usageError("--case requires a known test name.")
      }
      selected = [test]
      arguments.removeFirst(2)
    } else {
      guard arguments.first?.hasPrefix("--") != true else { usageError("Unknown test option.") }
      selected = cases
    }
    var failed = 0
    for test in selected {
      do {
        try await test.action(arguments)
        print("PASS: \(test.name)")
      } catch {
        failed += 1
        FileHandle.standardError.write(Data("FAIL: \(test.name): \(error)\n".utf8))
      }
    }
    print("\(selected.count - failed) passed; \(failed) failed; \(selected.count) total")
    if failed > 0 { exit(EXIT_FAILURE) }
  }

  private static func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
  }
}
