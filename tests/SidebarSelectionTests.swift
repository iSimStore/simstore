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
    do {
      NSApplication.shared.setActivationPolicy(.regular)
      let devices: [SimulatorDevice]
      if CommandLine.arguments.count == 2 {
        devices = try SimulatorDiscovery.decodeDevices(
          Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
      } else {
        devices = (0..<20).map {
          SimulatorDevice(
            id: "device-\($0)", name: "iPhone \($0)", runtime: "27.0",
            state: $0 == 12 ? .booted : .shutdown)
        }
      }
      guard let selected = devices.firstIndex(where: { $0.state == .booted }) else {
        throw failure("The inventory needs an already booted iPhone.")
      }
      let state = SidebarState()
      let host = NSHostingView(rootView: SidebarHarness(state: state))
      let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 240, height: 730),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      try await Task.sleep(for: .milliseconds(100))
      state.discovery = discovery(devices)
      try await settle(host)
      state.selectedDeviceID = devices[selected].id
      try await settle(host)
      guard let table = tables(in: host).first(where: { $0.numberOfRows == devices.count }),
        let scroll = table.enclosingScrollView
      else { throw failure("Expected the native simulator list.") }
      try requireVisible(selected, in: table)
      print(
        "Selected \(devices[selected].name): row=\(table.rect(ofRow: selected)), visible=\(table.visibleRect)"
      )

      for firstRow in [0, max(0, selected - 2)] {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: firstRow).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        guard
          let index = devices.indices.last(where: {
            table.visibleRect.contains(table.rect(ofRow: $0))
              && devices[$0].id != state.selectedDeviceID
          })
        else { throw failure("Expected another fully visible simulator row.") }
        let offset = table.visibleRect.origin
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        try await settle(host)
        guard state.selectedDeviceID == devices[index].id else {
          throw failure("Selecting a native row must update the selected simulator.")
        }
        guard table.visibleRect.origin == offset else {
          throw failure(
            "Selecting visible row \(index) must preserve scrolling: \(offset) -> \(table.visibleRect.origin)."
          )
        }
        guard
          let other = devices.indices.first(where: {
            table.visibleRect.contains(table.rect(ofRow: $0)) && $0 != index
          })
        else { throw failure("Expected another visible simulator for menu selection.") }
        state.selectedDeviceID = devices[other].id
        try await settle(host)
        guard table.selectedRow == other, table.visibleRect.origin == offset else {
          throw failure("Menu selection of a visible simulator must preserve scrolling.")
        }
      }

      state.selectedDeviceID = devices[selected].id
      try await settle(host)
      try requireVisible(selected, in: table)
      for index in [devices.count - 1, 0, selected] {
        state.selectedDeviceID = devices[index].id
        try await settle(host)
        try requireVisible(index, in: table)
      }

      for clipsTop in [true, false] {
        state.selectedDeviceID = devices[0].id
        try await settle(host)
        let row = table.rect(ofRow: selected)
        let origin = clipsTop ? row.midY : row.midY - table.visibleRect.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: origin))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        let viewport = table.visibleRect
        let visibleHeight = viewport.intersection(row).height
        guard visibleHeight > 0, visibleHeight < row.height else {
          throw failure("Expected a partially clipped simulator row.")
        }
        let expected = clipsTop ? row.minY : row.maxY - viewport.height
        table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        try await settle(host)
        try requireVisible(selected, in: table)
        guard state.selectedDeviceID == devices[selected].id,
          abs(table.visibleRect.minY - expected) <= 1
        else {
          throw failure(
            "Reveal a clipped row with minimum scrolling: expected \(expected), got \(table.visibleRect.minY)."
          )
        }
      }

      scroll.contentView.scroll(to: .zero)
      scroll.reflectScrolledClipView(scroll.contentView)
      let offset = table.visibleRect.origin
      state.discovery = discovery(devices)
      try await settle(host)
      guard table.visibleRect.origin == offset else {
        throw failure("Refreshing the same selection must preserve manual scrolling.")
      }

      state.discovery = discovery([])
      try await settle(host)
      state.discovery = discovery(devices)
      try await settle(host)
      guard let repopulated = tables(in: host).first(where: { $0.numberOfRows == devices.count })
      else { throw failure("Expected the simulator list after repopulation.") }
      try requireVisible(selected, in: repopulated)

      // A recreated sidebar must also reveal a selection that predates its appearance.
      let recreated = NSHostingView(rootView: SidebarHarness(state: state))
      window.contentView = recreated
      try await settle(recreated)
      guard let restored = tables(in: recreated).first(where: { $0.numberOfRows == devices.count })
      else { throw failure("Expected the recreated simulator list.") }
      try requireVisible(selected, in: restored)
      print(
        "PASS: initial and offscreen selection, visible row selection without scrolling, minimum scrolling for clipped rows, list repopulation, sidebar recreation, and refresh scroll preservation."
      )
    } catch {
      FileHandle.standardError.write(
        Data("Sidebar selection test failed: \(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  private static func settle(_ view: NSView) async throws {
    for _ in 0..<20 {
      view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private static func tables(in view: NSView) -> [NSTableView] {
    (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
  }

  private static func discovery(_ devices: [SimulatorDevice]) -> SimulatorDiscovery {
    SimulatorDiscovery(developerDirectory: URL(fileURLWithPath: "/Developer"), devices: devices)
  }

  private static func requireVisible(_ index: Int, in table: NSTableView) throws {
    guard table.selectedRow == index, table.visibleRect.contains(table.rect(ofRow: index)) else {
      throw failure(
        "Expected selected row \(index), got \(table.selectedRow); row=\(table.rect(ofRow: index)), visible=\(table.visibleRect)."
      )
    }
  }

  private static func failure(_ message: String) -> NSError {
    NSError(
      domain: "SidebarSelectionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
