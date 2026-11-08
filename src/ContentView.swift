import AppKit
import SwiftUI

@MainActor
struct ContentView: View {
  @State private var simulators: SimulatorStore
  @State private var catalog: CatalogStore
  @State private var installedApps: InstalledAppsStore
  @State private var installations: AppInstallationStore
  @State private var operationMonitor: SimulatorOperationMonitor
  @State private var launchError: String?
  @State private var librarySection: LibrarySection = .discover

  private static var installedXcodeURL: URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
  }

  init(
    discover: @escaping @MainActor () async throws -> SimulatorDiscovery = {
      return try await SimulatorDiscovery.scan(installedXcodeURL: ContentView.installedXcodeURL)
    },
    boot: @escaping @Sendable (String) async throws -> Void = {
      try await SimulatorControl.boot($0)
    },
    shutdown: @escaping @Sendable (String) async throws -> Void = {
      try await SimulatorControl.shutdown($0)
    },
    catalogClient: CatalogClient = .live,
    installer: AppInstaller = AppInstaller(),
    showDevice: (@MainActor (SimulatorDevice) async throws -> Void)? = nil,
    loadInstalledApps:
      @escaping @Sendable (SimulatorDevice) async throws -> [SimulatorApplication] = {
        try await SimulatorApplications.installedApps(on: $0)
      }
  ) {
    #if DEBUG
      let preview = Result { try PreviewScenario.parse(CommandLine.arguments) }
      let liveDiscover = discover
      let discover: @MainActor () async throws -> SimulatorDiscovery = {
        if let scenario = try preview.get() {
          return try await scenario.discover(installedXcodeURL: Self.installedXcodeURL)
        }
        return try await liveDiscover()
      }
      var installer = installer
      var boot = boot
      var shutdown = shutdown
      var loadInstalledApps = loadInstalledApps
      if case .success(.some(.incompatible)) = preview {
        installer.download = { _, _, _ in try PreviewScenario.rejectDeviceAction() }
        installer.command = { _, _ in try PreviewScenario.rejectDeviceAction() }
        boot = { _ in try PreviewScenario.rejectDeviceAction() }
        shutdown = { _ in try PreviewScenario.rejectDeviceAction() }
        loadInstalledApps = { _ in [] }
      }
    #endif
    let simulators = SimulatorStore(discover: discover, shutdown: shutdown, boot: boot)
    let operationMonitor = SimulatorOperationMonitor()
    _operationMonitor = State(initialValue: operationMonitor)
    _simulators = State(initialValue: simulators)
    _catalog = State(initialValue: CatalogStore(client: catalogClient))
    let installedApps = InstalledAppsStore(
      load: loadInstalledApps, operationMonitor: operationMonitor)
    _installedApps = State(initialValue: installedApps)
    _installations = State(
      initialValue: AppInstallationStore(
        installer: installer,
        showDevice: { device in
          if let showDevice {
            try await showDevice(device)
          } else {
            try await SimulatorPresenter.show(
              deviceID: device.id, manager: simulators.discovery?.deviceManager)
          }
        },
        didInstall: { application, deviceID in
          installedApps.recordInstallation(application, deviceID: deviceID)
        },
        didReplace: { application, deviceID in
          installedApps.recordReplacement(application, deviceID: deviceID)
        },
        didUninstall: { bundleID, deviceID in
          installedApps.recordUninstallation(bundleID: bundleID, deviceID: deviceID)
        },
        didOpen: { bundleID, deviceID in
          installedApps.removeRecentInstallation(bundleID: bundleID, deviceID: deviceID)
        }, operationMonitor: operationMonitor))
  }

  private var needsXcode: Bool {
    guard case .failure(let error) = simulators.result else { return false }
    return (error as? SimulatorDiscoveryError) == .xcodeNotInstalled
  }

  private var discovery: SimulatorDiscovery? {
    simulators.discovery
  }

  private var deviceManager: (name: String, url: URL)? {
    discovery?.deviceManager
  }

  private var updateCount: Int? {
    guard let device = simulators.selectedDevice, let catalog = catalog.catalog else { return nil }
    return installedApps.updatableApps(in: catalog, for: device, includingRecent: false)?.count
  }

  var body: some View {
    NavigationSplitView {
      GeometryReader { geometry in
        SidebarView(
          discovery: discovery, isChecking: simulators.isChecking, needsXcode: needsXcode,
          section: $librarySection, updateCount: updateCount,
          selectedDeviceID: simulators.selectedDeviceID,
          selectDevice: simulators.selectDevice,
          startDevice: startSimulator,
          openRepository: openRepository
        )
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    } detail: {
      GeometryReader { geometry in
        VStack(spacing: 0) {
          if let error = simulators.refreshError, discovery != nil {
            SimulatorRefreshWarningView(
              error: error, isChecking: simulators.isChecking, checkAgain: checkAgain
            )
            .padding(.horizontal, 28)
            .padding(.top, 20)
          }
          ZStack(alignment: .topLeading) {
            discoveryContent
              .frame(maxWidth: .infinity, maxHeight: .infinity)

            if simulators.selectedDevice == nil || discovery == nil {
              LibraryHeading(section: librarySection)
                .padding(32)
            }
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .background(Color(nsColor: .textBackgroundColor))
      }
      .toolbar {
        ToolbarItem(placement: .navigation) {
          SimulatorPicker(
            devices: discovery?.devices ?? [], selectedDevice: simulators.selectedDevice,
            selectDevice: simulators.selectDevice
          )
          .labelStyle(.titleAndIcon)
          .font(.system(size: 12))
        }
        ToolbarItem(placement: .primaryAction) {
          Button(action: checkAgain) {
            Label("Check for Simulators", systemImage: "arrow.clockwise")
          }
          .disabled(simulators.isChecking)
          .keyboardShortcut("r", modifiers: .command)
          .help(Text("Check for iOS simulators"))
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 900, minHeight: 600)
    .task { await simulators.refresh() }
    .onChange(of: librarySection) { _, _ in installedApps.clearRecentInstallations() }
    .onChange(of: discovery?.devices) { _, devices in
      operationMonitor.synchronize(with: devices)
    }
    .task(id: shouldMonitorState) {
      while shouldMonitorState && !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(2))
          try Task.checkCancellation()
          await simulators.refresh()
        } catch { return }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      checkAgain()
    }
    .alert(
      "Couldn’t Open Application",
      isPresented: Binding(
        get: { launchError != nil },
        set: { if !$0 { launchError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { launchError = nil }
    } message: {
      Text(launchError ?? "")
    }
    .alert(
      "Couldn’t Start Simulator",
      isPresented: Binding(
        get: { simulators.startError != nil },
        set: { if !$0 { simulators.startError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { simulators.startError = nil }
    } message: {
      Text(simulators.startError ?? "")
    }
    .alert(
      "Couldn’t Shut Down Simulator",
      isPresented: Binding(
        get: { simulators.shutdownError != nil },
        set: { if !$0 { simulators.shutdownError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { simulators.shutdownError = nil }
    } message: {
      Text(simulators.shutdownError ?? "")
    }
    .modifier(SimulatorRecoveryAlert(monitor: operationMonitor, shutdown: shutdownSimulator))
  }

  @ViewBuilder
  private var discoveryContent: some View {
    switch simulators.result {
    case .none:
      SimulatorLoadingView()
    case .some(.success(let snapshot)) where snapshot.devices.isEmpty:
      NoSimulatorsView(
        deviceManagerName: deviceManager?.name, isChecking: simulators.isChecking,
        openDeviceManager: openDeviceManager, openXcode: openXcode, checkAgain: checkAgain)
    case .some(.success):
      if let device = simulators.selectedDevice {
        CatalogBrowserView(
          section: librarySection,
          store: catalog, installedApps: installedApps, installations: installations,
          device: device,
          deviceManagerName: deviceManager?.name,
          startSimulator: startSimulator,
          shutdownSimulator: shutdownSimulator,
          openDeviceManager: openDeviceManager
        )
      }
    case .some(.failure) where needsXcode:
      MissingXcodeView(
        isChecking: simulators.isChecking, openAppStore: openAppStore, checkAgain: checkAgain)
    case .some(.failure(let error)):
      SimulatorDiscoveryErrorView(
        error: error, isChecking: simulators.isChecking, openXcode: openXcode,
        checkAgain: checkAgain)
    }
  }

  private func checkAgain() {
    Task {
      await simulators.refresh()
      if let device = simulators.selectedDevice { await installedApps.refresh(for: device) }
    }
  }

  private func startSimulator() {
    guard let id = simulators.selectedDeviceID else { return }
    startSimulator(id)
  }

  private func startSimulator(_ id: String) {
    Task {
      let started = await simulators.startDevice(id)
      if started, let device = simulators.selectedDevice, device.id == id {
        openDeviceManager()
      }
    }
  }

  private func shutdownSimulator() {
    guard let id = simulators.selectedDeviceID else { return }
    _ = shutdownSimulator(id)
  }

  private func shutdownSimulator(_ id: String) -> Bool {
    guard simulators.shutdownDevice(id) != nil else { return false }
    operationMonitor.stop(deviceID: id)
    installations.cancelOperations(deviceID: id)
    return true
  }

  private var shouldMonitorState: Bool {
    !simulators.startingDeviceIDs.isEmpty
      || !simulators.shuttingDownDeviceIDs.isEmpty
      || discovery?.devices.contains(where: \.state.isTransitioning) == true
  }

  private func openRepository() {
    let url = AppConfiguration.buildsRepositoryURL
    if !NSWorkspace.shared.open(url) {
      launchError = String(localized: "Open \(url.absoluteString) in your web browser.")
    }
  }

  private func openAppStore() {
    if !NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id497799835")!) {
      launchError = String(localized: "Open the App Store and search for Xcode.")
    }
  }

  private func openDeviceManager() {
    if let deviceManager {
      openApplication(deviceManager.url, name: deviceManager.name)
    } else {
      openXcode()
    }
  }

  private func openXcode() {
    openApplication(discovery?.xcodeURL ?? Self.installedXcodeURL, name: "Xcode")
  }

  private func openApplication(_ url: URL?, name: String) {
    guard let url, FileManager.default.fileExists(atPath: url.path) else {
      launchError = String(
        localized:
          "\(name) couldn’t be opened. Make sure the full Xcode application is installed and selected."
      )
      return
    }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) {
      _, error in
      if let error {
        Task { @MainActor in
          launchError = String(
            localized: "\(name) couldn’t be opened. \(error.localizedDescription)")
        }
      }
    }
  }
}
