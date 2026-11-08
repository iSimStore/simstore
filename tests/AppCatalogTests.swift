import Foundation

@main
struct AppCatalogTests {
  static func main() throws {
    try decodeAndSort()
    try largeVersionComponents()
    try localizationAndCompatibility()
    try compatibleUpdates()
    try rejectInvalidCatalogs()
    print("PASS: catalog decoding, version ordering, language fallback, and compatibility.")
  }

  static func decodeAndSort() throws {
    let catalog = try decode(apps: [app(versions: [version("1.9.0"), version("1.10.0")])])
    try require(catalog.schemaVersion == 1 && catalog.apps.count == 1, "Decode catalog metadata.")
    let entry = catalog.apps[0]
    try require(entry.id == "example" && entry.bundleID == "io.example.App", "Decode app identity.")
    try require(
      entry.repository.absoluteString == "https://github.com/example/app" && entry.license == "MIT",
      "Decode repository and license at app level.")
    try require(entry.categories == ["utilities"], "Decode category IDs.")
    try require(
      entry.versions.map(\.version) == ["1.10.0", "1.9.0"],
      "Version ordering must compare numeric components.")
    let build = entry.latestVersion
    try require(
      build.id == "1.10.0" && build.size == 1000 && build.time == 1_793_544_257,
      "Preserve build identity, archive size, and Unix timestamp.")
    try require(try decode(apps: []).apps.isEmpty, "A valid empty catalog is allowed.")
  }

  static func largeVersionComponents() throws {
    let expected = ["\(Int.max).1.0", "\(Int.max - 1).99.99", "10.0.0", "2.10.0", "2.9.999"]
    let entry = try decode(apps: [app(versions: expected.reversed().map { version($0) })]).apps[0]
    try require(
      entry.versions.map(\.version) == expected,
      "Sort numeric components without lexicographic ordering or integer packing overflow.")
  }

  static func localizationAndCompatibility() throws {
    let entry = try decode(apps: [
      app(versions: [version("1.9.0", minimum: "16.0"), version("1.10.0", minimum: "27.0")])
    ]).apps[0]
    try require(
      entry.localizedDescription(preferredLanguages: ["zh-Hans-CN"]) == "示例应用。",
      "Match a region-specific Simplified Chinese preference.")
    try require(
      entry.localizedDescription(preferredLanguages: ["de-DE", "en-GB"]) == "An example app.",
      "Use the English description when preferred languages are unavailable.")
    try require(
      entry.localizedDescription(preferredLanguages: ["de-DE"]) == "An example app.",
      "An unsupported language must fall back to English.")
    try require(
      entry.recommendedVersion(for: "27").version == "1.10.0",
      "An abbreviated runtime version compares equal to a padded minimum.")
    try require(
      entry.recommendedVersion(for: "16.4").version == "1.9.0",
      "Prefer the newest compatible version when the latest needs a newer runtime.")
    try require(
      entry.recommendedVersion(for: "15.0").version == "1.10.0",
      "Keep an application visible even when no build declares compatibility.")
    try require(!entry.latestVersion.isCompatible(with: "26.9.9"), "Compare all OS components.")
    try require(entry.latestVersion.isCompatible(with: "27.0.1"), "Accept newer runtime patches.")
    try require(
      !entry.latestVersion.isCompatible(with: "unknown"), "Unknown runtime is not compatible.")
  }

  static func compatibleUpdates() throws {
    let entry = try decode(apps: [
      app(versions: [
        version("1.9.0", minimum: "16.0"), version("1.11.0", minimum: "28.0"),
        version("1.10.0", minimum: "27.0"),
      ])
    ]).apps[0]
    try require(
      entry.availableUpdate(from: "1.9.0", runtime: "27.0")?.version == "1.10.0",
      "Offer the newest compatible build, comparing version components numerically.")
    try require(
      entry.availableUpdate(from: "1.8", runtime: "16.4")?.version == "1.9.0",
      "An older runtime may update to a compatible historical build.")
    for current in ["1.10", "1.10.0", "1.11.0", "2.0.0"] {
      try require(
        entry.availableUpdate(from: current, runtime: "27.0") == nil,
        "Equal or newer installed versions must never be treated as updates.")
    }
    for current: String? in [
      nil, "", "1.0-beta", "v1.0.0", "1.0.0.1", String(repeating: "9", count: 30),
    ] {
      try require(
        entry.availableUpdate(from: current, runtime: "27.0") == nil,
        "Unknown and uncomparable installed versions cannot imply an automatic update.")
    }
    try require(
      entry.availableUpdate(from: "1.0.0", runtime: "15.0") == nil
        && entry.availableUpdate(from: "1.0.0", runtime: "unknown") == nil,
      "No compatible build must produce no automatic update, rather than falling back to latest.")
    try require(
      entry.versions.last?.comparison(with: "1.10.0") == .orderedAscending,
      "Selecting a historical version must distinguish a downgrade from an update.")
  }

  static func rejectInvalidCatalogs() throws {
    try reject(["schemaVersion": 2, "apps": []], expected: .unsupportedSchema)
    try reject(["schemaVersion": 1, "apps": [app(), app()]])
    try reject(["schemaVersion": 1, "apps": [app(versions: [version("1.0.0"), version("1.0.0")])]])
    for (field, value) in [
      ("id", "../../elsewhere"), ("name", " "), ("license", ""), ("bundleID", "invalid"),
      ("repository", "file:///tmp/example"), ("repository", "https:example"),
      ("repository", "https://user:password@example.com/repo"),
      ("repository", "https://example.com/repo?key=value"),
    ] {
      var invalid = app()
      invalid[field] = value
      try reject(["schemaVersion": 1, "apps": [invalid]])
    }
    for (field, value) in [
      ("version", "v1.0.0"), ("version", "1.0.0-beta"), ("version", "01.0.0"),
      ("version", "\(Int.max)0.0.0"), ("version", "1.0.\(Int.max)0"),
      ("minSimulatorOS", "16.x"), ("minSimulatorOS", "16..0"),
      ("minSimulatorOS", "\(Int.max)0"),
      ("sha256", "abc"), ("revision", "main"), ("recipeRevision", "abcdef"),
    ] {
      var invalid = version("1.0.0")
      invalid[field] = value
      try reject(["schemaVersion": 1, "apps": [app(versions: [invalid])]])
    }
    for (field, value) in [("size", 0), ("time", -1)] {
      var invalid = version("1.0.0")
      invalid[field] = value
      try reject(["schemaVersion": 1, "apps": [app(versions: [invalid])]])
    }
    for field in ["time", "size", "minSimulatorOS"] {
      var invalid = version("1.0.0")
      invalid.removeValue(forKey: field)
      try reject(["schemaVersion": 1, "apps": [app(versions: [invalid])]])
    }
    for (field, value): (String, Any) in [
      ("versions", []), ("description", ["zh-Hans": "示例应用。"]),
      ("description", ["en": " "]), ("categories", []),
      ("categories", ["utilities", "utilities"]),
    ] {
      var invalid = app()
      invalid[field] = value
      try reject(["schemaVersion": 1, "apps": [invalid]])
    }
    do {
      _ = try AppCatalog.decode(Data("not JSON".utf8))
      throw failure("Invalid JSON must not be accepted.")
    } catch AppCatalogError.invalidCatalog {}
  }

  static func app(versions: [[String: Any]] = [version("1.0.0")]) -> [String: Any] {
    [
      "id": "example", "name": "Example", "bundleID": "io.example.App",
      "repository": "https://github.com/example/app", "license": "MIT",
      "description": ["en": "An example app.", "zh-Hans": "示例应用。"],
      "categories": ["utilities"], "versions": versions,
    ]
  }

  static func version(_ value: String, minimum: String = "16.0") -> [String: Any] {
    [
      "version": value, "minSimulatorOS": minimum,
      "sha256": String(repeating: "a", count: 64), "size": 1000,
      "revision": String(repeating: "b", count: 40),
      "recipeRevision": String(repeating: "c", count: 40), "time": 1_793_544_257,
    ]
  }

  static func decode(apps: [[String: Any]]) throws -> AppCatalog {
    try AppCatalog.decode(
      JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "apps": apps]))
  }

  static func reject(_ value: [String: Any], expected: AppCatalogError = .invalidCatalog) throws {
    do {
      _ = try AppCatalog.decode(JSONSerialization.data(withJSONObject: value))
      throw failure("An invalid catalog was accepted: \(value)")
    } catch let error as AppCatalogError {
      try require(error == expected, "Unexpected catalog validation error: \(error)")
    }
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  static func failure(_ message: String) -> Error {
    NSError(domain: "AppCatalogTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
