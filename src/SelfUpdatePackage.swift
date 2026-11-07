import Foundation
import MachO

enum SelfUpdatePackage {
  static func validate(
    _ application: URL, release: SelfUpdateRelease, bundleID: String,
    os: String = currentOS
  ) throws {
    let root = application.standardizedFileURL
    guard application.lastPathComponent == "SimStore.app",
      try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
      release.isCompatible(with: os)
    else { throw SelfUpdateError.incompatiblePackage }
    let info = try info(at: root)
    let build = try SelfUpdateBuild.read(at: root)
    guard info["CFBundlePackageType"] as? String == "APPL",
      info["CFBundleIdentifier"] as? String == bundleID,
      build.version == release.version, build.build == release.build,
      build.revision == release.revision, build.time == release.time, !build.dirty,
      info["LSMinimumSystemVersion"] as? String == release.minOS
    else { throw SelfUpdateError.wrongApplication }
    let main = try BundleValidator.executable(
      in: root.appending(path: "Contents/MacOS"), named: info["CFBundleExecutable"],
      invalidBundle: SelfUpdateError.wrongApplication)
    let helper = root.appending(path: "Contents/Helpers/SimStoreUpdater")
    let required = Set([main, helper].map { $0.resolvingSymlinksInPath().standardizedFileURL })
    let validator = BundleValidator(
      platform: UInt32(PLATFORM_MACOS), invalidBundle: SelfUpdateError.wrongApplication,
      binaryFailure: { _ in SelfUpdateError.incompatiblePackage })
    try validator.validate(
      root, required: required, isExecutable: { required.contains($0) },
      validateMinimum: { resolved, minimum in
        guard let declaredMinimum = CatalogVersionNumber(release.minOS), minimum <= declaredMinimum,
          resolved != main || minimum == declaredMinimum
        else { throw SelfUpdateError.incompatiblePackage }
      })
  }

  static var currentOS: String {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
  }

  static func info(at application: URL) throws -> [String: Any] {
    try BundleValidator.info(
      at: application.appending(path: "Contents/Info.plist"),
      invalidBundle: SelfUpdateError.wrongApplication)
  }
}
