import Foundation

extension SimulatorDevice {
  enum FormFactor: CaseIterable, Hashable {
    case phone
    case tablet

    var symbolName: String {
      switch self {
      case .phone: "iphone"
      case .tablet: "ipad.landscape"
      }
    }
  }

  var formFactor: FormFactor {
    if let deviceTypeIdentifier {
      return deviceTypeIdentifier.contains(".iPad-") ? .tablet : .phone
    }
    return name.contains("iPad") ? .tablet : .phone
  }

  var localFilesTitle: String {
    switch formFactor {
    case .phone: String(localized: "On My iPhone")
    case .tablet: String(localized: "On My iPad")
    }
  }

  var symbolName: String { formFactor.symbolName }

  var runtimeLabel: String { String(localized: "iOS \(runtime)") }
}
