import AppKit
import SwiftUI

@MainActor
enum AppInstallButtonTests {
  static func run() async throws {
    NSApplication.shared.setActivationPolicy(.regular)
    let app = InstallationFixtures.app()
    let device = InstallationFixtures.device
    let probe = RefreshUpdateInventory(bundleID: app.bundleID)
    let inventory = InstalledAppsStore(load: { _ in try await probe.load() })
    await inventory.refresh(for: device)
    let store = AppInstallationStore(
      installer: AppInstaller(download: { _, _, _ in
        throw InstallationFixtures.failure("A stale action must not start a download.")
      }), showDevice: { _ in })
    let changing = NSHostingView(
      rootView: AppInstallButton(
        app: app, version: app.latestVersion, device: device, store: store,
        installedApps: inventory, allowsVersionChanges: true))
    let opening = NSHostingView(
      rootView: AppInstallButton(
        app: app, version: app.latestVersion, device: device, store: store,
        installedApps: inventory))
    changing.frame = NSRect(x: 20, y: 20, width: 240, height: 80)
    opening.frame = NSRect(x: 280, y: 20, width: 240, height: 80)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 120))
    content.addSubview(changing)
    content.addSubview(opening)
    let window = NSWindow(
      contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    try await InstallationFixtures.eventually { button(in: changing)?.isEnabled == true }

    let refresh = Task { await inventory.refresh(for: device) }
    try await probe.waitForPending()
    try await InstallationFixtures.eventually { button(in: changing)?.isEnabled == false }
    button(in: changing)!.performClick(nil)
    try InstallationFixtures.require(
      button(in: opening)?.isEnabled == true
        && store.phase(appID: app.id, deviceID: device.id) == nil,
      "Refresh must block version changes while leaving Open available.")
    await probe.finish()
    await refresh.value
    try await InstallationFixtures.eventually { button(in: changing)?.isEnabled == true }
    button(in: changing)!.performClick(nil)
    try await InstallationFixtures.eventually { confirmation(in: window) != nil }

    let again = Task { await inventory.refresh(for: device) }
    try await probe.waitForPending()
    try await InstallationFixtures.eventually { confirmation(in: window) == nil }
    try InstallationFixtures.require(
      store.phase(appID: app.id, deviceID: device.id) == nil,
      "Starting a refresh must invalidate an unconfirmed version change.")
    await probe.finish()
    await again.value
    try await InstallationFixtures.eventually { button(in: changing)?.isEnabled == true }
    button(in: changing)!.performClick(nil)
    try await InstallationFixtures.eventually { confirmation(in: window) != nil }
    let staleConfirmation = confirmation(in: window)!
    inventory.recordReplacement(
      SimulatorApplication(bundleID: app.bundleID, version: "0.9.0", isUserApplication: true),
      deviceID: device.id)
    staleConfirmation.performClick(nil)
    try await InstallationFixtures.eventually { confirmation(in: window) == nil }
    try InstallationFixtures.require(
      store.phase(appID: app.id, deviceID: device.id) == nil
        && store.error(appID: app.id, deviceID: device.id) == nil,
      "A stale confirmation must recheck the action before starting an installation.")

    let canceled = Task { await inventory.refresh(for: device) }
    try await probe.waitForPending()
    canceled.cancel()
    await probe.finish()
    await canceled.value
    try await InstallationFixtures.eventually { button(in: changing)?.isEnabled == false }
    try InstallationFixtures.require(
      inventory.application(bundleID: app.bundleID, deviceID: device.id)?.version == "0.9.0",
      "Cancellation keeps the displayed cache without enabling stale version changes.")
    print("PASS: native install gating, Open during refresh, and stale confirmation protection.")
  }

  static func deviceCompatibility() async throws {
    NSApplication.shared.setActivationPolicy(.regular)
    var version = InstallationFixtures.version()
    version.supportsIPhone = false
    let app = InstallationFixtures.app(version: version)
    for (isIPad, runtime, allowsIncompatible, expected) in [
      (false, "27.0", true, false), (true, "27.0", false, true),
      (true, "14.0", false, false), (true, "14.0", true, true),
    ] {
      let device = SimulatorDevice(
        id: "test", name: "Renamed device", runtime: runtime, state: .booted,
        deviceTypeIdentifier: isIPad
          ? "com.apple.CoreSimulator.SimDeviceType.iPad-Air"
          : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
      let inventory = InstalledAppsStore(load: { _ in [] })
      await inventory.refresh(for: device)
      let store = AppInstallationStore(showDevice: { _ in })
      let view = NSHostingView(
        rootView: AppInstallButton(
          app: app, version: version, device: device,
          store: store, installedApps: inventory, allowsIncompatible: allowsIncompatible))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = view
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      try await InstallationFixtures.eventually { button(in: view) != nil }
      try InstallationFixtures.require(
        button(in: view)?.isEnabled == expected,
        "Device restrictions cannot be overridden; only the minimum OS can be overridden on iPad.")
    }
  }

  private static func button(in view: NSView) -> NSButton? {
    if let button = view as? NSButton { return button }
    return view.subviews.lazy.compactMap { button(in: $0) }.first
  }

  private static func confirmation(in window: NSWindow) -> NSButton? {
    func find(in view: NSView) -> NSButton? {
      if let button = view as? NSButton, button.title == "Downgrade" { return button }
      return view.subviews.lazy.compactMap { find(in: $0) }.first
    }
    return window.attachedSheet?.contentView.flatMap { find(in: $0) }
  }
}
