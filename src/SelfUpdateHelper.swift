import AppKit

@main
struct SelfUpdateHelper {
  @MainActor
  static func main() async {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--uninstall" {
      let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        .standardizedFileURL
      do {
        try await SelfUninstallation.run(from: directory)
      } catch {
        var message = error.localizedDescription
        if let uninstallError = error as? SelfUninstallError,
          let data = try? Data(contentsOf: directory.appending(component: "request.json")),
          let request = try? JSONDecoder().decode(SelfUninstallRequest.self, from: data)
        {
          message = uninstallError.message(
            in: SelfUpdateInstallation.localizationBundle(
              application: request.application, language: request.language))
        }
        try? JSONEncoder().encode(message).write(
          to: directory.appending(component: "error.json"), options: .atomic)
        exit(EXIT_FAILURE)
      }
      return
    }
    guard CommandLine.arguments.count == 2 else { exit(EXIT_FAILURE) }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      .standardizedFileURL
    var request: SelfUpdateRequest?
    do {
      let update = try SelfUpdateRequest.read(from: directory)
      request = update
      try SelfUpdatePackage.validate(
        SelfUpdateRequest.payload(in: directory), release: update.release, bundleID: update.bundleID
      )
      try Data().write(to: directory.appending(component: "ready"), options: .atomic)
      try await SelfUpdateInstallation.waitForExit(update.parentPID)
      try await SelfUpdateInstallation.replace(request: update, directory: directory)
      try? FileManager.default.removeItem(at: directory)
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      if let request {
        let bundle = SelfUpdateInstallation.localizationBundle(
          application: request.application, language: request.language)
        try? SelfUpdateInstallation.writeFailure(error, to: request.reportURL, bundle: bundle)
        if !SelfUpdateInstallation.isRunning(request.parentPID) {
          do {
            guard
              try SelfUpdateBuild.read(at: request.application).revision == request.currentRevision
            else { throw error }
            try await SelfUpdateInstallation.launchApplication(request.application)
          } catch {
            SelfUpdateInstallation.showFailure(error, bundle: bundle)
            exit(EXIT_FAILURE)
          }
        }
        try? FileManager.default.removeItem(at: directory)
      }
      exit(EXIT_FAILURE)
    }
  }
}
