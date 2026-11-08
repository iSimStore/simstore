import Foundation

struct AppCatalog: Sendable {
  let schemaVersion: Int
  let apps: [CatalogApp]

  static func decode(_ data: Data) throws -> AppCatalog {
    do {
      return try JSONDecoder().decode(AppCatalog.self, from: data)
    } catch let error as AppCatalogError {
      throw error
    } catch {
      throw AppCatalogError.invalidCatalog
    }
  }
}

struct CatalogApp: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let bundleID: String
  let repository: URL
  let license: String
  let description: [String: String]
  let categories: [String]
  let versions: [CatalogVersion]

  var latestVersion: CatalogVersion { versions[0] }

  func localizedDescription(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
    let languages = Bundle.preferredLocalizations(
      from: Array(description.keys).sorted(), forPreferences: preferredLanguages)
    return languages.first.flatMap { description[$0] } ?? description["en"] ?? ""
  }

  func recommendedVersion(for runtime: String) -> CatalogVersion {
    latestCompatibleVersion(for: runtime) ?? latestVersion
  }

  func latestCompatibleVersion(for runtime: String) -> CatalogVersion? {
    versions.first { $0.isCompatible(with: runtime) }
  }

  func availableUpdate(from installedVersion: String?, runtime: String) -> CatalogVersion? {
    guard let version = latestCompatibleVersion(for: runtime),
      version.comparison(with: installedVersion) == .orderedDescending
    else { return nil }
    return version
  }
}

struct CatalogVersion: Identifiable, Hashable, Sendable {
  let version: String
  let minSimulatorOS: String
  let sha256: String
  let size: Int64
  let revision: String
  let recipeRevision: String
  let time: Int64

  var id: String { version }

  func isCompatible(with runtime: String) -> Bool {
    guard let minimum = CatalogVersionNumber(minSimulatorOS),
      let installed = CatalogVersionNumber(runtime)
    else { return false }
    return installed >= minimum
  }

  func comparison(with installedVersion: String?) -> ComparisonResult? {
    guard let installedVersion, let installed = CatalogVersionNumber(installedVersion),
      let candidate = CatalogVersionNumber(version)
    else { return nil }
    if candidate == installed { return .orderedSame }
    return candidate > installed ? .orderedDescending : .orderedAscending
  }
}

enum AppCatalogError: LocalizedError, Equatable {
  case invalidCatalog
  case unsupportedSchema

  var errorDescription: String? {
    switch self {
    case .invalidCatalog:
      String(localized: "The app catalog is invalid. Try refreshing it again later.")
    case .unsupportedSchema:
      String(localized: "Update SimStore to read this app catalog.")
    }
  }
}

extension AppCatalog: Decodable {
  private enum CodingKeys: String, CodingKey { case schemaVersion, apps }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == 1 else { throw AppCatalogError.unsupportedSchema }
    apps = try values.decode([CatalogApp].self, forKey: .apps)
    guard Set(apps.map(\.id)).count == apps.count else { throw AppCatalogError.invalidCatalog }
  }
}

extension CatalogApp: Decodable {
  private enum CodingKeys: String, CodingKey {
    case id, name, bundleID, repository, license, description, categories, versions
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    bundleID = try values.decode(String.self, forKey: .bundleID)
    repository = try values.decode(URL.self, forKey: .repository)
    license = try values.decode(String.self, forKey: .license)
    description = try values.decode([String: String].self, forKey: .description)
    categories = try values.decode([String].self, forKey: .categories)
    let decodedVersions = try values.decode([CatalogVersion].self, forKey: .versions)
    guard matches(id, pattern: "[a-z][a-z0-9-]*"),
      nonempty(name), nonempty(license),
      matches(bundleID, pattern: "[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+"),
      repository.scheme == "https", repository.host?.isEmpty == false,
      !repository.path.isEmpty, repository.user == nil, repository.password == nil,
      repository.query == nil, repository.fragment == nil,
      description["en"].map(nonempty) == true,
      description.allSatisfy({ nonempty($0.key) && nonempty($0.value) }),
      !categories.isEmpty, categories.allSatisfy({ matches($0, pattern: "[a-z][a-z0-9-]*") }),
      Set(categories).count == categories.count,
      !decodedVersions.isEmpty,
      Set(decodedVersions.map(\.version)).count == decodedVersions.count
    else { throw AppCatalogError.invalidCatalog }
    let parsedVersions = try decodedVersions.map { version in
      guard let number = CatalogVersionNumber(version.version) else {
        throw AppCatalogError.invalidCatalog
      }
      return (version: version, number: number)
    }
    versions = parsedVersions.sorted { $0.number > $1.number }.map(\.version)
  }
}

extension CatalogVersion: Decodable {
  private enum CodingKeys: String, CodingKey {
    case version, minSimulatorOS, sha256, size, revision, recipeRevision, time
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(String.self, forKey: .version)
    minSimulatorOS = try values.decode(String.self, forKey: .minSimulatorOS)
    sha256 = try values.decode(String.self, forKey: .sha256)
    size = try values.decode(Int64.self, forKey: .size)
    revision = try values.decode(String.self, forKey: .revision)
    recipeRevision = try values.decode(String.self, forKey: .recipeRevision)
    time = try values.decode(Int64.self, forKey: .time)
    guard matches(version, pattern: "(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)"),
      CatalogVersionNumber(version) != nil,
      matches(minSimulatorOS, pattern: "[1-9][0-9]*(?:\\.[0-9]+){0,2}"),
      CatalogVersionNumber(minSimulatorOS) != nil,
      matches(sha256, pattern: "[0-9a-f]{64}"),
      matches(revision, pattern: "[0-9a-f]{40}"),
      matches(recipeRevision, pattern: "[0-9a-f]{40}"), size > 0, time >= 0
    else { throw AppCatalogError.invalidCatalog }
  }
}

struct CatalogVersionNumber: Comparable {
  let components: [Int]

  init?(_ text: String) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count),
      parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) })
    else { return nil }
    let numbers = parts.compactMap { Int($0) }
    guard numbers.count == parts.count else { return nil }
    components = numbers + Array(repeating: 0, count: 3 - numbers.count)
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.components.lexicographicallyPrecedes(rhs.components)
  }
}

private func nonempty(_ text: String) -> Bool {
  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func matches(_ text: String, pattern: String) -> Bool {
  text.range(of: "^(?:\(pattern))$", options: .regularExpression) == text.startIndex..<text.endIndex
}
