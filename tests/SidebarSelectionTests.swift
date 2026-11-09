import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
private final class SidebarState {
  var discovery: SimulatorDiscovery?
  var selectedDeviceID: String?
  var section = LibrarySection.discover
  var startRequests: [String] = []
  var selectionsAtStart: [String?] = []
}

private struct SidebarHarness: View {
  @Bindable var state: SidebarState

  var body: some View {
    GeometryReader { geometry in
      SidebarView(
        discovery: state.discovery, isChecking: false, needsXcode: false,
        section: $state.section, updateCount: nil, selectedDeviceID: state.selectedDeviceID,
        selectDevice: { state.selectedDeviceID = $0 },
        startDevice: {
          state.startRequests.append($0)
          state.selectionsAtStart.append(state.selectedDeviceID)
        }, openRepository: {}
      )
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }
  }
}

@main
@MainActor
struct SidebarSelectionTests {
  static func main() {
    NSApplication.shared.setActivationPolicy(.regular)
    Task { @MainActor in
      await runScenarios()
      exit(EXIT_SUCCESS)
    }
    // Native mouse tracking needs AppKit's event loop, not just async main's executor.
    NSApplication.shared.run()
  }

  private static func runScenarios() async {
    let scenarios: [(String, @MainActor (SidebarFixture) async throws -> Void)] = [
      ("initialSelection", initialSelection),
      ("visibleSelections", visibleSelections),
      ("offscreenSelections", offscreenSelections),
      ("topClippedSelection", { try await clippedSelection($0, clipsTop: true) }),
      ("bottomClippedSelection", { try await clippedSelection($0, clipsTop: false) }),
      ("refreshAndRepopulation", refreshAndRepopulation),
      ("singleClickShutdown", { try await singleClickShutdown($0) }),
      ("singleClickShutdownTitle", { try await singleClickShutdown($0, verticalFraction: 0.25) }),
      (
        "singleClickShutdownSubtitle", { try await singleClickShutdown($0, verticalFraction: 0.75) }
      ),
      ("singleClickShutdownPadding", { try await singleClickShutdown($0, verticalFraction: 0.05) }),
      ("singleClickShutdownIcon", { try await singleClickShutdown($0, horizontalFraction: 0.1) }),
      (
        "singleClickShutdownLeadingEdge",
        { try await singleClickShutdown($0, horizontalFraction: 0.025) }
      ),
      (
        "singleClickShutdownTrailingPadding",
        { try await singleClickShutdown($0, horizontalFraction: 0.9) }
      ),
      ("mouseDownShutdown", mouseDownShutdown),
      ("singleClickBooted", { try await clickInactive($0, state: .booted, count: 1) }),
      ("singleClickBooting", { try await clickInactive($0, state: .booting, count: 1) }),
      ("doubleClickShutdown", { try await doubleClickShutdown($0) }),
      (
        "doubleClickShutdownPadding",
        { try await doubleClickShutdown($0, verticalFraction: 0.05) }
      ),
      ("doubleClickBooted", { try await clickInactive($0, state: .booted) }),
      ("doubleClickBooting", { try await clickInactive($0, state: .booting) }),
      ("doubleClickShuttingDown", { try await clickInactive($0, state: .shuttingDown) }),
      ("doubleClickUnknown", { try await clickInactive($0, state: .unknown) }),
    ]
    await TestSuite.run(
      scenarios.map { name, scenario in
        TestSuite.Case(
          name,
          arguments: { arguments in
            let fixture = try SidebarFixture(arguments: arguments)
            defer { fixture.window.close() }
            try await scenario(fixture)
          })
      })
  }

  private static func initialSelection(_ fixture: SidebarFixture) async throws {
    _ = try await fixture.ready()
    // A recreated sidebar must reveal a selection that predates its appearance.
    fixture.window.contentView = NSHostingView(rootView: SidebarHarness(state: fixture.state))
    try await fixture.wait("Reveal the existing selection after sidebar recreation.") {
      guard let table = fixture.table else { return false }
      return fixture.isVisible(fixture.selected, in: table)
    }
  }

  private static func visibleSelections(_ fixture: SidebarFixture) async throws {
    let table = try await fixture.ready()
    guard let scroll = table.enclosingScrollView else { throw failure("Expected a scroll view.") }
    for firstRow in [0, max(0, fixture.selected - 2)] {
      scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: firstRow).minY))
      scroll.reflectScrolledClipView(scroll.contentView)
      guard
        let index = fixture.devices.indices.last(where: {
          table.visibleRect.contains(table.rect(ofRow: $0))
            && fixture.devices[$0].id != fixture.state.selectedDeviceID
        })
      else { throw failure("Expected another fully visible simulator row.") }
      let offset = table.visibleRect.origin
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      try await fixture.wait("Native selection must update the selected simulator.") {
        fixture.state.selectedDeviceID == fixture.devices[index].id && table.selectedRow == index
      }
      try await fixture.requireScrollRemains(offset, in: table)
      guard
        let other = fixture.devices.indices.first(where: {
          table.visibleRect.contains(table.rect(ofRow: $0)) && $0 != index
        })
      else { throw failure("Expected another visible simulator for menu selection.") }
      fixture.state.selectedDeviceID = fixture.devices[other].id
      try await fixture.wait("Menu selection must update the visible row.") {
        table.selectedRow == other
      }
      try await fixture.requireScrollRemains(offset, in: table)
    }
  }

  private static func offscreenSelections(_ fixture: SidebarFixture) async throws {
    let table = try await fixture.ready()
    for index in [fixture.devices.count - 1, 0, fixture.selected] {
      fixture.state.selectedDeviceID = fixture.devices[index].id
      try await fixture.wait("Reveal offscreen selection \(index).") {
        fixture.isVisible(index, in: table)
      }
    }
  }

  private static func clippedSelection(_ fixture: SidebarFixture, clipsTop: Bool) async throws {
    let table = try await fixture.ready()
    guard let scroll = table.enclosingScrollView else { throw failure("Expected a scroll view.") }
    fixture.state.selectedDeviceID = fixture.devices[0].id
    try await fixture.wait("Select another row before revealing the clipped row.") {
      fixture.isVisible(0, in: table)
    }
    let row = table.rect(ofRow: fixture.selected)
    let origin = clipsTop ? row.midY : row.midY - table.visibleRect.height
    scroll.contentView.scroll(to: NSPoint(x: 0, y: origin))
    scroll.reflectScrolledClipView(scroll.contentView)
    let viewport = table.visibleRect
    let visibleHeight = viewport.intersection(row).height
    guard visibleHeight > 0, visibleHeight < row.height else {
      throw failure("Expected a partially clipped simulator row.")
    }
    let expected = clipsTop ? row.minY : row.maxY - viewport.height
    table.selectRowIndexes(IndexSet(integer: fixture.selected), byExtendingSelection: false)
    try await fixture.wait("Reveal the clipped row with minimum scrolling to \(expected).") {
      fixture.state.selectedDeviceID == fixture.devices[fixture.selected].id
        && fixture.isVisible(fixture.selected, in: table)
        && abs(table.visibleRect.minY - expected) <= 1
    }
    try await fixture.requireScrollRemains(table.visibleRect.origin, in: table)
  }

  private static func refreshAndRepopulation(_ fixture: SidebarFixture) async throws {
    let table = try await fixture.ready()
    guard let scroll = table.enclosingScrollView else { throw failure("Expected a scroll view.") }
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    let offset = table.visibleRect.origin
    fixture.state.discovery = fixture.discovery(fixture.devices)
    try await fixture.requireScrollRemains(offset, in: table)
    fixture.state.discovery = fixture.discovery([])
    try await fixture.wait("Remove the empty simulator list.") { fixture.table == nil }
    fixture.state.discovery = fixture.discovery(fixture.devices)
    try await fixture.wait("Reveal the selection after list repopulation.") {
      guard let table = fixture.table else { return false }
      return fixture.isVisible(fixture.selected, in: table)
    }
  }

  private static func singleClickShutdown(
    _ fixture: SidebarFixture, verticalFraction: CGFloat = 0.5, horizontalFraction: CGFloat = 0.5
  ) async throws {
    let table = try await fixture.ready()
    let index = try fixture.visibleRow(in: table, state: .shutdown)
    try await fixture.click(
      index, in: table, count: 1,
      verticalFraction: verticalFraction, horizontalFraction: horizontalFraction)
    try await fixture.wait(
      "A single click selects immediately without waiting for a possible double click.",
      timeout: .milliseconds(100)
    ) {
      table.selectedRow == index && fixture.state.selectedDeviceID == fixture.devices[index].id
    }
    try await fixture.requireNoStart()
  }

  private static func mouseDownShutdown(_ fixture: SidebarFixture) async throws {
    let table = try await fixture.ready()
    let index = try fixture.visibleRow(in: table, state: .shutdown)
    let row = table.rect(ofRow: index)
    let point = table.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
    let timestamp = ProcessInfo.processInfo.systemUptime
    guard
      let down = NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
        windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1,
        clickCount: 1, pressure: 1)
    else { throw failure("Create the native mouse-down event.") }
    var selectionBeforeMouseUp: Int?
    let release = Timer(timeInterval: 0.2, repeats: false) { _ in
      MainActor.assumeIsolated {
        guard
          let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.2,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 2,
            clickCount: 1, pressure: 0)
        else { preconditionFailure("Create the native mouse-up event.") }
        selectionBeforeMouseUp = table.selectedRow
        NSApplication.shared.postEvent(up, atStart: false)
      }
    }
    // NSTableView tracks a held mouse in the event-tracking run-loop mode.
    RunLoop.main.add(release, forMode: .common)
    defer { release.invalidate() }
    NSApplication.shared.sendEvent(down)
    try await fixture.wait("Observe selection before releasing the mouse.") {
      selectionBeforeMouseUp != nil
    }
    guard selectionBeforeMouseUp == index else {
      throw failure("Select on mouse down, before mouse up or double-click recognition.")
    }
    try await fixture.requireNoStart()
  }

  private static func doubleClickShutdown(
    _ fixture: SidebarFixture, verticalFraction: CGFloat = 0.5
  ) async throws {
    let table = try await fixture.ready()
    let index = try fixture.visibleRow(in: table, state: .shutdown)
    try await fixture.click(index, in: table, count: 2, verticalFraction: verticalFraction)
    let id = fixture.devices[index].id
    try await fixture.wait("A double click selects and starts the shutdown simulator once.") {
      fixture.state.startRequests == [id] && fixture.state.selectionsAtStart == [id]
        && fixture.state.selectedDeviceID == id && table.selectedRow == index
    }
  }

  private static func clickInactive(
    _ fixture: SidebarFixture, state: SimulatorState, count: Int = 2
  )
    async throws
  {
    let table = try await fixture.ready()
    let index = try fixture.visibleRow(in: table)
    fixture.state.discovery = fixture.discovery(
      fixture.devices.enumerated().map { position, device in
        SimulatorDevice(
          id: device.id, name: device.name, runtime: device.runtime,
          state: position == index ? state : device.state)
      })
    try await fixture.click(index, in: table, count: count)
    try await fixture.wait(
      "A click still selects a \(state.rawValue) simulator.", timeout: .milliseconds(100)
    ) {
      table.selectedRow == index && fixture.state.selectedDeviceID == fixture.devices[index].id
    }
    try await fixture.requireNoStart()
  }

  fileprivate static func failure(_ message: String) -> NSError {
    NSError(
      domain: "SidebarSelectionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

@MainActor
private final class SidebarFixture {
  let state = SidebarState()
  let devices: [SimulatorDevice]
  let selected: Int
  let window: NSWindow

  init(arguments: [String]) throws {
    guard arguments.count <= 1 else {
      throw SidebarSelectionTests.failure("Expected at most one simulator inventory path.")
    }
    if let path = arguments.first {
      devices = try SimulatorDiscovery.decodeDevices(Data(contentsOf: URL(fileURLWithPath: path)))
    } else {
      devices = (0..<20).map {
        SimulatorDevice(
          id: "device-\($0)", name: "iPhone \($0)", runtime: "27.0",
          state: $0 == 12 ? .booted : .shutdown)
      }
    }
    guard let selected = devices.firstIndex(where: { $0.state == .booted }) else {
      throw SidebarSelectionTests.failure("The inventory needs an already booted iPhone.")
    }
    self.selected = selected
    window = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 240, height: 730),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SidebarHarness(state: state))
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
  }

  var table: NSTableView? {
    guard let root = window.contentView else { return nil }
    return tables(in: root).first(where: { $0.numberOfRows == devices.count })
  }

  func ready() async throws -> NSTableView {
    state.discovery = discovery(devices)
    try await wait("Display inventory before the initial selection arrives.") { table != nil }
    guard let table else { throw SidebarSelectionTests.failure("Expected the simulator list.") }
    state.selectedDeviceID = devices[selected].id
    try await wait("Reveal the initial booted simulator.") { isVisible(selected, in: table) }
    return table
  }

  func isVisible(_ index: Int, in table: NSTableView) -> Bool {
    table.selectedRow == index && table.visibleRect.contains(table.rect(ofRow: index))
  }

  func wait(
    _ message: String, timeout: Duration = .seconds(5), line: UInt = #line,
    until condition: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      window.contentView?.layoutSubtreeIfNeeded()
      if condition() { return }
      guard ContinuousClock.now < deadline else {
        throw SidebarSelectionTests.failure(
          "\(message) (line \(line)); selected row=\(table?.selectedRow ?? -1), viewport=\(table?.visibleRect ?? .zero)."
        )
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func requireScrollRemains(_ offset: NSPoint, in table: NSTableView) async throws {
    // Observe subsequent UI turns so a delayed selection task cannot pass unnoticed.
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
    repeat {
      window.contentView?.layoutSubtreeIfNeeded()
      guard table.visibleRect.origin == offset else {
        throw SidebarSelectionTests.failure(
          "Preserve scroll position: expected \(offset), got \(table.visibleRect.origin).")
      }
      try await Task.sleep(for: .milliseconds(20))
    } while ContinuousClock.now < deadline
  }

  func visibleRow(in table: NSTableView, state: SimulatorState? = nil) throws -> Int {
    guard
      let index = devices.indices.first(where: {
        $0 != selected && table.visibleRect.contains(table.rect(ofRow: $0))
          && (state == nil || devices[$0].state == state)
      })
    else { throw SidebarSelectionTests.failure("Expected another visible simulator row.") }
    return index
  }

  func click(
    _ index: Int, in table: NSTableView, count: Int,
    verticalFraction: CGFloat = 0.5, horizontalFraction: CGFloat = 0.5
  ) async throws {
    window.makeKeyAndOrderFront(nil)
    guard table.visibleRect.contains(table.rect(ofRow: index)) else {
      throw SidebarSelectionTests.failure("The clicked row must be visible.")
    }
    let row = table.rect(ofRow: index)
    let point = table.convert(
      NSPoint(
        x: row.minX + row.width * horizontalFraction,
        y: row.minY + row.height * verticalFraction), to: nil)
    for clickCount in 1...count {
      let timestamp = ProcessInfo.processInfo.systemUptime
      guard
        let down = NSEvent.mouseEvent(
          with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
          windowNumber: window.windowNumber, context: nil, eventNumber: clickCount * 2,
          clickCount: clickCount, pressure: 1),
        let up = NSEvent.mouseEvent(
          with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.01,
          windowNumber: window.windowNumber, context: nil, eventNumber: clickCount * 2 + 1,
          clickCount: clickCount, pressure: 0)
      else { throw SidebarSelectionTests.failure("Create the native mouse events.") }
      NSApplication.shared.postEvent(up, atStart: false)
      NSApplication.shared.sendEvent(down)
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func requireNoStart() async throws {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
    repeat {
      try await Task.sleep(for: .milliseconds(20))
      guard state.startRequests.isEmpty else {
        throw SidebarSelectionTests.failure("The click must not request simulator startup.")
      }
    } while ContinuousClock.now < deadline
  }

  func discovery(_ devices: [SimulatorDevice]) -> SimulatorDiscovery {
    SimulatorDiscovery(developerDirectory: URL(fileURLWithPath: "/Developer"), devices: devices)
  }

  private func tables(in view: NSView) -> [NSTableView] {
    (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
  }
}
