import Foundation

/// Информация о версии. BuildInfo переписывается make-app.sh при каждой сборке.
enum AppVersion {
    static let version = "3.2"
    static let build = BuildInfo.number
    static let buildDate = BuildInfo.date

    static var fullString: String {
        return "QSwitcher \(version) (билд \(build))"
    }
}

/// Автогенерируется make-app.sh — не редактировать руками.
enum BuildInfo {
    static let number = "22"
    static let date = "2026-08-10 01:54"
}
