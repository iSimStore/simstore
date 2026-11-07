import Foundation

enum AppPackageTests {
  static func run() throws {
    try checksums()
    try validArchiveAndBundle()
    try invalidArchives()
    try invalidBundles()
    try frameworks()
    try nestedBundles()
    try symlinkBoundaries()
  }

  static func checksums() throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = Data(repeating: 0x42, count: 2 * 1024 * 1024 + 7)
    let path = directory.appending(component: "archive")
    try data.write(to: path)
    try AppPackage.verify(path, version: InstallationFixtures.version(data: data))
    try expectFailure {
      try AppPackage.verify(
        path, version: InstallationFixtures.version(data: Data(data.dropLast())))
    }
    var changed = data
    changed[changed.count - 1] = 0
    try changed.write(to: path)
    try expectFailure {
      try AppPackage.verify(path, version: InstallationFixtures.version(data: data))
    }
  }

  static func validArchiveAndBundle() throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let entries = try InstallationFixtures.entries().map { entry in
      var entry = entry
      entry = InstallationFixtures.Entry(
        path: entry.path.replacingOccurrences(of: "Example.app", with: "An App 名称.app"),
        data: entry.data, type: entry.type, target: entry.target, mode: entry.mode)
      return entry
    }
    let archive = try InstallationFixtures.archive(entries, in: directory)
    let app = try AppPackage.extract(archive, to: directory.appending(component: "extracted"))
    try AppPackage.validate(
      app, app: InstallationFixtures.app(), version: InstallationFixtures.version())
    try InstallationFixtures.require(
      app.lastPathComponent == "An App 名称.app", "Keep app filenames intact.")
  }

  static func invalidArchives() throws {
    let directory = try InstallationFixtures.temporaryDirectory(in: URL(fileURLWithPath: "/tmp"))
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appending(component: "outside")
    let original = Data("Keep outside files unchanged".utf8)
    try original.write(to: marker)
    let attacks: [[InstallationFixtures.Entry]] = [
      [],
      [.init(path: "../outside", data: Data("replaced".utf8))],
      [.init(path: marker.path, data: Data("replaced".utf8))],
      [.init(path: "Example.app/", type: 53), .init(path: "other.txt")],
      [.init(path: "Example.app", type: 50, target: directory.path)],
      [
        .init(path: "Example.app/link", type: 50, target: directory.path),
        .init(path: "Example.app/link/outside", data: Data("replaced".utf8)),
      ],
      [
        .init(path: "Example.app/outside", type: 49, target: "../outside"),
        .init(path: "Example.app/outside", data: Data("replaced".utf8)),
      ],
    ]
    for (index, entries) in attacks.enumerated() {
      let archive = try InstallationFixtures.archive(entries, in: directory)
      try expectFailure {
        _ = try AppPackage.extract(archive, to: directory.appending(component: "attack-\(index)"))
      }
      try InstallationFixtures.require(
        try Data(contentsOf: marker) == original, "Do not modify files outside extraction.")
    }
  }

  static func invalidBundles() throws {
    typealias Mutation = (URL) throws -> Void
    let mutations: [Mutation] = [
      {
        try InstallationFixtures.info(bundleID: "org.example.Other").write(
          to: $0.appending(path: "Info.plist"))
      },
      { try InstallationFixtures.info(version: "2.0").write(to: $0.appending(path: "Info.plist")) },
      {
        try InstallationFixtures.info(platform: "iPhoneOS").write(
          to: $0.appending(path: "Info.plist"))
      },
      {
        try InstallationFixtures.info(executable: "../Example").write(
          to: $0.appending(path: "Info.plist"))
      },
      {
        try InstallationFixtures.executable(
          InstallationFixtures.machO(platform: 2), at: $0.appending(path: "Example"))
      },
      {
        try InstallationFixtures.executable(
          InstallationFixtures.machO(cpu: 0x0100_0007), at: $0.appending(path: "Example"))
      },
      {
        try InstallationFixtures.executable(
          Data([0xCA, 0xFE, 0xBA, 0xBE]), at: $0.appending(path: "Example"))
      },
      {
        try InstallationFixtures.executable(
          Data("not Mach-O".utf8), at: $0.appending(path: "Example"))
      },
      {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o644], ofItemAtPath: $0.appending(path: "Example").path)
      },
      { bundle in
        var data = InstallationFixtures.machO()
        data[36] = 0xFF
        try InstallationFixtures.executable(data, at: bundle.appending(path: "Example"))
      },
      {
        try InstallationFixtures.machO(platform: 1, type: 6).write(
          to: $0.appending(path: "hidden-library"))
      },
      {
        try FileManager.default.createSymbolicLink(
          atPath: $0.appending(path: "escape").path, withDestinationPath: "/tmp")
      },
    ]
    for mutate in mutations {
      let directory = try InstallationFixtures.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let bundle = try InstallationFixtures.bundle(in: directory)
      try mutate(bundle)
      try expectFailure {
        try AppPackage.validate(
          bundle, app: InstallationFixtures.app(), version: InstallationFixtures.version())
      }
    }
  }

  static func frameworks() throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = try InstallationFixtures.bundle(in: directory)
    let framework = bundle.appending(path: "Frameworks/Test.framework")
    let resources = framework.appending(path: "Versions/A/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try InstallationFixtures.info(executable: "Test").write(
      to: resources.appending(path: "Info.plist"))
    let binary = framework.appending(path: "Versions/A/Test")
    try InstallationFixtures.executable(InstallationFixtures.machO(type: 6), at: binary)
    for (path, target) in [
      ("Versions/Current", "A"), ("Test", "Versions/Current/Test"),
      ("Resources", "Versions/Current/Resources"),
    ] {
      try FileManager.default.createSymbolicLink(
        atPath: framework.appending(path: path).path, withDestinationPath: target)
    }
    try AppPackage.validate(
      bundle, app: InstallationFixtures.app(), version: InstallationFixtures.version())
    try InstallationFixtures.executable(
      InstallationFixtures.machO(platform: 2, type: 6), at: binary)
    try expectFailure {
      try AppPackage.validate(
        bundle, app: InstallationFixtures.app(), version: InstallationFixtures.version())
    }
  }

  static func nestedBundles() throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = try InstallationFixtures.bundle(in: directory)
    let nested = bundle.appending(path: "PlugIns/Extension.appex")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let info = nested.appending(component: "Info.plist")
    let binary = nested.appending(component: "Extension")
    try InstallationFixtures.info(executable: "Extension").write(to: info)
    try InstallationFixtures.executable(InstallationFixtures.machO(), at: binary)
    try AppPackage.validate(
      bundle, app: InstallationFixtures.app(), version: InstallationFixtures.version())
    try InstallationFixtures.info(executable: "Extension", platform: "iPhoneOS").write(to: info)
    do {
      try AppPackage.validate(
        bundle, app: InstallationFixtures.app(), version: InstallationFixtures.version())
      throw InstallationFixtures.failure("Reject nested bundles built for physical devices.")
    } catch AppPackage.Failure.invalidBundle {}
    try InstallationFixtures.info(executable: "Extension").write(to: info)
    try InstallationFixtures.machO(platform: 1).write(to: binary)
    do {
      try AppPackage.validate(
        bundle, app: InstallationFixtures.app(), version: InstallationFixtures.version())
      throw InstallationFixtures.failure("Reject a nested binary for the wrong platform.")
    } catch AppPackage.Failure.unsupportedBinary {}
    try Data("not a binary".utf8).write(to: binary)
    do {
      try AppPackage.validate(
        bundle, app: InstallationFixtures.app(), version: InstallationFixtures.version())
      throw InstallationFixtures.failure("Require a Mach-O executable for a nested bundle.")
    } catch AppPackage.Failure.invalidBundle {}
  }

  static func symlinkBoundaries() throws {
    let directory = try InstallationFixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = try InstallationFixtures.bundle(in: directory)
    let link = bundle.appending(component: "alias")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Info.plist")
    try AppPackage.validate(
      bundle, app: InstallationFixtures.app(), version: InstallationFixtures.version())
    try FileManager.default.removeItem(at: link)
    let sibling = directory.appending(component: "Example.app-sibling")
    try Data("outside".utf8).write(to: sibling)
    for target in [sibling.path, "missing-file"] {
      try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
      do {
        try AppPackage.validate(
          bundle, app: InstallationFixtures.app(), version: InstallationFixtures.version())
        throw InstallationFixtures.failure("Reject escaping or dangling symlinks.")
      } catch AppPackage.Failure.invalidBundle {}
      try FileManager.default.removeItem(at: link)
    }
  }

  static func expectFailure(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw InstallationFixtures.failure("Invalid input must fail before installation.")
  }
}
