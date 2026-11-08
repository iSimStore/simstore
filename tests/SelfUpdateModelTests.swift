import Foundation

enum SelfUpdateModelTests {
  static func run() throws {
    try largeVersionComponents()
    let nightly = try SelfUpdateFixtures.release(["tag": "latest", "build": 8])
    let stable = try SelfUpdateFixtures.release()
    let old = try SelfUpdateFixtures.release(["tag": "0.1.10", "version": "0.1.10"])
    let older = try SelfUpdateFixtures.release(["tag": "0.1.9", "version": "0.1.9"])
    let index = try SelfUpdateIndex.decode(SelfUpdateFixtures.index([older, nightly, stable, old]))
    try SelfUpdateFixtures.require(
      index.recommendedUpdate(from: SelfUpdateFixtures.current(), os: "14.0") == stable,
      "Stable must win over a newer nightly, regardless of input ordering.")
    try SelfUpdateFixtures.require(
      index.recommendedUpdate(from: SelfUpdateFixtures.current(version: "0.2.0"), os: "14.0")
        == nightly,
      "The latest compatible stable may opt into a newer nightly.")
    try SelfUpdateFixtures.require(
      index.recommendedUpdate(
        from: SelfUpdateFixtures.current(version: "0.2.0", build: 8), os: "14.0") == nil,
      "Do not reinstall the same nightly or downgrade to stable.")
    try SelfUpdateFixtures.require(
      index.recommendedUpdate(
        from: SelfUpdateFixtures.current(version: "0.1.10", build: 999), os: "14.0") == stable,
      "A stable version bump outranks the previous version's commit count.")
    let futureStable = try SelfUpdateFixtures.release(["minOS": "26.0"])
    let futureNightly = try SelfUpdateFixtures.release([
      "tag": "latest", "build": 8, "minOS": "27.0",
    ])
    let limited = try SelfUpdateIndex.decode(
      SelfUpdateFixtures.index([futureStable, older, futureNightly, old]))
    try SelfUpdateFixtures.require(
      limited.recommendedUpdate(from: SelfUpdateFixtures.current(), os: "14.6.1") == old,
      "Keep the newest stable that can run on the current OS and compare numeric versions.")
    try SelfUpdateFixtures.require(
      limited.recommendedUpdate(from: SelfUpdateFixtures.current(version: "0.1.10"), os: "14.6.1")
        == nil,
      "Never offer an incompatible nightly after reaching the compatible stable.")
    try SelfUpdateFixtures.require(
      !nightly.isCompatible(with: "invalid"), "Unknown OS versions must fail closed.")
    try SelfUpdateFixtures.rejects {
      _ = try SelfUpdateIndex.decode(SelfUpdateFixtures.index([stable]))
    }
    try SelfUpdateFixtures.rejects {
      _ = try SelfUpdateIndex.decode(SelfUpdateFixtures.index([nightly, nightly]))
    }
    try SelfUpdateFixtures.rejects {
      _ = try SelfUpdateIndex.decode(SelfUpdateFixtures.index([nightly, stable, stable]))
    }
    let invalid: [[String: Any]] = [
      ["version": "0.2"], ["version": "00.2.0"], ["tag": "v0.2.0"], ["build": 1], ["build": true],
      ["build": -1], ["build": "0"], ["size": 0], ["time": -1], ["revision": "abc"],
      ["sha256": "xyz"],
      ["minOS": "0"], ["minOS": "14.0.0.1"],
      ["version": "\(Int.max)0.0.0", "tag": "\(Int.max)0.0.0"],
      ["version": "1.0.\(Int.max)0", "tag": "1.0.\(Int.max)0"],
      ["minOS": "\(Int.max)0"],
    ]
    for value in invalid {
      try SelfUpdateFixtures.rejects { _ = try SelfUpdateFixtures.release(value) }
    }
    try SelfUpdateFixtures.require(
      SelfUpdateFixtures.current(build: 12).description == "0.1.0-12-gaaaaaaa",
      "Show the Git-derived version in About.")
    print(
      "PASS: compatible stable priority, nightly opt-in, numeric ordering, and strict update metadata."
    )
  }

  static func largeVersionComponents() throws {
    let highest = "\(Int.max).1.0"
    let stable = try SelfUpdateFixtures.release(["version": highest, "tag": highest])
    let lower = "\(Int.max - 1).99.99"
    let previous = try SelfUpdateFixtures.release(["version": lower, "tag": lower])
    let nightly = try SelfUpdateFixtures.release([
      "version": highest, "tag": "latest", "build": 1,
    ])
    let releases = [previous, nightly, stable]
    for versions in [releases, Array(releases.reversed())] {
      let index = try SelfUpdateIndex.decode(SelfUpdateFixtures.index(versions))
      try SelfUpdateFixtures.require(
        index.recommendedUpdate(from: SelfUpdateFixtures.current(), os: "14.0") == stable,
        "Select the highest numeric stable even when components reach Int.max.")
      try SelfUpdateFixtures.require(
        index.recommendedUpdate(from: SelfUpdateFixtures.current(version: highest), os: "14.0")
          == nightly,
        "Keep nightly opt-in and build comparison after reaching the highest stable.")
    }
  }
}
