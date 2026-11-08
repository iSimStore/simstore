import Darwin
import Foundation

enum AppDownloadTests {
  @MainActor
  static func run() async throws {
    try await progressDeliveryAndCompletion()
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = Data(repeating: 0x42, count: 4 * 1024 * 1024)
    let server = try DownloadTestServer(data: payload)
    let serving = Task.detached { server.serve() }
    let counter = DownloadCounter()
    let destination = directory.appending(component: "download")
    try await AppDownload.fetch(from: server.url, to: destination) { counter.record($0) }
    await serving.value
    try InstallationFixtures.require(
      counter.bytes == Int64(payload.count), "Real HTTP downloads must report the final byte count."
    )
    try InstallationFixtures.require(
      try Data(contentsOf: destination) == payload, "Write the complete download to disk.")

    let failureServer = try DownloadTestServer(data: Data("Unavailable".utf8), status: 503)
    let failedServing = Task.detached { failureServer.serve() }
    let failed = directory.appending(component: "failed")
    do {
      try await AppDownload.fetch(from: failureServer.url, to: failed) { _ in }
      throw InstallationFixtures.failure("Do not accept HTTP errors as downloads.")
    } catch AppDownload.Failure.httpStatus(503) {}
    await failedServing.value
    try InstallationFixtures.require(
      !FileManager.default.fileExists(atPath: failed.path), "Discard failed HTTP responses.")

    let cancelServer = try DownloadTestServer(data: payload)
    let cancelServing = Task.detached { cancelServer.serve() }
    let canceled = directory.appending(component: "canceled")
    let cancelCounter = DownloadCounter()
    let download = Task {
      try await AppDownload.fetch(from: cancelServer.url, to: canceled) { cancelCounter.record($0) }
    }
    try await InstallationFixtures.eventually { cancelCounter.bytes > 0 }
    download.cancel()
    do {
      try await download.value
      throw InstallationFixtures.failure("A canceled download must throw.")
    } catch is CancellationError {}
    await cancelServing.value
    try InstallationFixtures.require(
      !FileManager.default.fileExists(atPath: canceled.path), "Remove canceled downloads.")
    do {
      try await AppDownload.fetch(from: server.url, to: destination) { _ in }
      throw InstallationFixtures.failure("Do not replace an existing destination.")
    } catch CocoaError.fileWriteFileExists {}
    try InstallationFixtures.require(
      try Data(contentsOf: destination) == payload,
      "Preserve a pre-existing file when a download cannot start.")
    try await terminalFailures(in: directory)
  }

  @MainActor
  static func terminalFailures(in directory: URL) async throws {
    let partial = Data("partial".utf8)
    let truncated = try DownloadTestServer(data: partial, contentLength: partial.count * 2)
    let truncatedServing = Task.detached { truncated.serve() }
    let incomplete = directory.appending(component: "incomplete")
    do {
      try await AppDownload.fetch(from: truncated.url, to: incomplete) { _ in }
      throw InstallationFixtures.failure("A truncated HTTP body must not complete successfully.")
    } catch {
      try InstallationFixtures.require(
        (error as NSError).domain == NSURLErrorDomain, "Preserve the transport failure.")
    }
    await truncatedServing.value
    try InstallationFixtures.require(
      !FileManager.default.fileExists(atPath: incomplete.path), "Discard incomplete downloads.")

    let server = try DownloadTestServer(data: partial)
    let serving = Task.detached { server.serve() }
    let unwritable = directory.appending(path: "missing-parent/archive")
    do {
      try await AppDownload.fetch(from: server.url, to: unwritable) { _ in }
      throw InstallationFixtures.failure("A failed destination move must fail the download.")
    } catch {
      let domain = (error as NSError).domain
      try InstallationFixtures.require(
        domain == NSCocoaErrorDomain || domain == NSPOSIXErrorDomain,
        "Preserve the destination file error.")
    }
    await serving.value
    try InstallationFixtures.require(
      !FileManager.default.fileExists(atPath: unwritable.path), "Do not leave a failed destination."
    )
  }

  @MainActor
  static func progressDeliveryAndCompletion() async throws {
    let expected = InstallationFixtures.failure("Download progress failure")
    let errors: [Error?] = [nil, expected, CancellationError()]
    for error in errors {
      let source = DownloadProgressSource()
      var values: [Int64] = []
      var times: [ContinuousClock.Instant] = []
      let download = Task {
        try await AppDownload.fetch(
          from: URL(string: "https://example.com/archive")!,
          to: URL(fileURLWithPath: "/unused"), using: source.download
        ) {
          values.append($0)
          times.append(ContinuousClock.now)
        }
      }
      try await InstallationFixtures.eventually { values == [1] }
      await source.report(2)
      if error is CancellationError { download.cancel() }
      await source.finish(error: error)
      let result = await download.result
      switch result {
      case .success:
        try InstallationFixtures.require(error == nil, "A failed download must still throw.")
        try InstallationFixtures.require(
          values == [1, 2] && times[0].duration(to: times[1]) >= .milliseconds(90),
          "Deliver live progress at a bounded rate and flush the final byte count on success.")
      case .failure(let caught):
        try InstallationFixtures.require(
          (error is CancellationError && caught is CancellationError)
            || (error as? NSError == expected && caught as NSError == expected),
          "Preserve download errors and cancellation while stopping pending progress.")
      }
      let finishedCount = values.count
      await source.report(3)
      // Observe longer than one update interval to catch an outstanding progress delivery.
      try await Task.sleep(for: .milliseconds(150))
      try InstallationFixtures.require(
        values.count == finishedCount,
        "Late callbacks must not update progress after success, failure, or cancellation returns.")
    }
  }
}

private actor DownloadProgressSource {
  private var progress: AppDownload.Progress?
  private var pending: CheckedContinuation<Void, Error>?

  func download(_ url: URL, _ destination: URL, _ progress: @escaping AppDownload.Progress)
    async throws
  {
    self.progress = progress
    progress(1)
    try await withCheckedThrowingContinuation { pending = $0 }
  }

  func report(_ bytes: Int64) { progress?(bytes) }

  func finish(error: Error?) {
    let continuation = pending
    pending = nil
    if let error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
  }
}

private final class DownloadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var received: Int64 = 0
  var bytes: Int64 { lock.withLock { received } }
  func record(_ bytes: Int64) { lock.withLock { received = max(received, bytes) } }
}

private final class DownloadTestServer: Sendable {
  let url: URL
  private let socket: Int32
  private let data: Data
  private let status: Int
  private let contentLength: Int

  init(data: Data, status: Int = 200, contentLength: Int? = nil) throws {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { throw InstallationFixtures.failure("Cannot open test socket.") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(socket, 1) == 0 else {
      close(socket)
      throw InstallationFixtures.failure("Cannot bind test socket.")
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
    }
    guard named == 0 else {
      close(socket)
      throw InstallationFixtures.failure("Cannot read test port.")
    }
    self.socket = socket
    self.data = data
    self.status = status
    self.contentLength = contentLength ?? data.count
    url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/app.tar.bz2")!
  }

  func serve() {
    defer { close(socket) }
    var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, 5000) > 0 else { return }
    let client = accept(socket, nil, nil)
    guard client >= 0 else { return }
    defer { close(client) }
    var noSignal: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var request = [UInt8](repeating: 0, count: 8192)
    guard recv(client, &request, request.count, 0) > 0 else { return }
    let header = Data(
      "HTTP/1.1 \(status) Test\r\nContent-Length: \(contentLength)\r\nConnection: close\r\n\r\n"
        .utf8)
    guard write(header, to: client) else { return }
    for offset in stride(from: 0, to: data.count, by: 32 * 1024) {
      guard write(data.subdata(in: offset..<min(data.count, offset + 32 * 1024)), to: client) else {
        return
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
  }

  private func write(_ bytes: Data, to client: Int32) -> Bool {
    bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = send(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
        if count <= 0 { return false }
        offset += count
      }
      return true
    }
  }
}
