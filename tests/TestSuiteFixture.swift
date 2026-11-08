import Foundation

@main
struct TestSuiteFixture {
  @MainActor
  static func main() async {
    await TestSuite.run([
      .init("first") { print("ran first") },
      .init("failure") {
        throw NSError(
          domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected failure"])
      },
      .init("last") { print("ran last") },
    ])
  }
}
