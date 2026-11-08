import Foundation

enum SelfUpdateStoreTests {
  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("store.checks", run),
      .init("store.changedNightly") {
        let fixture = try fixture()
        try await changedNightly(initial: fixture.data, nightly: fixture.nightly)
      },
      .init("store.cancelInstallation") {
        try await cancelInstallation(data: fixture().data)
      },
    ]
  }

  private static func fixture() throws -> (
    release: SelfUpdateRelease, nightly: SelfUpdateRelease, data: Data
  ) {
    let release = try SelfUpdateFixtures.release()
    let nightly = try SelfUpdateFixtures.release(["tag": "latest", "build": 8])
    return (release, nightly, try SelfUpdateFixtures.index([nightly, release]))
  }

  @MainActor
  static func run() async throws {
    let fixture = try fixture()
    let release = fixture.release
    let data = fixture.data
    let counter = RequestCounter()
    var client = SelfUpdateClient()
    client.transport = { request in
      await counter.increment()
      try SelfUpdateFixtures.require(
        request.cachePolicy == .reloadIgnoringLocalCacheData,
        "Checks must bypass local HTTP caches.")
      try SelfUpdateFixtures.require(
        request.value(forHTTPHeaderField: "Cache-Control") == "no-cache",
        "Revalidate the moving update feed.")
      return (
        data,
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let store = SelfUpdateStore(current: SelfUpdateFixtures.current(), os: "14.0", client: client)
    store.check()
    store.check()
    try await SelfUpdateFixtures.eventually { !store.isBusy }
    try SelfUpdateFixtures.require(
      store.release == release && store.error == nil && store.hasChecked,
      "Offer the compatible stable update.")
    try SelfUpdateFixtures.require(await counter.value == 1, "Coalesce repeated check actions.")
    let current = SelfUpdateStore(
      current: SelfUpdateFixtures.current(version: "0.2.0", build: 8), os: "14.0", client: client)
    current.check()
    try await SelfUpdateFixtures.eventually { !current.isBusy }
    try SelfUpdateFixtures.require(
      current.release == nil && current.hasChecked && current.error == nil,
      "Show an up-to-date result.")
    client.transport = { request in
      (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
      )
    }
    let failed = SelfUpdateStore(current: SelfUpdateFixtures.current(), client: client)
    failed.check()
    try await SelfUpdateFixtures.eventually { !failed.isBusy }
    try SelfUpdateFixtures.require(
      failed.error?.contains("503") == true && !failed.hasChecked,
      "A failed check must allow retry and never claim up-to-date.")
  }

  @MainActor
  static func changedNightly(initial: Data, nightly: SelfUpdateRelease) async throws {
    let next = try SelfUpdateFixtures.index([
      SelfUpdateFixtures.release(["tag": "latest", "build": 9])
    ])
    let sequence = ResponseSequence([initial, next])
    var client = SelfUpdateClient()
    client.transport = { request in
      (
        await sequence.next(),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let store = SelfUpdateStore(
      current: SelfUpdateFixtures.current(version: "0.2.0"), os: "14.0", client: client)
    store.check()
    try await SelfUpdateFixtures.eventually { !store.isBusy }
    try SelfUpdateFixtures.require(store.release == nightly, "Offer the checked nightly first.")
    store.install()
    try await SelfUpdateFixtures.eventually { !store.isBusy }
    try SelfUpdateFixtures.require(
      store.release == nil && store.error == SelfUpdateError.releaseChanged.localizedDescription,
      "Ask for a fresh check rather than silently installing a different nightly.")
  }

  @MainActor
  static func cancelInstallation(data: Data) async throws {
    let directory = try SelfUpdateFixtures.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let application = try SelfUpdateFixtures.bundle(
      in: directory, release: SelfUpdateFixtures.release())
    var updater = SelfUpdater(
      application: application, bundleID: SelfUpdateFixtures.bundleID,
      reportURL: directory.appending(component: "error.json"))
    updater.download = { _, destination, progress in
      try Data("partial".utf8).write(to: destination)
      progress(1)
      try await Task.sleep(for: .seconds(60))
    }
    var client = SelfUpdateClient()
    client.transport = { request in
      (
        data,
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let store = SelfUpdateStore(
      current: SelfUpdateFixtures.current(), os: "14.0", client: client, updater: updater)
    store.check()
    try await SelfUpdateFixtures.eventually { !store.isBusy }
    store.install()
    store.cancel()
    try await SelfUpdateFixtures.eventually { !store.isBusy }
    try SelfUpdateFixtures.require(
      store.error == nil && store.release != nil,
      "Cancellation must leave the offered update available without an error.")
    try SelfUpdateInstallation.writeFailure(SelfUpdateError.launchFailed, to: updater.reportURL)
    try SelfUpdateFixtures.require(
      store.consumeFailureReport() && store.error != nil, "Surface helper failures after relaunch.")
    try SelfUpdateFixtures.require(!store.consumeFailureReport(), "Consume helper failures once.")
  }
}

private actor RequestCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

private actor ResponseSequence {
  private var values: [Data]
  init(_ values: [Data]) { self.values = values }
  func next() -> Data { values.removeFirst() }
}
