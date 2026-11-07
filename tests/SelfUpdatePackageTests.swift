import Foundation

enum SelfUpdatePackageTests {
  static func run() throws {
    try symlinkBoundaries()
    let directory = try SelfUpdateFixtures.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let release = try SelfUpdateFixtures.release()
    let application = try SelfUpdateFixtures.bundle(in: directory, release: release)
    try SelfUpdatePackage.validate(
      application, release: release, bundleID: SelfUpdateFixtures.bundleID)
    let original = try SelfUpdatePackage.info(at: application)
    let mutations: [[String: Any]] = [
      ["CFBundleIdentifier": "org.other.App"], ["CFBundleShortVersionString": "0.1.0"],
      ["CFBundleVersion": "2"], ["CFBundleVersion": 0], ["CFBundleVersion": "00"],
      ["SimStoreRevision": String(repeating: "c", count: 40)], ["SimStoreCommitTime": 1],
      ["SimStoreSourceDirty": true], ["LSMinimumSystemVersion": "13.0"],
      ["CFBundleExecutable": "../../outside"], ["CFBundlePackageType": "FMWK"],
    ]
    for changes in mutations {
      var info = original
      info.merge(changes) { _, new in new }
      try SelfUpdateFixtures.writeInfo(info, at: application)
      try SelfUpdateFixtures.rejects {
        try SelfUpdatePackage.validate(
          application, release: release, bundleID: SelfUpdateFixtures.bundleID)
      }
    }
    try SelfUpdateFixtures.writeInfo(original, at: application)
    try SelfUpdateFixtures.rejects {
      try SelfUpdatePackage.validate(
        application, release: release, bundleID: SelfUpdateFixtures.bundleID, os: "13.6")
    }
    let binary = application.appending(path: "Contents/MacOS/SimStore")
    for data in [
      SelfUpdateFixtures.machO(platform: 7), SelfUpdateFixtures.machO(cpu: 0x0100_0007),
      SelfUpdateFixtures.machO(minOS: 15 << 16), Data("not executable".utf8),
    ] {
      try data.write(to: binary)
      try SelfUpdateFixtures.rejects {
        try SelfUpdatePackage.validate(
          application, release: release, bundleID: SelfUpdateFixtures.bundleID)
      }
    }
    try SelfUpdateFixtures.machO().write(to: binary)
    let hidden = application.appending(path: "Contents/Resources/hidden")
    try FileManager.default.createDirectory(
      at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
    try SelfUpdateFixtures.machO(platform: 7).write(to: hidden)
    try SelfUpdateFixtures.rejects {
      try SelfUpdatePackage.validate(
        application, release: release, bundleID: SelfUpdateFixtures.bundleID)
    }
    try FileManager.default.removeItem(at: hidden)
    try FileManager.default.createSymbolicLink(
      atPath: hidden.path, withDestinationPath: directory.path)
    try SelfUpdateFixtures.rejects {
      try SelfUpdatePackage.validate(
        application, release: release, bundleID: SelfUpdateFixtures.bundleID)
    }
    try FileManager.default.removeItem(at: hidden)
    let helper = application.appending(path: "Contents/Helpers/SimStoreUpdater")
    var library = SelfUpdateFixtures.machO()
    library[12] = 6
    for data in [SelfUpdateFixtures.machO(platform: 7), library, Data("not Mach-O".utf8)] {
      try data.write(to: helper)
      try SelfUpdateFixtures.rejects {
        try SelfUpdatePackage.validate(
          application, release: release, bundleID: SelfUpdateFixtures.bundleID)
      }
    }
    try SelfUpdateFixtures.machO().write(to: helper)
    try FileManager.default.removeItem(
      at: application.appending(path: "Contents/Helpers/SimStoreUpdater"))
    try SelfUpdateFixtures.rejects {
      try SelfUpdatePackage.validate(
        application, release: release, bundleID: SelfUpdateFixtures.bundleID)
    }
    print(
      "PASS: app identity, actual minimum OS/platform/architecture, helper executable, and symlink boundaries."
    )
  }

  static func symlinkBoundaries() throws {
    let directory = try SelfUpdateFixtures.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let release = try SelfUpdateFixtures.release()
    let application = try SelfUpdateFixtures.bundle(in: directory, release: release)
    let link = application.appending(path: "Contents/alias")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Info.plist")
    try SelfUpdatePackage.validate(
      application, release: release, bundleID: SelfUpdateFixtures.bundleID)
    try FileManager.default.removeItem(at: link)
    let sibling = directory.appending(component: "SimStore.app-sibling")
    try Data("outside".utf8).write(to: sibling)
    for target in [sibling.path, "missing-file"] {
      try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
      do {
        try SelfUpdatePackage.validate(
          application, release: release, bundleID: SelfUpdateFixtures.bundleID)
        throw SelfUpdateFixtures.failure("Reject escaping or dangling symlinks in self-updates.")
      } catch SelfUpdateError.wrongApplication {}
      try FileManager.default.removeItem(at: link)
    }
  }
}
