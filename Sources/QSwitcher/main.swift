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

// === Обучение из файла: QSwitcher --train файл ===
// Тот же код, что окно «Обучить профиль на тексте…», с отчётом в stdout.
if let i = CommandLine.arguments.firstIndex(of: "--train"), i + 1 < CommandLine.arguments.count {
    setvbuf(stdout, nil, _IOLBF, 0)
    let path = CommandLine.arguments[i + 1]
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("не читается: \(path)"); exit(2) }
    _ = Dictionary.shared
    _ = Detector.shared
    SemProfile.shared.rebuildIfNeeded()
    let rep = SemProfile.shared.train(text: text, source: "файл")
    print("обучение: \(rep.text)")
    print("профиль: \(SemProfile.shared.path.path)")
    exit(0)
}

// === Режим прогона: QSwitcher --test файл ===
// Строка = фраза, целевое слово последнее или в *звёздочках*, ожидание после «=>».
if let i = CommandLine.arguments.firstIndex(of: "--test"), i + 1 < CommandLine.arguments.count {
    setvbuf(stdout, nil, _IOLBF, 0)
    let path = CommandLine.arguments[i + 1]
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("не читается: \(path)"); exit(2)
    }
    _ = Dictionary.shared
    _ = Detector.shared
    SemProfile.shared.rebuildIfNeeded()
    let rep = TestRunner.run(text, verbose: false)
    if rep.total > 0 { print("\nИтого: \(rep.ok)/\(rep.total) верно") }
    exit(0)
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
