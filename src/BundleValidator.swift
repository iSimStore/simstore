import Foundation

struct BundleValidator {
  let platform: UInt32
  let invalidBundle: Error
  let binaryFailure: (Error) -> Error

  func validate(
    _ root: URL, required: Set<URL>, isExecutable: (URL) -> Bool,
    nestedExecutable: (URL) throws -> URL? = { _ in nil },
    validateMinimum: (URL, CatalogVersionNumber) throws -> Void = { _, _ in }
  ) throws {
    var required = Set(required.map { $0.resolvingSymlinksInPath().standardizedFileURL })
    guard required.allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) }) else {
      throw invalidBundle
    }
    var enumerationError: Error?
    guard
      let files = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else { throw invalidBundle }
    var checked: Set<URL> = []
    for case let path as URL in files {
      try Task.checkCancellation()
      let resolved = path.resolvingSymlinksInPath().standardizedFileURL
      guard resolved.pathComponents.starts(with: root.pathComponents),
        FileManager.default.fileExists(atPath: resolved.path)
      else { throw invalidBundle }
      if let executable = try nestedExecutable(path) {
        required.insert(executable.resolvingSymlinksInPath().standardizedFileURL)
      }
      guard try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
        !checked.contains(resolved)
      else { continue }
      let file = try FileHandle(forReadingFrom: path)
      let magic = try file.read(upToCount: 4) ?? Data()
      try file.close()
      guard MachOValidation.isMachO(magic) else { continue }
      let minimum: CatalogVersionNumber
      do {
        minimum = try MachOValidation.validate(
          Data(contentsOf: path, options: .mappedIfSafe), platform: platform,
          isExecutable: isExecutable(resolved))
      } catch {
        throw binaryFailure(error)
      }
      try validateMinimum(resolved, minimum)
      checked.insert(resolved)
    }
    if let enumerationError { throw enumerationError }
    guard required.isSubset(of: checked) else { throw invalidBundle }
  }

  static func info(at path: URL, invalidBundle: Error) throws -> [String: Any] {
    guard
      let info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: path), format: nil) as? [String: Any]
    else { throw invalidBundle }
    return info
  }

  static func executable(in directory: URL, named value: Any?, invalidBundle: Error) throws -> URL {
    guard let name = value as? String, !name.isEmpty,
      name != ".", name != "..", !name.contains("/"),
      FileManager.default.isExecutableFile(atPath: directory.appending(component: name).path)
    else { throw invalidBundle }
    return directory.appending(component: name).resolvingSymlinksInPath().standardizedFileURL
  }
}
