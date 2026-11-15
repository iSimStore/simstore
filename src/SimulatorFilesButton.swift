import AppKit
import SwiftUI

@MainActor
struct SimulatorFilesButton: View {
  let device: SimulatorDevice
  var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }

  @State private var isOpening = false
  @State private var error: String?

  var body: some View {
    Button {
      isOpening = true
      let dataPath = device.dataPath
      Task {
        defer { isOpening = false }
        do {
          let directory = try await Task.detached(priority: .userInitiated) {
            try SimulatorFiles.directory(in: dataPath)
          }.value
          guard open(directory) else { throw SimulatorFilesError.couldNotOpen }
        } catch {
          self.error = error.localizedDescription
        }
      }
    } label: {
      Label(device.localFilesTitle, systemImage: "folder")
    }
    .disabled(isOpening)
    .help(Text("Open in Finder"))
    .accessibilityIdentifier("simulator-files")
    .alert(
      "Couldn’t Open Folder",
      isPresented: Binding(
        get: { error != nil },
        set: { if !$0 { error = nil } })
    ) {
      Button("OK", role: .cancel) { error = nil }
    } message: {
      Text(error ?? "")
    }
  }
}
