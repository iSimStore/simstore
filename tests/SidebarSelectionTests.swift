import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
private final class SidebarState {
  var discovery: SimulatorDiscovery?
  var selectedDeviceID: String?
  var section = LibrarySection.discover
}

private struct SidebarHarness: View {
  @Bindable var state: SidebarState

  var body: some View {
    GeometryReader { geometry in
      SidebarView(
        discovery: state.discovery, isChecking: false, needsXcode: false,
        section: $state.section, updateCount: nil, selectedDeviceID: state.selectedDeviceID,
        selectDevice: { state.selectedDeviceID = $0 }, openRepository: {}
      )
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }
  }
}

@main
@MainActor
struct SidebarSelectionTests {
  static func main() async {
    let scenarios: [(String, @MainActor (SidebarFixture) async throws -> Void)] = [
      ("initialSelection", initialSelection),
      ("visibleSelections", visibleSelections),
      ("offscreenSelections", offscreenSelections),
      ("topClippedSelection", { try await clippedSelection($0, clipsTop: true) }),
      ("bottomClippedSelection", { try await clippedSelection($0, clipsTop: false) }),
      ("refreshAndRepopulation", refreshAndRepopulation),
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
    NSApplication.shared.setActivationPolicy(.regular)
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

  func wait(_ message: String, line: UInt = #line, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
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

  func discovery(_ devices: [SimulatorDevice]) -> SimulatorDiscovery {
    SimulatorDiscovery(developerDirectory: URL(fileURLWithPath: "/Developer"), devices: devices)
  }

  private func tables(in view: NSView) -> [NSTableView] {
    (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
  }
}
