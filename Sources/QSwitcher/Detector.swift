import Foundation

/// Детектор раскладки. Портировано из keyswitcher (MIT, © Ilya Granin),
/// адаптировано под наш Config и Dictionary.
///
/// Возможности:
/// - Динамическая таблица транслита через LayoutResolver (поддержка любых раскладок)
/// - Словари RU/EN из Dictionary.shared (~146к и 48к слов)
/// - Список «плохих» n-грамм (~160к латинских + 80к кириллических подстрок,
///   которые в реальном языке практически не встречаются)
/// - Учёт контекста: смотрим на предыдущие набранные слова
/// - Обработка смешанных алфавитов (`;му` → `жму`, `'kkf` → `элла`)
/// - Ретроконверсия одиночных букв-предлогов
final class Detector {

    static let shared = Detector()

    private(set) var enToRu: [Character: Character] = [:]
    /// Карта по реальной раскладке без слияния с JSON — для свапа выделения.
    private var swapEnToRu: [Character: Character] = [:]
    private var swapRuToEn: [Character: Character] = [:]
    private(set) var ruToEn: [Character: Character] = [:]

    /// Плохие подстроки длиной 3-6, появление которых в слове сигнализирует
    /// о неправильной раскладке.
    private(set) var badLatin: Set<String> = []
    private(set) var badCyrillic: Set<String> = []

    private(set) var loaded = false

    private init() {
        load()
    }

    private func load() {
        // 1. Таблица транслитерации: динамическая через UCKeyTranslate + fallback на JSON
        let standardLayout = loadJSONFile(name: "layout_map", as: LayoutFile.self)
        let standardEnToRu = standardLayout.map { Detector.charMap($0.en_to_ru) } ?? [:]
        let standardRuToEn = standardLayout.map { Detector.charMap($0.ru_to_en) } ?? [:]

        if let dynamic = LayoutResolver.resolve() {
            print("📐 Раскладка: динамическая (en→ru: \(dynamic.enToRu.count), ru→en: \(dynamic.ruToEn.count))")
            self.enToRu = Detector.mergeMap(primary: dynamic.enToRu, fallback: standardEnToRu)
            self.ruToEn = Detector.mergeMap(primary: dynamic.ruToEn, fallback: standardRuToEn)
            // Свап выделения — только по реальной раскладке. В JSON зашита
            // ПК-раскладка ('`' → 'ё', '/' → '.'), а на маке '`' → ']', 'ё' на '\\',
            // '/' одинаков; слияние подменяло реальные пары «буквами из JSON».
            self.swapEnToRu = dynamic.enToRu
            self.swapRuToEn = dynamic.ruToEn
        } else {
            print("📐 Раскладка: используем JSON (динамическое определение не сработало)")
            self.enToRu = standardEnToRu
            self.ruToEn = standardRuToEn
            self.swapEnToRu = standardEnToRu
            self.swapRuToEn = standardRuToEn
        }

        // 2. Плохие n-граммы (натренированные триггеры)
        if let triggers = loadJSONFile(name: "bad_ngrams", as: TriggersFile.self) {
            badLatin = Set(triggers.latin)
            badCyrillic = Set(triggers.cyrillic)
            print("📊 Плохие n-граммы: \(badLatin.count) лат, \(badCyrillic.count) кир")
        } else {
            print("⚠️ bad_ngrams.json не найден — детектор будет работать слабее")
        }

        // 3. Частотные короткие слова (2-3 буквы)
        loadShortWords()

        loaded = !enToRu.isEmpty

        // 4. Сеть-детектор — грузим сразу, а не при первом слове: строки
        // «Сеть/selftest» должны быть в логе при старте, а первое решение
        // не должно платить за загрузку 8 МБ.
        _ = LayoutNet.shared
        _ = SemVec.shared
        _ = SemTopics.shared
        _ = SemProfile.shared
        // Ядро 5: частоты слов и символьная модель — тоже сразу, и самопроверка порта
        // в фоне: строка «Ядро 5 / самопроверка» в логе показывает, что решения
        // совпадают с эталоном на Python (nn/lm/model.py) на тех же данных.
        _ = NgramLM.shared
        _ = CharLM.shared
        if Core5.autoSelftest, let u = Core5.selftestURL {
            DispatchQueue.global(qos: .utility).async {
                let t0 = Date()
                let (n, bad) = Core5.selftest(url: u)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                print("🧪 Ядро 5 / самопроверка: \(n - bad)/\(n) совпало с эталоном (\(ms) мс)"
                      + (bad == 0 ? "" : " — ⚠️ порт расходится с nn/lm/model.py"))
            }
        }
    }


    // MARK: - Частотные короткие слова (2-3 буквы)
    //
    // Полный словарь на коротких словах бесполезен: в нём 437 двухбуквенных
    // «слов» вроде 'ут', 'аи', 'аш', и почти половина конфликтует с английскими
    // по раскладке. Принадлежность словарю там ничего не значит.
    //
    // Эти списки построены по частотным данным OpenSubtitles (ru_50k/en_50k):
    // слово попадает сюда если его реально печатают — либо оно частотно само
    // (>=20 на миллион), либо его свап в другом языке ещё реже. Тогда короткое
    // слово свапается только когда само нечастотное, а результат свапа частотный:
    // 'рук' защищено (55/млн), 'ут' нет (1.7/млн), а 'en' по ту сторону есть.
    static var commonShortRu: Set<String> = []
    static var commonShortEn: Set<String> = []

    private func loadShortWords() {
        Detector.commonShortRu = Detector.loadWordList(name: "short_ru")
        Detector.commonShortEn = Detector.loadWordList(name: "short_en")
        if Detector.commonShortRu.isEmpty || Detector.commonShortEn.isEmpty {
            print("⚠️ short_ru/short_en не найдены — короткие слова будут сверяться с полным словарём")
        } else {
            print("📏 Частотные короткие: ru=\(Detector.commonShortRu.count), en=\(Detector.commonShortEn.count)")
        }
    }

    private static func loadWordList(name: String) -> Set<String> {
        var urls: [URL] = []
        if let u = Bundle.main.url(forResource: name, withExtension: "txt") { urls.append(u) }
        if let r = Bundle.main.resourceURL {
            urls.append(r.appendingPathComponent("\(name).txt"))
            if let contents = try? FileManager.default.contentsOfDirectory(at: r, includingPropertiesForKeys: nil) {
                for item in contents where item.pathExtension == "bundle" {
                    urls.append(item.appendingPathComponent("Contents/Resources/\(name).txt"))
                    urls.append(item.appendingPathComponent("\(name).txt"))
                }
            }
        }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return Set(text.split(separator: "\n").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }.filter { !$0.isEmpty })
            }
        }
        return []
    }

    // MARK: - Транслитерация по физическим клавишам

    /// Преобразовать строку как если бы её набрали на другой раскладке.
    /// Учитывает смешанные алфавиты: «;му» (`;` на EN = `ж`) → «жму».
    func swap(_ s: String) -> String {
        let cyrLetters = s.filter(isCyrillicLetter).count
        let latLetters = s.filter(isLatinLetter).count
        let hasEnLayoutPunct = s.contains { ch in
            guard !isLatinLetter(ch), !isCyrillicLetter(ch) else { return false }
            guard let mapped = enToRu[ch] else { return false }
            return isCyrillicLetter(mapped)
        }

        // Смешанный текст с кириллицей → нормализуем к кириллице
        if cyrLetters > 0 && (latLetters > 0 || hasEnLayoutPunct) {
            return String(s.map { enToRu[$0] ?? $0 })
        }

        // Только кириллица → латиница
        if cyrLetters > 0 {
            return String(s.map { ruToEn[$0] ?? $0 })
        }

        // Только латиница (или EN-пунктуация маппящаяся на RU-букву) → кириллица
        return String(s.map { enToRu[$0] ?? ruToEn[$0] ?? $0 })
    }

    /// «Тупой» свап: каждый символ → его пара по физической клавише.
    /// Кириллица → латиница, латиница → кириллица. Для выделенного текста.
    /// Не пытается «нормализовать» смешанное — каждую букву меняет в свою сторону.
    func hardSwap(_ s: String, currentLang: InputSource.Lang? = nil) -> String {
        // Направление — по алфавиту текста. Знаки неоднозначны: '.' в русском
        // тексте — это RU-клавиша '/', а в латинском — EN-клавиша 'ю'. Раньше
        // любая точка считалась EN-клавишей, и «платформах.» → «gkfnajhvf[ю».
        // Букв нет (выделены одни знаки) — направление по текущей раскладке.
        let cyr = s.filter(isCyrillicLetter).count
        let lat = s.filter(isLatinLetter).count
        let textIsRu = (cyr == 0 && lat == 0) ? (currentLang == .ru) : cyr > lat
        // Только реальная раскладка: буква/знак → что на той же клавише в другой
        // ('[' → 'х', '\\' → 'ё', '"' → '@'); одинаков в обеих (пары нет) — та же
        // клавиша с Shift, как правый Option по кейкоду: '/' ↔ '?'. Ничего — как есть.
        let map = textIsRu ? swapRuToEn : swapEnToRu
        let pairs = LayoutResolver.shiftPairs(for: textIsRu ? .ru : .en)
        return String(s.map { ch -> Character in
            if isLatinLetter(ch) || isCyrillicLetter(ch) { return map[ch] ?? ch }
            return map[ch] ?? pairs[ch] ?? ch
        })
    }

    /// Свап только букв: каждая буква → что на той же клавише в другой раскладке
    /// (буква или знак: 'х' → '['), а знаки, цифры и пробелы остаются как есть.
    /// Для формул и кода, набранных не в той раскладке.
    func hardSwapLetters(_ s: String) -> String {
        return String(s.map { ch -> Character in
            if isLatinLetter(ch) { return swapEnToRu[ch] ?? ch }
            if isCyrillicLetter(ch) { return swapRuToEn[ch] ?? ch }
            return ch
        })
    }

    // MARK: - Главный детектор

    /// Решает: переключать или нет. Вызывается на границе слова.
    /// Возвращает true если надо вызвать swap() и заменить.
    /// Чем решилось последнее слово: "config" / "learned" — мимо профиля по правилу
    /// (на таком автопримеры не пишем), иначе пусто.
    static var lastReason = ""
    /// Клавиши → чтение, которое профиль уже разрешил в текущем предложении.
    /// Сбрасывается на границе предложения (Switcher) и в начале прогона.
    static var resolvedInSentence: [String: String] = [:]
    /// Профиль сказал «не уверен» — вопрос для LLM-арбитра (модуль «Full»).
    /// Switcher забирает его после решения и спрашивает асинхронно.
    static var pendingArbiter: Arbiter.Query?
    static func takePendingArbiter() -> Arbiter.Query? { defer { pendingArbiter = nil }; return pendingArbiter }

    static func shouldSwitch(word raw: String, currentLang: InputSource.Lang,
                             context: InputSource.Lang? = nil,
                             history: [String] = [], app: String? = nil,
                             topic: [String] = [], field: String = "") -> Bool {
        let cfg = Config.shared
        let lower = raw.lowercased()
        let layoutPunct: Set<Character> = [";", "[", "]", "'", "`", "\\", ",", "."]
        let effectiveChars = raw.filter { $0.isLetter || layoutPunct.contains($0) }

        Detector.lastReason = ""
        // Слово в конфиге с заглавными буквами — совпадение с учётом регистра
        // ("РФ" стопит только РФ, строчное рф уходит дальше), строчное — как раньше.
        func inList(_ list: Set<String>) -> Bool { list.contains(lower) || list.contains(raw) }
        if inList(cfg.forceWords) { Detector.lastReason = "config"; print("  [det] '\(raw)' в forceWords конфига → SWITCH"); return true }
        if inList(cfg.stopWords) { Detector.lastReason = "config"; print("  [det] '\(raw)' в stopWords конфига → keep"); return false }

        // Выученное на исправлениях пользователя. Важнее любых наших эвристик:
        // человек уже показал что он хочет для этого конкретного слова.
        // Исключение — коллизия, у которой профиль знает ОБА чтения: правило без
        // контекста для неё неверно по определению, решает контекст.
        let collision = cfg.semEnabled && SemVec.shared.loaded
            && ((LayoutNet.shared.keys(for: lower, ruToEn: shared.ruToEn).map { SemProfile.shared.readingCount(keys: $0) } ?? 0) >= 2
                || (cfg.semZeroShot && SemProfile.shared.isBaseCollision(typed: lower, swapped: shared.swap(lower))))
        if !collision, LearnedRules.shared.shouldForce(lower) {
            Detector.lastReason = "learned"
            print("  [det] '\(lower)' — выучено: переключаем")
            return true
        }
        if !collision, LearnedRules.shared.shouldStop(lower) {
            Detector.lastReason = "learned"
            print("  [det] '\(lower)' — выучено: не трогаем")
            return false
        }
        if collision, LearnedRules.shared.shouldForce(lower) || LearnedRules.shared.shouldStop(lower) {
            print("  [det] '\(lower)' — выученное правило есть, но это коллизия из профиля → решает контекст")
        }

        // Место ввода с жёстким ожиданием английского: терминал, редактор кода,
        // адресная строка, пароль, поле команд. Кириллица здесь — почти наверняка
        // забытая раскладка; редкие исключения закрывает root-отмена.
        if cfg.expectsEnglish(app: app, field: field) {
            let cyr = lower.contains { shared.isCyrillicLetter($0) }
            let where_ = field.isEmpty ? cfg.appClass(for: app).name : field
            if cyr {
                Detector.lastReason = "place"
                print("  [det] '\(raw)' кириллица в \(where_) → SWITCH (тут ждём английский)")
                return true
            }
            Detector.lastReason = "place"
            print("  [det] '\(raw)' латиница в \(where_) → keep")
            return false
        }

        // Одиночная буква — обрабатывается отдельно через контекст
        if effectiveChars.count == 1 {
            return shared.singleCharSwap(raw, context: context) != nil
        }

        guard effectiveChars.count >= cfg.minWordLength else { return false }

        if let r = shared.autoConvert(raw, context: context, history: history, app: app, topic: topic) {
            _ = r
            return true
        }
        // Первое слово в чате без контекста: скорее русское. Латиница, чей свап —
        // нормальное русское слово («yt» → «не», «lf» → «да»), переключается.
        if cfg.expectRussianInChat, history.isEmpty, cfg.appClass(for: app) == .chat,
           lower.allSatisfy({ shared.isLatinLetter($0) }) {
            let cand = shared.swap(lower)
            if Dictionary.shared.ru.contains(cand) || Detector.commonShortRu.contains(cand) {
                Detector.lastReason = "place"
                print("  [det] '\(raw)' первое слово в чате, свап '\(cand)' — русское слово → SWITCH")
                return true
            }
        }
        return false
    }

    /// Свап одиночной буквы-предлога с учётом контекста.
    /// Например, `f` после русских слов → `а` (предлог).
    /// Без контекста — не трогаем (могут быть EN `a`, `i`).
    func singleCharSwap(_ word: String, context: InputSource.Lang?) -> String? {
        guard let context = context else { return nil }
        let lower = word.lowercased()
        let singleRu: Set<String> = ["а", "и", "в", "к", "с", "о", "у", "я"]
        let singleEn: Set<String> = ["a", "i"]

        // Уже валидный предлог в каком-то языке — не трогаем
        if singleRu.contains(lower) || singleEn.contains(lower) { return nil }

        let swapped = swap(word)
        let swappedLow = swapped.lowercased()

        // Контекст RU и свап даёт RU-предлог → SWAP
        if singleRu.contains(swappedLow), context == .ru {
            return swapped
        }
        // Контекст EN и свап даёт EN-предлог → SWAP
        if singleEn.contains(swappedLow), context == .en {
            return swapped
        }
        return nil
    }

    /// Детектор. Возвращает свапнутую строку если надо переключить, иначе nil.
    /// Логика (по приоритету):
    ///   1. Слово смешанное → нормализуем (если результат — чистый алфавит)
    ///   2. Слово целиком в словаре текущего языка → не трогаем
    ///   3. Свап слова целиком есть в плохих триггерах → SWAP
    ///   4. Свап слова — валидное слово в другом языке → SWAP
    ///   5. Взвешенный score по плохим подстрокам → SWAP если перевешивает в 1.8 раз
    ///   6. Если контекст явно противоречит языку слова — SWAP
    func autoConvert(_ word: String, context: InputSource.Lang? = nil,
                     history: [String] = [], app: String? = nil, topic: [String] = []) -> String? {
        let dict = Dictionary.shared
        let lower = word.lowercased()

        guard lower.count >= 2 else { return nil }

        let isLatin = lower.allSatisfy { isLatinLetter($0) }
        let isCyrillic = lower.allSatisfy { isCyrillicLetter($0) }

        // (1) Смешанные алфавиты
        if !isLatin && !isCyrillic {
            let lettersLat = String(lower.filter { isLatinLetter($0) })
            let lettersCyr = String(lower.filter { isCyrillicLetter($0) })
            let hasLat = !lettersLat.isEmpty
            let hasCyr = !lettersCyr.isEmpty
            let hasEnLayoutPunct = lower.contains { ";[]'`\\,.".contains($0) }
            let isCandidate = (hasLat && hasCyr)
                           || (hasEnLayoutPunct && (hasLat || hasCyr))
            guard isCandidate else { return nil }

            // Если layout-пунктуация только в конце слова (как `Hello,`) — это настоящая
            // пунктуация. Не трогаем если буквенная часть в словаре.
            let layoutPunct: Set<Character> = [";", "[", "]", "'", "`", "\\", ",", "."]
            let firstIsLayoutPunct = lower.first.map { layoutPunct.contains($0) } ?? false
            if !firstIsLayoutPunct {
                if !hasCyr && hasLat && dict.en.contains(lettersLat) { return nil }
                if !hasLat && hasCyr && dict.ru.contains(lettersCyr) { return nil }
            }

            let normalized = swap(word)
            guard normalized.lowercased() != lower else { return nil }
            let normLow = normalized.lowercased()
            let normIsLat = normLow.allSatisfy { isLatinLetter($0) }
            let normIsCyr = normLow.allSatisfy { isCyrillicLetter($0) }
            if normIsLat || normIsCyr { return normalized }
            return nil
        }

        let len = lower.count

        // (0) Профиль чтений: клавиши, которые пользователь сам исправлял. Он знает
        // про ЭТИ клавиши больше любого словаря: чтение выбирается по левому
        // соседу, теме окна и регистру (семантические векторы), но только при
        // уверенном отрыве — иначе молчит, и дальше обычный порядок.
        let cfg = Config.shared
        if cfg.semEnabled, SemVec.shared.loaded,
           let keys = LayoutNet.shared.keys(for: lower, ruToEn: ruToEn) {
            let sem = SemVec.shared
            SemProfile.shared.clearExplain()
            let leftVec = history.first.map { sem.centered($0) }
            // Правила «второе вхождение тех же клавиш читается иначе» больше нет:
            // в живом тексте «РФ» повторяется десять раз подряд, и правило
            // честно чередовало РФ/HA по списку без точек.
            let used: Set<String> = []
            let d = SemProfile.shared.decide(keys: keys, typed: word, swapped: swap(word),
                                             topic: sem.topic(recentFirst: topic),
                                             left: leftVec, leftWord: history.first,
                                             usedInSentence: used, margin: Float(cfg.semMargin))
            if d == nil, SemProfile.shared.knows(keys: keys) || !SemProfile.shared.lastExplain.isEmpty {
                // Клавиши профилю известны, но уверенности нет — так и говорим,
                // иначе непонятно, почему «ничего не произошло».
                print("  [det] профиль знает '\(keys)', но уверенности нет: \(SemProfile.shared.lastExplain) (сосед '\(history.first ?? "—")', порог \(cfg.semMargin)) → дальше")
                // Это ровно тот случай для LLM-арбитра. Живой ввод — асинхронно
                // (Switcher), прогон — синхронно здесь же.
                let q = Arbiter.Query(typed: word, swapped: swap(word),
                                      left: Array(history.prefix(3)), topic: Array(topic.prefix(40)),
                                      app: cfg.appClass(for: app).name)
                if Arbiter.shared.syncMode, Arbiter.shared.available {
                    if let a = Arbiter.shared.ask(q, timeoutMs: 5000) {
                        let verdict = a.reading.map { "'\($0)'" } ?? "молчит"
                        print("  [det] арбитр → \(verdict) p=\(String(format: "%.2f", a.p)) \(a.ms) мс (\(a.raw))")
                        if let r = a.reading, a.p >= cfg.arbiterThreshold {
                            Detector.lastReason = "arbiter"
                            if r.lowercased() == swap(word).lowercased() { return swap(word) }
                            if r.lowercased() == lower { return nil }
                        }
                    } else {
                        print("  [det] арбитр не ответил")
                    }
                } else if cfg.arbiterEnabled {
                    Detector.pendingArbiter = q
                }
            }
            if let d = d {
                let candidate = swap(word)
                let leftWord = history.first ?? "—"
                if d.text == lower {
                    Detector.lastReason = "profile"
                    print("  [det] профиль \(d.explain) (сосед '\(leftWord)') → keep")
                    return nil
                }
                if d.text == candidate.lowercased() {
                    Detector.lastReason = "profile"
                    print("  [det] профиль \(d.explain) (сосед '\(leftWord)') → SWAP к '\(candidate)'")
                    return candidate
                }
                print("  [det] профиль \(d.explain) — чтение не совпало ни с '\(lower)', ни с '\(candidate)', пропускаю")
            }
        }

        // (0.9) N-граммы языка: «xnj» в английском корпусе нет, «что» — одно из
        // самых частых русских слов → свап первого слова без всякого контекста;
        // «ns» после «что» → пара «что ты» есть, «ns» нет → свап. Закрывает то,
        // где семантика слепа (двухбуквенные, первое слово), и стоит до щита —
        // иначе первая ошибка («Xnj» = латиница) отравляет контекст следующему.
        // Капс-аббревиатуры (РФ, HA, US, ТД) — не для n-грамм: в корпусе их нет,
        // а решение по ним — профиль и правила.
        let isCapsAbbrev = word.count <= 4 && word == word.uppercased() && word != word.lowercased()
        if cfg.ngramEnabled, NgramLM.shared.loaded, lower.count >= 2, !isCapsAbbrev,
           lower.allSatisfy({ $0.isLetter }) {
            let candidate = swap(word)
            let left = history.first(where: { !$0.isEmpty })
            if let (win, explain) = NgramLM.shared.decide(typed: lower, swapped: candidate.lowercased(),
                                                          left: left, margin: Float(cfg.ngramMargin)) {
                Detector.lastReason = "ngram"
                if win == lower {
                    print("  [det] n-грамм \(explain) (сосед '\(left ?? "—")') → keep")
                    return nil
                }
                print("  [det] n-грамм \(explain) (сосед '\(left ?? "—")') → SWAP к '\(candidate)'")
                return candidate
            } else if cfg.nnMode != "arbiter" {
                // Молчим — но объяснение полезно в прогоне.
                let (a, _) = NgramLM.shared.cost(lower, left: left)
                let (b, _) = NgramLM.shared.cost(candidate.lowercased(), left: left)
                print("  [det] n-грамм '\(lower)' \(String(format: "%.1f", a)) vs '\(candidate.lowercased())' \(String(format: "%.1f", b)) — разрыв мал → дальше")
            }
        }

        // (1а) Сеть — основной режим: решает до щита и словарей, если уверена.
        // Для коротких слов (≤3) порог строже (nnThresholdShort): ложный свап
        // короткого слова дороже пропуска. Не уверена — молчит.
        if cfg.nnMode != "arbiter",
           let verdict = netVerdict(word, lower: lower, isLatin: isLatin, history: history, app: app) {
            return verdict
        }

        // (1б) Щит коротких слов: короткое слово, НАБРАННОЕ В ЯЗЫКЕ КОНТЕКСТА,
        // против контекста не свапаем. Почти любая пара букв — чьё-то короткое
        // слово в другом языке ('ру' при ctx=ru свапалось в 'he', 'рф' → 'ha').
        // Стоит после сети: она, если уверена (строгий порог), знает про
        // контекст больше, чем язык соседей; не уверена — щит страхует.
        // Направление 'yt'→'не' при ctx=ru не задето: цель свапа = контекст.
        if len <= 3, let ctx = context, ctx == (isLatin ? .en : .ru) {
            print("  [det] '\(lower)' короткое, набрано в языке контекста (\(ctx)) → keep")
            return nil
        }

        // (2) Слово целиком валидно в текущем языке — не трогаем.
        //
        // Для 2-буквенных полный словарь не годится: в нём 2.35 млн слов вместе с
        // архаизмами и фамилиями, и почти любая пара букв формально «слово»
        // ('ут' — старое название ноты). Из-за этого глохла конвертация: набрал 'en',
        // получил 'ут', а свитчер считал что так и надо. Поэтому короткие сверяем
        // с компактным списком реально употребимых.
        let shortWord = lower.count <= 3
        if isLatin {
            let valid = (shortWord && !Detector.commonShortEn.isEmpty)
                ? Detector.commonShortEn.contains(lower) : dict.en.contains(lower)
            if valid {
                print("  [det] '\(lower)' валидное EN-слово → keep")
                return nil
            }
        }
        if isCyrillic {
            let valid = (shortWord && !Detector.commonShortRu.isEmpty)
                ? Detector.commonShortRu.contains(lower) : dict.ru.contains(lower)
            if valid {
                print("  [det] '\(lower)' валидное RU-слово → keep")
                return nil
            }
        }

        let candidate = swap(word)
        let candidateLower = candidate.lowercased()

        let triggers = isLatin ? badLatin : badCyrillic

        // (3) Слово целиком в плохих триггерах
        if triggers.contains(lower) {
            print("  [det] '\(lower)' в триггерах → SWAP к '\(candidate)'")
            return candidate
        }

        // (4) Свап есть в словаре другого языка
        // Логика по длине:
        // - 2 буквы: разрешаем свободно (yt → не, yf → на)
        //   2-буквенных EN-слов мало, и большинство уже в EN-словаре (it, is, of, in...)
        //   Если 2-буквенное не в EN-словаре, а свап есть в RU-словаре — почти точно промах раскладки.
        // - 3 буквы: требуем доп. подтверждения (защита от dmg → вьп):
        //   длина 4+, плохая n-грамма, или контекст
        // - 4+ букв: разрешаем
        let canSwap: Bool = {
            if len <= 2 { return true }
            if len >= 4 { return true }
            // len == 3: раньше требовался контекст, и это душило полезные случаи
            // ('dct'→'все', 'ljv'→'дом'). Проверка показала: все реальные аббревиатуры
            // (dmg, jpg, sql, api, git…) свапаются в бессмыслицу и отсекаются словарём.
            // Настоящих коллизий единицы (ltd→дев, ctv→сем), и они пишутся капсом —
            // от них защищает проверка регистра ниже.
            return true
        }()


        // (4а) щит коротких слов переехал выше сети — см. (1а)

        if isLatin && dict.ru.contains(candidateLower) {
            if canSwap {
                print("  [det] свап '\(candidate)' есть в RU (len=\(len), ctx=\(String(describing: context))) → SWAP")
                return candidate
            } else {
                print("  [det] свап '\(candidate)' в RU, но 3 буквы и нет подтверждения → keep")
            }
        }
        if isCyrillic && dict.en.contains(candidateLower) {
            if canSwap {
                print("  [det] свап '\(candidate)' есть в EN (len=\(len), ctx=\(String(describing: context))) → SWAP")
                return candidate
            } else {
                print("  [det] свап '\(candidate)' в EN, но 3 буквы и нет подтверждения → keep")
            }
        }

        // (5) Раньше тут было правило взвешенного score, но оно делало ложные свапы
        // валидных слов которых нет в словаре (пишешь → gbitim). Удалено: либо слово
        // в словаре другого языка (правило 4) → SWAP, либо ничего.

        // (6) Режим «арбитр»: сеть спрашиваем только когда словари промолчали.
        if cfg.nnMode == "arbiter",
           let verdict = netVerdict(word, lower: lower, isLatin: isLatin, history: history, app: app) {
            return verdict
        }

        print("  [det] '\(lower)' (свап='\(candidate)') не подошло ни одно правило → keep")
        return nil
    }

    // MARK: - Сеть

    /// Вердикт сети: свапнутая строка (SWAP), "" (уверенный keep) или nil (не уверена /
    /// выключена / слово не кодируется — решают словари). Порог и режим — из конфига.
    /// В логе всегда видно P(ru), контекст и класс приложения — решения остаются объяснимыми.
    private func netVerdict(_ word: String, lower: String, isLatin: Bool,
                            history: [String], app: String?) -> String?? {
        let cfg = Config.shared
        guard cfg.nnEnabled, LayoutNet.shared.loaded else { return nil }
        guard lower.count >= cfg.nnMinLen else { return nil }
        guard let keys = LayoutNet.shared.keys(for: lower, ruToEn: ruToEn) else { return nil }
        let ctx = history.prefix(3).map { LayoutNet.shared.ctxWord($0, ruToEn: ruToEn) }
        let appClass = cfg.appClass(for: app)
        let p = LayoutNet.shared.probabilityRu(keys: keys, ctx: Array(ctx), app: appClass, layoutRu: !isLatin)
        let intendedRu = p >= 0.5
        let conf = max(p, 1 - p)
        let ctxStr = history.prefix(3).joined(separator: " ")
        let tag = String(format: "P(ru)=%.3f", p)
        let threshold = lower.count <= 3 ? cfg.nnThresholdShort : cfg.nnThreshold
        guard conf >= Float(threshold) else {
            print("  [det] сеть \(tag) не уверена (порог \(threshold), ctx='\(ctxStr)', \(appClass.name)) → словари")
            return nil
        }
        if intendedRu == !isLatin {
            print("  [det] сеть \(tag) (ctx='\(ctxStr)', \(appClass.name)) → keep")
            return .some(nil)
        }
        let candidate = swap(word)
        print("  [det] сеть \(tag) (ctx='\(ctxStr)', \(appClass.name)) → SWAP к '\(candidate)'")
        return .some(candidate)
    }

    /// Сумма взвешенных совпадений плохих подстрок длины 3-6.
    /// Длинные совпадения весят больше (они дискриминативнее).
    private func weightedBadScore(in word: String, triggers: Set<String>) -> Int {
        let chars = Array(word)
        var score = 0
        for L in 3...6 where L <= chars.count {
            let weight = L - 2  // 3→1, 4→2, 5→3, 6→4
            let limit = chars.count - L
            for start in 0...limit {
                let sub = String(chars[start..<(start + L)])
                if triggers.contains(sub) { score += weight }
            }
        }
        return score
    }

    // MARK: - Helpers

    private func isLatinLetter(_ c: Character) -> Bool {
        return ("a"..."z").contains(c) || ("A"..."Z").contains(c)
    }

    private func isCyrillicLetter(_ c: Character) -> Bool {
        return ("а"..."я").contains(c) || c == "ё" || ("А"..."Я").contains(c) || c == "Ё"
    }

    // MARK: - JSON loading

    private struct LayoutFile: Decodable {
        let en_to_ru: [String: String]
        let ru_to_en: [String: String]
    }

    private struct TriggersFile: Decodable {
        let latin: [String]
        let cyrillic: [String]
    }

    private func loadJSONFile<T: Decodable>(name: String, as type: T.Type) -> T? {
        // Ищем так же как и словари — через Bundle и SwiftPM-bundle
        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: "json"),
            Bundle.main.resourceURL?.appendingPathComponent("\(name).json"),
        ]
        for url in candidates {
            guard let url = url, FileManager.default.fileExists(atPath: url.path) else { continue }
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(T.self, from: data) {
                return decoded
            }
        }
        // Поиск во вложенных бандлах
        if let resURL = Bundle.main.resourceURL,
           let contents = try? FileManager.default.contentsOfDirectory(at: resURL, includingPropertiesForKeys: nil) {
            for item in contents where item.pathExtension == "bundle" {
                let candidates = [
                    item.appendingPathComponent("Contents/Resources/\(name).json"),
                    item.appendingPathComponent("\(name).json"),
                ]
                for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                    if let data = try? Data(contentsOf: url),
                       let decoded = try? JSONDecoder().decode(T.self, from: data) {
                        return decoded
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Static helpers

    /// Мержит мапы: предпочитает primary, но если primary мапит пунктуацию на пунктуацию
    /// (а не на букву) — берёт fallback (где есть буква).
    /// Это спасает от кастомных раскладок где `.` → `,` вместо `.` → `ю`.
    private static func mergeMap(primary: [Character: Character],
                                  fallback: [Character: Character]) -> [Character: Character] {
        func isLetter(_ c: Character) -> Bool { c.isLetter }
        var out = fallback
        for (k, v) in primary {
            if let f = fallback[k] {
                if isLetter(v) || !isLetter(f) {
                    out[k] = v
                }
            } else {
                out[k] = v
            }
        }
        return out
    }

    private static func charMap(_ src: [String: String]) -> [Character: Character] {
        var out: [Character: Character] = [:]
        for (k, v) in src where k.count == 1 && v.count == 1 {
            out[k.first!] = v.first!
        }
        return out
    }
}

// MARK: - Ядро 5: решение по слову

extension Detector {

    /// Что должно стоять на экране после границы слова.
    struct Verdict {
        var shown: String
        /// Ядро 5 исправляет предыдущее слово задним числом: было retroFrom, станет retroPrev.
        var retroPrev: String? = nil
        var retroFrom: String? = nil
        var reason = ""
        var explain = ""
    }

    /// Решение для живого ввода и прогона.
    /// v5: решения человека (конфиг, выученные правила, поле пароля, список «английский
    /// ввод», обученный профиль) → ядро 5 (одна формула, Core5.swift).
    /// legacy: прежний каскад shouldSwitch, свап целиком.
    /// sepIsSpace — между предыдущим словом и этим на экране ровно один пробел.
    static func decide(word raw: String, currentLang: InputSource.Lang, context: InputSource.Lang?,
                       history: [String], app: String?, topic: [String], field: String,
                       sepIsSpace: Bool, core: Core5 = Core5.shared) -> Verdict {
        let cfg = Config.shared
        guard cfg.coreV5 else {
            let sw = shouldSwitch(word: raw, currentLang: currentLang, context: context,
                                  history: history, app: app, topic: topic, field: field)
            return Verdict(shown: sw ? shared.swap(raw) : raw, reason: lastReason)
        }
        let lower = raw.lowercased()
        let swapped = shared.swap(raw)
        Detector.lastReason = ""
        func external(_ shown: String, _ reason: String, confident: Bool = true) -> Verdict {
            Detector.lastReason = reason
            core.noteExternal(typed: raw, shown: shown, confident: confident)
            return Verdict(shown: shown, reason: reason)
        }

        // 1. Списки из конфига. Слово с заглавными — с учётом регистра ("РФ" ≠ "рф").
        func inList(_ list: Set<String>) -> Bool { list.contains(lower) || list.contains(raw) }
        if inList(cfg.forceWords) {
            print("  [det] '\(raw)' в forceWords конфига → SWITCH")
            return external(swapped, "config")
        }
        if inList(cfg.stopWords) {
            print("  [det] '\(raw)' в stopWords конфига → keep")
            return external(raw, "config")
        }

        // 2. Выученное жёстким правилом (хоткей «свап и правило»). Коллизия, у которой
        // профиль знает оба чтения, — решает контекст, не правило.
        let collision = cfg.semEnabled && SemVec.shared.loaded
            && ((LayoutNet.shared.keys(for: lower, ruToEn: shared.ruToEn).map { SemProfile.shared.readingCount(keys: $0) } ?? 0) >= 2
                || (cfg.semZeroShot && SemProfile.shared.isBaseCollision(typed: lower, swapped: swapped.lowercased())))
        if !collision, LearnedRules.shared.shouldForce(lower) {
            print("  [det] '\(lower)' — выучено: переключаем")
            return external(swapped, "learned")
        }
        if !collision, LearnedRules.shared.shouldStop(lower) {
            print("  [det] '\(lower)' — выучено: не трогаем")
            return external(raw, "learned")
        }

        // 3. Жёстко английский: поле пароля (и другие поля из expectEnglishFields, кроме
        // адресной строки) и приложения из списка «английский ввод». Терминал, код и
        // адресная строка — не правило, а сильное ожидание в ядре: русский промпт в
        // терминале и русский запрос в адресной строке остаются русскими.
        let appLower = app?.lowercased() ?? ""
        let hardField = field != "address" && !field.isEmpty && cfg.expectEnglishFields.contains(field)
        if hardField || (!appLower.isEmpty && cfg.expectEnglishBundles.contains(where: { appLower.contains($0) })) {
            let cyr = lower.contains { shared.isCyrillicLetter($0) }
            let where_ = hardField ? field : "список «английский ввод»"
            print("  [det] '\(raw)' \(cyr ? "кириллица" : "латиница") в \(where_) → \(cyr ? "SWITCH (тут английский)" : "keep")")
            return external(cyr ? swapped : raw, "place")
        }

        // 4. Кириллица вперемешку с латиницей / знаками EN-раскладки в одном слове —
        // нормализация к одному алфавиту (';му' → 'жму'), как раньше.
        if let mixed = shared.mixedVerdict(raw) {
            if let m = mixed {
                print("  [det] '\(raw)' смешанные алфавиты → '\(m)'")
                return external(m, "mixed")
            }
            print("  [det] '\(raw)' смешанные алфавиты — нормализовать нечем → keep")
            return external(raw, "mixed", confident: false)
        }

        // 4а. Адрес сайта, набранный в русской раскладке: «пщщпдуюсщь» → «google.com».
        // Модель языка адрес не оценит (точка — не буква); зона из списка и то, что
        // набранное — не русское слово, отсекают «клюем» → «rk.tv» и подобное.
        if lower.contains(where: { shared.isCyrillicLetter($0) }), Detector.looksLikeDomain(swapped),
           NgramLM.shared.uniD("ru", lower) == nil {
            print("  [det] '\(raw)' — адрес '\(swapped)' в русской раскладке → SWITCH")
            return external(swapped, "domain")
        }

        // 5. Профиль: клавиши, которые человек сам учил (HA/РФ…). Он знает про ЭТИ
        // клавиши больше любой модели. Не уверен — решает ядро, а вопрос уходит
        // LLM-арбитру (модуль «Full»), если он подключён.
        if cfg.semEnabled, SemVec.shared.loaded,
           let keys = LayoutNet.shared.keys(for: lower, ruToEn: shared.ruToEn),
           SemProfile.shared.knows(keys: keys) {
            let sem = SemVec.shared
            SemProfile.shared.clearExplain()
            let leftVec = history.first.map { sem.centered($0) }
            let d = SemProfile.shared.decide(keys: keys, typed: raw, swapped: swapped,
                                             topic: sem.topic(recentFirst: topic),
                                             left: leftVec, leftWord: history.first,
                                             usedInSentence: [], margin: Float(cfg.semMargin))
            let leftWord = history.first ?? "—"
            if let d = d {
                if d.text == lower {
                    print("  [det] профиль \(d.explain) (сосед '\(leftWord)') → keep")
                    return external(raw, "profile")
                }
                if d.text == swapped.lowercased() {
                    print("  [det] профиль \(d.explain) (сосед '\(leftWord)') → SWAP к '\(swapped)'")
                    return external(swapped, "profile")
                }
                print("  [det] профиль \(d.explain) — чтение не совпало ни с '\(lower)', ни с '\(swapped)' → ядро")
            } else {
                print("  [det] профиль знает '\(keys)', но уверенности нет: \(SemProfile.shared.lastExplain) (сосед '\(leftWord)', порог \(cfg.semMargin)) → ядро")
                let q = Arbiter.Query(typed: raw, swapped: swapped,
                                      left: Array(history.prefix(3)), topic: Array(topic.prefix(40)),
                                      app: cfg.appClass(for: app).name)
                if Arbiter.shared.syncMode, Arbiter.shared.available {
                    if let a = Arbiter.shared.ask(q, timeoutMs: 5000) {
                        let verdict = a.reading.map { "'\($0)'" } ?? "молчит"
                        print("  [det] арбитр → \(verdict) p=\(String(format: "%.2f", a.p)) \(a.ms) мс (\(a.raw))")
                        if let r = a.reading, a.p >= cfg.arbiterThreshold {
                            if r.lowercased() == swapped.lowercased() { return external(swapped, "arbiter") }
                            if r.lowercased() == lower { return external(raw, "arbiter") }
                        }
                    } else {
                        print("  [det] арбитр не ответил")
                    }
                } else if cfg.arbiterEnabled {
                    Detector.pendingArbiter = q
                }
            }
        }

        // 6. Ядро 5.
        let T = Core5.lang(raw)
        guard !T.isEmpty else { return Verdict(shown: raw, reason: "") }     // ни одной буквы — не слово
        let n = Core5.letters(raw, T)
        if cfg.minWordLength > 2, n > 1, n < cfg.minWordLength {
            print("  [det] '\(raw)' короче minWordLength=\(cfg.minWordLength) → keep")
            return external(raw, "config", confident: false)
        }
        let d = core.decide(typed: raw, alt: swapped, T: T, sepIsSpace: sepIsSpace,
                            swap: { shared.swap($0) })
        Detector.lastReason = "core5"
        print("  [det] ядро5: \(d.explain)")
        return Verdict(shown: d.shown, retroPrev: d.retroPrev, retroFrom: d.retroFrom,
                       reason: "core5", explain: d.explain)
    }

    /// Зоны, по которым строка считается адресом сайта. Без tv/cn/cs/cm и подобных:
    /// «клюем» по раскладке — «rk.tv», «каюсь» — «rf.cm», «Андрюше» — «fylh.it».
    static let domainZones: Set<String> = [
        "com", "ru", "org", "net", "io", "dev", "app", "info", "me", "co", "ai", "gg", "xyz",
        "site", "online", "tech", "pro", "biz", "edu", "gov", "eu", "us", "uk", "de", "fi", "su",
        "by", "ua", "fr", "es", "nl", "se", "no", "pl", "jp", "ca", "au", "ch", "be",
        "cloud", "store", "blog", "ly", "sh", "gl", "so", "to", "am", "in",
    ]

    /// «google.com», «www.youtube.com», «mail.yandex.ru» — метки из латиницы/цифр/дефиса
    /// через точку, первая не короче двух символов, последняя — известная зона.
    static func looksLikeDomain(_ s: String) -> Bool {
        let l = s.lowercased()
        guard l.count >= 5 else { return false }
        let labels = l.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels[0].count >= 2,
              let zone = labels.last, domainZones.contains(String(zone)) else { return false }
        for lab in labels {
            guard !lab.isEmpty, lab.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
            else { return false }
        }
        return true
    }

    /// Кириллица вперемешку с латиницей или знаками EN-раскладки: нормализуем к одному
    /// алфавиту. nil — слово не смешанное; .some(nil) — смешанное, но менять нечем.
    fileprivate func mixedVerdict(_ word: String) -> String?? {
        let lower = word.lowercased()
        let layoutPunct: Set<Character> = [";", "[", "]", "'", "`", "\\", ",", "."]
        let hasCyr = lower.contains { isCyrillicLetter($0) }
        let hasLat = lower.contains { isLatinLetter($0) }
        let hasEnPunct = lower.contains { layoutPunct.contains($0) }
        guard hasCyr && (hasLat || hasEnPunct) else { return nil }
        let firstIsLayoutPunct = lower.first.map { layoutPunct.contains($0) } ?? false
        let lettersCyr = String(lower.filter { isCyrillicLetter($0) })
        // «привет,» — настоящая пунктуация после русского слова
        if !firstIsLayoutPunct && !hasLat && Dictionary.shared.ru.contains(lettersCyr) { return .some(nil) }
        let normalized = swap(word)
        let nl = normalized.lowercased()
        guard nl != lower else { return .some(nil) }
        if nl.allSatisfy({ isLatinLetter($0) }) || nl.allSatisfy({ isCyrillicLetter($0) }) { return .some(normalized) }
        return .some(nil)
    }
}

// MARK: - Translit compatibility

/// Старый интерфейс Translit, чтобы не ломать остальной код.
/// Делегирует на Detector.shared.swap().
enum Translit {
    static func toRu(_ s: String) -> String {
        Detector.shared.swap(s)
    }
    static func toEn(_ s: String) -> String {
        Detector.shared.swap(s)
    }
}
