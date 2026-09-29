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

// Режимы командной строки — без фоновой самопроверки ядра (она печатала бы посреди вывода)
if CommandLine.arguments.contains(where: { ["--train", "--forget-tag", "--test", "--selftest-core"].contains($0) }) {
    Core5.autoSelftest = false
}

// === Самопроверка ядра 5: QSwitcher --selftest-core [файл] [--verbose] ===
// Те же входы, что эталон на Python (nn/lm/model.py → core5-selftest.json) → те же решения.
if let i = CommandLine.arguments.firstIndex(of: "--selftest-core") {
    setvbuf(stdout, nil, _IOLBF, 0)
    // Этапы — в stderr без буфера: если что-то повиснет, видно где
    fputs("selftest: частоты слов…\n", stderr)
    _ = NgramLM.shared
    fputs("selftest: символьная модель…\n", stderr)
    _ = CharLM.shared
    fputs("selftest: прогон эталона…\n", stderr)
    var url = Core5.selftestURL
    if i + 1 < CommandLine.arguments.count, !CommandLine.arguments[i + 1].hasPrefix("--") {
        url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    }
    guard let u = url else {
        print("нет core5-selftest.json — укажи путь: --selftest-core nn/lm/core5-selftest.json")
        exit(2)
    }
    let t0 = Date()
    let (n, bad) = Core5.selftest(url: u, verbose: CommandLine.arguments.contains("--verbose"))
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    print("Ядро 5 / самопроверка: \(n - bad)/\(n) совпало с эталоном (\(ms) мс)")
    exit(bad == 0 && n > 0 ? 0 : 1)
}

// === Обучение из файла: QSwitcher --train файл ===
// Тот же код, что окно «Обучить профиль на тексте…», с отчётом в stdout.
if let i = CommandLine.arguments.firstIndex(of: "--train"), i + 1 < CommandLine.arguments.count {
    setvbuf(stdout, nil, _IOLBF, 0)
    let path = CommandLine.arguments[i + 1]
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("не читается: \(path)"); exit(2) }
    _ = Dictionary.shared
    _ = Detector.shared
    _ = NgramLM.shared
    if CommandLine.arguments.contains("--arbiter") {
        Arbiter.shared.syncMode = true
        if let info = Arbiter.shared.info() { print("🤖 Арбитр: \(info)") }
        else { print("🤖 Арбитр: сокет \(Arbiter.shared.socketPath) не отвечает — запусти nn/llm/arbiter.py и включи arbiterEnabled") }
    }
    SemProfile.shared.rebuildIfNeeded()
    print("🧭 Профиль: \(SemProfile.shared.readingCount) чтений")
    // --tag имя: группа в журнале, откатывается целиком через --forget-tag имя
    var source = "файл"
    if let t = CommandLine.arguments.firstIndex(of: "--tag"), t + 1 < CommandLine.arguments.count {
        source = "файл:" + CommandLine.arguments[t + 1]
    }
    let rep = SemProfile.shared.train(text: text, source: source)
    print("обучение: \(rep.text)" + (source == "файл" ? "" : "  [группа \(source.dropFirst(5))]"))
    print("профиль: \(SemProfile.shared.path.path)")
    exit(0)
}

// === Откат группы обучения: QSwitcher --forget-tag имя ===
if let i = CommandLine.arguments.firstIndex(of: "--forget-tag"), i + 1 < CommandLine.arguments.count {
    setvbuf(stdout, nil, _IOLBF, 0)
    _ = Dictionary.shared
    _ = Detector.shared
    let r = SemProfile.shared.forget(tag: CommandLine.arguments[i + 1])
    print("удалено строк: \(r.removed), осталось: \(r.left); профиль: \(SemProfile.shared.readingCount) чтений")
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
    _ = NgramLM.shared
    _ = CharLM.shared
    if CommandLine.arguments.contains("--arbiter") {
        Arbiter.shared.syncMode = true
        if let info = Arbiter.shared.info() { print("🤖 Арбитр: \(info)") }
        else { print("🤖 Арбитр: сокет \(Arbiter.shared.socketPath) не отвечает — запусти nn/llm/arbiter.py и включи arbiterEnabled") }
    }
    SemProfile.shared.rebuildIfNeeded()
    print("🧭 Профиль: \(SemProfile.shared.readingCount) чтений")
    print("⚙️ Ядро: \(Config.shared.coreV5 ? "v5 (одна формула)" : "legacy (каскад)")")
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
