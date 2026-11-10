import AppKit
import SwiftUI

@MainActor
struct CatalogBrowserView: View {
  let section: LibrarySection
  let store: CatalogStore
  let installedApps: InstalledAppsStore
  let installations: AppInstallationStore
  let device: SimulatorDevice
  let deviceManagerName: String?
  let startSimulator: () -> Void
  let shutdownSimulator: () -> Void
  let openDeviceManager: () -> Void

  @State private var query = ""
  @State private var category = ""
  @State private var selectedApp: CatalogApp?
  @State private var showsSimulator = false

  private var categories: [String]? {
    availableApps.map { Array(Set($0.flatMap(\.categories))).sorted() }
  }

  private var availableApps: [CatalogApp]? {
    guard device.state == .booted, let catalog = store.catalog else { return nil }
    switch section {
    case .discover: return installedApps.discoverableApps(in: catalog, for: device.id)
    case .installed: return installedApps.installedApps(in: catalog, for: device.id)
    case .updates: return installedApps.updatableApps(in: catalog, for: device)
    }
  }

  private var updateBatch: AppUpdateBatch? {
    installations.updateBatch(deviceID: device.id)
  }

  private var apps: [CatalogApp] {
    (availableApps ?? []).filter { app in
      (category.isEmpty || app.categories.contains(category))
        && (query.isEmpty
          || [app.name, app.displayDescription, app.bundleID, app.categoryTitle]
            .contains { $0.localizedStandardContains(query) })
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      heading
      simulatorSummary
      if section == .updates, let batch = updateBatch {
        AppUpdateBatchView(
          batch: batch,
          phase: batch.currentApp.flatMap {
            installations.phase(appID: $0.id, deviceID: device.id)
          },
          cancel: { installations.cancelAllUpdates(deviceID: device.id) },
          dismiss: { installations.dismissUpdateBatch(deviceID: device.id) })
      }
      if let catalog = store.catalog {
        if let error = store.error {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
              Text("Showing Saved Catalog").fontWeight(.medium)
              Text(verbatim: error).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
          .font(.system(size: 12))
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
        if let availableApps {
          collection(catalog, availableApps: availableApps)
        } else {
          InstalledAppsStatusView(
            device: device, store: installedApps, refresh: refreshInstalledApps)
        }
      } else if store.isLoading {
        VStack(spacing: 14) {
          ProgressView()
          Text("Loading Apps…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView {
          Label("Catalog Unavailable", systemImage: "wifi.exclamationmark")
        } description: {
          Text(verbatim: store.error ?? String(localized: "Refresh the catalog to load apps."))
        } actions: {
          CatalogRefreshButton(isLoading: store.isLoading, refresh: refresh)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(.horizontal, 28)
    .padding(.top, 28)
    .task { await store.refresh() }
    .task(id: device) { await installedApps.refresh(for: device) }
    .onChange(of: installations.openedApp) { _, opened in
      dismissDetails(matching: opened)
    }
    .onChange(of: installations.uninstalledApp) { _, uninstalled in
      dismissDetails(matching: uninstalled)
    }
    .onChange(of: categories) { _, values in
      guard let values else { return }
      if !category.isEmpty && !values.contains(category) { category = "" }
    }
    .sheet(item: $selectedApp) { app in
      CatalogAppDetailView(
        app: app, device: device, installedApps: installedApps, installations: installations)
    }
    .popover(isPresented: $showsSimulator) {
      SimulatorDetailView(
        device: device,
        deviceManagerName: deviceManagerName,
        start: startSimulator, shutdown: shutdownSimulator, openDeviceManager: openDeviceManager
      )
      .frame(width: 480)
    }
  }

  private var heading: some View {
    HStack(alignment: .top, spacing: 20) {
      LibraryHeading(section: section)
      Spacer(minLength: 0)
      CatalogSearchField(text: $query)
        .frame(width: 180)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 5)
    }
  }

  private var simulatorSummary: some View {
    HStack(spacing: 10) {
      Image(systemName: device.symbolName)
        .frame(width: 18, height: 24)
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: device.name).fontWeight(.medium)
        Text(verbatim: "\(device.runtimeLabel) · \(device.state.label)")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      .lineLimit(1)
      Spacer(minLength: 12)
      if device.state.canStart || device.state.canShutdown || device.state.isTransitioning {
        SimulatorPowerButton(
          device: device,
          start: startSimulator, shutdown: shutdownSimulator)
      }
      Button {
        showsSimulator = true
      } label: {
        Label("Simulator Details", systemImage: "info.circle")
      }
      .labelStyle(.iconOnly)
      .accessibilityIdentifier("simulator-details")
    }
    .font(.system(size: 12))
    .controlSize(.small)
    .padding(12)
    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
  }

  private func collection(_ catalog: AppCatalog, availableApps: [CatalogApp]) -> some View {
    VStack(spacing: 14) {
      HStack(spacing: 12) {
        Picker("Category", selection: $category) {
          Text("All Apps").tag("")
          ForEach(categories ?? [], id: \.self) { value in
            Text(verbatim: CatalogCategory.title(value)).tag(value)
          }
        }
        .frame(maxWidth: 200)
        .accessibilityIdentifier("catalog-category")
        Spacer(minLength: 0)
        Text(verbatim: "\(apps.count) / \(availableApps.count)")
          .monospacedDigit().foregroundStyle(.secondary)
        if section == .updates {
          AppUpdateAllButton(
            isUpdating: updateBatch?.isRunning == true,
            canUpdate: !installations.pendingUpdates(
              in: catalog, installedApps: installedApps, on: device
            ).isEmpty
          ) {
            installations.updateAll(in: catalog, installedApps: installedApps, on: device)
          }
        }
        CatalogRefreshButton(isLoading: store.isLoading, refresh: refresh)
          .labelStyle(.iconOnly)
      }
      if catalog.apps.isEmpty {
        ContentUnavailableView {
          Label("No Apps Available", systemImage: "square.grid.2x2")
        } description: {
          Text("Published apps will appear here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if availableApps.isEmpty && section == .installed {
        ContentUnavailableView {
          Label("No Catalog Apps Installed", systemImage: "square.grid.2x2")
        } description: {
          Text("Apps you install from this catalog will appear here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if availableApps.isEmpty && section == .updates {
        ContentUnavailableView {
          Label {
            Text("All Apps Are Up to Date")
          } icon: {
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
          }
        } description: {
          Text("Newer compatible versions of your installed apps will appear here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if availableApps.isEmpty {
        ContentUnavailableView {
          Label {
            Text("All Apps Are Installed")
          } icon: {
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
          }
        } description: {
          Text("Every app in the catalog is already installed on this simulator.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if apps.isEmpty {
        ContentUnavailableView.search(text: query)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        appGrid
      }
    }
  }

  private var appGrid: some View {
    CatalogAppGrid(apps: apps) { app, focus in
      CatalogAppCard(
        app: app, device: device, installedApps: installedApps,
        installations: installations, section: section,
        focusedAppID: focus,
        showDetails: { selectedApp = app })
    }
    .id(section)
  }

  private func refreshInstalledApps() { Task { await installedApps.refresh(for: device) } }

  private func dismissDetails(matching key: AppInstallationStore.Key?) {
    if let key, key.deviceID == device.id, selectedApp?.id == key.appID {
      selectedApp = nil
    }
  }

  private func refresh() {
    installedApps.clearRecentInstallations()
    Task { await store.refresh() }
    refreshInstalledApps()
  }
}

@MainActor
private struct CatalogSearchField: NSViewRepresentable {
  @Binding var text: String

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = String(localized: "Search apps")
    field.sendsWholeSearchString = false
    field.sendsSearchStringImmediately = true
    field.maximumRecents = 0
    field.target = context.coordinator
    field.action = #selector(Coordinator.searchChanged(_:))
    field.setAccessibilityIdentifier("catalog-search")
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.text = $text
    if field.stringValue != text { field.stringValue = text }
  }

  @MainActor
  final class Coordinator: NSObject {
    var text: Binding<String>

    init(text: Binding<String>) { self.text = text }

    @objc func searchChanged(_ field: NSSearchField) {
      text.wrappedValue = field.stringValue
    }
  }
}
