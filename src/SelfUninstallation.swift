import AppKit
import CoreFoundation
import Darwin

struct SelfUninstallRequest: Codable {
  let application: URL
  let bundleID: String
  let parentPID: Int32
  var language = "en"
}

struct SelfUninstallPlan {
  let application: URL
  let bundleID: String
  let library: URL
  let temporary: URL

  init(
    application: URL, bundleID: String,
    library: URL = .libraryDirectory, temporary: URL = .temporaryDirectory
  ) throws {
    let application = application.resolvingSymlinksInPath().standardizedFileURL
    guard application.isFileURL, application.pathExtension == "app",
      !bundleID.isEmpty, ![".", ".."].contains(bundleID),
      !bundleID.contains("/"), !bundleID.contains("\\"),
      let info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: application.appending(path: "Contents/Info.plist")),
        format: nil) as? [String: Any],
      info["CFBundleIdentifier"] as? String == bundleID
    else { throw SelfUninstallError.invalidApplication }
    self.application = application
    self.bundleID = bundleID
    self.library = library
    self.temporary = temporary
  }

  func dataPaths(excluding work: URL? = nil) throws -> [URL] {
    var paths = [
      "Application Support/\(bundleID)", "Caches/\(bundleID)", "HTTPStorages/\(bundleID)",
      "HTTPStorages/\(bundleID).binarycookies", "Logs/\(bundleID)", "WebKit/\(bundleID)",
      "Preferences/\(bundleID).plist", "Saved Application State/\(bundleID).savedState",
    ].map { library.appending(path: $0) }
    for url in try children(of: library.appending(path: "Preferences/ByHost")) {
      let name = url.lastPathComponent
      if name.hasPrefix(bundleID + "."), name.hasSuffix(".plist"),
        UUID(uuidString: String(name.dropFirst(bundleID.count + 1).dropLast(6))) != nil
      {
        paths.append(url)
      }
    }
    for url in try children(of: temporary)
    where url.standardizedFileURL.path != work?.standardizedFileURL.path {
      if owns(url, prefix: bundleID + "-") || owns(url, prefix: bundleID + ".uninstall-") {
        paths.append(url)
      }
    }
    for url in try children(of: application.deletingLastPathComponent()) {
      if owns(url, prefix: ".simstore-update-") {
        if let data = try? Data(contentsOf: url.appending(component: "request.json")),
          let owner = try? JSONDecoder().decode(UpdateOwner.self, from: data),
          owner.application.resolvingSymlinksInPath().path != application.path
        {
          continue
        }
        paths.append(url)
      }
    }
    return paths
  }

  func removeData(excluding work: URL? = nil) throws {
    for url in try dataPaths(excluding: work) { try SelfUninstallation.removeIfPresent(url) }
  }

  private func owns(_ url: URL, prefix: String) -> Bool {
    let name = url.lastPathComponent
    return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
  }

  private struct UpdateOwner: Decodable { let application: URL }

  private func children(of directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
  }
}

enum SelfUninstallation {
  static func removeIfPresent(_ url: URL) throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
    }
  }

  static func clearPreferences(_ bundleID: String) throws {
    let application = bundleID as CFString
    for host in [kCFPreferencesAnyHost, kCFPreferencesCurrentHost] {
      if let keys = CFPreferencesCopyKeyList(application, kCFPreferencesCurrentUser, host) {
        CFPreferencesSetMultiple(nil, keys, application, kCFPreferencesCurrentUser, host)
      }
      guard CFPreferencesSynchronize(application, kCFPreferencesCurrentUser, host) else {
        throw SelfUninstallError.helperFailed
      }
    }
  }

  @MainActor
  static func run(from directory: URL) async throws {
    let request = try JSONDecoder().decode(
      SelfUninstallRequest.self,
      from: Data(contentsOf: directory.appending(component: "request.json")))
    let plan = try SelfUninstallPlan(application: request.application, bundleID: request.bundleID)
    let prefix = request.bundleID + ".uninstall-"
    guard
      directory.deletingLastPathComponent().resolvingSymlinksInPath()
        == URL.temporaryDirectory.resolvingSymlinksInPath(),
      directory.lastPathComponent.hasPrefix(prefix),
      UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count)))
        != nil,
      request.parentPID > 1, request.parentPID != getpid(),
      let running = NSRunningApplication(processIdentifier: request.parentPID),
      running.bundleIdentifier == request.bundleID,
      running.bundleURL?.resolvingSymlinksInPath().path == plan.application.path
    else { throw SelfUninstallError.invalidApplication }
    guard
      FileManager.default.isWritableFile(atPath: plan.application.deletingLastPathComponent().path),
      !plan.application.pathComponents.contains("AppTranslocation")
    else { throw SelfUninstallError.notWritable }
    try Task.checkCancellation()
    guard kill(request.parentPID, SIGSTOP) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ESRCH)
    }
    var completed = false
    defer { if !completed { kill(request.parentPID, SIGCONT) } }
    try await waitUntilStopped(request.parentPID)
    try Task.checkCancellation()
    try clearPreferences(request.bundleID)
    try plan.removeData(excluding: directory)
    try FileManager.default.removeItem(at: plan.application)
    try removeIfPresent(directory)
    // A normal quit can save preferences or window state again after they have been deleted.
    guard kill(request.parentPID, SIGKILL) == 0 || errno == ESRCH else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
    }
    completed = true
  }

  @MainActor
  static func waitUntilStopped(_ pid: Int32, timeout: Duration = .seconds(5)) async throws {
    // Wait for every app thread to stop before removing files its background tasks can write.
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
      try Task.checkCancellation()
      var info = proc_bsdinfo()
      guard
        proc_pidinfo(
          pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
          > 0
      else { throw POSIXError(.ESRCH) }
      if info.pbi_status == SSTOP { break }
      guard clock.now < deadline else { throw SelfUninstallError.helperFailed }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

enum SelfUninstallError: LocalizedError {
  case invalidApplication, notWritable, helperFailed

  var errorDescription: String? {
    message(in: .main)
  }

  func message(in bundle: Bundle) -> String {
    switch self {
    case .invalidApplication:
      String(
        localized: "The running SimStore app could not be verified. Nothing was uninstalled.",
        bundle: bundle)
    case .notWritable:
      String(
        localized: "Move SimStore to a writable folder before uninstalling it.", bundle: bundle)
    case .helperFailed:
      String(localized: "The uninstall assistant could not finish. Try again.", bundle: bundle)
    }
  }
}
