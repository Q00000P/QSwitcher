import Foundation

/// Инференс QSNet — контекстного детектора раскладки. Один в один повторяет
/// эталон nn/qsnet.py (QSNet.word_vec / build_input / forward): слово → клавиши
/// в EN-обозначениях → хэшированные n-граммы (FNV-1a) → среднее строк таблицы
/// эмбеддингов; плюс 3 предыдущих слова с флагами языка, класс приложения и
/// текущая раскладка → один скрытый слой ReLU → sigmoid = P(имелся в виду RU).
///
/// Веса: файл QSN1 (см. nn/README.md). Ищем сначала пользовательский
/// (~/Library/Application Support/QSwitcher/qsnet.bin — задел под синк и своё
/// дообучение), потом встроенный в бандл. Без файла сеть просто выключена.
///
/// Паритет с эталоном проверяется при загрузке по qsnet-selftest.json:
/// расхождение больше 1e-3 — сеть выключается с записью в лог, чтобы
/// испорченный порт не принимал решений молча.
final class LayoutNet {

    static let shared = LayoutNet()

    /// Класс приложения — порядок как в qsnet.APPS.
    enum AppClass: Int, CaseIterable {
        case other = 0, terminal, code, browser, chat
        var name: String { ["other", "terminal", "code", "browser", "chat"][rawValue] }
    }

    /// Флаг языка контекстного слова — порядок как в qsnet.CTX_FLAGS.
    enum CtxFlag: Int { case ru = 0, en, none }

    struct CtxWord {
        let keys: String?   // nil — слово не кодируется (путь, число): вектор нули
        let flag: CtxFlag
    }

    private(set) var loaded = false
    private(set) var source = ""
    private(set) var trained = ""
    /// Заголовок файла как есть — переносится в пользовательские веса при дообучении.
    private var header: [String: Any] = [:]
    /// Загружены пользовательские (дообученные) веса, а не встроенные.
    private(set) var isUser = false
    private var buckets = 0
    private var dim = 0
    private var hidden = 0
    private var inputDim = 0
    private var emb: [Float] = []
    private var w1: [Float] = []
    private var b1: [Float] = []
    private var w2: [Float] = []
    private var b2: Float = 0

    private static let keyChars: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz[];',.`")
    private static let ctxWords = 3
    private static let nFlags = 3
    private static let nApps = 5
    private static let nLangs = 2

    private init() {
        load()
    }

    // MARK: - Загрузка

    /// Пользовательские веса — результат «Дообучить на моих исправлениях».
    static var userWeightsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("QSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("qsnet.bin")
    }

    /// Ресурс из бандла (qsnet.bin, qsnet-replay.json, qsnet-selftest.json).
    private func resourceURL(_ name: String) -> URL? {
        guard let r = Bundle.main.resourceURL else { return nil }
        var urls = [r.appendingPathComponent(name)]
        if let contents = try? FileManager.default.contentsOfDirectory(at: r, includingPropertiesForKeys: nil) {
            for item in contents where item.pathExtension == "bundle" {
                urls.append(item.appendingPathComponent("Contents/Resources/" + name))
                urls.append(item.appendingPathComponent(name))
            }
        }
        return urls.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Перечитать веса (после дообучения или сброса). Потокобезопасно с точки
    /// зрения детектора: массивы заменяются целиком, старые доживают свой вызов.
    func reload() {
        loaded = false
        load()
    }

    private func candidatePaths() -> [URL] {
        var urls: [URL] = [LayoutNet.userWeightsURL]
        if let r = Bundle.main.resourceURL {
            urls.append(r.appendingPathComponent("qsnet.bin"))
            if let contents = try? FileManager.default.contentsOfDirectory(at: r, includingPropertiesForKeys: nil) {
                for item in contents where item.pathExtension == "bundle" {
                    urls.append(item.appendingPathComponent("Contents/Resources/qsnet.bin"))
                    urls.append(item.appendingPathComponent("qsnet.bin"))
                }
            }
        }
        return urls
    }

    private func load() {
        for url in candidatePaths() where FileManager.default.fileExists(atPath: url.path) {
            do {
                try parse(Data(contentsOf: url))
                source = url.path
                isUser = (url == LayoutNet.userWeightsURL)
                loaded = true
                let ft = header["finetuned"] as? String
                print("🧠 Сеть: \(url.path) (buckets=\(buckets), dim=\(dim), hidden=\(hidden), обучена \(trained)"
                      + (ft.map { ", дообучена \($0), v\(header["finetune_version"] ?? 0)" } ?? "") + ")")
                // Селфтест — только для встроенных весов: эталон считан именно по ним.
                if !isUser, !selfTest(near: url) {
                    loaded = false
                    print("⚠️ Сеть ВЫКЛЮЧЕНА: порт не совпал с эталоном (см. выше)")
                }
                return
            } catch {
                print("⚠️ Сеть: \(url.path) не читается: \(error)")
            }
        }
        print("🧠 Сеть: qsnet.bin не найден — работаем на словарях")
    }

    private func parse(_ data: Data) throws {
        guard data.count > 8, data[0] == 0x51, data[1] == 0x53, data[2] == 0x4E, data[3] == 0x31 else {
            throw NSError(domain: "QSNet", code: 1, userInfo: [NSLocalizedDescriptionKey: "не QSN1"])
        }
        let hlen = Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24
        guard data.count >= 8 + hlen,
              let header0 = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + hlen))) as? [String: Any],
              let b = header0["buckets"] as? Int, let d = header0["dim"] as? Int, let h = header0["hidden"] as? Int,
              let tensors = header0["tensors"] as? [[Any]] else {
            throw NSError(domain: "QSNet", code: 2, userInfo: [NSLocalizedDescriptionKey: "битый заголовок"])
        }
        header = header0
        buckets = b; dim = d; hidden = h
        inputDim = dim + LayoutNet.ctxWords * (dim + LayoutNet.nFlags) + LayoutNet.nApps + LayoutNet.nLangs
        if let id = header0["input_dim"] as? Int, id != inputDim {
            throw NSError(domain: "QSNet", code: 3, userInfo: [NSLocalizedDescriptionKey: "input_dim \(id) ≠ \(inputDim)"])
        }
        trained = header0["trained"] as? String ?? "?"

        var offset = 8 + hlen
        for t in tensors {
            guard t.count == 2, let name = t[0] as? String, let shape = t[1] as? [Int] else { continue }
            let count = shape.reduce(1, *)
            guard data.count >= offset + count * 4 else {
                throw NSError(domain: "QSNet", code: 4, userInfo: [NSLocalizedDescriptionKey: "обрезан тензор \(name)"])
            }
            // Копируем через буфер: Data не гарантирует выравнивание под Float.
            var arr = [Float](repeating: 0, count: count)
            _ = arr.withUnsafeMutableBytes { data.copyBytes(to: $0, from: offset..<(offset + count * 4)) }
            offset += count * 4
            switch name {
            case "emb": emb = arr
            case "w1": w1 = arr
            case "b1": b1 = arr
            case "w2": w2 = arr
            case "b2": b2 = arr.first ?? 0
            default: break
            }
        }
        guard emb.count == buckets * dim, w1.count == inputDim * hidden, b1.count == hidden, w2.count == hidden else {
            throw NSError(domain: "QSNet", code: 5, userInfo: [NSLocalizedDescriptionKey: "размеры тензоров не сходятся"])
        }
    }

    // MARK: - Нормализация: символы → клавиши

    /// Слово в любой раскладке → строка клавиш в EN-обозначениях
    /// («привет» → "ghbdtn"). nil — если в слове есть что-то не с буквенной клавиши.
    /// Карта ruToEn — динамическая, из Detector (на маке 'ё' даёт '\', сводим к '`').
    func keys(for word: String, ruToEn: [Character: Character]) -> String? {
        var out = ""
        for ch in word.lowercased() {
            var k = ch
            if ("а"..."я").contains(ch) || ch == "ё" {
                guard let m = ruToEn[ch] else { return nil }
                k = m
            }
            if k == "\\" || k == "|" { k = "`" }
            guard LayoutNet.keyChars.contains(k) else { return nil }
            out.append(k)
        }
        if out.isEmpty || out.count > 24 { return nil }
        return out
    }

    /// Контекстное слово как оно на экране → (клавиши, флаг языка по алфавиту).
    func ctxWord(_ word: String, ruToEn: [Character: Character]) -> CtxWord {
        let lower = word.lowercased()
        let cyr = lower.contains { ("а"..."я").contains($0) || $0 == "ё" }
        let lat = lower.contains { ("a"..."z").contains($0) }
        let flag: CtxFlag = (cyr && !lat) ? .ru : (lat && !cyr) ? .en : .none
        return CtxWord(keys: flag == .none ? nil : keys(for: lower, ruToEn: ruToEn), flag: flag)
    }

    // MARK: - Признаки

    /// FNV-1a 32 бит по ASCII-байтам. Строки признаков — только ASCII.
    private static func fnv1a(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811C9DC5
        for b in s.utf8 {
            h ^= UInt32(b)
            h = h &* 0x01000193
        }
        return h
    }

    /// Все подстроки длиной 1..4 строки "<keys>" плюс "=keys" (слово целиком).
    private func bucketsOf(_ keys: String) -> [Int] {
        let s = Array(("<" + keys + ">").utf8)
        var out: [Int] = []
        let n = s.count
        for L in 1...4 where L <= n {
            for i in 0...(n - L) {
                let sub = String(decoding: s[i..<(i + L)], as: UTF8.self)
                out.append(Int(LayoutNet.fnv1a(sub) % UInt32(buckets)))
            }
        }
        out.append(Int(LayoutNet.fnv1a("=" + keys) % UInt32(buckets)))
        return out
    }

    /// Вектор слова — среднее строк таблицы эмбеддингов; для nil — нули.
    private func wordVec(_ keys: String?, into x: inout [Float], at offset: Int) {
        guard let keys = keys, !keys.isEmpty else { return }
        let rows = bucketsOf(keys)
        for r in rows {
            let base = r * dim
            for j in 0..<dim { x[offset + j] += emb[base + j] }
        }
        let inv = 1.0 / Float(rows.count)
        for j in 0..<dim { x[offset + j] *= inv }
    }

    // MARK: - Прямой проход

    /// P(имелся в виду RU). ctx — предыдущие слова, БЛИЖАЙШЕЕ ПЕРВЫМ, до трёх.
    func probabilityRu(keys: String, ctx: [CtxWord], app: AppClass, layoutRu: Bool) -> Float {
        var x = [Float](repeating: 0, count: inputDim)
        var off = 0
        wordVec(keys, into: &x, at: off); off += dim
        for i in 0..<LayoutNet.ctxWords {
            let c: CtxWord = i < ctx.count ? ctx[i] : CtxWord(keys: nil, flag: .none)
            wordVec(c.keys, into: &x, at: off); off += dim
            x[off + c.flag.rawValue] = 1; off += LayoutNet.nFlags
        }
        x[off + app.rawValue] = 1; off += LayoutNet.nApps
        x[off + (layoutRu ? 0 : 1)] = 1

        var z = b2
        for j in 0..<hidden {
            var h = b1[j]
            let col = j
            for i in 0..<inputDim where x[i] != 0 {
                h += x[i] * w1[i * hidden + col]
            }
            if h > 0 { z += h * w2[j] }
        }
        return 1 / (1 + expf(-z))
    }

    // MARK: - Дообучение на личных примерах

    /// Личный или общий пример: клавиши, контекст, класс приложения, раскладка, метка.
    struct Example {
        let keys: String
        let ctx: [CtxWord]
        let app: AppClass
        let layoutRu: Bool
        let labelRu: Bool

        /// Из словаря JSON ({"keys","ctx":[[k,f]…],"app","layout","label"}).
        init?(json c: [String: Any]) {
            guard let keys = c["keys"] as? String, !keys.isEmpty,
                  let label = c["label"] as? String else { return nil }
            self.keys = keys
            self.ctx = ((c["ctx"] as? [[Any]]) ?? []).prefix(LayoutNet.ctxWords).map { pair in
                CtxWord(keys: pair.count > 0 ? pair[0] as? String : nil,
                        flag: (pair.count > 1 ? pair[1] as? String : nil).map {
                            $0 == "ru" ? CtxFlag.ru : $0 == "en" ? .en : .none } ?? .none)
            }
            let appName = c["app"] as? String ?? "other"
            self.app = AppClass.allCases.first { $0.name == appName } ?? .other
            self.layoutRu = (c["layout"] as? String) == "ru"
            self.labelRu = label == "ru"
        }

        init(keys: String, ctx: [CtxWord], app: AppClass, layoutRu: Bool, labelRu: Bool) {
            self.keys = keys; self.ctx = ctx; self.app = app; self.layoutRu = layoutRu; self.labelRu = labelRu
        }

        var json: [String: Any] {
            ["keys": keys,
             "ctx": ctx.map { c -> [Any] in [c.keys.map { $0 as Any } ?? NSNull(), ["ru", "en", "none"][c.flag.rawValue]] },
             "app": app.name, "layout": layoutRu ? "ru" : "en", "label": labelRu ? "ru" : "en"]
        }
    }

    struct FinetuneReport {
        let personal: Int, personalBefore: Int, personalAfter: Int
        let generic: Int, genericBefore: Int, genericAfter: Int
        let seconds: Double
        var text: String {
            "личных примеров \(personal): верно \(personalBefore) → \(personalAfter); "
            + "общих \(generic): \(genericBefore) → \(genericAfter); \(String(format: "%.1f", seconds)) с"
        }
    }

    // Гиперпараметры — ровно как в nn/finetune.py
    private static let ftEpochs = 300
    private static let ftLR: Float = 0.05
    private static let ftLambda: Float = 0.05
    private static let ftSmooth: Float = 0.02
    private static let ftPersonalWeight: Float = 20

    /// Общие примеры для replay — чтобы личные слова добавились, а не вытеснили базу.
    func loadReplay() -> [Example] {
        guard let url = resourceURL("qsnet-replay.json"),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { Example(json: $0) }
    }

    /// Аугментация личного примера: обе раскладки (намерение от раскладки не
    /// зависит) и копия без контекста, если контекст был. Как expand() в finetune.py.
    private static func expand(_ e: Example) -> [Example] {
        var out: [Example] = []
        for lay in [e.layoutRu, !e.layoutRu] {
            out.append(Example(keys: e.keys, ctx: e.ctx, app: e.app, layoutRu: lay, labelRu: e.labelRu))
            if !e.ctx.isEmpty {
                out.append(Example(keys: e.keys, ctx: [], app: e.app, layoutRu: lay, labelRu: e.labelRu))
            }
        }
        return out
    }

    /// Дообучить текущие веса на личных примерах (+ replay) и записать
    /// пользовательский qsnet.bin. Долго (секунды–десятки секунд) — звать из фона.
    /// Возвращает отчёт; веса в памяти НЕ подменяет — после сохранения зови reload().
    func finetune(personal: [Example], replay: [Example]) throws -> FinetuneReport {
        guard loaded else { throw NSError(domain: "QSNet", code: 10, userInfo: [NSLocalizedDescriptionKey: "сеть не загружена"]) }
        let t0 = Date()
        let pers = personal.flatMap(LayoutNet.expand)
        let samples = pers + replay
        let nP = pers.count, N = samples.count
        guard N > 0 else { throw NSError(domain: "QSNet", code: 11, userInfo: [NSLocalizedDescriptionKey: "нет примеров"]) }
        let D = dim, H = hidden, I = inputDim

        // Структура входа: слоты (offset, buckets) + плотная часть; веса примеров.
        var slots: [[(Int, [Int])]] = []
        var dense: [[Float]] = []
        var y = [Float](repeating: 0, count: N)
        var w = [Float](repeating: 1, count: N)
        for (i, e) in samples.enumerated() {
            var sl: [(Int, [Int])] = [(0, bucketsOf(e.keys))]
            var off = D
            for c in 0..<LayoutNet.ctxWords {
                if c < e.ctx.count, let k = e.ctx[c].keys, !k.isEmpty { sl.append((off, bucketsOf(k))) }
                off += D + LayoutNet.nFlags
            }
            slots.append(sl)
            var x = [Float](repeating: 0, count: I)
            off = D
            for c in 0..<LayoutNet.ctxWords {
                let flag = c < e.ctx.count ? e.ctx[c].flag : .none
                x[off + D + flag.rawValue] = 1
                off += D + LayoutNet.nFlags
            }
            x[off + e.app.rawValue] = 1; off += LayoutNet.nApps
            x[off + (e.layoutRu ? 0 : 1)] = 1
            dense.append(x)
            y[i] = e.labelRu ? 1 : 0
            w[i] = i < nP ? LayoutNet.ftPersonalWeight : 1
        }
        let wMean = w.reduce(0, +) / Float(N)
        for i in 0..<N { w[i] /= wMean }
        let yt = y.map { $0 * (1 - 2 * LayoutNet.ftSmooth) + LayoutNet.ftSmooth }

        var emb = self.emb, w1 = self.w1, b1 = self.b1, w2 = self.w2, b2 = self.b2
        let w1_0 = w1, b1_0 = b1, w2_0 = w2, b2_0 = b2
        var X = [Float](repeating: 0, count: N * I)
        var hp = [Float](repeating: 0, count: N * H)
        var p = [Float](repeating: 0, count: N)

        func assemble() {
            for i in 0..<N {
                let base = i * I
                for j in 0..<I { X[base + j] = dense[i][j] }
                for (off, bk) in slots[i] {
                    for r in bk {
                        let rb = r * D
                        for j in 0..<D { X[base + off + j] += emb[rb + j] }
                    }
                    let inv = 1 / Float(bk.count)
                    for j in 0..<D { X[base + off + j] *= inv }
                }
            }
        }
        func forward() {
            for i in 0..<N {
                let xb = i * I
                var z = b2
                for j in 0..<H {
                    var h = b1[j]
                    for k in 0..<I where X[xb + k] != 0 { h += X[xb + k] * w1[k * H + j] }
                    hp[i * H + j] = h
                    if h > 0 { z += h * w2[j] }
                }
                p[i] = 1 / (1 + expf(-z))
            }
        }
        func correct() -> (Int, Int) {
            var a = 0, b = 0
            for i in 0..<N where (p[i] >= 0.5) == (y[i] >= 0.5) { if i < nP { a += 1 } else { b += 1 } }
            return (a, b)
        }

        assemble(); forward()
        let before = correct()
        var gw1 = [Float](repeating: 0, count: I * H)
        var gb1 = [Float](repeating: 0, count: H)
        var gw2 = [Float](repeating: 0, count: H)
        var dh = [Float](repeating: 0, count: H)
        let lr = LayoutNet.ftLR, lam = LayoutNet.ftLambda
        for _ in 0..<LayoutNet.ftEpochs {
            assemble(); forward()
            for j in 0..<(I * H) { gw1[j] = lam * (w1[j] - w1_0[j]) }
            for j in 0..<H { gb1[j] = lam * (b1[j] - b1_0[j]); gw2[j] = lam * (w2[j] - w2_0[j]) }
            var gb2 = lam * (b2 - b2_0)
            for i in 0..<N {
                let dz = (p[i] - yt[i]) * w[i] / Float(N)
                gb2 += dz
                let xb = i * I
                for j in 0..<H {
                    let h = hp[i * H + j]
                    if h > 0 {
                        gw2[j] += h * dz
                        dh[j] = dz * w2[j]
                    } else { dh[j] = 0 }
                }
                for j in 0..<H where dh[j] != 0 {
                    gb1[j] += dh[j]
                    for k in 0..<I where X[xb + k] != 0 { gw1[k * H + j] += X[xb + k] * dh[j] }
                }
                // dX = dh · w1ᵀ, только по слотам эмбеддингов
                for (off, bk) in slots[i] {
                    let inv = 1 / Float(bk.count)
                    for d in 0..<D {
                        var g: Float = 0
                        let row = (off + d) * H
                        for j in 0..<H where dh[j] != 0 { g += dh[j] * w1[row + j] }
                        g *= inv * lr
                        if g != 0 { for r in bk { emb[r * D + d] -= g } }
                    }
                }
            }
            for j in 0..<(I * H) { w1[j] -= lr * gw1[j] }
            for j in 0..<H { b1[j] -= lr * gb1[j]; w2[j] -= lr * gw2[j] }
            b2 -= lr * gb2
        }
        // финальные веса — во временный набор, оценка, запись
        let keepEmb = self.emb, keepW1 = self.w1, keepB1 = self.b1, keepW2 = self.w2, keepB2 = self.b2
        self.emb = emb; self.w1 = w1; self.b1 = b1; self.w2 = w2; self.b2 = b2
        assemble(); forward()
        let after = correct()
        do {
            try saveUser(personalCount: personal.count)
        } catch {
            self.emb = keepEmb; self.w1 = keepW1; self.b1 = keepB1; self.w2 = keepW2; self.b2 = keepB2
            throw error
        }
        return FinetuneReport(personal: nP, personalBefore: before.0, personalAfter: after.0,
                              generic: N - nP, genericBefore: before.1, genericAfter: after.1,
                              seconds: Date().timeIntervalSince(t0))
    }

    /// Записать текущие веса как пользовательские (формат QSN1, заголовок — от базовых
    /// с отметкой дообучения).
    private func saveUser(personalCount: Int) throws {
        var h = header
        h["finetuned"] = LayoutNet.stamp()
        h["finetune_version"] = (h["finetune_version"] as? Int ?? 0) + 1
        h["personal_examples"] = personalCount
        h["base_trained"] = h["base_trained"] as? String ?? trained
        let hbytes = try JSONSerialization.data(withJSONObject: h)
        var data = Data("QSN1".utf8)
        var len = UInt32(hbytes.count).littleEndian
        data.append(Data(bytes: &len, count: 4))
        data.append(hbytes)
        for name in ((h["tensors"] as? [[Any]]) ?? []).compactMap({ $0.first as? String }) {
            let arr: [Float]
            switch name {
            case "emb": arr = emb
            case "w1": arr = w1
            case "b1": arr = b1
            case "w2": arr = w2
            case "b2": arr = [b2]
            default: continue
            }
            arr.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        try data.write(to: LayoutNet.userWeightsURL, options: .atomic)
        header = h
    }

    /// Сброс к встроенным весам: удалить пользовательский файл и перечитать.
    func resetToBase() {
        try? FileManager.default.removeItem(at: LayoutNet.userWeightsURL)
        reload()
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: Date())
    }

    // MARK: - Самопроверка

    /// qsnet-selftest.json рядом с весами: список {keys, ctx:[[keys|null, flag]], app, layout, p}.
    private func selfTest(near weights: URL) -> Bool {
        let dir = weights.deletingLastPathComponent()
        var url = dir.appendingPathComponent("qsnet-selftest.json")
        if !FileManager.default.fileExists(atPath: url.path),
           let r = Bundle.main.resourceURL {
            url = r.appendingPathComponent("qsnet-selftest.json")
        }
        guard let data = try? Data(contentsOf: url),
              let cases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("🧠 selftest: qsnet-selftest.json нет — паритет не проверен")
            return true
        }
        var maxDiff: Float = 0
        var worst = ""
        for c in cases {
            guard let keys = c["keys"] as? String, let appName = c["app"] as? String,
                  let layout = c["layout"] as? String, let want = c["p"] as? Double else { continue }
            let ctx: [CtxWord] = ((c["ctx"] as? [[Any]]) ?? []).map { pair in
                let k = pair[0] as? String
                let f = pair[1] as? String ?? "none"
                return CtxWord(keys: k, flag: f == "ru" ? .ru : f == "en" ? .en : .none)
            }
            let app = AppClass.allCases.first { $0.name == appName } ?? .other
            let p = probabilityRu(keys: keys, ctx: ctx, app: app, layoutRu: layout == "ru")
            let diff = abs(p - Float(want))
            if diff > maxDiff { maxDiff = diff; worst = "\(keys) ctx=\(ctx.count) \(appName)/\(layout): порт \(p) эталон \(want)" }
        }
        let ok = maxDiff <= 1e-3
        print("🧠 selftest: \(cases.count) случаев, макс. расхождение \(maxDiff)\(ok ? "" : " ✗ " + worst)")
        return ok
    }
}
