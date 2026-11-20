import SwiftUI

struct AppInstallButton: View {
  let app: CatalogApp
  let version: CatalogVersion
  let device: SimulatorDevice
  let store: AppInstallationStore
  let installedApps: InstalledAppsStore
  var allowsIncompatible = false
  var allowsVersionChanges = false
  var isDefaultAction = false

  @State private var showsConfirmation = false
  @State private var pendingVersionChange: VersionChange?

  private struct VersionChange {
    let app: CatalogApp
    let version: CatalogVersion
    let device: SimulatorDevice
    let action: AppInstallationAction
  }

  private var isInstalled: Bool? {
    installedApps.isInstalled(bundleID: app.bundleID, deviceID: device.id)
  }

  private var idleAction: AppInstallationAction {
    .forVersion(
      version, installed: installedApps.application(bundleID: app.bundleID, deviceID: device.id),
      allowsChanges: allowsVersionChanges)
  }

  private var phase: AppInstallationPhase? {
    store.phase(appID: app.id, deviceID: device.id)
  }

  private var action: AppInstallationAction {
    switch phase {
    case .queued, .downloading, .verifying, .extracting: .cancel
    case .installing: .installing
    case .canceling: .canceling
    case .opening: .opening
    case .uninstalling: .uninstalling
    case nil: idleAction
    }
  }

  private var enabled: Bool {
    if let phase { return phase.canCancel }
    guard device.state == .booted, let isInstalled else { return false }
    if idleAction == .open { return isInstalled }
    guard version.supportsIPhone || device.isIPad, installedApps.canInstall(on: device) else {
      return false
    }
    return allowsIncompatible || version.isCompatible(with: device.runtime, isIPad: device.isIPad)
  }

  private var requiresCompatibilityOverride: Bool {
    (version.supportsIPhone || device.isIPad) && allowsIncompatible && idleAction != .open
      && !version.isCompatible(with: device.runtime, isIPad: device.isIPad)
  }

  private var isPrimary: Bool { phase == nil && !requiresCompatibilityOverride }

  private func title(for action: AppInstallationAction) -> String {
    if action == idleAction, requiresCompatibilityOverride {
      return String(localized: "Install anyway")
    }
    return action.title
  }

  var body: some View {
    Group {
      if isPrimary {
        button.buttonStyle(.borderedProminent)
      } else {
        button.buttonStyle(.bordered)
      }
    }
    .alert(
      "Change Installed Version?", isPresented: $showsConfirmation, presenting: pendingVersionChange
    ) { request in
      Button("Cancel", role: .cancel) {}
      Button(role: .destructive) {
        guard installedApps.canInstall(on: request.device),
          AppInstallationAction.forVersion(
            request.version,
            installed: installedApps.application(
              bundleID: request.app.bundleID, deviceID: request.device.id),
            allowsChanges: true) == request.action
        else { return }
        store.replace(app: request.app, version: request.version, on: request.device)
      } label: {
        Text(verbatim: request.action.title)
      }
    } message: { request in
      if request.action == .downgrade {
        Text(
          "Install \(request.version.version) on \(request.device.name)? This is an older version and may not work with existing app data."
        )
      } else {
        Text(
          "Install \(request.version.version) on \(request.device.name)? The installed version could not be compared."
        )
      }
    }
    .onChange(of: installedApps.canInstall(on: device)) { _, canInstall in
      if !canInstall { dismissVersionChange() }
    }
    .onChange(of: installedApps.application(bundleID: app.bundleID, deviceID: device.id)) { _, _ in
      dismissVersionChange()
    }
  }

  private func dismissVersionChange() {
    showsConfirmation = false
    pendingVersionChange = nil
  }

  private var button: some View {
    Button {
      guard enabled else { return }
      switch action {
      case .install: store.install(app: app, version: version, on: device)
      case .update, .downgrade, .replace:
        if action.needsConfirmation {
          pendingVersionChange = VersionChange(
            app: app, version: version, device: device, action: action)
          showsConfirmation = true
        } else {
          store.replace(app: app, version: version, on: device)
        }
      case .open: store.open(app: app, on: device)
      case .cancel: store.cancel(appID: app.id, deviceID: device.id)
      case .installing, .canceling, .opening, .uninstalling: break
      }
    } label: {
      StableSizeView(action, states: AppInstallationAction.allCases) { value in
        Text(verbatim: title(for: value))
      }
      .lineLimit(1)
    }
    .disabled(!enabled)
    .keyboardShortcut(isDefaultAction && isPrimary ? .defaultAction : nil)
    .accessibilityLabel(Text(verbatim: "\(title(for: action)) \(app.name)"))
    .accessibilityValue(Text(verbatim: phase?.summary(totalBytes: version.size) ?? ""))
    .help(
      Text(
        verbatim: isInstalled == true && (version.supportsIPhone || device.isIPad)
          ? device.name : version.requirementsLabel))
  }
}

struct AppInstallStatusView: View {
  let appID: String
  let deviceID: String
  let version: CatalogVersion
  let store: AppInstallationStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let phase = store.phase(appID: appID, deviceID: deviceID) {
        if case .downloading(let bytes) = phase {
          DownloadProgressView(receivedBytes: bytes, totalBytes: version.size, title: phase.title)
        } else {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(verbatim: phase.title)
          }
        }
      }
      if let error = store.error(appID: appID, deviceID: deviceID) {
        Label {
          Text(verbatim: error).textSelection(.enabled)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("installation-error")
      }
    }
    .font(.system(size: 12))
  }
}
