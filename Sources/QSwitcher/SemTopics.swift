import Foundation

/// Темы из векторов (qsvec-topics.json, делает nn/sem/topics.py): ~100 центров
/// кластеров словаря. Любой вектор → распределение по темам за k умножений.
/// Это обобщение по осмысленным осям («сеть/сервер», «государство/граждане»,
/// «люди/ругань») — «шлюхи» уходят к людям и стране, «шлюз» к сети, без обучения.
final class SemTopics {

    static let shared = SemTopics()

    private(set) var loaded = false
    private(set) var names: [String] = []
    private(set) var top: [[String]] = []
    private var centers: [[Float]] = []
    private var tau: Float = 8
    var count: Int { names.count }

    private init() { load() }

    static var userURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("QSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("qsvec-topics.json")
    }

    /// Разобрать текст из окна и сохранить в пользовательскую копию (важнее встроенной).
    /// «N имя …» с существующим N — переименование (центр тот же). «N имя слова…» с новым
    /// N — своя тема: центр = среднее очищенных векторов перечисленных слов. Возвращает
    /// (переименовано, добавлено); размерность гистограмм при добавлении меняется —
    /// профиль надо пересобрать из журнала.
    func applyListing(_ text: String) throws -> (renamed: Int, added: Int) {
        guard loaded else { return (0, 0) }
        var newNames = names, newTop = top, newCenters = centers
        var renamed = 0, added = 0
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 2, let i = Int(parts[0]), i >= 0 else { continue }
            if i < names.count {
                if newNames[i] != parts[1] { newNames[i] = parts[1]; renamed += 1 }
                continue
            }
            // Своя тема из слов
            let words = Array(parts.dropFirst(2)).filter { $0.count >= 2 }
            guard !words.isEmpty, SemVec.shared.loaded else { continue }
            var c = [Float](repeating: 0, count: SemVec.shared.dim)
            var n: Float = 0
            for w in words {
                let v = SemVec.shared.centered(w)
                guard v.contains(where: { $0 != 0 }) else { continue }
                for j in 0..<c.count { c[j] += v[j] }
                n += 1
            }
            guard n > 0 else { continue }
            var norm: Float = 0
            for x in c { norm += x * x }
            norm = sqrt(norm)
            guard norm > 0 else { continue }
            newCenters.append(c.map { $0 / norm })
            newNames.append(parts[1])
            newTop.append(words)
            added += 1
        }
        let d: [String: Any] = ["k": newCenters.count, "dim": newCenters.first?.count ?? 0, "tau": tau,
                                "names": newNames, "top": newTop,
                                "centers": newCenters.map { $0.map { Double($0) } }]
        let data = try JSONSerialization.data(withJSONObject: d)
        try data.write(to: SemTopics.userURL, options: .atomic)
        names = newNames; top = newTop; centers = newCenters
        return (renamed, added)
    }

    private func load() {
        var urls: [URL] = []
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        urls.append(appSupport.appendingPathComponent("QSwitcher/qsvec-topics.json"))
        if let r = Bundle.main.resourceURL {
            urls.append(r.appendingPathComponent("qsvec-topics.json"))
            if let contents = try? FileManager.default.contentsOfDirectory(at: r, includingPropertiesForKeys: nil) {
                for item in contents where item.pathExtension == "bundle" {
                    urls.append(item.appendingPathComponent("Contents/Resources/qsvec-topics.json"))
                }
            }
        }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let c = d["centers"] as? [[NSNumber]] else { continue }
            centers = c.map { $0.map { $0.floatValue } }
            names = d["names"] as? [String] ?? centers.indices.map { "тема \($0)" }
            top = d["top"] as? [[String]] ?? []
            tau = (d["tau"] as? NSNumber)?.floatValue ?? 8
            loaded = !centers.isEmpty
            print("🧭 Темы: \(names.count) (\(url.lastPathComponent))")
            return
        }
        print("🧭 Темы: qsvec-topics.json нет — обобщение по темам выключено")
    }

    /// Единичный (или любой ненулевой) вектор → распределение по темам.
    func assign(_ v: [Float]) -> [Float]? {
        guard loaded, let first = centers.first, first.count == v.count else { return nil }
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = sqrt(norm)
        guard norm > 0 else { return nil }
        var s = [Float](repeating: 0, count: centers.count)
        var mx: Float = -Float.greatestFiniteMagnitude
        for (i, c) in centers.enumerated() {
            var d: Float = 0
            for j in 0..<v.count { d += c[j] * v[j] }
            s[i] = d / norm
            mx = max(mx, s[i])
        }
        var sum: Float = 0
        for i in 0..<s.count { s[i] = expf(tau * (s[i] - mx)); sum += s[i] }
        return s.map { $0 / sum }
    }

    /// Острота гистограммы: 1 — одна тема, 0 — ровным слоем. Мера «мусорности»
    /// чтения: у обломков вроде «ha», «jin» темы плоские, у слов — острые.
    static func sharpness(_ d: [Float]?) -> Float {
        guard let d = d, d.count > 1 else { return 0 }
        let sum = d.reduce(0, +)
        guard sum > 0 else { return 0 }
        var h: Float = 0
        for x in d where x > 0 { let p = x / sum; h -= p * log(p) }
        let hmax = log(Float(d.count))
        return max(0, min(1, 1 - h / hmax))
    }

    /// Сходство гистограмм: косинус корней (устойчив к разной массе).
    static func histSim(_ a: [Float]?, _ b: [Float]?) -> Float {
        guard let a = a, let b = b, a.count == b.count else { return 0 }
        let sa = a.reduce(0, +), sb = b.reduce(0, +)
        guard sa > 0, sb > 0 else { return 0 }
        var d: Float = 0
        for j in 0..<a.count { d += sqrt(a[j] / sa) * sqrt(b[j] / sb) }
        return d
    }

    func explain(_ d: [Float]?, n: Int = 3) -> String {
        guard loaded, let d = d, !d.isEmpty else { return "—" }
        let sum = d.reduce(0, +)
        guard sum > 0 else { return "—" }
        let idx = d.indices.sorted { d[$0] > d[$1] }.prefix(n)
        return idx.map { "\(names[$0].split(separator: "/").first.map(String.init) ?? names[$0]) \(String(format: "%.2f", d[$0] / sum))" }
                  .joined(separator: ", ")
    }

    /// Текст списка тем для просмотра.
    func listing() -> String {
        names.indices.map { i in
            String(format: "%3d  %-28@ %@", i, names[i] as NSString, (i < top.count ? top[i].joined(separator: " ") : "") as NSString)
        }.joined(separator: "\n")
    }
}
