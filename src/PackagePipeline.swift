import Foundation

struct PackagePipeline: Sendable {
  typealias Progress = @MainActor @Sendable (AppInstallationPhase) -> Void

  let size: Int64
  let sha256: String
  let download: AppDownload.Fetch
  var command: Command.Runner = Command.run

  func prepare(
    from url: URL, archive: URL, extractingTo contents: URL, progress: @escaping Progress,
    validate: @escaping @Sendable (URL) throws -> Void,
    afterValidation: @escaping @Sendable () throws -> Void = {}
  ) async throws -> URL {
    try Task.checkCancellation()
    await progress(.downloading(0))
    try await AppDownload.fetch(from: url, to: archive, using: download) { bytes in
      progress(.downloading(bytes))
    }
    try Task.checkCancellation()
    await progress(.verifying)
    let preparation = Task.detached(priority: .userInitiated) {
      try AppPackage.verify(archive, size: size, sha256: sha256)
      try Task.checkCancellation()
      await progress(.extracting)
      let bundle = try AppPackage.extract(archive, to: contents, command: command)
      try validate(bundle)
      try Task.checkCancellation()
      try afterValidation()
      try Task.checkCancellation()
      return bundle
    }
    let bundle = try await withTaskCancellationHandler {
      try await preparation.value
    } onCancel: {
      preparation.cancel()
    }
    try Task.checkCancellation()
    return bundle
  }
}
