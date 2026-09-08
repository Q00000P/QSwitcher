import Foundation

/// Языковая модель на словных n-граммах (nn/ngram/build.py → qsngram.bin, QSNG2).
/// Две таблицы (ru, en): униграммы и биграммы, по хэшу FNV-1a, запись 3 байта =
/// 16-битный отпечаток + −logP в шагах 0.1 ната, две корзины на ключ.
/// Эталон расчёта — nn/ngram/score.py; здесь то же самое, только левый сосед
/// (правого при вводе ещё нет). Лукап — два хэша и сравнение, микросекунды.
final class NgramLM {
    static let shared = NgramLM()
    private(set) var loaded = false

    private var uniBits = 0, biBits = 0, scale: Float = 0.1
    private var tables: [String: (uni: Data, bi: Data)] = [:]

    // Те же константы, что в score.py
    static let backoff: Float = 1.2   // пары нет — униграмма с надбавкой
    /// Слова нет в корпусе — хуже ЛЮБОГО настоящего слова (шкала до 25.5). С потолком 12
    /// «kubectl» (19) проигрывал несуществующему «лгиусед» — и так свапалось всё редкое.
    static let unseen: Float = 30.0
    static let switchCost: Float = 0.7 // сосед другого алфавита

    private init() { load() }

    // MARK: - Загрузка

    private func candidatePaths() -> [URL] {
        var urls: [URL] = []
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        urls.append(appSupport.appendingPathComponent("QSwitcher/qsngram.bin"))
        if let r = Bundle.main.resourceURL { urls.append(r.appendingPathComponent("qsngram.bin")) }
        return urls
    }

    private func load() {
        for url in candidatePaths() where FileManager.default.fileExists(atPath: url.path) {
            do {
                try parse(Data(contentsOf: url))
                loaded = true
                let mb = Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1e6
                print("🔡 N-граммы: \(url.lastPathComponent) (\(String(format: "%.1f", mb)) МБ, слов 2^\(uniBits), пар 2^\(biBits) на язык)")
                return
            } catch {
                print("⚠️ N-граммы: \(url.path) не читаются: \(error)")
            }
        }
        print("🔡 N-граммы: qsngram.bin не найден — сигнал выключен")
    }

    private struct Header: Decodable { let v: Int; let uni_bits: Int; let bi_bits: Int; let langs: [String]; let scale: Float }

    private func parse(_ d: Data) throws {
        guard d.count > 9, d[0..<5] == Data("QSNG2".utf8) else { throw NSError(domain: "NgramLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "не QSNG2"]) }
        var off = 5
        func u32() -> Int { let v = d[off..<off+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }; off += 4; return Int(UInt32(littleEndian: v)) }
        let hl = u32()
        let h = try JSONDecoder().decode(Header.self, from: d[off..<off+hl]); off += hl
        uniBits = h.uni_bits; biBits = h.bi_bits; scale = h.scale
        var t: [String: (Data, Data)] = [:]
        for lang in h.langs {
            let ul = u32(), bl = u32()
            let u = d.subdata(in: off..<off+ul); off += ul
            let b = d.subdata(in: off..<off+bl); off += bl
            t[lang] = (u, b)
        }
        tables = t
    }

    // MARK: - Хэши (как в build.py)

    static func fnv1a(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811C9DC5
        for b in s.utf8 { h ^= UInt32(b); h = h &* 0x01000193 }
        return h
    }
    static func fp16(_ s: String) -> UInt16 {
        let v = UInt16(truncatingIfNeeded: fnv1a("\u{01}" + s + "\u{02}") >> 16)
        return v == 0 ? 1 : v
    }
    static func slots(_ key: String, mask: UInt32) -> (Int, Int) {
        let a = fnv1a(key) & mask
        let b = fnv1a("\u{03}" + key) & mask
        return (Int(a), Int(b != a ? b : (a &+ 1) & mask))
    }

    private func get(_ table: Data, bits: Int, key: String) -> Float? {
        let mask = UInt32((1 << bits) - 1)
        let fp = NgramLM.fp16(key)
        let (a, b) = NgramLM.slots(key, mask: mask)
        for slot in [a, b] {
            let i = table.startIndex + slot * 3
            let cur = UInt16(table[i]) | (UInt16(table[i + 1]) << 8)
            if cur == fp { return Float(table[i + 2]) * scale }
        }
        return nil
    }

    func uni(_ lang: String, _ w: String) -> Float? {
        guard let t = tables[lang] else { return nil }
        return get(t.uni, bits: uniBits, key: w)
    }
    func bi(_ lang: String, _ p: String, _ w: String) -> Float? {
        guard let t = tables[lang] else { return nil }
        return get(t.bi, bits: biBits, key: p + "\u{1F}" + w)
    }

    // MARK: - Балл чтения

    static func lang(of s: String) -> String {
        for c in s.unicodeScalars {
            if (0x0400...0x04FF).contains(c.value) { return "ru" }
            if (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A) { return "en" }
        }
        return ""
    }

    /// −logP чтения с учётом левого соседа: пара, иначе униграмма + откат,
    /// плюс смена языка, если сосед другого алфавита. Меньше — лучше.
    func cost(_ word: String, left: String?) -> (Float, String) {
        let lang = NgramLM.lang(of: word)
        guard !lang.isEmpty else { return (NgramLM.unseen, "нет алфавита") }
        guard let u = uni(lang, word) else { return (NgramLM.unseen, "\(lang): слова нет") }
        guard let l = left?.lowercased(), !l.isEmpty else { return (u, String(format: "слово %.1f", u)) }
        let ll = NgramLM.lang(of: l)
        var c: Float = 0; var why = ""
        if !ll.isEmpty && ll != lang {
            c = u + NgramLM.backoff + NgramLM.switchCost
            why = String(format: "откат %.1f, смена языка +%.1f", u + NgramLM.backoff, NgramLM.switchCost)
        } else if let b = bi(lang, l, word) {
            c = b; why = String(format: "пара %.1f", b)
        } else {
            c = u + NgramLM.backoff; why = String(format: "откат %.1f", c)
        }
        return (c, why)
    }

    /// Слово есть в корпусе своего языка?
    func known(_ word: String) -> Bool {
        let lang = NgramLM.lang(of: word)
        return !lang.isEmpty && uni(lang, word) != nil
    }

    /// nil — молчим; иначе победившее чтение и объяснение.
    /// Свапаем ТОЛЬКО в слово, которое есть в корпусе: опечатка, сленг, редкий
    /// термин («сломали», «kubectl») не должны превращаться в мусор только потому,
    /// что модель их не видела. «Не видели оба» — молчим.
    func decide(typed: String, swapped: String, left: String?, margin: Float) -> (String, String)? {
        let (a, wa) = cost(typed, left: left)
        let (b, wb) = cost(swapped, left: left)
        let explain = String(format: "'%@' %.2f (%@) vs '%@' %.2f (%@)", typed, a, wa, swapped, b, wb)
        let ka = known(typed), kb = known(swapped)
        if kb && b + margin < a { return (swapped, explain) }
        if ka && a + margin < b { return (typed, explain) }
        return nil
    }
}
