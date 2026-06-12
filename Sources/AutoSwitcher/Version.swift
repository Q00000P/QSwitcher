import Foundation

/// Информация о версии. BuildInfo переписывается make-app.sh при каждой сборке.
enum AppVersion {
    static let version = "0.7"
    static let build = BuildInfo.number
    static let buildDate = BuildInfo.date

    static var fullString: String {
        return "AutoSwitcher \(version) (билд \(build))"
    }
}

/// Автогенерируется make-app.sh — не редактировать руками.
enum BuildInfo {
    static let number = "2"
    static let date = "2026-06-12 22:15"
}
