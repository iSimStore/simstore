import Foundation

struct SelfUpdateBuild: Equatable, Sendable {
  let version: String
  let build: Int
  let revision: String
  let time: Int64
  let dirty: Bool

  var displayVersion: String { "\(version) (\(build))" }
  var description: String {
    let value = build == 0 ? version : "\(version)-\(build)-g\(revision.prefix(7))"
    return dirty ? "\(value)-dirty" : value
  }

  static func read(at application: URL) throws -> SelfUpdateBuild {
    let data = try Data(contentsOf: application.appending(path: "Contents/Info.plist"))
    let info = try PropertyListDecoder().decode(BundleVersion.self, from: data)
    guard validVersion(info.version), let build = Int(info.build), build >= 0,
      String(build) == info.build, validRevision(info.revision), info.time >= 0
    else { throw SelfUpdateError.invalidVersion }
    return Self(
      version: info.version, build: build, revision: info.revision, time: info.time,
      dirty: info.dirty)
  }

  private struct BundleVersion: Decodable {
    let version: String
    let build: String
    let revision: String
    let time: Int64
    let dirty: Bool

    enum CodingKeys: String, CodingKey {
      case version = "CFBundleShortVersionString"
      case build = "CFBundleVersion"
      case revision = "SimStoreRevision"
      case time = "SimStoreCommitTime"
      case dirty = "SimStoreSourceDirty"
    }
  }
}

struct SelfUpdateRelease: Codable, Equatable, Sendable {
  let tag: String
  let version: String
  let build: Int
  let minOS: String
  let revision: String
  let time: Int64
  let size: Int64
  let sha256: String

  var isNightly: Bool { tag == "latest" }
  var displayVersion: String { "\(version) (\(build))" }

  func isCompatible(with os: String) -> Bool {
    guard let minimum = CatalogVersionNumber(minOS), let os = CatalogVersionNumber(os) else {
      return false
    }
    return os >= minimum
  }

  func isNewer(than current: SelfUpdateBuild) -> Bool {
    guard let version = CatalogVersionNumber(version),
      let installed = CatalogVersionNumber(current.version)
    else { return false }
    return version > installed || (version == installed && build > current.build)
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    tag = try values.decode(String.self, forKey: .tag)
    version = try values.decode(String.self, forKey: .version)
    build = try values.decode(Int.self, forKey: .build)
    minOS = try values.decode(String.self, forKey: .minOS)
    revision = try values.decode(String.self, forKey: .revision)
    time = try values.decode(Int64.self, forKey: .time)
    size = try values.decode(Int64.self, forKey: .size)
    sha256 = try values.decode(String.self, forKey: .sha256)
    guard validVersion(version), build >= 0,
      tag == "latest" || (tag == version && build == 0),
      CatalogVersionNumber(minOS) != nil,
      minOS.range(of: #"^[1-9][0-9]*(?:\.[0-9]+){0,2}$"#, options: .regularExpression) != nil,
      validRevision(revision), time >= 0, size > 0,
      sha256.count == 64, sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    else { throw SelfUpdateError.invalidIndex }
  }
}

struct SelfUpdateIndex: Decodable, Sendable {
  let versions: [SelfUpdateRelease]

  static func decode(_ data: Data) throws -> SelfUpdateIndex {
    do {
      let index = try JSONDecoder().decode(Self.self, from: data)
      guard index.versions.filter(\.isNightly).count == 1,
        Set(index.versions.map(\.tag)).count == index.versions.count
      else { throw SelfUpdateError.invalidIndex }
      return index
    } catch {
      throw SelfUpdateError.invalidIndex
    }
  }

  func recommendedUpdate(from current: SelfUpdateBuild, os: String) -> SelfUpdateRelease? {
    let compatible = versions.compactMap {
      release -> (release: SelfUpdateRelease, number: CatalogVersionNumber)? in
      guard release.isCompatible(with: os), let number = CatalogVersionNumber(release.version)
      else {
        return nil
      }
      return (release: release, number: number)
    }
    let stable = compatible.filter { !$0.release.isNightly }.max { $0.number < $1.number }?.release
    if let stable, stable.isNewer(than: current) { return stable }
    return compatible.first { $0.release.isNightly && $0.release.isNewer(than: current) }?.release
  }
}

enum SelfUpdateError: LocalizedError {
  case invalidIndex, invalidVersion, wrongApplication, incompatiblePackage, notWritable
  case helperFailed, quitTimedOut, launchFailed, releaseChanged
  case recoveryFailed(URL)

  var errorDescription: String? {
    message(in: .main)
  }

  func message(in bundle: Bundle) -> String {
    switch self {
    case .invalidIndex:
      String(
        localized: "The update information is invalid. Check for updates again later.",
        bundle: bundle)
    case .invalidVersion:
      String(
        localized: "This copy of SimStore has invalid version information. Reinstall it to update.",
        bundle: bundle)
    case .wrongApplication:
      String(
        localized: "The downloaded app does not match the selected SimStore build.", bundle: bundle)
    case .incompatiblePackage:
      String(localized: "The downloaded app is not compatible with this Mac.", bundle: bundle)
    case .notWritable:
      String(
        localized: "Move SimStore to a writable Applications folder before updating it.",
        bundle: bundle)
    case .helperFailed:
      String(
        localized: "The update assistant could not start. SimStore has not been replaced.",
        bundle: bundle)
    case .quitTimedOut:
      String(localized: "SimStore did not quit in time. The update was canceled.", bundle: bundle)
    case .launchFailed:
      String(
        localized: "The updated app could not start. The previous version has been restored.",
        bundle: bundle)
    case .releaseChanged:
      String(
        localized: "Available updates have changed. Check for updates again before downloading.",
        bundle: bundle)
    case .recoveryFailed(let previous):
      String(
        localized: "The previous app is saved at \(previous.path). Restore it before trying again.",
        bundle: bundle)
    }
  }
}

private func validVersion(_ value: String) -> Bool {
  let parts = value.split(separator: ".", omittingEmptySubsequences: false)
  return parts.count == 3 && CatalogVersionNumber(value) != nil
    && parts.allSatisfy { part in Int(part).map { String($0) == part } == true }
}

private func validRevision(_ value: String) -> Bool {
  value.count == 40 && value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
}
