import Foundation
import SystemConfiguration

/// Режим личного слоя (config.json: "personalMode").
enum PersonalMode: String {
    /// Выключен: ядро решает без него, в слой ничего не пишется.
    case off
    /// Обучение: только наблюдает и копит, в решениях не участвует.
    case learn
    /// Работа + обучение: участвует в решениях и продолжает учиться.
    case on
    /// Только работа: участвует в решениях, ничего нового не запоминает.
    case frozen
}

/// Таблица одного устройства. Каждое устройство пишет только свою — слияние при импорте
/// и синхронизации без двойного счёта: чужие таблицы заменяются целиком более свежими
/// копиями, в решениях участвует сумма.
final class PersonalTable {
    var device = "", name = "", platform = ""
    /// Когда таблица менялась последний раз (мс Unix).
    var updated: Int64 = 0
    /// [0] — ru, [1] — en.
    var uni: [[String: Double]] = [[:], [:]]
    var bi: [[String: Double]] = [[:], [:]]
    var typo: [[String: [String: Double]]] = [[:], [:]]
    /// Счётчики событий для меню: принятые слова, исправления, опечатки.
    var words = 0.0, corrections = 0.0, typos = 0.0

    init(device: String, name: String, platform: String) {
        self.device = device; self.name = name; self.platform = platform
    }
}

/// Личный слой ядра 5: что человек оставляет на экране — слова, пары соседей (и через смену
/// языка: «сервер HA»), свои опечатки. Эталон — Personal в nn/lm/model.py (самопроверка сверяет
/// стоимости), порт один в один с PersonalLM.cs. Веса: принятое слово +1, исправление +3
/// (тоггл назад, ручной свап, стёр и набрал в другой раскладке). Доводом слово становится с
/// веса 2: одно исправление — сразу, одно случайное слово — нет.
///
/// Наблюдение отложенное: слово засчитывается на следующей границе, если его не тронули;
/// ручная правка заменяет его исправленным. Пароли, исключённые приложения и формулы сюда не
/// попадают (решает Switcher). На диске — personal.qsp, зашифрован ключом из Keychain.
final class PersonalLM {
    static let minW = 2.0
    static let smooth = 50.0
    static let pairSmooth = 5.0
    static let typoCost = log(2.0)
    static let weightAccepted = 1.0
    static let weightCorrection = 3.0
    // Потолки: год набора — десятки тысяч слов; сверх — отрезаем самые редкие
    private static let maxUni = 150_000, maxBi = 400_000, maxTypo = 20_000

    /// Живой слой приложения (загружается при первом обращении).
    static let shared: PersonalLM = PersonalLM.loadShared()

    /// Для прогонов из командной строки (--test): тот же файл, только чтение — участвует,
    /// если в конфиге он в работе, и ничего не запоминает; битый файл не трогается.
    static let readOnlyShared: PersonalLM = {
        let lm = PersonalLM.load(readOnly: true)
        lm.modeSource = {
            let m = Config.shared.personalMode
            return (m == .on || m == .frozen) ? .frozen : .off
        }
        return lm
    }()

    private let lock = NSLock()
    private var tables: [String: PersonalTable] = [:]
    // Сумма по устройствам — то, что видит ядро
    private var sumUni: [[String: Double]] = [[:], [:]]
    private var sumBi: [[String: Double]] = [[:], [:]]
    private var sumTypo: [[String: [String: Double]]] = [[:], [:]]
    private var n: [Double] = [0, 0]

    /// Это устройство (его таблица — единственная, куда пишем).
    private(set) var local: PersonalTable
    /// Очищено всё — более старые таблицы при слиянии не принимаются.
    private(set) var clearedAt: Int64 = 0
    /// Режим (из конфига, читается на каждое действие).
    var modeSource: () -> PersonalMode = { .on }
    var mode: PersonalMode { modeSource() }
    var uses: Bool { mode == .on || mode == .frozen }
    var learns: Bool { mode == .learn || mode == .on }
    /// Для «стёр и набрал в другой раскладке»: свап по настоящей раскладке.
    var swap: (String) -> String = { $0 }
    /// Сколько изменений с последнего сохранения.
    private(set) var dirty = 0

    init(device: String, name: String, platform: String) {
        local = PersonalTable(device: device, name: name, platform: platform)
        tables[device] = local
    }

    @inline(__always) private static func li(_ lang: String) -> Int { lang == "ru" ? 0 : 1 }

    /// Сравнение по кодам символов (как ordinal в C# и str в Python).
    private static func ordinalLess(_ a: String, _ b: String) -> Bool {
        var ia = a.unicodeScalars.makeIterator(), ib = b.unicodeScalars.makeIterator()
        while true {
            let x = ia.next(), y = ib.next()
            switch (x, y) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): if x.value != y.value { return x.value < y.value }
            }
        }
    }

    // MARK: запросы ядра

    /// −ln P_личн(слово) или nil (вес меньше minW).
    func cost(_ lang: String, _ w: String) -> Double? {
        guard lang == "ru" || lang == "en" else { return nil }
        lock.lock(); defer { lock.unlock() }
        let i = PersonalLM.li(lang)
        guard let v = sumUni[i][w.lowercased()], v >= PersonalLM.minW else { return nil }
        return -log(v / (n[i] + PersonalLM.smooth))
    }

    /// −ln P_личн(слово | предыдущее) — предыдущее любого языка, или nil.
    func pair(_ lang: String, _ prev: String, _ w: String) -> Double? {
        guard lang == "ru" || lang == "en" else { return nil }
        lock.lock(); defer { lock.unlock() }
        let p = prev.lowercased()
        guard let v = sumBi[PersonalLM.li(lang)][p + "\u{1F}" + w.lowercased()], v >= PersonalLM.minW else { return nil }
        var pl = Core5.lang(p)
        if pl.isEmpty { pl = lang }
        let c = sumUni[PersonalLM.li(pl)][p] ?? 0.0
        return -log(v / (c + PersonalLM.pairSmooth))
    }

    /// Во что человек обычно исправляет это написание: самое частое, при равенстве — первое
    /// по кодам символов; nil — если вес меньше minW.
    func typoOf(_ lang: String, _ w: String) -> String? {
        guard lang == "ru" || lang == "en" else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let t = sumTypo[PersonalLM.li(lang)][w.lowercased()], !t.isEmpty else { return nil }
        var best: String? = nil
        var bv = 0.0
        for (r, v) in t {
            if best == nil || v > bv || (v == bv && PersonalLM.ordinalLess(r, best!)) { best = r; bv = v }
        }
        return bv >= PersonalLM.minW ? best : nil
    }

    // MARK: наполнение (под замком)

    private static func inc(_ d: inout [String: Double], _ k: String, _ v: Double) {
        d[k, default: 0] += v
    }

    private func addLocal(_ lang: String, _ w: String, _ k: Double, _ prev: String?) {
        let i = PersonalLM.li(lang)
        PersonalLM.inc(&local.uni[i], w, k); PersonalLM.inc(&sumUni[i], w, k); n[i] += k
        if let p = prev, !p.isEmpty {
            let key = p + "\u{1F}" + w
            PersonalLM.inc(&local.bi[i], key, k); PersonalLM.inc(&sumBi[i], key, k)
        }
        touch()
    }

    private func addTypoLocal(_ lang: String, _ wrong: String, _ right: String, _ k: Double) {
        let i = PersonalLM.li(lang)
        PersonalLM.inc(&local.typo[i][wrong, default: [:]], right, k)
        PersonalLM.inc(&sumTypo[i][wrong, default: [:]], right, k)
        local.typos += 1
        touch()
    }

    private func touch() {
        local.updated = Int64(Date().timeIntervalSince1970 * 1000)
        dirty += 1
    }

    /// Добавить напрямую (тесты): слово и пара с предыдущим.
    func add(_ lang: String, _ w: String, _ k: Double = 1, prev: String? = nil) {
        guard lang == "ru" || lang == "en" else { return }
        lock.lock(); addLocal(lang, w.lowercased(), k, prev?.lowercased()); lock.unlock()
    }

    // MARK: наблюдение за вводом

    private var pending: (word: String, lang: String, prev: String?, w: Double)? = nil
    private var erased: String? = nil
    private var boostNext = false

    /// Ядро слова для слоя: язык по буквам, края без знаков, нижний регистр; только буквы
    /// своего языка (и дефис/апостроф внутри), 2…32 буквы. Иначе nil.
    static func coreOf(_ shown: String) -> (core: String, lang: String)? {
        let lang = Core5.lang(shown)
        guard !lang.isEmpty else { return nil }
        let core = Core5.splitPunct(shown, lang).1.lowercased()
        let n = Core5.letters(core, lang)
        guard n >= 2, n <= 32 else { return nil }
        for c in core where c != "-" && c != "'" {
            if Core5.letters(String(c), lang) == 0 { return nil }
        }
        return (core, lang)
    }

    private func commitPending() {
        guard let p = pending else { return }
        pending = nil
        addLocal(p.lang, p.word, p.w, p.prev)
        if p.w >= PersonalLM.weightCorrection { local.corrections += 1 } else { local.words += 1 }
    }

    /// Граница слова: на экране осталось shown. prevShown — предыдущее слово на экране,
    /// adjacent — стоят вплотную через пробел (для пары).
    func observe(shown: String, prevShown: String?, adjacent: Bool) {
        guard learns else {
            lock.lock(); pending = nil; erased = nil; boostNext = false; lock.unlock()
            return
        }
        lock.lock(); defer { lock.unlock() }
        commitPending()
        guard let c = PersonalLM.coreOf(shown) else { erased = nil; boostNext = false; return }
        var w = PersonalLM.weightAccepted
        if boostNext { w = PersonalLM.weightCorrection }
        if let e = erased {
            if self.swap(e).lowercased() == c.core { w = PersonalLM.weightCorrection }   // стёр и набрал то же в другой раскладке
            erased = nil
        }
        boostNext = false
        let prev = (adjacent && prevShown != nil) ? PersonalLM.coreOf(prevShown!)?.core : nil
        pending = (c.core, c.lang, prev, w)
    }

    /// Ядро исправило предыдущее слово задним числом — засчитываем исправленное.
    func retroChanged(_ newShown: String) {
        lock.lock(); defer { lock.unlock() }
        guard let p = pending else { return }
        if let c = PersonalLM.coreOf(newShown) { pending = (c.core, c.lang, p.prev, p.w) } else { pending = nil }
    }

    /// Человек поменял последнее слово (ручной свап, тоггл): засчитывается то, что теперь на
    /// экране, с весом исправления. Повторный тоггл перезаписывает.
    func manualFix(_ to: String) {
        guard learns else { return }
        let words = to.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard let last = words.last else { return }
        let c = PersonalLM.coreOf(String(last))
        lock.lock(); defer { lock.unlock() }
        erased = nil
        guard let cc = c else { pending = nil; return }
        pending = (cc.core, cc.lang, pending?.prev, PersonalLM.weightCorrection)
    }

    /// Человек свапнул недонабранное слово — оно на экране уже исправленным, границы для
    /// него не будет.
    func manualWord(_ to: String) {
        guard learns else { return }
        lock.lock(); defer { lock.unlock() }
        commitPending()
        erased = nil
        if let c = PersonalLM.coreOf(to) { pending = (c.core, c.lang, nil, PersonalLM.weightCorrection) } else { pending = nil }
    }

    /// Стирают назад за границу слова: предыдущее больше не довод.
    func dropPending() {
        lock.lock(); pending = nil; lock.unlock()
    }

    /// Предыдущее слово стёрто целиком: если следующее — оно же в другой раскладке, это
    /// исправление пропущенного свапа.
    func erasedWord(_ word: String) {
        lock.lock(); pending = nil; erased = word; lock.unlock()
    }

    /// Внутри слова правили (стёрли часть и набрали): attempt — каким было до первой правки,
    /// final — каким ушло. Та же раскладка и 1–2 правки — личная опечатка; то же слово в другой
    /// раскладке — пропущенный свап (следующее observe — с весом исправления).
    func inWordEdit(attempt: String, final: String) {
        guard learns, let a = PersonalLM.coreOf(attempt), let f = PersonalLM.coreOf(final) else { return }
        lock.lock(); defer { lock.unlock() }
        if a.lang != f.lang {
            if self.swap(a.core).lowercased() == f.core { boostNext = true }
            return
        }
        let wa = a.core, wf = f.core
        let la = wa.count, lf = wf.count
        if wa == wf || la < 3 || lf < 3 { return }
        if la < lf || la > lf + 1 { return }          // оборванное — не опечатка
        if PersonalLM.distance(wa, wf) > 2 { return }
        addTypoLocal(a.lang, wa, wf, 1.0)
    }

    /// Конец сеанса ввода (клик, другое приложение): отложенное засчитывается.
    func flush() {
        lock.lock(); commitPending(); erased = nil; boostNext = false; lock.unlock()
    }

    /// Расстояние Дамерау–Левенштейна (с перестановкой соседних).
    private static func distance(_ sa: String, _ sb: String) -> Int {
        let a = Array(sa), b = Array(sb)
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] { v = min(v, d[i - 2][j - 2] + 1) }
                d[i][j] = v
            }
        }
        return d[a.count][b.count]
    }

    // MARK: сводка

    struct Summary {
        var wordsRu = 0, wordsEn = 0, pairs = 0, typoForms = 0
        var accepted = 0.0, corrections = 0.0, typos = 0.0, devices = 0
    }

    func stats() -> Summary {
        lock.lock(); defer { lock.unlock() }
        var s = Summary()
        s.wordsRu = sumUni[0].count; s.wordsEn = sumUni[1].count
        s.pairs = sumBi[0].count + sumBi[1].count
        s.typoForms = sumTypo[0].count + sumTypo[1].count
        for t in tables.values { s.accepted += t.words; s.corrections += t.corrections; s.typos += t.typos }
        s.devices = tables.count
        return s
    }

    // MARK: хранение и слияние

    private static func tableToJSON(_ t: PersonalTable) -> [String: Any] {
        func pairOfLangs(_ m: [[String: Double]]) -> [String: Any] { ["ru": m[0], "en": m[1]] }
        return [
            "device": t.device, "name": t.name, "platform": t.platform, "updated": t.updated,
            "stats": ["words": t.words, "corrections": t.corrections, "typos": t.typos],
            "uni": pairOfLangs(t.uni), "bi": pairOfLangs(t.bi),
            "typo": ["ru": t.typo[0], "en": t.typo[1]],
        ]
    }

    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private static func tableFromJSON(_ e: [String: Any], deviceOverride: String? = nil) -> PersonalTable {
        let t = PersonalTable(device: deviceOverride ?? (e["device"] as? String ?? ""),
                              name: e["name"] as? String ?? "", platform: e["platform"] as? String ?? "")
        t.updated = (e["updated"] as? NSNumber)?.int64Value ?? 0
        if let st = e["stats"] as? [String: Any] {
            t.words = num(st["words"]) ?? 0; t.corrections = num(st["corrections"]) ?? 0; t.typos = num(st["typos"]) ?? 0
        }
        func read(_ name: String) -> [[String: Double]] {
            var out: [[String: Double]] = [[:], [:]]
            guard let o = e[name] as? [String: Any] else { return out }
            for (i, L) in ["ru", "en"].enumerated() {
                for (k, v) in (o[L] as? [String: Any]) ?? [:] { if let d = num(v) { out[i][k] = d } }
            }
            return out
        }
        t.uni = read("uni"); t.bi = read("bi")
        if let ty = e["typo"] as? [String: Any] {
            for (i, L) in ["ru", "en"].enumerated() {
                for (k, v) in (ty[L] as? [String: Any]) ?? [:] {
                    var r: [String: Double] = [:]
                    for (rk, rv) in (v as? [String: Any]) ?? [:] { if let d = num(rv) { r[rk] = d } }
                    if !r.isEmpty { t.typo[i][k] = r }
                }
            }
        }
        return t
    }

    /// Весь слой (все устройства) — для файла на диске и для экспорта.
    func toJSON() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return toJSONLocked()
    }

    private func toJSONLocked() -> [String: Any] {
        let ordered = tables.values.sorted { a, b in
            if (a.device == local.device) != (b.device == local.device) { return a.device == local.device }
            return PersonalLM.ordinalLess(a.device, b.device)
        }
        return ["v": 1, "self": local.device, "clearedAt": clearedAt, "tables": ordered.map { PersonalLM.tableToJSON($0) }]
    }

    /// Загрузить свой файл. Своё устройство — из "self".
    static func fromJSON(_ root: [String: Any], defaultDevice: String, name: String, platform: String) -> PersonalLM {
        let selfId = (root["self"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultDevice
        let lm = PersonalLM(device: selfId, name: name, platform: platform)
        lm.clearedAt = (root["clearedAt"] as? NSNumber)?.int64Value ?? 0
        for te in (root["tables"] as? [[String: Any]]) ?? [] {
            let t = tableFromJSON(te)
            if t.device.isEmpty { continue }
            if t.device == selfId { t.name = name; t.platform = platform; lm.local = t }
            lm.tables[t.device] = t
        }
        lm.tables[lm.local.device] = lm.local
        lm.rebuild()
        lm.dirty = 0
        return lm
    }

    /// Самопроверка: таблица эталона (формат Personal.to_json) как единственная.
    static func fromReference(_ personal: [String: Any]) -> PersonalLM {
        let lm = PersonalLM(device: "selftest", name: "selftest", platform: "test")
        let t = tableFromJSON(personal, deviceOverride: "selftest")
        lm.local = t
        lm.tables = ["selftest": t]
        lm.rebuild()
        return lm
    }

    /// Слить слой из файла (импорт, синхронизация): чужие устройства — более свежая копия
    /// целиком, своё — не трогаем. Возвращает, сколько таблиц принято.
    @discardableResult
    func merge(_ personal: [String: Any]) -> Int {
        lock.lock(); defer { lock.unlock() }
        var taken = 0
        let cleared = (personal["clearedAt"] as? NSNumber)?.int64Value ?? 0
        if cleared > clearedAt {
            // На другом устройстве всё очистили позже — очищаем и здесь
            clearedAt = cleared
            for (key, t) in tables where t.updated < cleared {
                if key == local.device { resetLocal() } else { tables.removeValue(forKey: key) }
            }
        }
        for te in (personal["tables"] as? [[String: Any]]) ?? [] {
            let t = PersonalLM.tableFromJSON(te)
            if t.device.isEmpty || t.device == local.device || t.updated < clearedAt { continue }
            if let old = tables[t.device], old.updated >= t.updated { continue }
            tables[t.device] = t
            taken += 1
        }
        rebuild()
        dirty += 1
        return taken
    }

    private func resetLocal() {
        let fresh = PersonalTable(device: local.device, name: local.name, platform: local.platform)
        tables[local.device] = fresh
        local = fresh
    }

    /// Очистить весь слой (все устройства). При синхронизации очистка расходится по метке.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        clearedAt = Int64(Date().timeIntervalSince1970 * 1000)
        tables = [:]
        resetLocal()
        pending = nil; erased = nil; boostNext = false
        rebuild()
        dirty += 1
    }

    /// Сумма по устройствам заново (после загрузки, слияния, обрезки).
    private func rebuild() {
        sumUni = [[:], [:]]; sumBi = [[:], [:]]; sumTypo = [[:], [:]]; n = [0, 0]
        for t in tables.values {
            for i in 0..<2 {
                for (k, v) in t.uni[i] { PersonalLM.inc(&sumUni[i], k, v); n[i] += v }
                for (k, v) in t.bi[i] { PersonalLM.inc(&sumBi[i], k, v) }
                for (k, rights) in t.typo[i] {
                    for (rk, rv) in rights { PersonalLM.inc(&sumTypo[i][k, default: [:]], rk, rv) }
                }
            }
        }
    }

    /// Снимок для записи на диск. Заодно обрезает свою таблицу по потолкам.
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var pruned = false
        for i in 0..<2 {
            pruned = PersonalLM.prune(&local.uni[i], PersonalLM.maxUni) || pruned
            pruned = PersonalLM.prune(&local.bi[i], PersonalLM.maxBi) || pruned
            if local.typo[i].count > PersonalLM.maxTypo {
                let drop = local.typo[i].sorted { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) }
                    .prefix(local.typo[i].count - PersonalLM.maxTypo * 9 / 10).map { $0.key }
                for k in drop { local.typo[i].removeValue(forKey: k) }
                pruned = true
            }
        }
        if pruned { rebuild() }
        dirty = 0
        return toJSONLocked()
    }

    private static func prune(_ d: inout [String: Double], _ maxN: Int) -> Bool {
        guard d.count > maxN else { return false }
        var th = 1.0
        while d.count > maxN * 9 / 10 {
            d = d.filter { $0.value > th }
            th *= 2
        }
        return true
    }

    // MARK: диск — personal.qsp ("QSP1" + AES-GCM ключом из Keychain от JSON, сжатого DEFLATE)

    static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("QSwitcher/personal.qsp")
    }

    private static let magic = Data("QSP1".utf8)
    private static let saveQueue = DispatchQueue(label: "qswitcher.personal.save", qos: .utility)

    /// readOnly — для прогонов из командной строки: битый файл не трогать.
    static func load(readOnly: Bool = false) -> PersonalLM {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        let url = fileURL
        if let data = try? Data(contentsOf: url) {
            do {
                guard data.count > 4, data.prefix(4) == magic else { throw NSError(domain: "QSP", code: 1) }
                let plain = try SecureLogCrypto.decrypt(Data(data.dropFirst(4)))
                guard let raw = plain.decompressed(),
                      let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                    throw NSError(domain: "QSP", code: 2)
                }
                let lm = fromJSON(root, defaultDevice: UUID().uuidString, name: name, platform: "mac")
                let s = lm.stats()
                print("🧠 Личный слой: слов ru \(s.wordsRu), en \(s.wordsEn), пар \(s.pairs), опечаток \(s.typoForms), устройств \(s.devices)")
                return lm
            } catch {
                if readOnly {
                    print("⚠️ Личный слой не прочитался — прогон без него")
                } else {
                    let broken = url.appendingPathExtension("broken")
                    try? FileManager.default.removeItem(at: broken)
                    try? FileManager.default.moveItem(at: url, to: broken)
                    print("⚠️ Личный слой не прочитался — начинаю заново, старый файл: \(broken.path)")
                }
            }
        } else {
            print("🧠 Личный слой: пока пуст")
        }
        return PersonalLM(device: UUID().uuidString, name: name, platform: "mac")
    }

    private static func loadShared() -> PersonalLM {
        let lm = load()
        lm.modeSource = { Config.shared.personalMode }
        lm.swap = { Detector.shared.swap($0) }
        return lm
    }

    /// Записать (в фоне): снимок под замком слоя, шифрование и файл — вне его.
    func save(sync: Bool = false) {
        let snap = snapshot()
        let work = {
            guard let json = try? JSONSerialization.data(withJSONObject: snap, options: [.sortedKeys]),
                  let packed = json.compressed() else { return }
            do {
                let enc = try SecureLogCrypto.encrypt(packed)
                var out = PersonalLM.magic
                out.append(enc)
                let url = PersonalLM.fileURL
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try out.write(to: url, options: .atomic)
            } catch {
                print("⚠️ Личный слой не записался: \(error.localizedDescription)")
            }
        }
        if sync { PersonalLM.saveQueue.sync(execute: work) } else { PersonalLM.saveQueue.async(execute: work) }
    }

    private var timer: DispatchSourceTimer?

    /// Запись раз в 5 минут, если менялся.
    func startAutosave() {
        let t = DispatchSource.makeTimerSource(queue: PersonalLM.saveQueue)
        t.schedule(deadline: .now() + 300, repeating: 300)
        t.setEventHandler { [weak self] in
            guard let self = self, self.dirty > 0 else { return }
            self.save()
        }
        t.resume()
        timer = t
    }
}
