import CoreGraphics
import Foundation
import ImageIO

@main
@MainActor
struct IconCacheTests {
  @MainActor
  static func main() async {
    await TestSuite.run(cases)
  }

  @MainActor
  static var cases: [TestSuite.Case] {
    [
      .init("memoryAndOfflineDisk", memoryAndOfflineDisk),
      .init("versionsAndDownsampling", versionsAndDownsampling),
      .init("failuresAndRecovery", failuresAndRecovery),
      .init("sharedRequestsAndCancellation", sharedRequestsAndCancellation),
      .init("decodingDoesNotBlockOtherRequests", decodingDoesNotBlockOtherRequests),
      .init("downloadLimit", downloadLimit),
      .init("diskEviction", diskEviction),
      .init("concurrentDiskEviction", concurrentDiskEviction),
      .init("diskFailureAndOversizedEntry", diskFailureAndOversizedEntry),
    ]
  }

  static func memoryAndOfflineDisk() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try png()
    let probe = IconTransport(data: data)
    let cache = IconCache(directory: directory, transport: { try await probe.send($0) })
    let id = key("example")
    let first = try await cache.image(for: id)
    try require(
      first.width == 152 && first.height == 152, "Keep smaller images at their original resolution."
    )
    let file = directory.appending(component: id.filename)
    try require(try Data(contentsOf: file) == data, "Persist the original PNG bytes.")
    try FileManager.default.removeItem(at: file)
    let second = try await cache.image(for: id)
    let calls = await probe.calls
    try require(
      first === second && calls.count == 1,
      "Reuse the decoded image without another download.")
    try data.write(to: file)
    let offline = IconCache(
      directory: directory, transport: { _ in throw URLError(.notConnectedToInternet) })
    let restored = try await offline.image(for: id)
    try require(restored.width == 152, "A fresh cache instance must work offline from disk.")
    try require(
      calls.first?.cachePolicy == .reloadIgnoringLocalCacheData,
      "Use the app-managed cache instead of HTTP cached responses.")
    try require(calls.first?.timeoutInterval == 30, "Bound the icon request timeout.")
  }

  static func versionsAndDownsampling() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = IconTransport(data: try png(width: 512, height: 384))
    let cache = IconCache(directory: directory, transport: { try await probe.send($0) })
    let first = key("example")
    let recipe = key("example", revision: "second-recipe")
    let version = key("example", version: "2.0.0")
    for id in [first, recipe, version] {
      let image = try await cache.image(for: id)
      try require(
        image.width == 256 && image.height == 192,
        "Downsample large images while preserving their aspect ratio.")
      try require(
        FileManager.default.fileExists(atPath: directory.appending(component: id.filename).path),
        "Cache each build under its own key.")
    }
    try require(
      await probe.calls.count == 3,
      "A version or recipe change invalidates the icon even if the asset URL stays the same.")
    try require(
      Set([first.filename, recipe.filename, version.filename]).count == 3,
      "Build identities must not collide.")
  }

  static func failuresAndRecovery() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try png()
    let probe = IconTransport(data: data, status: 503)
    let cache = IconCache(directory: directory, transport: { try await probe.send($0) })
    let id = key("retry")
    do {
      _ = try await cache.image(for: id)
      throw failure("An HTTP error must not be accepted as an icon.")
    } catch IconCache.Failure.httpStatus(503) {}
    try require(
      !FileManager.default.fileExists(atPath: directory.appending(component: id.filename).path),
      "Do not persist failed HTTP responses.")
    await probe.configure(data: Data("not an image".utf8))
    do {
      _ = try await cache.image(for: id)
      throw failure("A successful HTTP response must still contain an image.")
    } catch IconCache.Failure.invalidImage {}
    await probe.configure(data: data)
    _ = try await cache.image(for: id)
    try require(
      await probe.calls.count == 3, "Failed requests must release their slot and permit retries.")

    let corrupt = key("corrupt")
    try Data("broken cache".utf8).write(to: directory.appending(component: corrupt.filename))
    _ = try await cache.image(for: corrupt)
    try require(
      try Data(contentsOf: directory.appending(component: corrupt.filename)) == data,
      "Replace corrupt cached bytes after a successful download.")
    let invalid = IconCache(
      directory: directory,
      transport: { request in
        (
          data,
          URLResponse(
            url: request.url!, mimeType: "image/png", expectedContentLength: data.count,
            textEncodingName: nil)
        )
      })
    do {
      _ = try await invalid.image(for: key("non-http"))
      throw failure("Require an HTTP response.")
    } catch IconCache.Failure.invalidResponse {}
  }

  static func sharedRequestsAndCancellation() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = IconTransport(data: try png(), suspended: true)
    let cache = IconCache(directory: directory, transport: { try await probe.send($0) })
    let id = key("shared")
    let first = Task { try await cache.image(for: id) }
    try await eventually { await probe.calls.count == 1 }
    var joined = false
    let second = Task {
      joined = true
      return try await cache.image(for: id)
    }
    try await eventually { joined }
    first.cancel()
    await probe.releaseAll()
    let image = try await second.value
    do {
      _ = try await first.value
      throw failure("A canceled view must not apply the downloaded icon.")
    } catch is CancellationError {}
    let calls = await probe.calls.count
    try require(
      image.width == 152 && calls == 1,
      "Canceling one caller must not cancel the shared request.")
    let canceled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await cache.image(for: key("already-canceled"))
    }
    do {
      _ = try await canceled.value
      throw failure("Do not start requests for already canceled callers.")
    } catch is CancellationError {}
    try require(
      await probe.calls.count == 1, "An already canceled request must not reach the network.")
  }

  static func decodingDoesNotBlockOtherRequests() async throws {
    for cached in [true, false] {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let data = try png()
      let blockedData = Data("slow image".utf8)
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { throw failure("Decode the image fixture.") }
      let started = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }
      let probe = IconTransport(data: data)
      let cache = IconCache(
        directory: directory, maximumConcurrentDownloads: 2,
        decoder: { bytes in
          if bytes == blockedData {
            started.signal()
            guard release.wait(timeout: .now() + 5) == .success else { return nil }
          }
          return decoded
        },
        transport: { try await probe.send($0) })
      let warmKey = key("warm")
      let warm = try await cache.image(for: warmKey)
      let blockedKey = key("blocked")
      if cached {
        try blockedData.write(to: directory.appending(component: blockedKey.filename))
      } else {
        await probe.configure(data: blockedData)
      }
      let owner = Task { try await cache.image(for: blockedKey) }
      let didStart = await Task.detached {
        waitForDecode(started)
      }.value
      try require(didStart, "Start decoding before checking other requests.")
      owner.cancel()
      let waiter = Task { try await cache.image(for: blockedKey) }
      await probe.configure(data: data)
      var memoryFinished = false
      let memoryHit = Task {
        let image = try await cache.image(for: warmKey)
        memoryFinished = true
        return image
      }
      var downloadFinished = false
      let download = Task {
        let image = try await cache.image(for: key("independent"))
        downloadFinished = true
        return image
      }
      let progressed: Bool
      do {
        try await eventually { memoryFinished && downloadFinished }
        progressed = true
      } catch {
        progressed = false
      }
      release.signal()
      _ = try await waiter.value
      do {
        _ = try await owner.value
        throw failure("A canceled caller must not apply an image after decoding.")
      } catch is CancellationError {}
      let memoryImage = try await memoryHit.value
      _ = try await download.value
      try require(
        progressed && memoryImage === warm,
        "A blocked disk or network image decoder must allow memory hits and unrelated downloads to finish."
      )
      try require(
        await probe.calls.count == (cached ? 2 : 3),
        "Keep sharing the blocked request after its original caller is canceled.")
    }
  }

  nonisolated static func waitForDecode(_ started: DispatchSemaphore) -> Bool {
    started.wait(timeout: .now() + 5) == .success
  }

  static func downloadLimit() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = IconTransport(data: try png(), suspended: true)
    let cache = IconCache(directory: directory, transport: { try await probe.send($0) })
    let jobs = (0..<7).map { index in
      Task { try await cache.image(for: key("queued-\(index)")) }
    }
    try await eventually { await probe.calls.count == 4 }
    await probe.release(0)
    try await eventually { await probe.calls.count == 5 }
    try require(await probe.peakActive == 4, "Only four distinct icons may download concurrently.")
    await probe.releaseAll()
    for job in jobs { _ = try await job.value }
    let calls = await probe.calls.count
    let peakActive = await probe.peakActive
    try require(
      calls == 7 && peakActive == 4,
      "Queued downloads must all complete within the concurrency limit.")
  }

  static func diskEviction() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try png()
    let probe = IconTransport(data: data)
    let cache = IconCache(
      directory: directory, diskLimit: data.count * 2, transport: { try await probe.send($0) })
    let a = key("a")
    let b = key("b")
    let c = key("c")
    for id in [a, b] { _ = try await cache.image(for: id) }
    for (id, age) in [(a, 1), (b, 2)] {
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: Double(age))],
        ofItemAtPath: directory.appending(component: id.filename).path)
    }
    _ = try await cache.image(for: a)
    _ = try await cache.image(for: c)
    try require(
      FileManager.default.fileExists(atPath: directory.appending(component: a.filename).path),
      "A memory hit must refresh the icon's disk recency.")
    try require(
      !FileManager.default.fileExists(atPath: directory.appending(component: b.filename).path),
      "Evict the least recently used icon first.")
    try data.write(to: directory.appending(component: b.filename))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)],
      ofItemAtPath: directory.appending(component: b.filename).path)
    let unrelated = directory.appending(component: "notes.txt")
    try Data("Keep this file".utf8).write(to: unrelated)
    let offline = IconCache(
      directory: directory, diskLimit: data.count * 2,
      transport: { _ in throw URLError(.notConnectedToInternet) })
    _ = try await offline.image(for: c)
    try require(
      !FileManager.default.fileExists(atPath: directory.appending(component: b.filename).path),
      "Trim leftover over-budget files on the first disk access.")
    try require(
      FileManager.default.fileExists(atPath: unrelated.path),
      "Only manage files with generated cache names.")
  }

  static func concurrentDiskEviction() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try png()
    let limit = data.count * 2
    let probe = IconTransport(data: data, suspended: true)
    let cache = IconCache(
      directory: directory, diskLimit: limit, transport: { try await probe.send($0) })
    let keys = (0..<7).map { key("concurrent-\($0)") }
    let jobs = keys.map { id in Task { try await cache.image(for: id) } }
    try await eventually { await probe.calls.count == 4 }
    await probe.releaseAll()
    for job in jobs { _ = try await job.value }
    let retained = keys.filter {
      FileManager.default.fileExists(atPath: directory.appending(component: $0.filename).path)
    }
    let totalSize = try retained.reduce(0) {
      $0 + (try Data(contentsOf: directory.appending(component: $1.filename))).count
    }
    try require(
      retained.count == 2 && totalSize <= limit,
      "Concurrent saves must respect the disk budget without evicting more files than necessary.")
    let offline = IconCache(
      directory: directory, diskLimit: limit,
      transport: { _ in throw URLError(.notConnectedToInternet) })
    for id in retained {
      let image = try await offline.image(for: id)
      try require(image.width == 152, "Retained concurrent writes must remain valid offline.")
    }
  }

  static func diskFailureAndOversizedEntry() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try png()
    let blocked = directory.appending(component: "regular-file")
    try Data().write(to: blocked)
    for (path, limit) in [
      (blocked.appending(component: "icons"), data.count * 2),
      (directory.appending(component: "tiny-cache"), 1),
    ] {
      let probe = IconTransport(data: data)
      let cache = IconCache(
        directory: path, diskLimit: limit, transport: { try await probe.send($0) })
      let id = key("no-disk")
      let image = try await cache.image(for: id)
      try require(image.width == 152, "A disk write failure must not hide a downloaded image.")
      try require(
        !FileManager.default.fileExists(atPath: path.appending(component: id.filename).path),
        "Do not write entries larger than the entire disk budget.")
      _ = try await cache.image(for: id)
      try require(
        await probe.calls.count == 1, "Keep using memory when persistence is unavailable.")
    }
  }

  static func key(_ id: String, version: String = "1.0.0", revision: String = "recipe")
    -> IconCache.Key
  {
    IconCache.Key(
      url: URL(string: "https://example.com/releases/download/\(id)%2F\(version)/icon.png")!,
      recipeRevision: revision)
  }

  static func png(width: Int = 152, height: Int = 152) throws -> Data {
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw failure("Cannot create an image fixture.") }
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { throw failure("Cannot encode an image fixture.") }
    CGImageDestinationAddImage(destination, image, nil)
    try require(CGImageDestinationFinalize(destination), "Finish encoding the image fixture.")
    return data as Data
  }

  static func temporaryDirectory() throws -> URL {
    let directory = URL.temporaryDirectory.appending(
      component: "icon-cache-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func eventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw failure("An async operation timed out.") }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  static func failure(_ message: String) -> NSError {
    NSError(domain: "IconCacheTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

private actor IconTransport {
  private var data: Data
  private var status: Int
  private var suspended: Bool
  private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
  private var active = 0
  private(set) var peakActive = 0
  private(set) var calls: [URLRequest] = []

  init(data: Data, status: Int = 200, suspended: Bool = false) {
    self.data = data
    self.status = status
    self.suspended = suspended
  }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let index = calls.count
    calls.append(request)
    active += 1
    peakActive = max(peakActive, active)
    defer { active -= 1 }
    if suspended { await withCheckedContinuation { pending[index] = $0 } }
    let response = HTTPURLResponse(
      url: URL(string: "https://release-assets.example.com/signed-image")!, statusCode: status,
      httpVersion: nil, headerFields: nil)!
    return (data, response)
  }

  func configure(data: Data, status: Int = 200) {
    self.data = data
    self.status = status
  }

  func release(_ index: Int) { pending.removeValue(forKey: index)?.resume() }

  func releaseAll() {
    suspended = false
    let continuations = pending.values
    pending.removeAll()
    for continuation in continuations { continuation.resume() }
  }
}
