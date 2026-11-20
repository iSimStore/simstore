import SwiftUI

struct CatalogAppCard: View {
  let app: CatalogApp
  let device: SimulatorDevice
  let installedApps: InstalledAppsStore
  let installations: AppInstallationStore
  let section: LibrarySection
  @FocusState.Binding var focusedAppID: String?
  let showDetails: () -> Void

  private var runtime: String { device.runtime }
  private var showsInstallation: Bool { section != .discover }

  var body: some View {
    let version =
      installations.activeUpdateVersion(appID: app.id, deviceID: device.id)
      ?? app.recommendedVersion(for: runtime, isIPad: device.isIPad)
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
          CatalogIcon(app: app)
          VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: app.name)
              .font(.system(size: 15, weight: .semibold))
              .lineLimit(2, reservesSpace: true)
            Text(verbatim: app.categoryTitle)
              .font(.system(size: 10)).foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        Text(verbatim: app.displayDescription)
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .lineLimit(2, reservesSpace: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      HStack {
        versionSummary(version)
        Spacer(minLength: 4)
        if section != .installed {
          Text(verbatim: ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        if section == .installed {
          AppUninstallButton(
            app: app, device: device, installedApps: installedApps, installations: installations
          )
          .labelStyle(.iconOnly)
          .controlSize(.small)
          .accessibilityIdentifier("catalog-uninstall-\(app.id)")
        }
        AppInstallButton(
          app: app, version: version, device: device, store: installations,
          installedApps: installedApps, allowsVersionChanges: section == .updates
        )
        .controlSize(.small)
        .accessibilityIdentifier("catalog-install-\(app.id)")
      }
      .font(.system(size: 11))
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      Button(action: showDetails) {
        RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor))
          .contentShape(RoundedRectangle(cornerRadius: 14))
      }
      .buttonStyle(.plain)
      .focused($focusedAppID, equals: app.id)
      .accessibilityLabel(Text(verbatim: app.name))
      .accessibilityValue(
        Text(
          verbatim:
            section == .installed
            ? "\(app.displayDescription) · \(versionText(version))"
            : "\(app.displayDescription) · \(versionText(version)) · \(version.requirementsLabel) · \(ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file))"
        )
      )
      .accessibilityHint(Text("View app details and versions"))
      .accessibilityIdentifier("catalog-app-\(app.id)")
      .accessibilitySortPriority(1)
      .help(
        Text(
          verbatim: installations.error(appID: app.id, deviceID: device.id)
            ?? app.displayDescription))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07))
    }
    .contentShape(RoundedRectangle(cornerRadius: 14))
  }

  private var installedVersion: String {
    installedApps.application(bundleID: app.bundleID, deviceID: device.id)?.displayVersion
      ?? String(localized: "Version Unavailable")
  }

  private func versionText(_ version: CatalogVersion) -> String {
    if !showsInstallation { return version.version }
    if section == .updates,
      version.comparison(
        with: installedApps.application(bundleID: app.bundleID, deviceID: device.id)?.version)
        == .orderedDescending
    {
      return "\(installedVersion) → \(version.version)"
    }
    return installedVersion
  }

  private func versionSummary(_ version: CatalogVersion) -> some View {
    HStack(spacing: 4) {
      if let phase = installations.phase(appID: app.id, deviceID: device.id),
        section != .installed, phase != .uninstalling
      {
        Text(verbatim: phase.summary(totalBytes: version.size)).foregroundStyle(.secondary)
          .monospacedDigit()
      } else if installations.error(appID: app.id, deviceID: device.id) != nil {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
        Text(verbatim: versionText(version)).monospacedDigit()
      } else if !version.supportsIPhone && !device.isIPad && !showsInstallation {
        Label("iPad only", systemImage: "ipad")
          .foregroundStyle(.orange)
      } else if showsInstallation || version.isCompatible(with: runtime, isIPad: device.isIPad) {
        Text(verbatim: versionText(version)).monospacedDigit()
      } else {
        Label("iOS \(version.minSimulatorOS)+", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
    }
    .lineLimit(1)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
