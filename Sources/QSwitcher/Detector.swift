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

    static func shouldSwitch(word raw: String, currentLang: InputSource.Lang,
                             context: InputSource.Lang? = nil,
                             history: [String] = [], app: String? = nil,
                             topic: [String] = []) -> Bool {
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

        // Одиночная буква — обрабатывается отдельно через контекст
        if effectiveChars.count == 1 {
            return shared.singleCharSwap(raw, context: context) != nil
        }

        guard effectiveChars.count >= cfg.minWordLength else { return false }

        return shared.autoConvert(raw, context: context, history: history, app: app, topic: topic) != nil
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
            let d = SemProfile.shared.decide(keys: keys, typed: word, swapped: swap(word),
                                             topic: sem.topic(recentFirst: topic),
                                             left: leftVec, leftWord: history.first, margin: Float(cfg.semMargin))
            if d == nil, SemProfile.shared.knows(keys: keys) || !SemProfile.shared.lastExplain.isEmpty {
                // Клавиши профилю известны, но уверенности нет — так и говорим,
                // иначе непонятно, почему «ничего не произошло».
                print("  [det] профиль знает '\(keys)', но уверенности нет: \(SemProfile.shared.lastExplain) (сосед '\(history.first ?? "—")', порог \(cfg.semMargin)) → дальше")
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
