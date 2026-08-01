import Foundation

/// Загружает словари из bundle. Каждый файл — по слову на строку, UTF-8.
final class Dictionary {

    static let shared = Dictionary()

    private(set) var ru: Set<String> = []
    private(set) var en: Set<String> = []
    private(set) var loaded: Bool = false

    private init() {
        load()
    }

    private func load() {
        let started = Date()

        let ruURL = findResource("ru", ext: "txt")
        let enURL = findResource("en", ext: "txt")

        if let url = ruURL {
            print("📚 Найден ru.txt: \(url.path)")
            ru = readWords(from: url)
        } else {
            fputs("⚠️ ru.txt не найден ни в одном из путей.\n", stderr)
        }
        if let url = enURL {
            print("📚 Найден en.txt: \(url.path)")
            en = readWords(from: url)
        } else {
            fputs("⚠️ en.txt не найден ни в одном из путей.\n", stderr)
        }

        // Override: пользовательский каталог
        let userDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QSwitcher/dicts", isDirectory: true)
        let userRu = userDir.appendingPathComponent("ru.txt")
        let userEn = userDir.appendingPathComponent("en.txt")
        if FileManager.default.fileExists(atPath: userRu.path) {
            ru.formUnion(readWords(from: userRu))
            print("📚 Подмержен пользовательский ru: \(userRu.path)")
        }
        if FileManager.default.fileExists(atPath: userEn.path) {
            en.formUnion(readWords(from: userEn))
            print("📚 Подмержен пользовательский en: \(userEn.path)")
        }

        loaded = !ru.isEmpty && !en.isEmpty
        let dt = Date().timeIntervalSince(started)
        if loaded {
            print(String(format: "📚 Словари загружены: ru=%d, en=%d (%.2f сек)", ru.count, en.count, dt))
        } else {
            fputs("⚠️ Словари не загружены. Без них работает только n-gram эвристика.\n", stderr)
        }
    }

    /// Поиск ресурса по нескольким путям с логированием.
    private func findResource(_ name: String, ext: String) -> URL? {
        let fileName = "\(name).\(ext)"

        // 1. Bundle.main напрямую (.app/Contents/Resources/<name>.<ext>)
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }

        // 2. Главный путь — Contents/Resources/ внутри .app
        if let resURL = Bundle.main.resourceURL {
            let direct = resURL.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }

            // 3. Внутри SwiftPM-сгенерированного бандла (если есть)
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: resURL, includingPropertiesForKeys: nil) {
                for item in contents where item.pathExtension == "bundle" {
                    let inner1 = item.appendingPathComponent("Contents/Resources/\(fileName)")
                    if FileManager.default.fileExists(atPath: inner1.path) { return inner1 }
                    let inner2 = item.appendingPathComponent(fileName)
                    if FileManager.default.fileExists(atPath: inner2.path) { return inner2 }
                }
            }
        }

        // 4. Рядом с бинарём (для CLI/dev-режима)
        if let exePath = Bundle.main.executablePath {
            let exeDir = (exePath as NSString).deletingLastPathComponent
            let baseURL = URL(fileURLWithPath: exeDir)
            let candidates = [
                baseURL.appendingPathComponent("Resources/\(fileName)"),
                baseURL.appendingPathComponent(fileName),
                baseURL.appendingPathComponent("../Resources/\(fileName)"),
                baseURL.appendingPathComponent("QSwitcher_QSwitcher.bundle/\(fileName)"),
                baseURL.appendingPathComponent("QSwitcher_QSwitcher.bundle/Contents/Resources/\(fileName)"),
            ]
            for c in candidates {
                if FileManager.default.fileExists(atPath: c.path) { return c }
            }
        }

        return nil
    }

    private func readWords(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url) else {
            fputs("⚠️ Не удалось прочитать \(url.path)\n", stderr)
            return []
        }
        guard let text = String(data: data, encoding: .utf8) else {
            fputs("⚠️ Файл \(url.path) не в UTF-8\n", stderr)
            return []
        }
        var set = Set<String>()
        set.reserveCapacity(150_000)
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.count >= 2 { set.insert(trimmed) }
        }
        return set
    }
}
