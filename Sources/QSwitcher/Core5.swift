import Foundation

// Ядро решения QSwitcher 5 — одна формула вместо каскада слоёв.
// Эталон и обучение: nn/lm/ (model.py, charlm.py), самопроверка: nn/lm/core5-selftest.json.
//
// На каждое слово — два прочтения одних и тех же клавиш: набранное (язык T) и другое (A).
// Для каждого языка — стоимость = −ln P (меньше — правдоподобнее):
//
//   P_L(слово) = (1−α−τ)·P_частоты + α·P_символы + τ·P_опечатка
//   + пара с предыдущим словом того же языка (если сосед уверенный)
//   + регистр: слово ЦЕЛИКОМ заглавными → −ln P(капсом | слово, L)
//   + переход: −ln(1−π) тот же язык, −ln π смена; без уверенного соседа — ожидание приложения
//   + раскладка: +b_K, если L — не текущая раскладка
//
//   LO = стоимость(T) − стоимость(A);   LO > θ и «другое прочтение — слово» → свап.
//
// Вето нет: всё, что знает ядро, — слагаемые одной суммы; решение раскладывается в лог.
// Короткое неуверенное слово откладывается и решается задним числом по следующему.

// MARK: - Хэш-таблица (формат QSNG2 / QSCL1)

/// Запись 3 байта: 16-битный отпечаток (LE) + значение; две корзины на ключ.
/// Хэши — FNV-1a по байтам UTF-8, как в nn/ngram/build.py и nn/lm/charlm.py.
/// Таблица — окно в общем массиве файла (без копий).
struct QSTable {
    private let base: [UInt8]
    private let off: Int
    private let mask: UInt32
    private let empty: Bool

    init(base: [UInt8], offset: Int, count: Int, bits: Int) {
        self.base = base
        self.off = offset
        self.mask = UInt32((1 << bits) - 1)
        // Размер обязан быть (mask+1)·3 — иначе файл битый, таблицу не читаем
        self.empty = count < (Int(mask) + 1) * 3 || offset + count > base.count
    }

    @inline(__always) private static func step(_ h: UInt32, _ b: UInt8) -> UInt32 {
        return (h ^ UInt32(b)) &* 0x01000193
    }

    func get<S: Sequence>(_ key: S) -> UInt8? where S.Element == UInt8 {
        if empty { return nil }
        var a: UInt32 = 0x811C9DC5
        var b: UInt32 = QSTable.step(0x811C9DC5, 0x03)
        var f: UInt32 = QSTable.step(0x811C9DC5, 0x01)
        for x in key {
            a = QSTable.step(a, x); b = QSTable.step(b, x); f = QSTable.step(f, x)
        }
        f = QSTable.step(f, 0x02)
        let sa = a & mask
        var sb = b & mask
        if sb == sa { sb = (sa &+ 1) & mask }
        var fp = UInt16(truncatingIfNeeded: f >> 16)
        if fp == 0 { fp = 1 }
        let ia = off + Int(sa) * 3
        if (UInt16(base[ia]) | (UInt16(base[ia + 1]) << 8)) == fp { return base[ia + 2] }
        let ib = off + Int(sb) * 3
        if (UInt16(base[ib]) | (UInt16(base[ib + 1]) << 8)) == fp { return base[ib + 2] }
        return nil
    }

    func get(_ key: String) -> UInt8? { return get(key.utf8) }
}

// MARK: - Символьная модель языка (qschar.bin, QSCL1)

/// «Как выглядит слово этого языка»: символьные n-граммы внутри слова с метками «^» и «$»,
/// сглаживание Уиттена–Белла в форме с откатом. Оценивает ЛЮБУЮ строку: опечатки, сленг,
/// новые словоформы — там, где словарь молчит. Учится nn/lm/charlm.py.
final class CharLM {
    static let shared = CharLM()
    private(set) var loaded = false
    private(set) var order = 5
    private var scale: Double = 20
    private var ng: [String: QSTable] = [:]
    private var hist: [String: QSTable] = [:]
    private var caps: [String: QSTable] = [:]
    /// Символ алфавита языка → его байты UTF-8; чужой символ → «#».
    private var charBytes: [String: [Character: [UInt8]]] = [:]
    private var capCost: Double { 255.0 / scale }

    private init() { load() }

    private func candidatePaths() -> [URL] {
        var urls: [URL] = []
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        urls.append(appSupport.appendingPathComponent("QSwitcher/qschar.bin"))
        if let r = Bundle.main.resourceURL { urls.append(r.appendingPathComponent("qschar.bin")) }
        return urls
    }

    private func load() {
        for url in candidatePaths() where FileManager.default.fileExists(atPath: url.path) {
            do {
                try parse(Data(contentsOf: url))
                loaded = true
                let mb = Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1e6
                print("🔤 Символьная модель: \(url.path) (\(String(format: "%.1f", mb)) МБ, порядок \(order))")
                return
            } catch {
                print("⚠️ Символьная модель: \(url.path) не читается: \(error)")
            }
        }
        print("🔤 Символьная модель: qschar.bin не найден — ядро 5 опирается только на частоты слов")
    }

    private struct Header: Decodable {
        struct T: Decodable { let bits: Int }
        let v: Int
        let order: Int
        let scale: Double
        let langs: [String]
        let alpha: [String: String]
        let tables: [String: T]
    }

    private func parse(_ d: Data) throws {
        let all = [UInt8](d)
        guard all.count > 9, Array(all[0..<5]) == Array("QSCL1".utf8) else {
            throw NSError(domain: "CharLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "не QSCL1"])
        }
        var off = 5
        func u32() -> Int {
            var v = Int(all[off])
            v |= Int(all[off + 1]) << 8
            v |= Int(all[off + 2]) << 16
            v |= Int(all[off + 3]) << 24
            off += 4
            return v
        }
        let hl = u32()
        let h = try JSONDecoder().decode(Header.self, from: Data(all[off..<off + hl])); off += hl
        order = h.order; scale = h.scale
        for lang in h.langs {
            var m: [Character: [UInt8]] = [:]
            for ch in h.alpha[lang] ?? "" { m[ch] = Array(String(ch).utf8) }
            charBytes[lang] = m
            for name in ["ng", "hist", "caps"] {
                let n = u32()
                guard off + n <= all.count else {
                    throw NSError(domain: "CharLM", code: 2, userInfo: [NSLocalizedDescriptionKey: "файл обрезан"])
                }
                let bits = h.tables["\(lang).\(name)"]?.bits ?? 10
                let t = QSTable(base: all, offset: off, count: n, bits: bits)
                off += n
                switch name {
                case "ng": ng[lang] = t
                case "hist": hist[lang] = t
                default: caps[lang] = t
                }
            }
        }
    }

    /// −ln P(слово) по символам, с концом слова. Чужие символы → «#» (сильный штраф).
    func wordCost(_ word: String, _ lang: String) -> Double {
        guard loaded, let n = ng[lang], let hi = hist[lang], let cb = charBytes[lang] else { return 60 }
        let caret: [UInt8] = [0x5E], dollar: [UInt8] = [0x24], unk: [UInt8] = [0x23]
        var cs: [[UInt8]] = Array(repeating: caret, count: max(0, order - 1))
        for ch in word.lowercased() { cs.append(cb[ch] ?? unk) }
        cs.append(dollar)
        var total = 0.0
        var key: [UInt8] = []
        key.reserveCapacity(48)
        for i in (order - 1)..<cs.count {
            var bo = 0.0
            var got: Double? = nil
            var k = order - 1
            while k >= 0 {
                key.removeAll(keepingCapacity: true)
                for j in (i - k)..<i { key.append(contentsOf: cs[j]) }
                let hlen = key.count
                key.append(contentsOf: cs[i])
                if let v = n.get(key) { got = bo + Double(v) / scale; break }
                key.removeLast(key.count - hlen)
                if let l = hi.get(key) { bo += Double(l) / scale }
                k -= 1
            }
            total += got ?? (bo + capCost)
        }
        return total
    }

    /// Доля вхождений слова целиком заглавными (UI, IP, РФ) или nil.
    func capsP(_ word: String, _ lang: String) -> Double? {
        guard let t = caps[lang], let v = t.get(word.lowercased()) else { return nil }
        return Double(v) / 255.0
    }
}

// MARK: - Ожидание языка по приложению

/// Какой язык человек обычно набирает в этом приложении (по тому, что осталось на
/// экране; счётчики с затуханием) — ожидание для первого слова ввода. Пока данных
/// мало — по классу приложения: терминал и код — скорее английский, чаты — русский.
/// В файле только bundle id и два числа — никакого текста.
final class AppLangStats {
    static let shared = AppLangStats()
    private var counts: [String: [Double]] = [:]
    private var dirty = 0
    private let lock = NSLock()

    private var url: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("QSwitcher/app-lang.json")
    }

    private init() {
        if let d = try? Data(contentsOf: url),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: [Double]] {
            counts = j.filter { $0.value.count == 2 }
        }
    }

    /// Ожидание по классу приложения (без личной статистики).
    static func classPrior(_ app: String?) -> Double {
        let cls = Config.shared.appClass(for: app).name
        var d: Double
        switch cls {
        case "terminal": d = 0.15
        case "code": d = 0.2
        case "browser": d = 0.6
        case "chat": d = 0.8
        default: d = 0.7
        }
        // Класс из «ждём английский» (config: expectEnglishApps) — не мягче 0.2
        if Config.shared.expectEnglishApps.contains(cls) { d = min(d, 0.2) }
        return d
    }

    /// P(русский | приложение): класс как псевдосчёт 20 слов + своя статистика.
    func priorRu(_ app: String?) -> Double {
        let d = AppLangStats.classPrior(app)
        lock.lock(); defer { lock.unlock() }
        let c = counts[app ?? "?"] ?? [0, 0]
        return (c[0] + 20 * d) / (c[0] + c[1] + 20)
    }

    func note(_ app: String?, lang: String, delta: Double = 1) {
        guard lang == "ru" || lang == "en" else { return }
        lock.lock()
        let key = app ?? "?"
        var c = counts[key] ?? [0, 0]
        let i = lang == "ru" ? 0 : 1
        c[i] = max(0, c[i] + delta)
        if c[0] + c[1] > 2000 { c = [c[0] * 0.5, c[1] * 0.5] }     // затухание: старое весит меньше
        counts[key] = c
        dirty += 1
        let flush = dirty >= 50
        if flush { dirty = 0 }
        let snapshot = flush ? counts : [:]
        lock.unlock()
        if flush { save(snapshot) }
    }

    func saveNow() {
        lock.lock(); let s = counts; dirty = 0; lock.unlock()
        save(s)
    }

    private func save(_ snapshot: [String: [Double]]) {
        guard let d = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

// MARK: - Ядро

final class Core5 {
    /// Живой ввод. Прогоны и самопроверка берут свои экземпляры — чтобы не сбить контекст.
    static let shared = Core5(useConfig: true)
    /// Самопроверка порта в фоне при загрузке детектора (в режимах командной строки — нет).
    static var autoSelftest = true

    struct Params {
        var alpha = 0.03        // доля новых/редких слов (символьная модель)
        var tau = 0.02          // доля опечаток
        var beta = 0.5          // вес пары с предыдущим словом
        var pi = 0.04           // смена языка между соседними словами
        var bK = 1.0            // «язык не совпадает с раскладкой»
        var theta = 2.0         // порог свапа
        var thetaDefer = -1.0   // короткое слово выше этого LO ждёт правого соседа
        var capsP0 = 0.03       // P(капсом) для слова вне таблицы регистра
        var uShort = 13.0       // короткое другое прочтение: частота слова не реже e^-13
        var uShort2 = 16.0      // …или не реже e^-16, но при уверенном LO
        var loStrong = 5.0
        var cRel = 4.5          // набранное — явный мусор: новое хотя бы произносимо (на букву)
        var cJunk = 6.0
        var cMax = 3.2          // неизвестное длинное: символьная стоимость на букву не выше
        var typoMin = 4
        var typoMax = 32
        var short = 3
        var edge = 1.5          // цена символа-«пунктуации» на краю прочтения
        var deferShort = true
    }
    var p = Params()
    private let useConfig: Bool

    /// Слово на экране — контекст для следующего.
    struct Word {
        var typed = "", alt = "", T = "", A = ""
        var shown = "", lang = ""
        var lo = 0.0
        var pending = false
        var confident = true
    }

    struct Parts {
        var word: Double? = nil
        var char = 0.0
        var typo: Double? = nil
        var pair: Double? = nil
        var caps: Double? = nil
        var text: String {
            var s: [String] = []
            s.append("слово " + (word.map { String(format: "%.1f", $0) } ?? "-"))
            s.append(String(format: "симв %.1f", char))
            if let t = typo { s.append(String(format: "опеч %.1f", t)) }
            if let pr = pair { s.append(String(format: "пара %.1f", pr)) }
            if let c = caps { s.append(String(format: "капс %.1f", c)) }
            return "{" + s.joined(separator: ", ") + "}"
        }
    }

    struct Decision {
        var switchNow = false
        var shown = ""
        /// Исправление задним числом: предыдущее слово было на экране как retroFrom, станет retroPrev.
        var retroPrev: String? = nil
        var retroFrom: String? = nil
        var pending = false
        var lo = 0.0
        var explain = ""
    }

    private(set) var prev: Word? = nil
    private(set) var priorRu = 0.5
    private let lock = NSLock()

    static let alphaRu = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
    static let alphaEn = "abcdefghijklmnopqrstuvwxyz"
    private static let setRu = Set(alphaRu), setEn = Set(alphaEn)
    private static let arrRu = Array(alphaRu), arrEn = Array(alphaEn)
    private static let valid1: [String: Set<String>] = [
        "ru": ["а", "в", "и", "к", "о", "с", "у", "я"],
        "en": ["a", "i"],
    ]

    init(useConfig: Bool = true) { self.useConfig = useConfig }

    private func applyConfig() {
        let c = Config.shared
        p.theta = c.coreTheta
        p.pi = min(0.5, max(0.001, c.corePi))
        p.bK = c.coreLayoutBias
        p.deferShort = c.coreDeferShort
    }

    // MARK: состояние ввода

    /// Начало ввода: клик, смена приложения, навигация, пауза — левого контекста нет.
    func reset(priorRu: Double) {
        lock.lock(); prev = nil; self.priorRu = priorRu; lock.unlock()
    }

    /// Левый сосед неизвестен (стёрли назад, вставка), ожидание приложения прежнее.
    func forgetPrev() {
        lock.lock(); prev = nil; lock.unlock()
    }

    /// Слово решено не ядром (правило, профиль, место) — всё равно контекст.
    /// confident=false — решение ничего не говорит о языке (формула, слепой набор).
    func noteExternal(typed: String, shown: String, confident: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        let l = Core5.lang(shown)
        guard confident, !l.isEmpty else { prev = nil; return }
        var w = Word()
        w.typed = typed; w.shown = shown; w.lang = l
        w.T = Core5.lang(typed); w.A = w.T == "ru" ? "en" : "ru"
        w.confident = true
        prev = w
    }

    /// Человек поменял последнее слово руками — его решение окончательно.
    func noteManual(shown: String) {
        lock.lock(); defer { lock.unlock() }
        let l = Core5.lang(shown)
        guard !l.isEmpty else { prev = nil; return }
        var w = prev ?? Word()
        w.shown = shown; w.lang = l; w.pending = false; w.confident = true
        prev = w
    }

    // MARK: текст

    /// Нижний регистр одного символа без риска: если строчная форма — не один символ, как есть.
    @inline(__always) static func lower1(_ c: Character) -> Character {
        let s = c.lowercased()
        return s.count == 1 ? s.first! : c
    }

    static func lang(_ w: String) -> String {
        for ch in w.lowercased() {
            if setRu.contains(ch) { return "ru" }
            if setEn.contains(ch) { return "en" }
        }
        return ""
    }

    static func letters(_ w: String, _ lang: String) -> Int {
        let s = lang == "ru" ? setRu : setEn
        return w.lowercased().reduce(0) { $0 + (s.contains($1) ? 1 : 0) }
    }

    /// (начало, ядро, конец): по краям — символы, которые в этом языке не буквы.
    static func splitPunct(_ w: String, _ lang: String) -> (String, String, String) {
        let chars = Array(w)
        func inAlpha(_ c: Character) -> Bool {
            let l = lower1(c)
            if lang == "ru" { return setRu.contains(l) || l == "-" }
            return setEn.contains(l) || l == "-" || l == "'"
        }
        var i = 0, j = chars.count
        while i < j && !inAlpha(chars[i]) { i += 1 }
        while j > i && !inAlpha(chars[j - 1]) { j -= 1 }
        return (String(chars[0..<i]), String(chars[i..<j]), String(chars[j..<chars.count]))
    }

    static func isCaps(_ w: String) -> Bool {
        let n = w.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
        return n >= 2 && w.uppercased() == w && w.lowercased() != w
    }

    /// Замена букв по таблице RU↔EN (Apple Russian) — только для самопроверки; в работе
    /// другое прочтение даёт настоящая раскладка (Detector.swap).
    static let r2e: [Character: Character] = {
        let ru = Array("йцукенгшщзхъфывапролджэячсмитьбюё"), en = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.\\")
        var m: [Character: Character] = [:]
        for (a, b) in zip(ru, en) { m[a] = b }
        return m
    }()
    static let e2r: [Character: Character] = {
        var m: [Character: Character] = [:]
        for (a, b) in r2e { m[b] = a }
        return m
    }()
    static func letterSwap(_ w: String) -> String {
        var out = ""
        for ch in w {
            let lo = lower1(ch)
            if let m = r2e[lo] ?? e2r[lo] {
                if ch != lo { out += String(m).uppercased() } else { out.append(m) }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: модель

    private func known(_ lang: String, _ w: String) -> Double? {
        return NgramLM.shared.uniD(lang, w)
    }

    /// Ближайшее известное слово в одной правке: −ln P(соседа) + ln(число правок).
    private func typo(_ lang: String, _ w: String) -> Double? {
        let chars = Array(w)
        let n = chars.count
        guard n >= p.typoMin, n <= p.typoMax else { return nil }
        let a = lang == "ru" ? Core5.arrRu : Core5.arrEn
        var cands = Set<String>()
        cands.reserveCapacity(n * (2 * a.count + 2) + a.count)
        for i in 0..<n {
            var d = chars; d.remove(at: i); cands.insert(String(d))
            if i + 1 < n { var t = chars; t.swapAt(i, i + 1); cands.insert(String(t)) }
            for c in a where c != chars[i] { var s = chars; s[i] = c; cands.insert(String(s)) }
        }
        for i in 0...n {
            for c in a { var s = chars; s.insert(c, at: i); cands.insert(String(s)) }
        }
        var best: Double? = nil
        for c in cands {
            if let u = known(lang, c), best == nil || u < best! { best = u }
        }
        guard let b = best else { return nil }
        return b + log(Double(cands.count))
    }

    private func wordCost(_ w: String, _ lang: String, prevWord: String?) -> (Double, Parts) {
        let lw = w.lowercased()
        var parts = Parts()
        let k = known(lang, lw)
        let c = CharLM.shared.wordCost(lw, lang)
        let t = k == nil ? typo(lang, lw) : nil
        parts.word = k; parts.char = c; parts.typo = t
        let pk: Double = k.map { exp(-$0) } ?? 0.0
        let pt: Double = t.map { exp(-$0) } ?? 0.0
        // порядок сложения — как в эталоне: (A + B) + C
        var pw: Double = (1 - p.alpha - p.tau) * pk
        pw += p.alpha * exp(-c)
        pw += p.tau * pt
        if let pv = prevWord, !pv.isEmpty, let b = NgramLM.shared.biD(lang, pv.lowercased(), lw) {
            pw = p.beta * exp(-b) + (1 - p.beta) * pw
            parts.pair = b
        }
        return (-log(max(pw, 1e-300)), parts)
    }

    private func reading(_ r: String, _ lang: String, prevWord: String?, prevLang: String?, caps: Bool) -> (Double, Parts, String) {
        let (pre, cr, post) = Core5.splitPunct(r, lang)
        if cr.isEmpty { return (60, Parts(), cr) }
        let pw = (prevWord != nil && prevLang == lang) ? prevWord : nil
        var (cost, parts) = wordCost(cr, lang, prevWord: pw)
        cost += p.edge * Double(pre.count + post.count)
        if caps {
            let cp: Double
            if let v = CharLM.shared.capsP(cr, lang) { cp = min(0.99, max(0.01, v)) } else { cp = p.capsP0 }
            let cc = -log(cp)
            parts.caps = cc
            cost += cc
        }
        return (cost, parts, cr)
    }

    /// Можно ли переключать В это прочтение: оно должно быть словом.
    private func isWord(_ core: String, _ lang: String, _ parts: Parts, caps: Bool, lo: Double, typedCpc: Double) -> Bool {
        let n = Core5.letters(core, lang)
        if n == 0 { return false }
        if n == 1 { return Core5.valid1[lang]?.contains(core.lowercased()) ?? false }
        let k = parts.word
        if n <= p.short {
            if let k = k, k <= p.uShort { return true }
            if let k = k, k <= p.uShort2, lo > p.loStrong { return true }
            if caps, (parts.caps ?? 9) < 1.0, k != nil { return true }
            return false
        }
        if k != nil || parts.typo != nil { return true }
        let cpc = parts.char / Double(n + 1)
        if cpc <= p.cMax { return true }
        // набранное — явный мусор («bvzlt,fu»), новое хотя бы произносимо («имядебаг»)
        return typedCpc > p.cJunk && cpc <= p.cRel && lo > 10.0
    }

    private func prior(_ lang: String) -> Double {
        let pr = lang == "ru" ? priorRu : 1 - priorRu
        return -log(min(max(pr, 0.02), 0.98))
    }

    private func trans(_ lang: String, _ prev: Word?) -> Double {
        guard let pv = prev, pv.confident else { return prior(lang) }
        return lang == pv.lang ? -log(1 - p.pi) : -log(p.pi)
    }

    private struct Scored {
        var lo = 0.0, alt = "", A = "", ok = false
        var cT = 0.0, cA = 0.0, tT = 0.0, tA = 0.0
        var partsT = Parts(), partsA = Parts()
    }

    private func score(typed: String, alt altIn: String, T: String, prev: Word?, swap: (String) -> String) -> Scored {
        var s = Scored()
        let A = T == "ru" ? "en" : "ru"
        var alt = altIn
        let caps = Core5.isCaps(typed)
        let ctx = (prev?.confident ?? false) ? prev : nil
        let pw = ctx?.shown, pl = ctx?.lang
        let (cT, partsT, coreT) = reading(typed, T, prevWord: pw, prevLang: pl, caps: caps)
        var (cA, partsA, coreA) = reading(alt, A, prevWord: pw, prevLang: pl, caps: caps)
        // хвост, который в набранной раскладке — пунктуация, можно оставить как набран: «ghbdtn,» → «привет,»
        let (pre, cr, post) = Core5.splitPunct(typed, T)
        if !post.isEmpty && pre.isEmpty && !cr.isEmpty {
            let a2 = swap(cr)
            let (c2, parts2, core2) = reading(a2, A, prevWord: pw, prevLang: pl, caps: caps)
            if c2 < cA { cA = c2; partsA = parts2; coreA = core2; alt = a2 + post }
        }
        let tT = trans(T, prev), tA = trans(A, prev)
        let lo = (cT + tT) - (cA + tA + p.bK)
        let nT = max(1, Core5.letters(coreT, T))
        s.ok = isWord(coreA, A, partsA, caps: caps, lo: lo, typedCpc: partsT.char / Double(nT + 1))
        s.lo = lo; s.alt = alt; s.A = A
        s.cT = cT; s.cA = cA; s.tT = tT; s.tA = tA; s.partsT = partsT; s.partsA = partsA
        return s
    }

    /// Решение по слову. typed — как набрано (язык T), alt — другое прочтение тех же клавиш
    /// (по настоящей раскладке), sepIsSpace — между предыдущим словом и этим на экране ровно
    /// один пробел и больше ничего (иначе задним числом не правим).
    func decide(typed: String, alt: String, T: String, sepIsSpace: Bool, swap: (String) -> String) -> Decision {
        lock.lock(); defer { lock.unlock() }
        if useConfig { applyConfig() }
        var d = Decision()
        let s = score(typed: typed, alt: alt, T: T, prev: prev, swap: swap)
        let n = Core5.letters(typed, T)
        var w = Word()
        w.typed = typed; w.T = T; w.A = s.A; w.alt = s.alt; w.lo = s.lo
        if s.lo > p.theta && s.ok {
            w.shown = s.alt; w.lang = s.A
        } else {
            w.shown = typed; w.lang = T
            if p.deferShort && n <= p.short && s.lo > p.thetaDefer && s.ok {
                w.pending = true; w.confident = false
            }
        }
        let curConf = (w.shown != typed) || s.lo < -p.theta
        if var pw = prev, pw.pending, curConf {
            let bonus = log((1 - p.pi) / p.pi)
            var add = w.lang == pw.A ? bonus : -bonus
            // пара справа: «другое прочтение prev → текущее» против «prev как набрано → текущее»
            if w.lang == pw.A, let bA = NgramLM.shared.biD(pw.A, pw.alt.lowercased(), w.shown.lowercased()) {
                add += min(3.0, max(0.0, 12.0 - bA) / 3)
            }
            if w.lang == pw.T, let bT = NgramLM.shared.biD(pw.T, pw.typed.lowercased(), w.shown.lowercased()) {
                add -= min(3.0, max(0.0, 12.0 - bT) / 3)
            }
            let newLo = pw.lo + add
            var flipped = false
            if newLo > p.theta && sepIsSpace {
                d.retroFrom = pw.shown
                pw.shown = pw.alt; pw.lang = pw.A
                d.retroPrev = pw.alt
                flipped = true
            }
            pw.pending = false; pw.confident = true; pw.lo = newLo
            if flipped {
                // текущее — с исправленным соседом
                let s2 = score(typed: typed, alt: alt, T: T, prev: pw, swap: swap)
                w.lo = s2.lo
                if s2.lo > p.theta && s2.ok { w.shown = s2.alt; w.lang = s2.A }
                else { w.shown = typed; w.lang = T }
            }
        }
        d.switchNow = w.shown != typed
        d.shown = w.shown
        d.pending = w.pending
        d.lo = w.lo
        // по частям — длинную цепочку «+» компилятор Swift разбирает мучительно долго
        var ex = "\(typed)[\(T)] "
        ex += String(format: "%.1f+%.1f ", s.cT, s.tT)
        ex += s.partsT.text
        ex += " vs \(s.alt)[\(s.A)] "
        ex += String(format: "%.1f+%.1f+%.1f ", s.cA, s.tA, p.bK)
        ex += s.partsA.text
        ex += String(format: " → LO %+.1f", s.lo)
        if !s.ok { ex += " (не слово)" }
        if w.pending { ex += " отложено" }
        if let to = d.retroPrev { ex += " ↺ предыдущее '\(d.retroFrom ?? "")' → '\(to)'" }
        d.explain = ex
        prev = w
        return d
    }

    // MARK: самопроверка порта (nn/lm/core5-selftest.json)

    static var selftestURL: URL? {
        if let r = Bundle.main.resourceURL {
            let u = r.appendingPathComponent("core5-selftest.json")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Те же входы, что эталон на Python → те же решения. Возвращает (проверено, расхождений).
    /// Гоняет СВОЙ экземпляр с параметрами по умолчанию — живой контекст не трогает.
    @discardableResult
    static func selftest(url: URL, verbose: Bool = false) -> (Int, Int) {
        guard let d = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            print("⚠️ самопроверка ядра 5: не читается \(url.path)")
            return (0, 0)
        }
        var checked = 0, bad = 0
        for row in (j["chars"] as? [[Any]]) ?? [] {
            guard row.count == 3, let w = row[0] as? String, let l = row[1] as? String,
                  let e = (row[2] as? NSNumber)?.doubleValue else { continue }
            let got = CharLM.shared.wordCost(w.lowercased(), l)
            checked += 1
            if abs(got - e) > 0.05 {
                bad += 1
                print("  ✗ символьная '\(w)' [\(l)] \(String(format: "%.4f", got)) ≠ \(String(format: "%.4f", e))")
            }
        }
        let c = Core5(useConfig: false)
        for seq in (j["seqs"] as? [[String: Any]]) ?? [] {
            let pr = (seq["prior"] as? NSNumber)?.doubleValue ?? 0.5
            c.reset(priorRu: pr)
            for row in (seq["words"] as? [[Any]]) ?? [] {
                guard row.count == 5, let typed = row[0] as? String, let shown = row[1] as? String,
                      let lo = (row[2] as? NSNumber)?.doubleValue else { continue }
                let pend = (row[3] as? NSNumber)?.boolValue ?? false
                let retro = (row[4] as? NSNumber)?.boolValue ?? false
                let T = Core5.lang(typed)
                if T.isEmpty { continue }
                let r = c.decide(typed: typed, alt: Core5.letterSwap(typed), T: T, sepIsSpace: true, swap: Core5.letterSwap)
                checked += 1
                let okShown = r.shown == shown, okLo = abs(r.lo - lo) <= 0.05
                let okPend = r.pending == pend, okRetro = (r.retroPrev != nil) == retro
                if !(okShown && okLo && okPend && okRetro) {
                    bad += 1
                    if verbose || bad <= 20 {
                        print("  ✗ '\(typed)' → '\(r.shown)' (ждали '\(shown)') LO \(String(format: "%.3f", r.lo)) (ждали \(String(format: "%.3f", lo)))"
                              + (okPend ? "" : " отложено \(r.pending)") + (okRetro ? "" : " ретро \(r.retroPrev ?? "-")"))
                        if verbose { print("     \(r.explain)") }
                    }
                }
            }
        }
        return (checked, bad)
    }
}
