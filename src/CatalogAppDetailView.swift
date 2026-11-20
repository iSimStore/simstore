import AppKit
import SwiftUI

@MainActor
struct CatalogAppDetailView: View {
  let app: CatalogApp
  let device: SimulatorDevice
  let installedApps: InstalledAppsStore
  let installations: AppInstallationStore
  @State private var versionID: String
  @State private var showsBuildDetails = false
  @State private var collapsedContentHeight: CGFloat = 560
  @Environment(\.dismiss) private var dismiss

  init(
    app: CatalogApp, device: SimulatorDevice,
    installedApps: InstalledAppsStore, installations: AppInstallationStore
  ) {
    self.app = app
    self.device = device
    self.installedApps = installedApps
    self.installations = installations
    _versionID = State(
      initialValue: installations.activeUpdateVersion(appID: app.id, deviceID: device.id)?.version
        ?? app.recommendedVersion(for: device.runtime, isIPad: device.isIPad).version)
  }

  private var runtime: String { device.runtime }

  private var version: CatalogVersion {
    installations.activeUpdateVersion(appID: app.id, deviceID: device.id)
      ?? app.versions.first(where: { $0.version == versionID })
      ?? app.recommendedVersion(for: runtime, isIPad: device.isIPad)
  }

  private var versions: [CatalogVersion] {
    guard let active = installations.activeUpdateVersion(appID: app.id, deviceID: device.id),
      !app.versions.contains(where: { $0.id == active.id })
    else { return app.versions }
    return [active] + app.versions
  }

  private var contentHeight: CGFloat {
    let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
    // Reserve space for the footer, window chrome, and screen edges.
    let available = (screen?.visibleFrame.height ?? 900) - 160
    return min(collapsedContentHeight.rounded(.up), available)
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack(alignment: .top, spacing: 20) {
            CatalogIcon(app: app, size: 80)
            VStack(alignment: .leading, spacing: 8) {
              Text(verbatim: app.name).font(.system(size: 26, weight: .bold))
              Text(verbatim: app.categoryTitle).font(.system(size: 12)).foregroundStyle(.secondary)
              Text(verbatim: app.displayDescription).font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
            GridRow {
              Text("Simulator").foregroundStyle(.secondary)
              Text(verbatim: "\(device.name) · \(device.runtimeLabel)")
            }
            if let application = installedApps.application(
              bundleID: app.bundleID, deviceID: device.id)
            {
              GridRow {
                Text("Installed Version").foregroundStyle(.secondary)
                Text(verbatim: application.displayVersion)
              }
            }
            GridRow {
              Text("Version").foregroundStyle(.secondary)
              Picker(selection: $versionID) {
                ForEach(versions) { build in
                  Text(verbatim: build.version).tag(build.version)
                }
              } label: {
                Text("Available Versions")
              }
              .labelsHidden()
              .accessibilityIdentifier("catalog-version")
              .disabled(installations.phase(appID: app.id, deviceID: device.id) != nil)
              .frame(maxWidth: 240)
            }
            GridRow {
              Text("Requires").foregroundStyle(.secondary)
              Text(verbatim: version.requirementsLabel)
            }
            GridRow {
              Text("Download Size").foregroundStyle(.secondary)
              Text(
                verbatim: ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file))
            }
            GridRow {
              Text("Published").foregroundStyle(.secondary)
              Text(
                Date(timeIntervalSince1970: TimeInterval(version.time)),
                format: .dateTime.year().month().day())
            }
            GridRow {
              Text("License").foregroundStyle(.secondary)
              Text(verbatim: app.license).textSelection(.enabled)
            }
            GridRow {
              Text("Bundle ID").foregroundStyle(.secondary)
              CopyableText(value: app.bundleID, copyLabel: "Copy Bundle ID")
                .font(.system(size: 11, design: .monospaced))
            }
          }
          .font(.system(size: 13))
          .frame(maxWidth: .infinity, alignment: .leading)

          if !version.supportsIPhone && !device.isIPad {
            Text("This build is only available for iPad. Select an iPad simulator to install it.")
              .font(.system(size: 12))
              .foregroundStyle(.orange)
          }

          if (version.supportsIPhone || device.isIPad)
            && !version.isCompatible(with: runtime, isIPad: device.isIPad)
          {
            Label {
              Text(
                "This build requires iOS \(version.minSimulatorOS) or later. It may not work on iOS \(runtime)."
              )
            } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
          }

          AppInstallStatusView(
            appID: app.id, deviceID: device.id, version: version, store: installations)

          HStack(spacing: 20) {
            Link(destination: app.repository) {
              Label("Source Repository", systemImage: "curlybraces")
            }
            Link(
              destination: AppConfiguration.manifestURL(
                appID: app.id, revision: version.recipeRevision)
            ) {
              Label("Build Manifest", systemImage: "doc.text")
            }
            .accessibilityIdentifier("build-manifest")
            Link(destination: AppConfiguration.releaseURL(appID: app.id, version: version.version))
            {
              Label("Build Release", systemImage: "arrow.up.right.square")
            }
          }

          DisclosureGroup("Build Details", isExpanded: $showsBuildDetails) {
            VStack(alignment: .leading, spacing: 12) {
              buildDetail(
                "Source Revision", value: version.revision,
                link: AppConfiguration.commitURL(
                  repository: app.repository, revision: version.revision))
              buildDetail(
                "Recipe Revision", value: version.recipeRevision,
                link: AppConfiguration.commitURL(
                  repository: AppConfiguration.buildsRepositoryURL, revision: version.recipeRevision
                ))
              buildDetail("SHA-256", value: version.sha256, copyLabel: "Copy SHA-256")
            }
            .padding(.top, 12)
          }
          .disclosureGroupStyle(DetailsDisclosureStyle())
          .font(.system(size: 12))

          Text(
            "License refers to the upstream project’s main license. Some components or resources may use other licenses."
          )
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .background {
          GeometryReader { geometry in
            Color.clear.preference(key: DetailContentHeight.self, value: geometry.size.height)
          }
        }
      }
      .frame(height: contentHeight)
      .onPreferenceChange(DetailContentHeight.self) { height in
        if !showsBuildDetails && height > 0 { collapsedContentHeight = height }
      }
      Divider()
      HStack {
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        if installedApps.isInstalled(bundleID: app.bundleID, deviceID: device.id) == true {
          AppUninstallButton(
            app: app, device: device, installedApps: installedApps, installations: installations
          )
          .accessibilityIdentifier("detail-uninstall")
        }
        Spacer()
        if AppInstallationAction.forVersion(
          version,
          installed: installedApps.application(bundleID: app.bundleID, deviceID: device.id),
          allowsChanges: true
        ).isVersionChange {
          Button {
            installations.open(app: app, on: device)
          } label: {
            Text(verbatim: AppInstallationAction.open.title)
          }
          .buttonStyle(.bordered)
          .disabled(
            device.state != .booted
              || installations.phase(appID: app.id, deviceID: device.id) != nil
          )
          .accessibilityIdentifier("detail-open")
        }
        AppInstallButton(
          app: app, version: version, device: device, store: installations,
          installedApps: installedApps,
          allowsIncompatible: true, allowsVersionChanges: true, isDefaultAction: true
        )
        .accessibilityIdentifier("detail-install")
      }
      .padding(20)
    }
    .frame(width: 580)
  }

  private func buildDetail(
    _ title: LocalizedStringKey, value: String, link: URL? = nil,
    copyLabel: LocalizedStringKey? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).foregroundStyle(.secondary)
      Group {
        if let link {
          Link(destination: link) { Text(verbatim: value) }
        } else if let copyLabel {
          CopyableText(value: value, copyLabel: copyLabel)
        } else {
          Text(verbatim: value).textSelection(.enabled)
        }
      }
      .font(.system(size: 10, design: .monospaced))
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct DetailContentHeight: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
