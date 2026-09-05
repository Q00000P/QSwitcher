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

    private func candidatePaths() -> [URL] {
        var urls: [URL] = []
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        urls.append(appSupport.appendingPathComponent("QSwitcher/qsnet.bin"))
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
                loaded = true
                print("🧠 Сеть: \(url.path) (buckets=\(buckets), dim=\(dim), hidden=\(hidden), обучена \(trained))")
                if !selfTest(near: url) {
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
              let header = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + hlen))) as? [String: Any],
              let b = header["buckets"] as? Int, let d = header["dim"] as? Int, let h = header["hidden"] as? Int,
              let tensors = header["tensors"] as? [[Any]] else {
            throw NSError(domain: "QSNet", code: 2, userInfo: [NSLocalizedDescriptionKey: "битый заголовок"])
        }
        buckets = b; dim = d; hidden = h
        inputDim = dim + LayoutNet.ctxWords * (dim + LayoutNet.nFlags) + LayoutNet.nApps + LayoutNet.nLangs
        if let id = header["input_dim"] as? Int, id != inputDim {
            throw NSError(domain: "QSNet", code: 3, userInfo: [NSLocalizedDescriptionKey: "input_dim \(id) ≠ \(inputDim)"])
        }
        trained = header["trained"] as? String ?? "?"

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
