import Foundation

enum CatalogCategory: String {
  case browser, cloud, communication, email, games, health, maps, media, music, productivity,
    reading,
    security, social, utilities

  var title: String {
    switch self {
    case .browser: String(localized: "Browser")
    case .cloud: String(localized: "Cloud")
    case .communication: String(localized: "Communication")
    case .email: String(localized: "Email")
    case .games: String(localized: "Games")
    case .health: String(localized: "Health")
    case .maps: String(localized: "Maps")
    case .media: String(localized: "Media")
    case .music: String(localized: "Music")
    case .productivity: String(localized: "Productivity")
    case .reading: String(localized: "Reading")
    case .security: String(localized: "Security")
    case .social: String(localized: "Social")
    case .utilities: String(localized: "Utilities")
    }
  }

  static func title(_ category: String) -> String {
    Self(rawValue: category)?.title ?? category
  }
}
