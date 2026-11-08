import Foundation

enum AppDownload {
  typealias Progress = @Sendable (Int64) -> Void
  typealias Fetch = @Sendable (URL, URL, @escaping Progress) async throws -> Void

  static func fetch(
    from url: URL, to destination: URL, using download: Fetch,
    progress: @escaping @MainActor @Sendable (Int64) -> Void
  ) async throws {
    try Task.checkCancellation()
    let (stream, continuation) = AsyncStream.makeStream(
      of: Int64.self, bufferingPolicy: .bufferingNewest(1))
    // One consumer coalesces callbacks before hopping to the main actor.
    let updates = Task.detached(priority: .utility) {
      let clock = ContinuousClock()
      var nextUpdate = clock.now
      for await bytes in stream {
        do {
          try await clock.sleep(until: nextUpdate)
          try Task.checkCancellation()
        } catch { break }
        await progress(bytes)
        nextUpdate = clock.now.advanced(by: .milliseconds(100))
      }
    }
    try await withTaskCancellationHandler {
      do {
        try await download(url, destination) { continuation.yield($0) }
        try Task.checkCancellation()
        continuation.finish()
        // Deliver the final sample before a caller advances to verification.
        await updates.value
        try Task.checkCancellation()
      } catch {
        updates.cancel()
        continuation.finish()
        await updates.value
        throw error
      }
    } onCancel: {
      updates.cancel()
      continuation.finish()
    }
  }

  static func fetch(from url: URL, to destination: URL, progress: @escaping Progress) async throws {
    try Task.checkCancellation()
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 60
    let transfer = AppDownloadTransfer(destination: destination, progress: progress)
    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { transfer.start(request, continuation: $0) }
      } onCancel: {
        transfer.cancel()
      }
      try Task.checkCancellation()
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  enum Failure: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
      switch self {
      case .invalidResponse:
        String(localized: "The download server returned an invalid response.")
      case .httpStatus(let status):
        String(localized: "The download server returned HTTP \(status).")
      }
    }
  }
}

private final class AppDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let destination: URL
  private let progress: AppDownload.Progress
  private let lock = NSLock()
  private var session: URLSession?
  private var continuation: CheckedContinuation<Void, Error>?
  private var result: Result<Void, Error>?
  private var canceled = false

  init(destination: URL, progress: @escaping AppDownload.Progress) {
    self.destination = destination
    self.progress = progress
  }

  func start(_ request: URLRequest, continuation: CheckedContinuation<Void, Error>) {
    lock.withLock {
      guard !canceled else {
        continuation.resume(throwing: CancellationError())
        return
      }
      self.continuation = continuation
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      configuration.timeoutIntervalForRequest = 60
      configuration.timeoutIntervalForResource = 3600
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      self.session = session
      let task = session.downloadTask(with: request)
      task.resume()
    }
  }

  func cancel() {
    let session = lock.withLock { () -> URLSession? in
      guard !canceled else { return nil }
      canceled = true
      return self.session
    }
    session?.invalidateAndCancel()
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    progress(totalBytesWritten)
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let result = Result {
      guard let response = downloadTask.response as? HTTPURLResponse else {
        throw AppDownload.Failure.invalidResponse
      }
      guard (200..<300).contains(response.statusCode) else {
        throw AppDownload.Failure.httpStatus(response.statusCode)
      }
      try FileManager.default.moveItem(at: location, to: destination)
    }
    lock.withLock { self.result = result }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    let completion = lock.withLock {
      let continuation = continuation
      let session = canceled ? nil : self.session
      self.continuation = nil
      self.session = nil
      let result: Result<Void, Error> =
        if canceled { .failure(CancellationError()) } else if let error { .failure(error) } else {
          self.result ?? .failure(AppDownload.Failure.invalidResponse)
        }
      self.result = nil
      return (continuation: continuation, result: result, session: session)
    }
    // Cancellation invalidates the session; other outcomes close it here.
    completion.session?.finishTasksAndInvalidate()
    completion.continuation?.resume(with: completion.result)
  }
}
