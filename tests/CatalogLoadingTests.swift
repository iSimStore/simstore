import Foundation

@main
@MainActor
struct CatalogLoadingTests {
  @MainActor
  static func main() async {
    await TestSuite.run(cases)
  }

  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("releaseURLs", releaseURLs),
      .init("firstDownloadAndCache", firstDownloadAndCache),
      .init("cachedFallbackAndRecovery", cachedFallbackAndRecovery),
      .init("invalidDownloadsPreserveCache", invalidDownloadsPreserveCache),
      .init("corruptCacheAndUnwritableCache", corruptCacheAndUnwritableCache),
      .init("refreshCoalescingAndCancellation", refreshCoalescingAndCancellation),
      .init("joiningRefreshAfterCancellation", joiningRefreshAfterCancellation),
    ]
  }

  static func releaseURLs() throws {
    let revision = String(repeating: "a", count: 40)
    try require(
      AppConfiguration.commitURL(
        repository: URL(string: "https://github.com/example/upstream")!, revision: revision
      ).absoluteString == "https://github.com/example/upstream/commit/\(revision)",
      "Source commits belong to the upstream repository.")
    try require(
      AppConfiguration.commitURL(
        repository: AppConfiguration.buildsRepositoryURL, revision: revision
      ).absoluteString == "https://github.com/iSimStore/simstore-builds/commit/\(revision)",
      "Recipe commits belong to the builds repository.")
    try require(
      AppConfiguration.catalogURL.absoluteString
        == "https://github.com/iSimStore/simstore-builds/releases/download/latest/index.json",
      "Load the aggregated index from the latest release.")
    try require(
      AppConfiguration.releaseURL(appID: "localsend", version: "1.17.0").absoluteString
        == "https://github.com/iSimStore/simstore-builds/releases/tag/localsend%2F1.17.0",
      "Encode app ID and version as a single release-tag path component.")
    try require(
      AppConfiguration.assetURL(appID: "localsend", version: "1.17.0", filename: "icon.png")
        .absoluteString
        == "https://github.com/iSimStore/simstore-builds/releases/download/localsend%2F1.17.0/icon.png",
      "Read icons from the selected version's release.")
    try require(
      AppConfiguration.assetURL(
        appID: "localsend", version: "1.17.0", filename: "localsend.app.tar.bz2"
      ).absoluteString
        == "https://github.com/iSimStore/simstore-builds/releases/download/localsend%2F1.17.0/localsend.app.tar.bz2",
      "The release tag carries the version; the app archive filename carries only the app ID.")
  }

  static func firstDownloadAndCache() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = TransportProbe(data: fixture())
    let client = client(directory, probe: probe)
    try require(try await client.loadCached() == nil, "A missing cache is not an error.")
    let store = CatalogStore(client: client)
    await store.refresh()
    try require(store.catalog?.apps.first?.name == "Example", "Show the downloaded catalog.")
    try require(
      !store.isLoading && !store.isUsingCache && store.error == nil,
      "A successful download must clear loading and offline state.")
    try require(
      try Data(contentsOf: client.cacheURL) == fixture(), "Save the exact validated payload.")
    let request = await probe.lastRequest
    try require(request?.url == catalogURL, "Use the configured catalog URL.")
    try require(
      request?.cachePolicy == .reloadIgnoringLocalCacheData,
      "Refresh must ask the repository for its current catalog.")
    try require(request?.timeoutInterval == 30, "Bound an unresponsive repository request.")
  }

  static func cachedFallbackAndRecovery() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = TransportProbe(data: fixture(), suspended: true)
    let client = client(directory, probe: probe)
    try fixture().write(to: client.cacheURL)
    let store = CatalogStore(client: client)
    let refresh = Task { await store.refresh() }
    try await eventually { await probe.calls == 1 }
    try require(
      store.catalog?.apps.first?.versions.first?.version == "1.0.0"
        && store.isLoading && store.isUsingCache,
      "Display valid cached data while the network is still pending.")
    await probe.finish(error: URLError(.notConnectedToInternet))
    await refresh.value
    try require(
      store.catalog != nil && store.isUsingCache && store.error != nil && !store.isLoading,
      "Keep the cached catalog and expose an offline error.")
    await probe.configure(data: fixture(version: "2.0.0"))
    await store.refresh()
    try require(
      store.catalog?.apps.first?.versions.first?.version == "2.0.0"
        && !store.isUsingCache && store.error == nil,
      "A retry should replace stale data and clear the offline error.")
    try require(
      try Data(contentsOf: client.cacheURL) == fixture(version: "2.0.0"),
      "Cache the recovered current catalog.")
  }

  static func invalidDownloadsPreserveCache() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = TransportProbe(data: Data("not JSON".utf8))
    let client = client(directory, probe: probe)
    try fixture().write(to: client.cacheURL)
    let store = CatalogStore(client: client)
    await store.refresh()
    try require(
      store.catalog != nil && store.isUsingCache && store.error != nil,
      "A malformed remote catalog must fall back to the last valid catalog.")
    try require(
      try Data(contentsOf: client.cacheURL) == fixture(),
      "Never overwrite valid cache bytes with malformed remote data.")
    await probe.configure(data: fixture(version: "2.0.0"), status: 503)
    await store.refresh()
    try require(store.error?.contains("503") == true, "Preserve the HTTP status in the error.")
    try require(
      try Data(contentsOf: client.cacheURL) == fixture(),
      "An HTTP error payload must never replace the cache.")
    let emptyDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: emptyDirectory) }
    let unavailable = CatalogStore(client: self.client(emptyDirectory, probe: probe))
    await unavailable.refresh()
    try require(
      unavailable.catalog == nil && unavailable.error != nil && !unavailable.isUsingCache,
      "An unavailable repository without cache must expose an empty error state.")
  }

  static func corruptCacheAndUnwritableCache() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = TransportProbe(data: fixture())
    let client = client(directory, probe: probe)
    try Data("broken cache".utf8).write(to: client.cacheURL)
    let store = CatalogStore(client: client)
    await store.refresh()
    try require(
      store.catalog != nil && store.error == nil && !store.isUsingCache,
      "A corrupt disk cache must not prevent a valid network download.")
    try require(
      try Data(contentsOf: client.cacheURL) == fixture(), "Replace corrupt cache after validation.")
    let blocked = directory.appending(path: "regular-file")
    try Data().write(to: blocked)
    let noCache = CatalogClient(
      url: catalogURL, cacheURL: blocked.appending(path: "index.json"),
      transport: { try await probe.send($0) })
    try require(
      try await noCache.fetch().apps.count == 1,
      "A failed disk write must not hide a successfully downloaded catalog.")
  }

  static func refreshCoalescingAndCancellation() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = TransportProbe(data: fixture(version: "2.0.0"), suspended: true)
    let client = client(directory, probe: probe)
    try fixture().write(to: client.cacheURL)
    let store = CatalogStore(client: client)
    let first = Task { await store.refresh() }
    try await eventually { await probe.calls == 1 }
    let second = Task { await store.refresh() }
    await Task.yield()
    try require(await probe.calls == 1, "Concurrent refreshes must share one request.")
    first.cancel()
    second.cancel()
    await probe.finish()
    await first.value
    await second.value
    try require(
      !store.isLoading && store.error == nil && store.isUsingCache
        && store.catalog?.apps.first?.versions.first?.version == "1.0.0",
      "Cancellation must remain silent, retain cached data, and finish all waiters.")
    try require(
      try Data(contentsOf: client.cacheURL) == fixture(),
      "A canceled download must not replace the cache.")
    await probe.configure(data: fixture(version: "2.0.0"))
    await store.refresh()
    try require(
      store.catalog?.apps.first?.versions.first?.version == "2.0.0" && store.error == nil,
      "A canceled refresh must not prevent a later retry.")
    await probe.configure(data: fixture(), error: URLError(.cancelled))
    await store.refresh()
    try require(store.error == nil, "URLSession cancellation must remain silent too.")
  }

  static func joiningRefreshAfterCancellation() async throws {
    for cancelledOwner in [true, false] {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let probe = TransportProbe(data: fixture(), suspended: true)
      let client = client(directory, probe: probe)
      let store = CatalogStore(client: client)
      let first = Task { await store.refresh() }
      try await eventually { await probe.calls == 1 }
      if cancelledOwner { first.cancel() }
      var joinerStarted = false
      let second = Task {
        joinerStarted = true
        await store.refresh()
      }
      try await eventually { joinerStarted }
      try require(
        await probe.calls == 1, "The joining refresh must first share the pending request.")
      await probe.finish(error: cancelledOwner ? nil : URLError(.cancelled))
      await first.value
      await second.value
      try require(
        !store.isLoading && store.error == nil,
        "Finish both refreshes without a cancellation error.")
      if cancelledOwner {
        try require(
          await probe.calls == 2 && store.catalog?.apps.first?.name == "Example",
          "An active joining refresh must retry after its request owner's task was canceled.")
        try require(
          try Data(contentsOf: client.cacheURL) == fixture(),
          "Cache the joining caller's successful retry when no prior catalog was available.")
      } else {
        try require(
          await probe.calls == 1 && store.catalog == nil,
          "A URLSession cancellation without task cancellation must not trigger repeated retries.")
      }
    }
  }

  static let catalogURL = URL(string: "https://example.com/releases/download/latest/index.json")!

  private static func client(_ directory: URL, probe: TransportProbe) -> CatalogClient {
    CatalogClient(
      url: catalogURL, cacheURL: directory.appending(path: "index.json"),
      transport: { try await probe.send($0) })
  }

  static func fixture(version: String = "1.0.0") -> Data {
    Data(
      """
      {
        "schemaVersion": 1,
        "apps": [{
          "id": "example", "name": "Example", "bundleID": "org.example.Example",
          "repository": "https://github.com/example/example", "license": "MIT",
          "description": {"en": "An example app.", "zh-Hans": "示例应用。"},
          "categories": ["utilities"],
          "versions": [{
            "version": "\(version)", "minSimulatorOS": "16.0", "size": 1024,
            "sha256": "\(String(repeating: "a", count: 64))",
            "revision": "\(String(repeating: "b", count: 40))",
            "recipeRevision": "\(String(repeating: "c", count: 40))", "time": 1793544257
          }]
        }]
      }
      """.utf8)
  }

  static func temporaryDirectory() throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: "catalog-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func eventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw failure("An async operation timed out.") }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  static func failure(_ message: String) -> NSError {
    NSError(domain: "CatalogLoadingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

private actor TransportProbe {
  private var data: Data
  private var status: Int
  private var error: URLError?
  private var suspended: Bool
  private var pending: CheckedContinuation<Void, Never>?
  private(set) var calls = 0
  private(set) var lastRequest: URLRequest?

  init(data: Data, status: Int = 200, suspended: Bool = false) {
    self.data = data
    self.status = status
    self.suspended = suspended
  }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    calls += 1
    lastRequest = request
    if suspended {
      await withCheckedContinuation { pending = $0 }
    }
    if let error { throw error }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    return (data, response)
  }

  func finish(error: URLError? = nil) {
    self.error = error
    suspended = false
    let continuation = pending
    pending = nil
    continuation?.resume()
  }

  func configure(data: Data, status: Int = 200, error: URLError? = nil) {
    self.data = data
    self.status = status
    self.error = error
    suspended = false
  }
}
