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
    /// Глушим stdout на время «тихих» решений по контекстным словам.
    @discardableResult
    static func silence(_ on: Bool) -> Bool {
        struct S { static var saved: Int32 = -1; static var on = false }
        let was = S.on
        if on && !S.on {
            fflush(stdout)
            S.saved = dup(STDOUT_FILENO)
            let devnull = open("/dev/null", O_WRONLY)
            dup2(devnull, STDOUT_FILENO); close(devnull)
            S.on = true
        } else if !on && S.on {
            fflush(stdout)
            dup2(S.saved, STDOUT_FILENO); close(S.saved)
            S.on = false
        }
        return was
    }

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
            Detector.resolvedInSentence.removeAll()
            var words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            // Место ввода в тесте: «@terminal ls -la» / «@chat привет» / «@address ...»
            var app = "test", field = ""
            if let first = words.first, first.hasPrefix("@") {
                let tag = String(first.dropFirst()).lowercased()
                switch tag {
                case "terminal": app = "com.apple.terminal"
                case "code": app = "com.microsoft.vscode"
                case "chat": app = "ru.keepcoder.telegram"
                case "browser": app = "com.apple.safari"
                case "address": app = "com.apple.safari"; field = "address"
                case "password": field = "password"
                default: break
                }
                words.removeFirst()
            }
            guard !words.isEmpty else { continue }
            var ti = words.count - 1
            for (k, w) in words.enumerated() where w.count > 2 && w.hasPrefix("*") && w.hasSuffix("*") {
                words[k] = String(w.dropFirst().dropLast()); ti = k
            }
            let word = words[ti]
            // Как при живом наборе: слова ДО цели уже прошли через детектор и стоят
            // на экране в решённом виде. Иначе «Xnj *ns* знаешь» видит соседом
            // сырое 'Xnj', хотя живьём к моменту 'ns' на экране уже 'Что' и пара
            // «что ты» есть. Решаем предыдущие слова по очереди, тихо.
            var before: [String] = []
            for w in words[..<ti] {
                let prevIsRu = w.contains { ("а"..."я").contains($0) || ("А"..."Я").contains($0) || $0 == "ё" || $0 == "Ё" }
                let saved = TestRunner.silence(true)
                let sw = Detector.shouldSwitch(word: w, currentLang: prevIsRu ? .ru : .en, context: nil,
                                               history: before.reversed(), app: app,
                                               topic: before.reversed(), field: field)
                TestRunner.silence(saved)
                before.append(sw ? Detector.shared.swap(w) : w)
            }
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
            // История — всё предложение до цели (ближайшее первым): нужно и для соседа,
            // и чтобы увидеть те же клавиши, уже занятые в этом предложении.
            let willSwitch = Detector.shouldSwitch(word: word, currentLang: cur, context: ctx,
                                                   history: before.reversed(),
                                                   app: app, topic: before.reversed(), field: field)
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
