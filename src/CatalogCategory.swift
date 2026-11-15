import Foundation

enum CatalogCategory: String {
  case browser, cloud, communication, email, games, health, lifestyle, maps, media, music,
    news, photography, productivity, reading, reference, security, social, utilities, weather
  case developerTools = "developer-tools"

  var title: String {
    switch self {
    case .browser: String(localized: "Browser")
    case .cloud: String(localized: "Cloud")
    case .communication: String(localized: "Communication")
    case .developerTools: String(localized: "Developer Tools")
    case .email: String(localized: "Email")
    case .games: String(localized: "Games")
    case .health: String(localized: "Health")
    case .lifestyle: String(localized: "Lifestyle")
    case .maps: String(localized: "Maps")
    case .media: String(localized: "Media")
    case .music: String(localized: "Music")
    case .news: String(localized: "News")
    case .photography: String(localized: "Photography")
    case .productivity: String(localized: "Productivity")
    case .reading: String(localized: "Reading")
    case .reference: String(localized: "Reference")
    case .security: String(localized: "Security")
    case .social: String(localized: "Social")
    case .utilities: String(localized: "Utilities")
    case .weather: String(localized: "Weather")
    }
  }

  static func title(_ category: String) -> String {
    Self(rawValue: category)?.title ?? category
  }
}
