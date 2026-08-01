import Foundation

/// Перенос пользовательских данных со старого имени приложения.
///
/// При переименовании AutoSwitcher → QSwitcher меняется папка в Application Support,
/// а там лежит то что человек накопил: настройки и выученные правила. Молча их
/// потерять нельзя, поэтому при первом запуске под новым именем переносим.
///
/// Выполняется один раз: если новая папка уже есть, ничего не делаем.
enum Migration {

    static func runIfNeeded() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let old = appSupport.appendingPathComponent("AutoSwitcher", isDirectory: true)
        let new = appSupport.appendingPathComponent("QSwitcher", isDirectory: true)

        // Новая папка уже есть — миграция не нужна
        guard !fm.fileExists(atPath: new.path) else { return }
        // Старой нет — чистая установка
        guard fm.fileExists(atPath: old.path) else { return }

        do {
            // Копируем, а не переносим: старая версия останется рабочей
            // если человек захочет откатиться.
            try fm.copyItem(at: old, to: new)
            print("📦 Настройки перенесены из AutoSwitcher (конфиг, выученные правила, словари)")
        } catch {
            print("⚠️ Не удалось перенести настройки: \(error.localizedDescription)")
            print("   Скопируй вручную: ~/Library/Application Support/AutoSwitcher → QSwitcher")
        }

        // Защищённый лог лежит отдельно, в Logs
        let logsOld = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AutoSwitcher", isDirectory: true)
        let logsNew = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/QSwitcher", isDirectory: true)
        if fm.fileExists(atPath: logsOld.path) && !fm.fileExists(atPath: logsNew.path) {
            try? fm.copyItem(at: logsOld, to: logsNew)
            print("📦 Защищённый лог перенесён (ключ в Keychain прежний, записи читаются)")
        }
    }
}
