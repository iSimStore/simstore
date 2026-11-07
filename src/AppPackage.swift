import CryptoKit
import Foundation
import MachO

enum AppPackage {
  static func verify(_ archive: URL, version: CatalogVersion) throws {
    try verify(archive, size: version.size, sha256: version.sha256)
  }

  static func verify(_ archive: URL, size expectedSize: Int64, sha256: String) throws {
    let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard size.map(Int64.init) == expectedSize else { throw Failure.sizeMismatch }
    let file = try FileHandle(forReadingFrom: archive)
    defer { try? file.close() }
    var hash = SHA256()
    while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      try Task.checkCancellation()
      hash.update(data: chunk)
    }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == sha256 else { throw Failure.checksumMismatch }
  }

  static func extract(
    _ archive: URL, to directory: URL, command: Command.Runner = Command.run
  ) throws -> URL {
    let listing = try command("/usr/bin/tar", ["-tjf", archive.path])
    let paths = String(decoding: listing, as: UTF8.self).split(separator: "\n")
    guard !paths.isEmpty,
      paths.allSatisfy({ path in
        !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
      })
    else { throw Failure.invalidArchive }
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    // Keep bsdtar's default protections against dot-dot paths and symlink traversal.
    _ = try command(
      "/usr/bin/tar",
      [
        "-xjf", archive.path, "-C", directory.path, "--no-same-owner", "--no-same-permissions",
      ])
    try Task.checkCancellation()
    let roots = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard roots.count == 1, let app = roots.first, app.pathExtension == "app",
      try app.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
      try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
    else { throw Failure.invalidArchive }
    return app
  }

  static func validate(_ bundle: URL, app: CatalogApp, version: CatalogVersion) throws {
    let root = bundle.resolvingSymlinksInPath().standardizedFileURL
    let info = try bundleInfo(root)
    guard info["CFBundleIdentifier"] as? String == app.bundleID,
      let actualVersion = info["CFBundleShortVersionString"] as? String,
      CatalogVersionNumber(actualVersion) == CatalogVersionNumber(version.version)
    else { throw Failure.wrongApp }
    let mainExecutable = try executable(in: root, info: info)
    try validatePlatform(info)
    let validator = BundleValidator(
      platform: UInt32(PLATFORM_IOSSIMULATOR), invalidBundle: Failure.invalidBundle,
      binaryFailure: { error in
        if error is MachOValidation.Failure { return Failure.unsupportedBinary }
        return error
      })
    try validator.validate(
      root, required: [mainExecutable], isExecutable: { $0 == mainExecutable },
      nestedExecutable: { path in
        guard ["app", "appex", "framework"].contains(path.pathExtension) else { return nil }
        let info = try bundleInfo(path)
        let executable = try executable(in: path, info: info)
        if path.pathExtension != "framework" { try validatePlatform(info) }
        return executable
      })
  }

  private static func bundleInfo(_ bundle: URL) throws -> [String: Any] {
    let candidates = [
      bundle.appending(path: "Info.plist"), bundle.appending(path: "Resources/Info.plist"),
    ]
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    else { throw Failure.invalidBundle }
    return try BundleValidator.info(at: path, invalidBundle: Failure.invalidBundle)
  }

  private static func executable(in bundle: URL, info: [String: Any]) throws -> URL {
    try BundleValidator.executable(
      in: bundle, named: info["CFBundleExecutable"], invalidBundle: Failure.invalidBundle)
  }

  private static func validatePlatform(_ info: [String: Any]) throws {
    guard info["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneSimulator"],
      let minimum = info["MinimumOSVersion"] as? String, CatalogVersionNumber(minimum) != nil
    else { throw Failure.invalidBundle }
  }

  enum Failure: LocalizedError {
    case sizeMismatch, checksumMismatch, invalidArchive, wrongApp, invalidBundle, unsupportedBinary

    var errorDescription: String? {
      switch self {
      case .sizeMismatch:
        String(localized: "The downloaded file has the wrong size. Try downloading it again.")
      case .checksumMismatch:
        String(localized: "The downloaded file failed its SHA-256 check. Try downloading it again.")
      case .invalidArchive:
        String(localized: "The download must contain exactly one app bundle with safe file paths.")
      case .wrongApp:
        String(localized: "The downloaded app does not match the selected app and version.")
      case .invalidBundle:
        String(localized: "The downloaded app bundle is invalid.")
      case .unsupportedBinary:
        String(localized: "The app must contain only arm64 iOS Simulator binaries.")
      }
    }
  }
}
