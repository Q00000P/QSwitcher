import Foundation

/// Семантические векторы слов (qsvec.bin, формат QSV1) — порт nn/sem/qsvec.py.
/// RU и EN в одном пространстве; незнакомое слово и опечатка собираются из
/// n-грамм 3..5 символов (хэш fastText). Векторы хранятся int8 со масштабом
/// на строку и раскрываются при обращении — ~25 МБ в памяти, без float-копий.
///
/// «Очищенный» вектор = вектор минус общая компонента (среднее по частотной части
/// словаря), единичной длины: только им и меряем смысл. Тема — затухающее среднее
/// очищенных векторов последних слов без служебных.
final class SemVec {

    static let shared = SemVec()

    private(set) var loaded = false
    private(set) var dim = 0
    private var vocab = 0, buckets = 0, minn = 3, maxn = 5
    private var index: [String: Int] = [:]
    private var wordList: [String] = []
    private var vecQ: [Int8] = [], vecScale: [Float] = []
    private var ngQ: [Int8] = [], ngScale: [Float] = []
    private var common: [Float] = []

    /// Служебные слова — в теме не участвуют (как STOP в qsvec.py).
    static let stop: Set<String> = Set("""
    и в во не что он на я с со как а то все она так его но да ты к у же вы за бы по только ее мне было вот от меня еще нет о из ему теперь когда даже ну вдруг ли если уже или ни быть был него до вас нибудь опять уж вам ведь там потом себя ничего ей может они тут где есть надо ней для мы тебя их чем была сам чтоб без будто чего раз тоже себе под будет ж тогда кто этот того потому этого какой совсем ним здесь этом один почти мой тем чтобы нее сейчас были куда зачем всех никогда можно при наконец два об другой хоть после над больше тот через эти нас про всего них какая много разве три эту моя впрочем хорошо свою этой перед иногда лучше чуть том нельзя такой им более всегда конечно всю между
    the be to of and a in that have i it for not on with he as you do at this but his by from they we say her she or an will my one all would there their what so up out if about who get which go me when make can like time no just him know take people into year your good some could them see other than then now look only come its over think also back after use two how our work first well way even new want because any these give day most us is are was were been has had did does am
    """.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })

    private init() { load() }

    // MARK: - Загрузка

    private func candidatePaths() -> [URL] {
        var urls: [URL] = []
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        urls.append(appSupport.appendingPathComponent("QSwitcher/qsvec.bin"))
        if let r = Bundle.main.resourceURL {
            urls.append(r.appendingPathComponent("qsvec.bin"))
            if let contents = try? FileManager.default.contentsOfDirectory(at: r, includingPropertiesForKeys: nil) {
                for item in contents where item.pathExtension == "bundle" {
                    urls.append(item.appendingPathComponent("Contents/Resources/qsvec.bin"))
                }
            }
        }
        return urls
    }

    private func load() {
        for url in candidatePaths() where FileManager.default.fileExists(atPath: url.path) {
            do {
                try parse(Data(contentsOf: url))
                loaded = true
                print("🧭 Векторы: \(url.lastPathComponent) (\(vocab) слов, \(buckets) корзин, dim \(dim))")
                return
            } catch {
                print("⚠️ Векторы: \(url.path) не читаются: \(error)")
            }
        }
        print("🧭 Векторы: qsvec.bin не найден — семантика выключена")
    }

    private func parse(_ data: Data) throws {
        guard data.count > 8, data[0] == 0x51, data[1] == 0x53, data[2] == 0x56, data[3] == 0x31 else {
            throw NSError(domain: "QSVec", code: 1, userInfo: [NSLocalizedDescriptionKey: "не QSV1"])
        }
        let hlen = Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24
        guard let h = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + hlen))) as? [String: Any],
              let d = h["dim"] as? Int, let v = h["vocab"] as? Int, let b = h["buckets"] as? Int else {
            throw NSError(domain: "QSVec", code: 2, userInfo: [NSLocalizedDescriptionKey: "битый заголовок"])
        }
        dim = d; vocab = v; buckets = b
        minn = h["minn"] as? Int ?? 3; maxn = h["maxn"] as? Int ?? 5
        var off = 8 + hlen
        index.reserveCapacity(vocab)
        for i in 0..<vocab {
            let n = Int(data[off]) | Int(data[off + 1]) << 8
            off += 2
            let w = String(decoding: data[off..<(off + n)], as: UTF8.self)
            off += n
            wordList.append(w)
            if index[w] == nil { index[w] = i }
        }
        func readRows(_ count: Int) throws -> ([Float], [Int8]) {
            var scales = [Float](repeating: 0, count: count)
            var q = [Int8](repeating: 0, count: count * dim)
            let rowBytes = 4 + dim
            guard data.count >= off + count * rowBytes else {
                throw NSError(domain: "QSVec", code: 3, userInfo: [NSLocalizedDescriptionKey: "обрезан"])
            }
            data.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                for i in 0..<count {
                    let p = base.advanced(by: off + i * rowBytes)
                    var s: Float = 0
                    memcpy(&s, p, 4)
                    scales[i] = s
                    q.withUnsafeMutableBytes { qb in
                        memcpy(qb.baseAddress!.advanced(by: i * dim), p.advanced(by: 4), dim)
                    }
                }
            }
            off += count * rowBytes
            return (scales, q)
        }
        (vecScale, vecQ) = try readRows(vocab)
        (ngScale, ngQ) = try readRows(buckets)
        // Общая компонента — среднее по частотной части словаря
        common = [Float](repeating: 0, count: dim)
        let n = min(vocab, 50_000)
        for i in 0..<n {
            let s = vecScale[i], base = i * dim
            for j in 0..<dim { common[j] += s * Float(vecQ[base + j]) }
        }
        for j in 0..<dim { common[j] /= Float(n) }
    }

    // MARK: - Лукап

    /// FNV-1a как в fastText: байт приводится к знаковому int8 перед xor.
    private static func ftHash(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in s.utf8 {
            h ^= UInt32(bitPattern: Int32(Int8(bitPattern: b)))
            h = h &* 16777619
        }
        return h
    }

    private func ngramRows(_ word: String) -> [Int] {
        let s = Array("<" + word + ">")
        let n = s.count
        var rows: [Int] = []
        for i in 0..<n {
            for L in minn...maxn where i + L <= n && !(i == 0 && L == n) {
                rows.append(Int(SemVec.ftHash(String(s[i..<(i + L)])) % UInt32(buckets)))
            }
        }
        return rows
    }

    /// Фон слова: средний cos единичного вектора с фиксированным набором частотных слов.
    /// У мусорных токенов («ha», «jin») он высокий — они «немножко похожи на всё»,
    /// и без вычитания фона выигрывают любое сравнение.
    private var bgRows: [[Float]] = []
    func background(_ unitVec: [Float]) -> Float {
        guard loaded, unitVec.count == dim else { return 0 }
        if bgRows.isEmpty {
            // Стратифицированно по всему словарю (не только частотные служебные —
            // иначе фон у мусорных токенов занижен, а у «в» и «быдло» не учтён).
            let n = 256
            for k in 0..<n {
                let i = min(vocab - 1, (k * vocab) / n + (vocab / (2 * n)))
                let w = wordList[i]
                if SemVec.stop.contains(w) || w.count < 3 { continue }
                bgRows.append(centered(w))
            }
        }
        var acc: Float = 0
        for r in bgRows { acc += SemVec.cos(unitVec, r) }
        return acc / Float(bgRows.count)
    }

    /// Слово есть в словаре корпуса (не собрано из кусочков).
    func inVocab(_ word: String) -> Bool { loaded && index[word.lowercased()] != nil }

    /// Сырой вектор слова: строка словаря или среднее n-грамм.
    func vector(_ word: String) -> [Float] {
        var out = [Float](repeating: 0, count: dim)
        guard loaded else { return out }
        let w = word.lowercased()
        if let i = index[w] {
            let s = vecScale[i], base = i * dim
            for j in 0..<dim { out[j] = s * Float(vecQ[base + j]) }
            return out
        }
        let rows = ngramRows(w)
        guard !rows.isEmpty else { return out }
        for r in rows {
            let s = ngScale[r], base = r * dim
            for j in 0..<dim { out[j] += s * Float(ngQ[base + j]) }
        }
        let inv = 1 / Float(rows.count)
        for j in 0..<dim { out[j] *= inv }
        return out
    }

    /// Очищенный вектор единичной длины — им меряем смысл.
    func centered(_ word: String) -> [Float] {
        var v = vector(word)
        guard loaded else { return v }
        var norm: Float = 0
        for j in 0..<dim { v[j] -= common[j]; norm += v[j] * v[j] }
        norm = sqrt(norm)
        if norm > 0 { for j in 0..<dim { v[j] /= norm } }
        return v
    }

    /// Тема: затухающее среднее очищенных векторов (последние слова первыми — ближние
    /// весят больше), без служебных и коротких слов.
    func topic(recentFirst words: [String], decay: Float = 0.9) -> [Float] {
        var acc = [Float](repeating: 0, count: dim)
        guard loaded else { return acc }
        var wsum: Float = 0, w: Float = 1
        for word in words {
            let lw = word.lowercased()
            if SemVec.stop.contains(lw) || lw.count < 3 { continue }
            let v = centered(lw)
            for j in 0..<dim { acc[j] += w * v[j] }
            wsum += w
            w *= decay
        }
        if wsum > 0 { for j in 0..<dim { acc[j] /= wsum } }
        return acc
    }

    static func cos(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d: Float = 0, na: Float = 0, nb: Float = 0
        for j in 0..<a.count { d += a[j] * b[j]; na += a[j] * a[j]; nb += b[j] * b[j] }
        return d / ((sqrt(na) + 1e-9) * (sqrt(nb) + 1e-9))
    }
}
