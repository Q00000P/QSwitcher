import Cocoa
import Carbon

/// Центральный модуль: глобальный event tap, буфер слова, перенабор,
/// undo, double-shift hotkey, смена регистра, транслит.
final class Switcher {

    private struct Keystroke {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        let chars: String
    }

    /// Состояние последнего свитча, держится пока не разрушится контекст.
    /// state переключается между .converted и .original при каждом тоггле.
    private final class LastSwitch {
        let originalChars: String
        let convertedChars: String
        let triggerKeyCode: CGKeyCode
        var state: ToggleState
        var timestamp: Date

        init(originalChars: String, convertedChars: String, triggerKeyCode: CGKeyCode, state: ToggleState) {
            self.originalChars = originalChars
            self.convertedChars = convertedChars
            self.triggerKeyCode = triggerKeyCode
            self.state = state
            self.timestamp = Date()
        }
    }

    enum ToggleState {
        case original   // в документе сейчас исходный текст
        case converted  // в документе сейчас конвертированный текст
    }

    private static let magic: Int64 = 0x4150_5357

    /// Краткая метка времени для логов (HH:mm:ss).
    static func ts() -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: Date())
    }

    /// Окно в секундах для отмены последнего автопереключения по Esc.
    private static let undoWindow: TimeInterval = 10.0

    /// Максимальное удержание модификатора, при котором считаем «короткое нажатие».
    private static let modifierTapWindow: TimeInterval = 0.5

    /// keyCode правого Option = 61 (kVK_RightOption)
    private static let rightOptionKey: CGKeyCode = 61
    /// keyCode левого Option тоже принимаем (некоторые маки имеют только левый)
    private static let leftOptionKey: CGKeyCode = 58

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var word: [Keystroke] = []
    private var lastSwitch: LastSwitch?

    /// Состояние трекинга «короткого» нажатия модификатора.
    private var modifierPressTime: Date?

    /// Дебаунс ручного свапа — защита от двойного срабатывания Option.
    private var lastManualSwitchTime: Date = .distantPast
    private static let debounceWindow: TimeInterval = 0.35
    private var modifierContaminated: Bool = false
    private var trackedModifierKey: CGKeyCode?

    /// Последнее завершённое слово (с триггером), которое детектор оставил без свапа.
    /// Хранится чтобы Option мог сделать ручной свап задним числом — даже после пробела,
    /// пока пользователь не начал что-то ещё печатать.
    private struct LastCompletedWord {
        let chars: String
        let triggerKeyCode: CGKeyCode
        let lang: InputSource.Lang
    }
    private var lastCompletedWord: LastCompletedWord?

    /// Сохранённое содержимое буфера обмена для отложенного восстановления.
    private var lastSavedClipboard: [NSPasteboardItem]?

    /// История последних N набранных слов для определения контекста (RU vs EN).
    private var wordHistory: [String] = []
    private let historyCapacity = 5

    private(set) var lastUserAppBundleId: String?
    private(set) var currentLang: InputSource.Lang = .en

    var onLanguageChanged: ((InputSource.Lang) -> Void)?

    // MARK: - Lifecycle

    func start() {
        // Слушаем keyDown И flagsChanged (для дабл-Shift)
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let cb: CGEventTapCallBack = { _, type, event, ctx in
            let me = Unmanaged<Switcher>.fromOpaque(ctx!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cb,
            userInfo: userInfo
        ) else {
            fputs("❌ Не удалось создать event tap. Проверь права Accessibility.\n", stderr)
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lastUserAppBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        currentLang = InputSource.currentLanguage()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceDidChange),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )

        print("✅ AutoSwitcher активен. Option (одиночное нажатие) — переключить, Esc — отменить.")
    }

    @objc private func appDidActivate(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        lastUserAppBundleId = app.bundleIdentifier
        word.removeAll()
        wordHistory.removeAll()
        lastSwitch = nil
        lastCompletedWord = nil
    }

    @objc private func inputSourceDidChange() {
        let new = InputSource.currentLanguage()
        if new != currentLang {
            currentLang = new
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onLanguageChanged?(self.currentLang)
            }
        }
    }

    private var isCurrentAppExcluded: Bool {
        guard let bid = lastUserAppBundleId else { return false }
        return Config.shared.excludedApps.contains(bid)
    }

    // MARK: - Tap handler

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // === flagsChanged: ловим одиночный тап Option ===
        if type == .flagsChanged {
            if event.getIntegerValueField(.eventSourceUserData) == Switcher.magic {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            // Принимаем оба Option (левый 58 и правый 61), но по умолчанию ждём правый
            if keyCode == Switcher.rightOptionKey || keyCode == Switcher.leftOptionKey {
                let isPressed = event.flags.contains(.maskAlternate)
                if isPressed {
                    // Нажали — стартуем трекинг
                    modifierPressTime = Date()
                    modifierContaminated = false
                    trackedModifierKey = keyCode
                } else {
                    // Отпустили — проверяем условия
                    if let pressTime = modifierPressTime,
                       trackedModifierKey == keyCode,
                       !modifierContaminated {
                        let held = Date().timeIntervalSince(pressTime)
                        // Дебаунс: игнорируем повторные срабатывания в пределах окна
                        // (железо/система иногда шлёт два press/release подряд → held≈0)
                        let sinceLast = Date().timeIntervalSince(lastManualSwitchTime)
                        if held < Switcher.modifierTapWindow && sinceLast > Switcher.debounceWindow {
                            lastManualSwitchTime = Date()
                            let isLeft = (keyCode == Switcher.leftOptionKey)
                            let side = isLeft ? "левый" : "правый"
                            print("[\(Switcher.ts())] [opt-tap] \(side) Option (held=\(String(format: "%.3f", held))s)")
                            DispatchQueue.main.async { [weak self] in
                                if isLeft {
                                    // Левый Option — ТОЛЬКО свап выделения (мышкой)
                                    self?.handleSelectionSwap()
                                } else {
                                    // Правый Option — свап набранного / тоггл
                                    self?.handleBufferSwap()
                                }
                            }
                        }
                    }
                    modifierPressTime = nil
                    modifierContaminated = false
                    trackedModifierKey = nil
                }
            } else {
                // Любой другой модификатор-чейндж во время удержания Option = «загрязнение»
                if modifierPressTime != nil {
                    modifierContaminated = true
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        if event.getIntegerValueField(.eventSourceUserData) == Switcher.magic {
            return Unmanaged.passUnretained(event)
        }

        // Любое нажатие настоящей клавиши во время удержания модификатора —
        // «загрязняет» удержание (это уже шорткат, не одиночный тап)
        if modifierPressTime != nil {
            modifierContaminated = true
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // === Esc для отмены последнего свитча (тоггл) ===
        if keyCode == 53 /* Escape */ {
            if let last = lastSwitch,
               Date().timeIntervalSince(last.timestamp) < Switcher.undoWindow {
                // НЕ обнуляем lastSwitch — оставляем чтобы можно было ещё раз тоггнуть
                word.removeAll()
                DispatchQueue.main.async { [weak self] in self?.toggleLastSwitch(last) }
                return nil
            }
            // Иначе пропускаем Esc как обычно
            word.removeAll()
            return Unmanaged.passUnretained(event)
        }

        // === ⌃⇧U — смена регистра выделенного ===
        if keyCode == 32 /* U */,
           flags.contains(.maskControl),
           flags.contains(.maskShift) {
            DispatchQueue.main.async { [weak self] in self?.toggleSelectionCase() }
            return nil
        }

        // === ⌃⇧T — транслит выделенного ===
        if keyCode == 17 /* T */,
           flags.contains(.maskControl),
           flags.contains(.maskShift) {
            DispatchQueue.main.async { [weak self] in self?.transliterateSelection() }
            return nil
        }

        if !Config.shared.enabled || isCurrentAppExcluded {
            word.removeAll()
            return Unmanaged.passUnretained(event)
        }

        // ⌘⇧Space — универсальная альтернатива: сначала выделение, потом буфер
        if keyCode == 49,
           flags.contains(.maskCommand),
           flags.contains(.maskShift) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let sel = self.readSelection(restoreClipboard: false), !sel.isEmpty, sel.count <= 5000 {
                    self.word.removeAll()
                    self.lastSwitch = nil
                    self.lastCompletedWord = nil
                    self.swapSelectedText(sel)
                } else {
                    self.handleBufferSwap()
                }
            }
            return nil
        }

        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            word.removeAll()
            return Unmanaged.passUnretained(event)
        }

        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        let chars = len > 0 ? String(utf16CodeUnits: buf, count: len) : ""

        // === Логирование нажатий в SecureLog ===
        // Если включён лог и (logSecureInput=true ИЛИ не в secure-input поле)
        if Config.shared.logEnabled, !chars.isEmpty {
            let inSecure = IsSecureEventInputEnabled()
            if Config.shared.logSecureInput || !inSecure {
                let app = lastUserAppBundleId ?? "?"
                let secureMark = inSecure ? " [SECURE]" : ""
                SecureLog.shared.append("[key]\(secureMark) '\(chars)' kc=\(keyCode) app=\(app)")
            }
        }

        if keyCode == 51 /* Backspace */ {
            if !word.isEmpty { word.removeLast() }
            lastSwitch = nil
            lastCompletedWord = nil
            return Unmanaged.passUnretained(event)
        }

        // EN-пунктуация которая на RU-раскладке даёт букву.
        // Эти символы — часть слова, не граница: `[h.` (хр.), `;му` (жму), `'kkf` (элла).
        let layoutPunctChars: Set<Character> = [";", "[", "]", "'", "`", "\\", ",", "."]
        let firstChar = chars.first
        let isLayoutPunct = firstChar.map { layoutPunctChars.contains($0) } ?? false

        // Граница слова: пробел/Enter/Tab или «настоящая» пунктуация (но не layout-pun)
        let isWordEnd =
            keyCode == 49 || keyCode == 36 || keyCode == 76 || keyCode == 48 ||
            (isPunctuation(chars) && !isLayoutPunct)

        if isWordEnd {
            if !word.isEmpty {
                let text = word.map { $0.chars }.joined()
                let cur = InputSource.currentLanguage()
                // Обновляем контекст: добавляем слово в историю ДО решения о свапе
                // (для самого слова контекст = что было ДО него)
                let context = computeContext()
                let willSwitch = Detector.shouldSwitch(word: text, currentLang: cur, context: context)
                print("[\(Switcher.ts())] [boundary] '\(text)' (\(cur), ctx=\(context.map { String(describing: $0) } ?? "nil")) → \(willSwitch ? "SWITCH" : "keep")")
                SecureLog.shared.append("[boundary] '\(text)' (\(cur)) → \(willSwitch ? "SWITCH" : "keep")")
                if willSwitch {
                    let replay = word
                    let trigger = Keystroke(keyCode: keyCode, flags: flags, chars: chars)
                    word.removeAll()
                    // В истории сохраняем уже свапнутую версию
                    let swapped = Detector.shared.swap(text)
                    appendToHistory(swapped)
                    DispatchQueue.main.async { [weak self] in
                        self?.performSwitch(replay: replay, trigger: trigger, fromLang: cur)
                    }
                    return nil
                }
                // Не свапаем — добавляем как есть и запоминаем для возможного ручного свапа
                appendToHistory(text)
                lastCompletedWord = LastCompletedWord(
                    chars: text,
                    triggerKeyCode: keyCode,
                    lang: cur
                )
                word.removeAll()
            }
            lastSwitch = nil
            return Unmanaged.passUnretained(event)
        }

        let resetKeys: Set<CGKeyCode> = [
            123, 124, 125, 126,
            115, 116, 117, 119, 121,
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111
        ]
        if resetKeys.contains(keyCode) {
            word.removeAll()
            lastSwitch = nil
            lastCompletedWord = nil
            return Unmanaged.passUnretained(event)
        }

        if !chars.isEmpty {
            word.append(Keystroke(keyCode: keyCode, flags: flags, chars: chars))
        }
        return Unmanaged.passUnretained(event)
    }

    private func isPunctuation(_ s: String) -> Bool {
        guard let c = s.first else { return false }
        if c.isLetter || c.isNumber { return false }
        return c.isPunctuation || c.isSymbol
    }

    /// Добавить слово в историю и обрезать до capacity.
    private func appendToHistory(_ word: String) {
        wordHistory.append(word)
        if wordHistory.count > historyCapacity {
            wordHistory.removeFirst()
        }
    }

    /// Доминирующий язык в недавнем контексте (последние 3 слова).
    /// Возвращает nil если данных мало.
    private func computeContext() -> InputSource.Lang? {
        let recent = wordHistory.suffix(3)
        var cyr = 0, lat = 0
        for w in recent {
            for c in w {
                if ("а"..."я").contains(c) || c == "ё" || ("А"..."Я").contains(c) || c == "Ё" {
                    cyr += 1
                } else if ("a"..."z").contains(c) || ("A"..."Z").contains(c) {
                    lat += 1
                }
            }
        }
        guard cyr + lat >= 2 else { return nil }
        if cyr > lat { return .ru }
        if lat > cyr { return .en }
        return nil
    }

    /// Двойной Shift / ⌘⇧Space:
    /// Тоггл по Option. Приоритеты:
    /// 1. Выделение → свапаем выделение БЕЗУСЛОВНО
    /// 2. В буфере есть новое слово → свапаем его (тоггл прошлого свитча отменяется)
    /// 3. Тоггл последнего автосвитча (туда-обратно)
    /// 4. Последнее завершённое слово (после пробела)
    /// 5. Ничего
    /// ЛЕВЫЙ Option — свап выделенного мышкой текста. Только это, ничего больше.
    /// Не лезет в буфер набора и не тоггает — если выделения нет, просто ничего.
    private func handleSelectionSwap() {
        // ВАЖНО: readSelection/writeSelection шлют ⌘C/⌘V и ждут доставки циклами usleep.
        // На главном потоке это замораживает RunLoop → события не доставляются →
        // буфер не меняется. Поэтому ВСЯ операция (чтение + запись) в фоне.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let selected = self.readSelection(restoreClipboard: false),
                  !selected.isEmpty, selected.count <= 5000 else {
                print("[selSwap] нет выделения — ничего")
                return
            }
            print("[selSwap] выделение (\(selected.count) симв) → swap")
            DispatchQueue.main.async {
                self.word.removeAll()
                self.lastSwitch = nil
                self.lastCompletedWord = nil
            }
            // Свап и запись тоже в фоне (внутри usleep для ⌘V)
            self.swapSelectedTextSync(selected)
        }
    }

    /// ПРАВЫЙ Option — свап набранного / тоггл. Не трогает выделение вообще
    /// (не дёргает ⌘C), поэтому работает стабильно.
    private func handleBufferSwap() {
        // 1. Буфер содержит новое слово
        if !word.isEmpty {
            print("[bufSwap] свап буфера ('\(word.map{$0.chars}.joined())')")
            lastSwitch = nil
            forceSwitchLastWord()
            return
        }
        // 2. Тоггл последнего свитча
        if let last = lastSwitch {
            print("[bufSwap] тоггл последнего свитча")
            toggleLastSwitch(last)
            return
        }
        // 3. Последнее завершённое слово
        if let lastWord = lastCompletedWord {
            print("[bufSwap] свап последнего завершённого слова '\(lastWord.chars)'")
            swapLastCompletedWord(lastWord)
            return
        }
        print("[bufSwap] нечего свапать")
    }

    /// Свапнуть последнее завершённое слово задним числом.
    /// Курсор сейчас стоит ПОСЛЕ триггера (например после пробела).
    /// Удаляем триггер + слово, печатаем свапнутое слово + тот же триггер.
    private func swapLastCompletedWord(_ last: LastCompletedWord) {
        let original = last.chars
        let translated = Detector.shared.swap(original)
        guard translated != original else {
            print("[manual-completed] свап равен оригиналу — нечего менять")
            return
        }

        let target: InputSource.Lang = (last.lang == .ru) ? .en : .ru
        let triggerCount = (last.triggerKeyCode != 0) ? 1 : 0
        let toDelete = original.count + triggerCount

        sendBackspaces(toDelete)
        InputSource.switchTo(target)

        for ch in translated {
            postUnicode(String(ch))
            usleep(3_000)
        }

        // Возвращаем триггер
        if last.triggerKeyCode != 0 {
            postVirtualKey(last.triggerKeyCode)
        }

        // Сохраняем как тоггл-состояние, чтобы Option повторно можно было откатить назад
        lastSwitch = LastSwitch(
            originalChars: original,
            convertedChars: translated,
            triggerKeyCode: last.triggerKeyCode,
            state: .converted
        )
        lastCompletedWord = nil
        playSound()
        print("[manual-completed] '\(original)' → '\(translated)'")
    }

    /// Свапнуть выделенный текст в другую раскладку — БЕЗУСЛОВНО.
    /// Каждый символ меняется на пару по физической клавише.
    /// Не проверяет словари, не пытается «понять» что это.
    /// Просто механический свап как при печати в другой раскладке.
    private func swapSelectedText(_ text: String) {
        swapSelectedTextSync(text)
    }

    /// Свап выделенного. Вызывается из фонового потока (usleep для ⌘V не блокирует main).
    private func swapSelectedTextSync(_ text: String) {
        let swapped = Detector.shared.hardSwap(text)
        guard swapped != text else {
            print("[manual-sel] свап равен оригиналу — нечего менять")
            return
        }

        // Целевая раскладка — по тому что получилось после свапа
        let cyrCount = swapped.filter { ("а"..."я").contains($0) || $0 == "ё"
                                       || ("А"..."Я").contains($0) || $0 == "Ё" }.count
        let latCount = swapped.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
        let target: InputSource.Lang? = cyrCount > latCount ? .ru : (latCount > cyrCount ? .en : nil)

        print("[manual-sel] '\(text.prefix(40))' → '\(swapped.prefix(40))'")
        writeSelection(swapped)

        if let target = target {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                InputSource.switchTo(target)
            }
        }
        playSound()
    }

    // MARK: - Switching (Unicode-based)

    /// Цепочка ретроконверсии: одиночные буквы перед текущим словом, которые
    /// после свапа становятся валидными предлогами целевого языка.
    /// Возвращает массив пар (оригинал, свап) от старого к новому.
    private func retroactiveChain(targetLang: InputSource.Lang) -> [(original: String, swapped: String)] {
        let validRu: Set<String> = ["а", "и", "в", "к", "с", "о", "у", "я"]
        let validEn: Set<String> = ["a", "i"]

        var chain: [(String, String)] = []
        // Идём с конца истории: -1 это только что добавленное (главное слово), не его смотрим
        // Стартуем с предпоследнего (-2)
        var i = wordHistory.count - 2
        while i >= 0 {
            let prev = wordHistory[i]
            // Только одиночные буквы
            guard prev.count == 1 else { break }
            let prevLow = prev.lowercased()
            // Если уже валидный предлог в целевом языке — стоп (не ломаем)
            if targetLang == .ru && validRu.contains(prevLow) { break }
            if targetLang == .en && validEn.contains(prevLow) { break }

            let prevSwap = Detector.shared.swap(prev)
            let prevSwapLow = prevSwap.lowercased()

            // Свап должен быть отличен от оригинала и быть валидным предлогом целевого языка
            let isValidTarget =
                (targetLang == .ru && validRu.contains(prevSwapLow)) ||
                (targetLang == .en && validEn.contains(prevSwapLow))
            if isValidTarget && prevSwap != prev {
                chain.append((prev, prevSwap))
                i -= 1
            } else {
                break
            }
        }
        return chain.reversed()  // от старого к новому
    }

    private func performSwitch(replay: [Keystroke], trigger: Keystroke, fromLang: InputSource.Lang) {
        let target: InputSource.Lang = (fromLang == .ru) ? .en : .ru
        let original = replay.map { $0.chars }.joined()
        let translated: String = (target == .ru) ? Translit.toRu(original) : Translit.toEn(original)

        // Ретроконверсия: цепочка одиночных букв перед текущим словом
        let retro = retroactiveChain(targetLang: target)

        if !retro.isEmpty {
            // Удаляем: каждое retro-слово (1 символ) + пробел после него, и текущее слово
            let charsToDelete = retro.count * 2 + replay.count
            print("[retro] цепочка: \(retro.map { "\($0.original)→\($0.swapped)" }.joined(separator: ", "))")
            print("[switch] '\(original)' → '\(translated)' с ретро (\(fromLang) → \(target))")

            sendBackspaces(charsToDelete)
            InputSource.switchTo(target)

            // Печатаем все ретро-свапы через пробелы, потом основное слово
            for (i, pair) in retro.enumerated() {
                if i > 0 { postUnicode(" ") }
                for ch in pair.swapped {
                    postUnicode(String(ch))
                    usleep(2_000)
                }
            }
            postUnicode(" ")
            for ch in translated {
                postUnicode(String(ch))
                usleep(3_000)
            }

            // Обновляем историю: заменяем ретро-слова на свапнутые
            for (offset, pair) in retro.enumerated() {
                // retro[0] = самое старое, его позиция в истории = count-2-(retro.count-1)
                let idx = wordHistory.count - 2 - (retro.count - 1) + offset
                if idx >= 0 && idx < wordHistory.count {
                    wordHistory[idx] = pair.swapped
                }
            }
        } else {
            print("[switch] '\(original)' → '\(translated)'  (\(fromLang) → \(target))")
            sendBackspaces(replay.count)
            InputSource.switchTo(target)
            for ch in translated {
                postUnicode(String(ch))
                usleep(3_000)
            }
        }

        // Печатаем триггер (пробел/Enter/пунктуация)
        let controlKeys: Set<CGKeyCode> = [49, 36, 48, 76]
        if controlKeys.contains(trigger.keyCode) {
            postVirtualKey(trigger.keyCode)
        } else if !trigger.chars.isEmpty {
            postUnicode(trigger.chars)
        }

        lastSwitch = LastSwitch(
            originalChars: original,
            convertedChars: translated,
            triggerKeyCode: trigger.keyCode,
            state: .converted
        )
        lastCompletedWord = nil

        playSound()
    }

    func forceSwitchLastWord() {
        guard !word.isEmpty else { return }
        let cur = InputSource.currentLanguage()
        let target: InputSource.Lang = (cur == .ru) ? .en : .ru
        let replay = word
        word.removeAll()

        let original = replay.map { $0.chars }.joined()
        let translated: String = (target == .ru) ? Translit.toRu(original) : Translit.toEn(original)
        print("[manual] '\(original)' → '\(translated)'  (\(cur) → \(target))")

        sendBackspaces(replay.count)
        InputSource.switchTo(target)
        for ch in translated {
            postUnicode(String(ch))
            usleep(3_000)
        }

        lastSwitch = LastSwitch(
            originalChars: original,
            convertedChars: translated,
            triggerKeyCode: 0,
            state: .converted
        )
        lastCompletedWord = nil
        playSound()
    }

    /// Тоггл последнего свитча — переключает между исходным и конвертированным.
    /// Без лимита по времени — пока буфер не разрушен пользовательским действием.
    private func toggleLastSwitch(_ last: LastSwitch) {
        let triggerCount = (last.triggerKeyCode != 0) ? 1 : 0

        let currentText: String
        let targetText: String
        switch last.state {
        case .converted:
            currentText = last.convertedChars
            targetText = last.originalChars
            last.state = .original
        case .original:
            currentText = last.originalChars
            targetText = last.convertedChars
            last.state = .converted
        }
        last.timestamp = Date()

        // Удаляем текущий текст + триггер
        sendBackspaces(currentText.count + triggerCount)

        // Определяем целевую раскладку по содержимому targetText
        let cyrCount = targetText.filter { ("а"..."я").contains($0) || $0 == "ё"
                                          || ("А"..."Я").contains($0) || $0 == "Ё" }.count
        let latCount = targetText.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
        let target: InputSource.Lang = cyrCount > latCount ? .ru : .en
        InputSource.switchTo(target)

        // Печатаем целевой текст
        for ch in targetText {
            postUnicode(String(ch))
            usleep(3_000)
        }

        // Возвращаем триггер
        if last.triggerKeyCode != 0 {
            postVirtualKey(last.triggerKeyCode)
        }

        print("[toggle] '\(currentText)' → '\(targetText)' (state теперь = \(last.state))")
        playSound()
    }

    // MARK: - Selection helpers (case toggle, transliteration)

    /// Циклическая смена регистра выделенного: lower → Title → UPPER → lower.
    private func toggleSelectionCase() {
        guard let text = readSelection(restoreClipboard: false), !text.isEmpty else {
            print("[case] нет выделения"); return
        }
        let next = nextCaseCycle(text)
        writeSelection(next)
        print("[case] '\(text)' → '\(next)'")
        playSound()
    }

    /// Транслит выделенного: кириллица → латиница (ГОСТ-подобный).
    private func transliterateSelection() {
        guard let text = readSelection(restoreClipboard: false), !text.isEmpty else {
            print("[translit] нет выделения"); return
        }
        let result = Transliterator.cyrillicToLatin(text)
        writeSelection(result)
        print("[translit] '\(text)' → '\(result)'")
        playSound()
    }

    private func readSelection(restoreClipboard: Bool = true) -> String? {
        let pb = NSPasteboard.general
        let savedItems = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        lastSavedClipboard = savedItems

        // КРИТИЧНО: Option (или другой модификатор хоткея) может быть ещё физически
        // нажат в момент чтения. Если послать ⌘C пока висит Option — система увидит
        // ⌘⌥C (другая комбинация), и копирование НЕ сработает.
        // Ждём пока все модификаторы отпустятся.
        for _ in 0..<30 {
            let cur = CGEventSource.flagsState(.combinedSessionState)
            let hasModifiers = cur.contains(.maskAlternate) || cur.contains(.maskCommand)
                            || cur.contains(.maskControl) || cur.contains(.maskShift)
            if !hasModifiers { break }
            usleep(10_000)
        }

        let beforeCount = pb.changeCount

        // Чистый ⌘C (флаги строго command, ничего лишнего)
        postVirtualKey(8 /* C */, flags: .maskCommand)

        // Ждём пока changeCount увеличится (копирование произошло)
        var copied = false
        for _ in 0..<60 {
            usleep(10_000)
            if pb.changeCount > beforeCount {
                copied = true
                break
            }
        }
        print("[readSel] changeCount \(beforeCount)→\(pb.changeCount) copied=\(copied)")

        var result: String? = nil
        if copied {
            // Содержимое может дописываться (text/RTF/HTML по очереди) — ждём стабилизации
            usleep(40_000)
            var prev = pb.string(forType: .string)
            for _ in 0..<10 {
                usleep(30_000)
                let cur = pb.string(forType: .string)
                if cur == prev { break }
                prev = cur
            }
            if let s = prev, !s.isEmpty {
                result = s
            }
        }

        // Восстанавливаем буфер если просили или если ничего не прочитали
        if restoreClipboard || result == nil {
            pb.clearContents()
            if let saved = savedItems {
                pb.writeObjects(saved)
            }
            lastSavedClipboard = nil
        }

        return result
    }

    private func writeSelection(_ s: String) {
        let pb = NSPasteboard.general
        // Берём сохранённый буфер из readSelection (если он был), иначе текущий
        let savedItems: [NSPasteboardItem]?
        if let fromRead = lastSavedClipboard {
            savedItems = fromRead
            lastSavedClipboard = nil
        } else {
            savedItems = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
        }

        pb.clearContents()
        pb.setString(s, forType: .string)
        usleep(30_000)  // даём pasteboard-серверу применить новое содержимое

        // Ждём отпускания модификаторов (как в readSelection) чтобы ⌘V не стал ⌘⌥V
        for _ in 0..<30 {
            let cur = CGEventSource.flagsState(.combinedSessionState)
            let hasModifiers = cur.contains(.maskAlternate) || cur.contains(.maskCommand)
                            || cur.contains(.maskControl) || cur.contains(.maskShift)
            if !hasModifiers { break }
            usleep(10_000)
        }

        // ⌘V
        postVirtualKey(9 /* V */, flags: .maskCommand)

        // Восстанавливаем буфер ПОЗЖЕ — медленные приложения (Electron, браузеры)
        // обрабатывают вставку до 0.5-1 сек. Если восстановить сразу — вставится
        // старое содержимое буфера («куски предыдущих текстов»).
        let snapshotChangeCount = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Восстанавливаем только если буфер всё ещё наш (пользователь не копировал сам)
            if pb.changeCount == snapshotChangeCount, let saved = savedItems {
                pb.clearContents()
                pb.writeObjects(saved)
            }
        }
    }

    private func nextCaseCycle(_ s: String) -> String {
        let lower = s.lowercased()
        let upper = s.uppercased()
        // Title: первая буква каждого слова большая, остальные маленькие
        let title = s.lowercased().split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let first = word.first else { return "" }
                return String(first).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")

        if s == lower { return title }
        if s == title { return upper }
        return lower
    }

    // MARK: - Sound

    private func playSound() {
        guard Config.shared.soundEnabled else { return }
        DispatchQueue.main.async {
            if let s = NSSound(named: NSSound.Name("Pop")) {
                s.volume = 0.3
                s.play()
            }
        }
    }

    // MARK: - Synthetic events

    private func postUnicode(_ s: String) {
        let utf16 = Array(s.utf16)
        let src = CGEventSource(stateID: .privateState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            down.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: Switcher.magic)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            up.flags = []
            up.setIntegerValueField(.eventSourceUserData, value: Switcher.magic)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postVirtualKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .privateState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.setIntegerValueField(.eventSourceUserData, value: Switcher.magic)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.setIntegerValueField(.eventSourceUserData, value: Switcher.magic)
            up.post(tap: .cghidEventTap)
        }
    }

    private func sendBackspaces(_ n: Int) {
        for _ in 0..<n {
            postVirtualKey(51)
            usleep(3_000)
        }
    }
}
