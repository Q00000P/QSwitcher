import Foundation

/// Самообучение на исправлениях пользователя.
///
/// Идея: любой статический список для коротких слов — гадание. `вк` это ВКонтакте
/// или промах вместо `dr`? Универсального ответа нет, он зависит от того чем человек
/// занимается. Поэтому решает сам пользователь, а мы просто запоминаем:
///
///   - свитчер переключил, а человек вернул обратно  → больше это слово не трогать
///   - свитчер не тронул, а человек переключил вручную → впредь переключать
///
/// Правило перезаписывается при обратном действии: передумал — просто сделай наоборот.
/// Хранится в Application Support рядом с конфигом, переживает перезапуск.
final class LearnedRules {

    static let shared = LearnedRules()

    /// Слова которые НЕ надо переключать (пользователь откатывал).
    private(set) var stop: Set<String> = []
    /// Слова которые НАДО переключать (пользователь переключал вручную).
    private(set) var force: Set<String> = []

    private var path: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("QSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("learned.json")
    }

    private struct Stored: Codable {
        var stop: [String]
        var force: [String]
    }

    private init() {
        load()
    }

    // MARK: - Запросы

    func shouldStop(_ word: String) -> Bool { stop.contains(word.lowercased()) }
    func shouldForce(_ word: String) -> Bool { force.contains(word.lowercased()) }

    // MARK: - Обучение

    /// Пользователь откатил автопереключение — значит слово трогать не надо.
    func learnStop(_ word: String) {
        let w = word.lowercased()
        guard !w.isEmpty else { return }
        force.remove(w)          // обратное правило отменяется
        guard stop.insert(w).inserted else { return }
        print("[learn] '\(w)' — больше не переключаем")
        save()
    }

    /// Пользователь переключил вручную то что мы оставили — значит надо переключать.
    func learnForce(_ word: String) {
        let w = word.lowercased()
        guard !w.isEmpty else { return }
        stop.remove(w)           // обратное правило отменяется
        guard force.insert(w).inserted else { return }
        print("[learn] '\(w)' — впредь переключаем")
        save()
    }

    /// Забыть всё выученное.
    func reset() {
        stop.removeAll()
        force.removeAll()
        save()
        print("[learn] правила сброшены")
    }

    var summary: String {
        "не переключать: \(stop.count), переключать: \(force.count)"
    }

    // MARK: - Хранение

    private func load() {
        guard let data = try? Data(contentsOf: path),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        stop = Set(s.stop)
        force = Set(s.force)
        print("🧠 Выученные правила: \(summary)")
    }

    private func save() {
        let s = Stored(stop: stop.sorted(), force: force.sorted())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(s) else { return }
        try? data.write(to: path, options: .atomic)
    }
}
