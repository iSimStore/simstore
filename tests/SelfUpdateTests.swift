import Foundation

@main
struct SelfUpdateTests {
  @MainActor
  static func main() async {
    await TestSuite.run(
      [
        .init("model", SelfUpdateModelTests.run),
        .init("model.largeVersionComponents", SelfUpdateModelTests.largeVersionComponents),
        .init("package", SelfUpdatePackageTests.run),
        .init("package.symlinkBoundaries", SelfUpdatePackageTests.symlinkBoundaries),
        .init("view", SelfUpdateViewTests.run),
      ] + SelfUpdateInstallerTests.cases + SelfUpdateStoreTests.cases)
  }
}
