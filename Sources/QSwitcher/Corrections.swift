import Foundation

/// Личные исправления для дообучения сети. Пишутся при явном обучении
/// (Shift + правый Option: «впредь переключать» / «больше не переключать») вместе
/// с контекстом и классом приложения — то, чего у LearnedRules нет.
/// Файл: ~/Library/Application Support/QSwitcher/nn-corrections.jsonl, по JSON на строку:
///   {"keys":"he","ctx":[["f","ru"]],"app":"chat","layout":"ru","label":"ru","t":"…"}
/// При дообучении к ним добавляются слова из learned.json (force → другой язык,
/// stop → свой), одинаковые (клавиши + контекст) схлопываются, последний побеждает.
final class Corrections {

    static let shared = Corrections()

    private var path: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("QSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nn-corrections.jsonl")
    }

    /// Записать исправление. word — как набрано; intendedRu — какой язык имелся в виду;
    /// history — предыдущие слова как на экране, ближайшее первым (без самого слова).
    func record(word: String, intendedRu: Bool, onScreen: String, history: [String], topic: [String], app: String?,
                source: String = "свап") {
        let det = Detector.shared
        let net = LayoutNet.shared
        guard let keys = net.keys(for: word.lowercased(), ruToEn: det.ruToEn), keys.count >= 2 else { return }
        // Семантический профиль: чтение (как теперь на экране) + тема окна + левый сосед
        if SemVec.shared.loaded {
            let sem = SemVec.shared
            // Тема — без самого слова (оно уже в кольце темы после границы)
            let ex = Set([word.lowercased(), onScreen.lowercased()])
            let topic = topic.filter { !ex.contains($0.lowercased()) }
            let screenWord = onScreen.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? onScreen
            let cleaned = screenWord.filter { $0.isLetter }
            if !cleaned.isEmpty {
                SemProfile.shared.observe(keys: keys, text: cleaned,
                                          topic: sem.topic(recentFirst: topic),
                                          left: history.first.map { sem.centered($0) })
                SemProfile.shared.journalLive(target: cleaned, left: history.first, topicRecentFirst: topic, source: source)
                SemProfile.shared.save()
            }
        }
        let ctx = history.prefix(3).map { net.ctxWord($0, ruToEn: det.ruToEn) }
        let layoutRu = word.lowercased().contains { ("а"..."я").contains($0) || $0 == "ё" }
        let ex = LayoutNet.Example(keys: keys, ctx: Array(ctx), app: Config.shared.appClass(for: app),
                                   layoutRu: layoutRu, labelRu: intendedRu)
        var j = ex.json
        j["t"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: j),
              let line = String(data: data, encoding: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path.path) {
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
            h.closeFile()
        } else {
            try? (line + "\n").write(to: path, atomically: true, encoding: .utf8)
        }
        let ctxText = history.prefix(3).joined(separator: " ")
        print("[nn] исправление: '\(word)' → \(intendedRu ? "ru" : "en") (ctx='\(ctxText)')")
    }

    /// Все личные примеры: файл исправлений + learned.json. Дубликаты по
    /// (клавиши, контекст) — последний побеждает.
    func examples() -> [LayoutNet.Example] {
        var byKey: [String: LayoutNet.Example] = [:]
        var order: [String] = []
        func put(_ e: LayoutNet.Example) {
            let k = e.keys + "|" + e.ctx.map { ($0.keys ?? "") + ":" + String($0.flag.rawValue) }.joined(separator: ",")
            if byKey[k] == nil { order.append(k) }
            byKey[k] = e
        }
        let det = Detector.shared
        let net = LayoutNet.shared
        let learned = LearnedRules.shared
        for w in learned.force {   // набрано не в той раскладке → имелся в виду другой язык
            let ru = w.contains { ("а"..."я").contains($0) || $0 == "ё" }
            if let keys = net.keys(for: w, ruToEn: det.ruToEn), keys.count >= 2 {
                put(LayoutNet.Example(keys: keys, ctx: [], app: .other, layoutRu: ru, labelRu: !ru))
            }
        }
        for w in learned.stop {    // как набрано — так и надо
            let ru = w.contains { ("а"..."я").contains($0) || $0 == "ё" }
            if let keys = net.keys(for: w, ruToEn: det.ruToEn), keys.count >= 2 {
                put(LayoutNet.Example(keys: keys, ctx: [], app: .other, layoutRu: ru, labelRu: ru))
            }
        }
        if let text = try? String(contentsOf: path, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let e = LayoutNet.Example(json: j) else { continue }
                put(e)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    var count: Int { examples().count }

    func reset() {
        try? FileManager.default.removeItem(at: path)
    }
}
