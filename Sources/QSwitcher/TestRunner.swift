import Foundation

/// Прогон фраз через тот же детектор, что живой ввод (без хука). Используется
/// из командной строки (--test) и из меню («Профиль: прогон…»).
/// Строка: «фраза => ожидание»; цель — последнее слово или в *звёздочках*;
/// «#» — комментарий; без «=>» — просто показать решение.
enum TestRunner {

    static var phrasesURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("QSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test-phrases.txt")
    }

    struct Report {
        var lines: [String] = []
        var total = 0, ok = 0
        var text: String { lines.joined(separator: "\n") + (total > 0 ? "\n\nИтого: \(ok)/\(total) верно" : "") }
    }

    /// verbose — добавлять объяснение детектора (последнюю строку профиля) к каждой фразе.
    static func run(_ text: String, verbose: Bool = true) -> Report {
        var rep = Report()
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var expect: String? = nil
            if let r = line.range(of: "=>") {
                expect = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                line = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            var words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else { continue }
            var ti = words.count - 1
            for (k, w) in words.enumerated() where w.count > 2 && w.hasPrefix("*") && w.hasSuffix("*") {
                words[k] = String(w.dropFirst().dropLast()); ti = k
            }
            let word = words[ti]
            let before = Array(words[..<ti])
            var cyr = 0, lat = 0
            for w in before.suffix(3) {
                for ch in w {
                    if ("а"..."я").contains(ch) || ("А"..."Я").contains(ch) || ch == "ё" || ch == "Ё" { cyr += 1 }
                    else if ch.isLetter { lat += 1 }
                }
            }
            let ctx: InputSource.Lang? = (cyr + lat < 2) ? nil : (cyr > lat ? .ru : lat > cyr ? .en : nil)
            let isRu = word.contains { ("а"..."я").contains($0) || ("А"..."Я").contains($0) || $0 == "ё" || $0 == "Ё" }
            let cur: InputSource.Lang = isRu ? .ru : .en
            print("--- \(line)")
            SemProfile.shared.clearExplain()
            let willSwitch = Detector.shouldSwitch(word: word, currentLang: cur, context: ctx,
                                                   history: Array(before.suffix(3).reversed()),
                                                   app: "test", topic: before.reversed())
            let result = willSwitch ? Detector.shared.swap(word) : word
            var verdict = "\(line)    = \(result)"
            if let e = expect {
                rep.total += 1
                let hit = result.lowercased() == e.lowercased()
                if hit { rep.ok += 1 }
                verdict += hit ? "   ✅" : "   ❌ ждали \(e)"
            }
            print("    = \(result)" + (expect.map { result.lowercased() == $0.lowercased() ? "   ✅" : "   ❌ ждали \($0)" } ?? ""))
            rep.lines.append(verdict)
            if verbose, !SemProfile.shared.lastExplain.isEmpty {
                rep.lines.append("      " + SemProfile.shared.lastExplain)
            }
        }
        return rep
    }
}
