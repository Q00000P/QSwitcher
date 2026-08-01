import Cocoa
import Foundation

// === Логирование в файл ===
// Все print() и fputs(stderr) дублируются в ~/Library/Logs/QSwitcher.log
// чтобы можно было разобраться с проблемой постфактум, без запуска из терминала.
func setupFileLogging() {
    let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let logFile = logsDir.appendingPathComponent("QSwitcher.log")

    // Ротация: если лог больше 5 МБ — переименовываем в .old (одна копия)
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
       let size = attrs[.size] as? Int, size > 5_000_000 {
        let old = logsDir.appendingPathComponent("QSwitcher.log.old")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logFile, to: old)
    }

    // Перенаправляем stdout и stderr в файл (append).
    // Запуск из терминала продолжит показывать вывод только если запущен
    // через `tee`, но для отладки достаточно tail -f самого лог-файла.
    freopen(logFile.path, "a", stdout)
    freopen(logFile.path, "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)   // линейная буферизация — строки пишутся сразу
    setvbuf(stderr, nil, _IONBF, 0)

    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\n===== \(AppVersion.fullString) запущен \(df.string(from: Date())) =====")
}

setupFileLogging()

// Перенос настроек со старого имени (AutoSwitcher) — один раз при первом запуске
Migration.runIfNeeded()

// Загружаем словари синхронно до запуска event tap.
// На больших словарях это ~0.3 сек — допустимая задержка при старте.
_ = Dictionary.shared

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
