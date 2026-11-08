import AppKit
import SwiftUI

@MainActor
struct SidebarView: View {
  let discovery: SimulatorDiscovery?
  let isChecking: Bool
  let needsXcode: Bool
  @Binding var section: LibrarySection
  let updateCount: Int?
  let selectedDeviceID: String?
  let selectDevice: (String) -> Void
  let openRepository: () -> Void

  private static let sectionRowHeight: CGFloat = 44
  private static let simulatorRowVerticalInset: CGFloat = 10

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .frame(width: 37, height: 37)
        Text(verbatim: "SimStore")
          .font(.system(size: 22, weight: .bold))
          .tracking(-0.7)
      }
      .padding(.horizontal, 20)
      .padding(.top, 24)
      .padding(.bottom, 27)
      .fixedSize(horizontal: false, vertical: true)

      sectionList

      simulatorListTitle
        .textCase(.uppercase)
        .font(.system(size: 10, weight: .semibold))
        .tracking(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 15)
        .fixedSize(horizontal: false, vertical: true)

      if let discovery, !discovery.devices.isEmpty {
        ScrollViewReader { proxy in
          List(
            selection: Binding(
              get: { selectedDeviceID },
              set: { if let id = $0 { selectDevice(id) } })
          ) {
            ForEach(discovery.devices) { device in
              Label {
                VStack(alignment: .leading, spacing: 4) {
                  Text(device.name).font(.system(size: 12, weight: .medium))
                  Text(
                    "\(device.runtimeLabel) · \(device.state.label)"
                  )
                  .font(.system(size: 10))
                  .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
              } icon: {
                Image(systemName: device.symbolName)
                  .foregroundStyle(.secondary)
                  .frame(width: 20)
              }
              .tag(device.id)
              .id(device.id)
              .listRowInsets(
                EdgeInsets(
                  top: Self.simulatorRowVerticalInset, leading: 12,
                  bottom: Self.simulatorRowVerticalInset, trailing: 12)
              )
              .anchorPreference(key: SimulatorRowBounds.self, value: .bounds) {
                [device.id: $0]
              }
              .accessibilityElement(children: .combine)
              .help(Text(verbatim: device.id))
            }
          }
          .listStyle(.sidebar)
          .scrollContentBackground(.hidden)
          .accessibilityLabel(simulatorListTitle)
          .frame(minHeight: 0)
          .overlayPreferenceValue(SimulatorRowBounds.self) { bounds in
            GeometryReader { geometry in
              Color.clear
                .task(id: selectedDeviceID) {
                  guard let id = selectedDeviceID else { return }
                  // The native list needs its first layout before it can reveal a row.
                  await Task.yield()
                  guard !Task.isCancelled else { return }
                  let viewport = CGRect(origin: .zero, size: geometry.size)
                  if let anchor = bounds[id] {
                    // Anchors cover row content; include its vertical list insets.
                    let row = geometry[anchor].insetBy(dx: 0, dy: -Self.simulatorRowVerticalInset)
                    if viewport.contains(row) { return }
                    if viewport.intersects(row) {
                      proxy.scrollTo(id)
                      return
                    }
                  }
                  proxy.scrollTo(id, anchor: .center)
                }
            }
            .allowsHitTesting(false)
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 7) {
          Text(
            isChecking
              ? String(localized: "Checking for devices…")
              : needsXcode
                ? String(localized: "Xcode required")
                : discovery == nil
                  ? String(localized: "No devices to display")
                  : String(localized: "No simulators yet")
          )
          .font(.system(size: 12, weight: .medium))
          Text(
            needsXcode
              ? String(localized: "Install Xcode to add iPhone and iPad simulators.")
              : String(localized: "Your iPhone and iPad simulators will appear here.")
          )
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
      }

      Spacer(minLength: 24)

      Button(action: openRepository) {
        Label("App Repository", systemImage: "arrow.up.right.square")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .padding(24)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var sectionList: some View {
    let count = LibrarySection.allCases.count
    return List(
      selection: Binding<LibrarySection?>(
        get: { section },
        set: { if let item = $0 { section = item } })
    ) {
      ForEach(LibrarySection.allCases, id: \.self) { item in
        HStack(spacing: 8) {
          Label {
            Text(verbatim: item.title)
          } icon: {
            Image(systemName: item.symbolName)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if item == .updates, let count = visibleUpdateCount {
            Text(count, format: .number)
              .font(.system(size: 10, weight: .semibold))
              .monospacedDigit()
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .frame(height: 18)
              .background(Color.accentColor, in: Capsule())
              .accessibilityHidden(true)
          }
        }
        .frame(minHeight: 18)
        .font(.system(size: 13, weight: section == item ? .semibold : .regular))
        .tag(item)
        .listRowInsets(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityValue(
          Text(verbatim: item == .updates ? visibleUpdateCount?.formatted() ?? "" : "")
        )
        .accessibilityIdentifier("library-\(item.rawValue)")
      }
    }
    .listStyle(.sidebar)
    .environment(\.defaultMinListRowHeight, Self.sectionRowHeight)
    .contentMargins(.vertical, 0, for: .scrollContent)
    .scrollContentBackground(.hidden)
    .scrollDisabled(true)
    .frame(height: CGFloat(count) * Self.sectionRowHeight)
    .accessibilityIdentifier("library-navigation")
  }

  private var simulatorListTitle: Text { Text("Simulators") }

  private var visibleUpdateCount: Int? {
    guard let updateCount, updateCount > 0 else { return nil }
    return updateCount
  }
}

private struct SimulatorRowBounds: PreferenceKey {
  static let defaultValue: [String: Anchor<CGRect>] = [:]

  static func reduce(
    value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}
