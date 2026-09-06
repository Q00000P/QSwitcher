import Foundation

/// Профиль чтений коллизий — порт nn/sem/profile.py (формат 2). Слой, который синкается.
///
/// У клавиш ("ha") есть чтения ("ha", "рф"). У чтения не центроид, а САМИ примеры
/// (тема окна, левый сосед, вес, регистр, время). Сравниваем с ближайшими, а не со
/// средним: «HA» — это десяток конкретных ситуаций, и чужое слово ни к одной из них
/// не близко → молчим. Тематика настолько широка, насколько разнообразны примеры.
/// Источник истины — журнал примеров (profile-examples.txt); profile.json — производная.
final class SemProfile {

    static let shared = SemProfile()

    struct Example {
        var topic: [Float]      // единичный или нули
        var left: [Float]?      // единичный или nil
        var weight: Int
        var caseKind: String
        var time: Int
        var bgTopic: Float = 0  // фон векторов (хабовость) — вычитается из сходства
        var bgLeft: Float = 0
    }

    struct Reading {
        var examples: [Example] = []
        var topics: [Float]? = nil      // гистограмма тем (масса = вес примеров)
        var cases: [String: Int] = [:]
        var count = 0
        var updated = 0
    }

    struct Decision {
        let text: String
        let score: Float
        let lead: Float
        let explain: String
    }

    // Веса и пороги — ровно как в profile.py
    static let wLeft: Float = 1.0, wTopic: Float = 0.6, wCase: Float = 0.4
    static let caseMin = 3
    static let singleMin: Float = 0.35
    static let minSignal: Float = 0.15
    static let topK = 2
    static let maxExamples = 300
    static let wTopics: Float = 0.8
    static let seedWeight = 3

    private(set) var readings: [String: [String: Reading]] = [:]
    private let lock = NSLock()
    private(set) var lastExplain = ""
    func clearExplain() { lastExplain = "" }
    /// Старый формат на диске — пересобрать из журнала, когда все синглтоны готовы.
    private(set) var needsRebuild = false

    func rebuildIfNeeded() {
        guard needsRebuild else { return }
        needsRebuild = false
        let rep = rebuild(fromJournal: journalText())
        print("🧭 Профиль пересобран из журнала: \(rep.text)")
    }

    var path: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("QSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile.json")
    }
    var journalPath: URL { path.deletingLastPathComponent().appendingPathComponent("profile-examples.txt") }

    private init() { load() }

    var readingCount: Int { lock.lock(); defer { lock.unlock() }; return readings.values.reduce(0) { $0 + $1.count } }
    func knows(keys: String) -> Bool { lock.lock(); defer { lock.unlock() }; return readings[keys] != nil }
    func readingCount(keys: String) -> Int { lock.lock(); defer { lock.unlock() }; return readings[keys]?.count ?? 0 }

    // MARK: - Файл

    func load() {
        guard let data = try? Data(contentsOf: path),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard (d["format"] as? Int ?? 1) >= 2 else {
            // Старый формат (центроиды): пересобрать из журнала, но НЕ здесь — load()
            // идёт из инициализации синглтонов, а пересборка лезет в Detector, который
            // сам ещё инициализируется (рекурсивный static let → тихое падение).
            needsRebuild = true
            print("🧭 Профиль старого формата — пересоберу из журнала после старта")
            return
        }
        var out: [String: [String: Reading]] = [:]
        for (keys, rs) in (d["readings"] as? [String: [String: [String: Any]]]) ?? [:] {
            var m: [String: Reading] = [:]
            for (text, r) in rs {
                var rd = Reading(topics: (r["tp"] as? [NSNumber])?.map { $0.floatValue },
                                 cases: (r["case"] as? [String: Int]) ?? [:],
                                 count: r["count"] as? Int ?? 0, updated: r["updated"] as? Int ?? 0)
                for e in (r["ex"] as? [[Any]]) ?? [] where e.count >= 5 {
                    let t = (e[0] as? [NSNumber])?.map { $0.floatValue } ?? []
                    let l = (e[1] as? [NSNumber])?.map { $0.floatValue }
                    rd.examples.append(Example(topic: t, left: l, weight: (e[2] as? Int) ?? 1,
                                               caseKind: e[3] as? String ?? "lower", time: (e[4] as? Int) ?? 0,
                                               bgTopic: t.contains(where: { $0 != 0 }) ? SemVec.shared.background(t) : 0,
                                               bgLeft: l.map { SemVec.shared.background($0) } ?? 0))
                }
                m[text] = rd
            }
            out[keys] = m
        }
        lock.lock(); readings = out; lock.unlock()
        print("🧭 Профиль: \(readingCount) чтений")
    }

    func save() {
        lock.lock(); let snapshot = readings; lock.unlock()
        func rd(_ v: [Float]) -> [Double] { v.map { (Double($0) * 1000).rounded() / 1000 } }
        var rs: [String: Any] = [:]
        for (keys, m) in snapshot {
            var mm: [String: Any] = [:]
            for (text, r) in m {
                let ex: [[Any]] = r.examples.map { [rd($0.topic), $0.left.map(rd) ?? NSNull(), $0.weight, $0.caseKind, $0.time] }
                mm[text] = ["ex": ex, "tp": r.topics.map(rd) ?? NSNull(), "case": r.cases,
                            "count": r.count, "updated": r.updated] as [String: Any]
            }
            rs[keys] = mm
        }
        let d: [String: Any] = ["format": 2, "dim": SemVec.shared.dim,
                                "saved": Int(Date().timeIntervalSince1970), "readings": rs]
        if let data = try? JSONSerialization.data(withJSONObject: d) {
            try? data.write(to: path, options: .atomic)
        }
    }

    // MARK: - Обучение

    static func caseOf(_ word: String) -> String {
        if word.count > 1, word == word.uppercased(), word != word.lowercased() { return "upper" }
        if let f = word.first, f.isUppercase { return "title" }
        return "lower"
    }

    private static func unit(_ v: [Float]?) -> [Float]? {
        guard let v = v else { return nil }
        var n: Float = 0
        for x in v { n += x * x }
        n = sqrt(n)
        guard n > 0 else { return nil }
        return v.map { $0 / n }
    }

    /// Распределение контекста по темам: тема окна и левый сосед пополам.
    private static func ctxDist(_ t: [Float]?, _ l: [Float]?) -> [Float]? {
        let parts = [t.flatMap { SemTopics.shared.assign($0) }, l.flatMap { SemTopics.shared.assign($0) }].compactMap { $0 }
        guard let first = parts.first else { return nil }
        var d = [Float](repeating: 0, count: first.count)
        for p in parts { for j in 0..<d.count { d[j] += p[j] / Float(parts.count) } }
        return d
    }

    /// Пользователь выбрал чтение text для клавиш keys в этом контексте.
    func observe(keys: String, text: String, topic: [Float], left: [Float]?, weight: Int = 1) {
        guard SemVec.shared.loaded else { return }
        let t = SemProfile.unit(topic), l = SemProfile.unit(left)
        guard t != nil || l != nil else { return }
        let dist = SemProfile.ctxDist(t, l)
        lock.lock(); defer { lock.unlock() }
        var m = readings[keys] ?? [:]
        let key = text.lowercased()
        var r = m[key] ?? Reading()
        let w = max(1, weight)
        let c = SemProfile.caseOf(text)
        r.examples.append(Example(topic: t ?? [Float](repeating: 0, count: SemVec.shared.dim), left: l,
                                  weight: w, caseKind: c, time: Int(Date().timeIntervalSince1970),
                                  bgTopic: t.map { SemVec.shared.background($0) } ?? 0,
                                  bgLeft: l.map { SemVec.shared.background($0) } ?? 0))
        while r.examples.count > SemProfile.maxExamples {
            let idx = r.examples.firstIndex { $0.weight <= 1 } ?? 0
            r.examples.remove(at: idx)
        }
        if let d = dist {
            if var tp = r.topics, tp.count == d.count {
                for j in 0..<d.count { tp[j] += d[j] * Float(w) }
                r.topics = tp
            } else {
                r.topics = d.map { $0 * Float(w) }
            }
        }
        r.cases[c, default: 0] += w
        r.count += w
        r.updated = Int(Date().timeIntervalSince1970)
        m[key] = r
        readings[keys] = m
        print("[sem] профиль: '\(keys)' → '\(key)' (\(r.count) прим., регистр \(c)\(w > 1 ? ", вес \(w)" : ""))")
    }

    // MARK: - Решение

    private func caseFit(_ r: Reading, _ typed: String) -> Float {
        let total = r.cases.values.reduce(0, +)
        guard total >= SemProfile.caseMin else { return 0 }
        return 2 * Float(r.cases[typed] ?? 0) / Float(total) - 1
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var d: Float = 0
        for j in 0..<a.count { d += a[j] * b[j] }
        return d
    }

    /// Нулевой режим: профиль клавиш не знает, но оба чтения — реальные слова корпуса.
    /// Чтения строятся из базы: вектор слова как единственный «пример», темы — из него же.
    /// Работает для he/ру, vs/мы, ye/ну без обучения; для личных терминов (HA = Home
    /// Assistant) базе неоткуда знать — нужна строка «#тема».
    private func zeroShotReadings(typed: String, swapped: String) -> [String: Reading]? {
        let sem = SemVec.shared
        guard sem.loaded else { return nil }
        var out: [String: Reading] = [:]
        for w in [typed.lowercased(), swapped.lowercased()] where w.count >= 2 && sem.inVocab(w) {
            let v = sem.centered(w)
            var r = Reading()
            let bg = sem.background(v)
            r.examples = [Example(topic: v, left: v, weight: 1, caseKind: "lower", time: 0, bgTopic: bg, bgLeft: bg)]
            r.topics = SemTopics.shared.assign(v)
            r.count = 1
            out[w] = r
        }
        return out.count == 2 ? out : nil
    }

    /// Оба чтения — слова корпуса (для обхода выученных правил без контекста).
    func isBaseCollision(typed: String, swapped: String) -> Bool {
        zeroShotReadings(typed: typed, swapped: swapped) != nil
    }

    /// Что выбрать для клавиш keys, набранных как typed. nil — уверенности нет / профиль молчит.
    func decide(keys: String, typed: String, swapped: String = "", topic: [Float], left: [Float]?, leftWord: String? = nil,
                margin: Float) -> Decision? {
        lock.lock(); var m = readings[keys]; lock.unlock()
        var zeroShot = false
        if m == nil || m!.isEmpty, !swapped.isEmpty, Config.shared.semZeroShot {
            m = zeroShotReadings(typed: typed, swapped: swapped)
            zeroShot = m != nil
        }
        guard let m = m, !m.isEmpty else { return nil }
        let tq = SemProfile.unit(topic), lq0 = SemProfile.unit(left)
        // Сосед, совпадающий с самим чтением (набрал «РФ РФ»), или служебный («в», «на»,
        // «быть») — не сигнал: в нём нет темы, при таком соседе решает тема окна.
        let selfWords = Set([typed.lowercased(), swapped.lowercased()])
        let lw = leftWord?.lowercased() ?? ""
        let leftUseless = selfWords.contains(lw) || SemVec.stop.contains(lw) || lw.count < 3
        let lq = leftUseless ? nil : lq0
        let tc = SemProfile.caseOf(typed)
        let ctxD = SemProfile.ctxDist(tq, lq)
        // Фон запроса: «в», «быдло» тоже «похожи на всё» по-своему — вычитаем с обеих сторон
        let bgQ = lq.map { SemVec.shared.background($0) } ?? 0
        let bgT = tq.map { SemVec.shared.background($0) } ?? 0
        var scored: [(s: Float, text: String, best: Float, explain: String)] = []
        for (text, r) in m {
            // Гибрид: центроид (обобщение — «не техника → РФ» без обучения) плюс два
            // ближайших примера (точность — «колесо» не пройдёт на среднем «это вещь»).
            var sims: [(Float, Float, Float)] = []
            let dim = r.examples.first?.topic.count ?? 0
            var cT = [Float](repeating: 0, count: dim), cL = [Float](repeating: 0, count: dim)
            var wT: Float = 0, wL: Float = 0
            for e in r.examples {
                var s: Float = 0, sl: Float = 0, st: Float = 0
                // минус фон: мусорный токен «похож на всё», честное сходство — сверх фона
                if let lq = lq, let l = e.left { sl = SemProfile.dot(lq, l) - (e.bgLeft + bgQ) / 2; s += SemProfile.wLeft * sl }
                if let tq = tq, e.topic.contains(where: { $0 != 0 }) { st = SemProfile.dot(tq, e.topic) - (e.bgTopic + bgT) / 2; s += SemProfile.wTopic * st }
                sims.append((s, sl, st))
                let w = Float(e.weight)
                if e.topic.contains(where: { $0 != 0 }) { for j in 0..<dim { cT[j] += w * e.topic[j] }; wT += w }
                if let l = e.left, l.count == dim { for j in 0..<dim { cL[j] += w * l[j] }; wL += w }
            }
            guard !sims.isEmpty else { continue }
            sims.sort { $0.0 > $1.0 }
            let top = Array(sims.prefix(SemProfile.topK))
            let knn = top.map { $0.0 }.reduce(0, +) / Float(top.count)
            var cen: Float = 0, cenL: Float = 0, cenT: Float = 0
            if let lq = lq, wL > 0, let u = SemProfile.unit(cL) { cenL = SemProfile.dot(lq, u) - (SemVec.shared.background(u) + bgQ) / 2; cen += SemProfile.wLeft * cenL }
            if let tq = tq, wT > 0, let u = SemProfile.unit(cT) { cenT = SemProfile.dot(tq, u) - (SemVec.shared.background(u) + bgT) / 2; cen += SemProfile.wTopic * cenT }
            // Качество чтения — острота его тем. У обломка («ha» = «ха-ха», «jin») темы
            // плоские, и все его сходства — шум; гасим их. У слова и у чтения с «#тема»
            // гистограмма острая — полный вес. Пол 0.15, чтобы совсем не обнулять.
            let q = max(0.15, min(1, SemTopics.sharpness(r.topics) * 3))
            var s = (knn + cen) / 2 * q
            var best = max(top.map { max($0.1, $0.2) }.max() ?? 0, max(cenL, cenT)) * q
            // Темы: обобщение по осмысленным осям — «шлюхи» к «людям/стране», «шлюз» к «сети»
            // минус сходство равномерного с контекстом: плоская гистограмма даёт ноль, а не 0.7
            let flat = ctxD.map { [Float](repeating: 1, count: $0.count) }
            let th = (SemTopics.histSim(r.topics, ctxD) - SemTopics.histSim(flat, ctxD)) * q
            s += SemProfile.wTopics * th
            best = max(best, th)
            let cf = caseFit(r, tc)
            s += SemProfile.wCase * cf
            scored.append((s, text, best,
                           "\(text) \(String(format: "%+.2f", s)) (кач. \(String(format: "%.2f", q)); темы \(String(format: "%.2f", th)) [\(SemTopics.shared.explain(r.topics))]; центр: сосед \(String(format: "%.2f", cenL)), тема \(String(format: "%.2f", cenT)); ближ.: сосед \(String(format: "%.2f", top[0].1)), тема \(String(format: "%.2f", top[0].2)); регистр \(String(format: "%+.1f", cf)); прим. \(sims.count))"))
        }
        guard !scored.isEmpty else { return nil }
        scored.sort { $0.s > $1.s }
        let explain = (zeroShot ? "[база] " : "") + scored.map { $0.explain }.joined(separator: " vs ")
        lastExplain = explain
        if scored[0].best < SemProfile.minSignal {
            lastExplain = explain + " — сигнал слаб (< \(SemProfile.minSignal))"
            return nil
        }
        if scored.count == 1 {
            let need = max(margin, SemProfile.singleMin)
            return scored[0].s >= need ? Decision(text: scored[0].text, score: scored[0].s, lead: scored[0].s, explain: explain) : nil
        }
        let lead = scored[0].s - scored[1].s
        guard lead >= margin else { return nil }
        return Decision(text: scored[0].text, score: scored[0].s, lead: lead, explain: explain)
    }

    // MARK: - Обучение текстом и журнал (источник истины)

    struct TrainReport {
        var lines = 0, examples = 0
        var touched: Set<String> = []
        var text: String {
            "строк \(lines), примеров \(examples)" + (touched.isEmpty ? "" : ", клавиши: \(touched.sorted().joined(separator: ", "))")
        }
    }

    /// 'живу в рф [10]  # пометка' → (слова, индекс цели, вес). Цель — слово в *звёздочках*
    /// или последнее; вес — [n] в конце; всё после # — для человека. nil — учить нечему.
    static func parseLine(_ raw: String) -> (words: [String], target: Int, weight: Int)? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]).trimmingCharacters(in: .whitespaces) }
        if line.isEmpty { return nil }
        var weight = 1
        if let m = line.range(of: #"\[\s*(\d+)\s*\]\s*$"#, options: .regularExpression) {
            weight = Int(line[m].filter { $0.isNumber }) ?? 1
            line = String(line[..<m.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        var words: [String] = []
        var target: Int? = nil
        for t in line.split(whereSeparator: { $0.isWhitespace }) {
            var core = String(t).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()«»\"'"))
            if core.count > 2, core.hasPrefix("*"), core.hasSuffix("*") {
                core = String(core.dropFirst().dropLast())
                target = words.count
            }
            core = core.filter { $0.isLetter }
            if !core.isEmpty { words.append(core) }
        }
        guard !words.isEmpty else { return nil }
        return (words, target ?? words.count - 1, weight)
    }

    /// Каждая строка — пример: цель + тема из остальных слов + левый сосед.
    func train(text: String, source: String = "текст", journal: Bool = true) -> TrainReport {
        var rep = TrainReport()
        let sem = SemVec.shared
        guard sem.loaded else { return rep }
        for raw in text.components(separatedBy: .newlines) {
            // «#тема HA: home assistant умный дом датчики шлюз [3]» — готовое облако чтения без примеров
            if let m = raw.range(of: #"^\s*#тема\s+(\S+)\s*:\s*(.+)$"#, options: .regularExpression) {
                var body = String(raw[m]).replacingOccurrences(of: #"^\s*#тема\s+"#, with: "", options: .regularExpression)
                var weight = SemProfile.seedWeight
                if let wm = body.range(of: #"\[\s*(\d+)\s*\]\s*$"#, options: .regularExpression) {
                    weight = Int(body[wm].filter { $0.isNumber }) ?? weight
                    body = String(body[..<wm.lowerBound])
                }
                let parts = body.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let reading = parts[0]
                let words = parts[1].split(whereSeparator: { !$0.isLetter }).map(String.init).filter { !$0.isEmpty }
                guard let keys = LayoutNet.shared.keys(for: reading.lowercased(), ruToEn: Detector.shared.ruToEn),
                      keys.count >= 2, !words.isEmpty else { continue }
                observe(keys: keys, text: reading, topic: sem.topic(recentFirst: words.reversed()), left: nil, weight: weight)
                if journal { journalAppendRaw(raw.trimmingCharacters(in: .whitespaces), source: source) }
                rep.lines += 1; rep.examples += weight; rep.touched.insert(keys)
                continue
            }
            guard let (words, ti, weight) = SemProfile.parseLine(raw) else { continue }
            guard let keys = LayoutNet.shared.keys(for: words[ti].lowercased(), ruToEn: Detector.shared.ruToEn),
                  keys.count >= 2 else { continue }
            var others = words
            others.remove(at: ti)
            let topic = others.isEmpty ? [Float](repeating: 0, count: sem.dim) : sem.topic(recentFirst: others.reversed())
            let left: [Float]? = ti > 0 ? sem.centered(words[ti - 1]) : nil
            observe(keys: keys, text: words[ti], topic: topic, left: left, weight: weight)
            if journal { journalAppend(words: words, target: ti, weight: weight, source: source) }
            rep.lines += 1
            rep.examples += weight
            rep.touched.insert(keys)
        }
        if rep.lines > 0 { save() }
        return rep
    }

    /// Строка журнала: слова темы (дальние → ближние), левый сосед, *цель* [вес]  # источник дата.
    func journalAppend(words: [String], target: Int, weight: Int, source: String) {
        var parts = words
        parts[target] = "*" + words[target] + "*"
        let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"
        let line = parts.joined(separator: " ") + (weight != 1 ? " [\(weight)]" : "") + "   # \(source) \(f.string(from: Date()))\n"
        if let h = FileHandle(forWritingAtPath: journalPath.path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            try? line.write(to: journalPath, atomically: true, encoding: .utf8)
        }
    }

    /// Строка «#тема …» в журнал как есть.
    func journalAppendRaw(_ line: String, source: String) {
        let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"
        let text = line + "   # \(source) \(f.string(from: Date()))\n"
        if let h = FileHandle(forWritingAtPath: journalPath.path) {
            h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); h.closeFile()
        } else {
            try? text.write(to: journalPath, atomically: true, encoding: .utf8)
        }
    }

    /// Пример из живого ввода — в журнал (тема: до 10 ближних слов, дальние первыми).
    func journalLive(target: String, left: String?, topicRecentFirst: [String], source: String) {
        var words = Array(topicRecentFirst.prefix(10).reversed())
        if let l = left, words.last?.lowercased() != l.lowercased() { words.append(l) }
        words.append(target)
        journalAppend(words: words, target: words.count - 1, weight: 1, source: source)
    }

    func journalText() -> String { (try? String(contentsOf: journalPath, encoding: .utf8)) ?? "" }

    /// Пересобрать профиль из (отредактированного) журнала: он становится журналом.
    func rebuild(fromJournal text: String) -> TrainReport {
        lock.lock(); readings = [:]; lock.unlock()
        try? text.write(to: journalPath, atomically: true, encoding: .utf8)
        let rep = train(text: text, journal: false)
        save()
        return rep
    }

    // MARK: - Синк

    /// Слияние: примеры объединяются (одинаковые по времени и первому числу не дублируются).
    func merge(json d: [String: Any]) {
        guard (d["format"] as? Int ?? 1) >= 2, let rs = d["readings"] as? [String: [String: [String: Any]]] else { return }
        lock.lock(); defer { lock.unlock() }
        for (keys, others) in rs {
            var mine = readings[keys] ?? [:]
            for (text, o) in others {
                var a = mine[text] ?? Reading()
                var seen = Set(a.examples.map { "\($0.time):\(Int(($0.topic.first ?? 0) * 1000))" })
                for e in (o["ex"] as? [[Any]]) ?? [] where e.count >= 5 {
                    let ex = Example(topic: (e[0] as? [NSNumber])?.map { $0.floatValue } ?? [],
                                     left: (e[1] as? [NSNumber])?.map { $0.floatValue },
                                     weight: (e[2] as? Int) ?? 1, caseKind: e[3] as? String ?? "lower", time: (e[4] as? Int) ?? 0)
                    let tag = "\(ex.time):\(Int((ex.topic.first ?? 0) * 1000))"
                    if !seen.contains(tag) {
                        seen.insert(tag)
                        a.examples.append(ex)
                        a.count += ex.weight
                        a.cases[ex.caseKind, default: 0] += ex.weight
                    }
                }
                a.examples.sort { $0.time < $1.time }
                if a.examples.count > SemProfile.maxExamples { a.examples.removeFirst(a.examples.count - SemProfile.maxExamples) }
                if let otp = (o["tp"] as? [NSNumber])?.map({ $0.floatValue }) {
                    if var tp = a.topics, tp.count == otp.count { for j in 0..<tp.count { tp[j] += otp[j] }; a.topics = tp } else { a.topics = otp }
                }
                a.updated = max(a.updated, o["updated"] as? Int ?? 0)
                mine[text] = a
            }
            readings[keys] = mine
        }
    }

    func reset() {
        lock.lock(); readings = [:]; lock.unlock()
        try? FileManager.default.removeItem(at: path)
    }
}
