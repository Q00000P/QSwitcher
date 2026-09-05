import Foundation

/// Информация о версии. BuildInfo переписывается make-app.sh при каждой сборке.
enum AppVersion {
    static let version = "4.0"
    static let build = BuildInfo.number
    static let buildDate = BuildInfo.date
    /// Метка волны разработки (задаётся в make-app.sh).
    static let wave = "wave4d"

    static var fullString: String {
        return "QSwitcher \(version) (\(wave), билд \(build))"
    }
}

/// Автогенерируется make-app.sh — не редактировать руками.
enum BuildInfo {
    static let number = "54"
    static let date = "2026-09-05 03:08"
}
