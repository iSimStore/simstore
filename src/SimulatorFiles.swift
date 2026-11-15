import Foundation

enum SimulatorFiles {
  /// Resolve the local Files provider directly so shutdown devices remain accessible.
  static func directory(in dataPath: URL?) throws -> URL {
    guard let dataPath else { throw SimulatorFilesError.unavailable }
    let containers = dataPath.appending(
      path: "Containers/Shared/AppGroup", directoryHint: .isDirectory)
    let manager = FileManager.default
    guard manager.fileExists(atPath: containers.path) else {
      throw SimulatorFilesError.unavailable
    }
    for container in try manager.contentsOfDirectory(
      at: containers, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    {
      let metadata = container.appending(
        component: ".com.apple.mobile_container_manager.metadata.plist")
      guard let data = try? Data(contentsOf: metadata),
        let properties = (try? PropertyListSerialization.propertyList(from: data, format: nil))
          as? [String: Any],
        properties["MCMMetadataIdentifier"] as? String
          == "group.com.apple.FileProvider.LocalStorage"
      else { continue }
      let directory = container.appending(
        component: "File Provider Storage", directoryHint: .isDirectory)
      var isDirectory: ObjCBool = false
      if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        return directory
      }
    }
    throw SimulatorFilesError.unavailable
  }
}

enum SimulatorFilesError: LocalizedError {
  case unavailable
  case couldNotOpen

  var errorDescription: String? {
    switch self {
    case .unavailable:
      String(localized: "Local files aren’t available yet. Start the simulator and try again.")
    case .couldNotOpen:
      String(localized: "The folder could not be opened in Finder. Try again.")
    }
  }
}
