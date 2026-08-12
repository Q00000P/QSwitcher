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
        /// Переключение было автоматическим (не по нажатию пользователя).
        /// Нужно чтобы отличить «свитчер ошибся, я откатил» от обычного тоггла.
        let wasAutomatic: Bool

        init(originalChars: String, convertedChars: String, triggerKeyCode: CGKeyCode,
             state: ToggleState, wasAutomatic: Bool = false) {
            self.originalChars = originalChars
            self.convertedChars = convertedChars
            self.triggerKeyCode = triggerKeyCode
            self.state = state
            self.wasAutomatic = wasAutomatic
            self.timestamp = Date()
        }
    }

    enum ToggleState {
        case original   // в документе сейчас исходный текст
        case converted  // в документе сейчас конвертированный текст
    }

    private static let leftShiftKey: CGKeyCode = 56
    private static let rightShiftKey: CGKeyCode = 60

    /// Очередь для отправки синтетических событий. СТРОГО последовательная.
    ///
    /// Через DispatchQueue.global два переключения подряд выполнялись параллельно:
    /// одно ещё слало backspace, другое уже печатало замену. Результат — съеденный
    /// текст, мусор при свапе выделения и падения. Все стирания и печать обязаны
    /// идти друг за другом, иначе события перемешиваются на уровне системы.
    private let emitQueue = DispatchQueue(label: "local.QSwitcher.emit", qos: .userInitiated)

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
        /// Цифро-пунктуационный префикс, набранный вплотную перед словом
        /// и отброшенный буфером ('10' перед 'ю0ю0ю1' в IP-адресе).
        /// Ручной свап конвертирует слово ВМЕСТЕ с ним — как Punto.
        var prefix: String = ""
        /// Кейстроки слова: ручной свап по кейкодам (см. swapByKeycodes).
        var keys: [Keystroke] = []
    }
    private var lastCompletedWord: LastCompletedWord?

    /// Отброшенный из буфера префикс текущего слова (см. LastCompletedWord.prefix).
    /// Живёт строго вместе с word: любой сброс слова сбрасывает и его.
    private var droppedPrefix = ""

    /// Сохранённое содержимое буфера обмена для отложенного восстановления.
    private var lastSavedClipboard: [NSPasteboardItem]?

    /// Сколько слов подряд сконвертировано в одну и ту же сторону.
    /// Раскладку переключаем только когда набралось подтверждение смены языка —
    /// разовая вставка аббревиатуры ('NL' посреди русского текста) раскладку не трогает.
    /// Пользователь держал Shift при свапе — запомнить правило независимо от длины.
    /// Был ли Shift зажат в любой момент удержания Option.
    /// Проверять только флаги в момент отпускания нельзя: правым Shift и правым
    /// Option жмут одной рукой, и Shift часто уходит раньше — признак терялся.
    private var shiftDuringHold = false

    private var pendingExplicitLearn = false

    private var consecutiveConversions = 0
    private var lastConversionTarget: InputSource.Lang?

    /// Запланировано ли отложенное восстановление буфера обмена.
    /// readSelection ждёт его завершения, иначе примет восстановленное
    /// содержимое за «скопированное выделение» и вставит чужой текст.
    private var pendingClipboardRestore = false

    // === Input-gate ===
    /// Счётчик активных заданий замены. Пока > 0 — реальные keyDown пользователя
    /// не пропускаются в приложение, а копятся в pendingRealEvents и довводятся
    /// после завершения замены. Без шлюза быстрый набор вклинивается между
    /// синтетическими backspace и печатью замены: backspace съедает свежие буквы,
    /// замена размазывается по ним — те самые «наслоения» при живой печати.
    private var activeReplays = 0
    private var pendingRealEvents: [(event: CGEvent, chars: String)] = []
    private static let pendingCap = 64
    /// Страховка: если задание замены зависло и счётчик не обнулился,
    /// через 2 с принудительно открываем ввод — иначе клавиатура «мертва».
    private var gateWatchdog: Timer?

    /// История последних N набранных слов для определения контекста (RU vs EN).
    private var wordHistory: [String] = []
    private let historyCapacity = 5

    private(set) var lastUserAppBundleId: String?
    private(set) var currentLang: InputSource.Lang = .en

    var onLanguageChanged: ((InputSource.Lang) -> Void)?

    // MARK: - Lifecycle

    func start() {
        // Слушаем keyDown И flagsChanged (для дабл-Shift)
        // Клики мыши тоже слушаем: после них курсор в другом месте, и накопленное
        // недописанное слово там уже не рядом. Без этого буфер тащил старые буквы
        // и склеивал их со следующим словом ('приложений' + 'что' → 'приложенийчто').
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)
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
        KeyTranslate.installObserver()

        // Смена раскладки посреди слова означает что дальше пойдут символы
        // другого алфавита. Копить их в тот же буфер нельзя — получается склейка
        // вида 'никогдаhe,' и детектор анализирует несуществующее слово.
        KeyTranslate.onLayoutChanged = { [weak self] in
            // switchTo может прийти из фонового потока (свап выделения),
            // а буфер принадлежит главному — переносим туда.
            DispatchQueue.main.async {
                guard let self = self, !self.word.isEmpty else { return }
                print("[layout] раскладка сменилась — сбрасываю незавершённое слово")
                self.word.removeAll()
                self.droppedPrefix = ""
            }
        }

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

        print("✅ QSwitcher активен. Option (одиночное нажатие) — переключить, Esc — отменить.")
    }

    @objc private func appDidActivate(_ notif: Notification) {
        guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        lastUserAppBundleId = app.bundleIdentifier
        word.removeAll()
        droppedPrefix = ""
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
        let excluded = Config.shared.excludedApps
        // Активное приложение
        if let bid = lastUserAppBundleId, excluded.contains(bid) { return true }
        // И владелец фокуса ввода — системные накладки (поиск программ, Spotlight)
        // активными приложениями не становятся, но фокус держат.
        if let focus = AXSelection.focusedAppBundleIDCached(), excluded.contains(focus) { return true }
        return false
    }

    // MARK: - Tap handler

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // По таймауту переподнимаем ТОЛЬКО при живых правах.
            // По userInput (в т.ч. отзыв Accessibility) — НЕ воюем немедленным
            // re-enable: система гасит tap, мы его форсим, она гасит снова —
            // и весь системный ввод замирал наглухо, пока идёт эта борьба.
            // Вместо этого открываем шлюз, чистим состояние и ждём возврата
            // прав таймером.
            if type == .tapDisabledByTimeout, AXIsProcessTrusted() {
                if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                print("[tap] отключён (\(type == .tapDisabledByUserInput ? "userInput/отзыв прав" : "timeout без прав")) — жду возврата прав")
                activeReplays = 0
                pendingRealEvents.removeAll()
                gateWatchdog?.invalidate()
                gateWatchdog = nil
                word.removeAll()
                droppedPrefix = ""
                scheduleTapRecovery()
            }
            return Unmanaged.passUnretained(event)
        }

        // === flagsChanged: ловим одиночный тап Option ===
        if type == .leftMouseDown || type == .rightMouseDown {
            if !word.isEmpty {
                print("[buf] клик мышью — сбрасываю незавершённое слово")
                word.removeAll()
                droppedPrefix = ""
            }
            lastSwitch = nil
            lastCompletedWord = nil
            return Unmanaged.passUnretained(event)
        }

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
                    shiftDuringHold = event.flags.contains(.maskShift)
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
                            // Shift зажат в момент отпускания Option — явная команда
                            // «переключи и запомни», работает на словах любой длины.
                            let withShift = event.flags.contains(.maskShift) || shiftDuringHold
                            let shiftMark = withShift ? " +Shift(обучение)" : ""
                            print("[\(Switcher.ts())] [opt-tap] \(side) Option\(shiftMark) (held=\(String(format: "%.3f", held))s)")
                            DispatchQueue.main.async { [weak self] in
                                if isLeft {
                                    // Левый Option — ТОЛЬКО свап выделения (мышкой)
                                    self?.handleSelectionSwap()
                                } else {
                                    // Правый Option — свап набранного / тоггл
                                    self?.handleBufferSwap(explicitLearn: withShift)
                                }
                            }
                        }
                    }
                    modifierPressTime = nil
                    modifierContaminated = false
                    trackedModifierKey = nil
                    shiftDuringHold = false
                }
            } else if keyCode == Switcher.leftShiftKey || keyCode == Switcher.rightShiftKey {
                // Shift — часть жеста «переключи и запомни», а не помеха.
                // Запоминаем что он был, и НЕ помечаем нажатие загрязнённым:
                // иначе отпускание Shift раньше Option гасило бы весь тап.
                if modifierPressTime != nil, event.flags.contains(.maskShift) {
                    shiftDuringHold = true
                }
            } else {
                // Остальные модификаторы (Cmd, Ctrl, Fn) во время удержания Option
                // означают что жмут другое сочетание — не наше дело.
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

        // Идёт замена — реальный ввод задерживаем, чтобы он не вклинился между
        // синтетическими backspace и печатью. Символ переводим СЕЙЧАС, пока
        // раскладка ещё не переключена заменой: довводить будем юникодом,
        // иначе кейкоды лягут на экран буквами новой раскладки (на винде так
        // кириллица превращалась в 'z ndjq'). Контрольные клавиши довводятся
        // репостом события — они от раскладки не зависят.
        if activeReplays > 0 {
            if pendingRealEvents.count < Switcher.pendingCap, let copy = event.copy() {
                let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let chars = KeyTranslate.char(keyCode: kc, flags: event.flags) ?? ""
                pendingRealEvents.append((event: copy, chars: chars))
                return nil
            }
            // Переполнение очереди — пропускаем как есть, хуже потерять ввод
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
                // Хвост (цифры нового набора) — до сброса буфера, иначе тоггл
                // снесёт его стиранием, как в кейсе «гит 3»
                let bufText = word.map { $0.chars }.joined()
                let tail = bufText.contains(where: { $0.isLetter }) ? "" : droppedPrefix + bufText
                // НЕ обнуляем lastSwitch — оставляем чтобы можно было ещё раз тоггнуть
                word.removeAll()
                droppedPrefix = ""
                DispatchQueue.main.async { [weak self] in self?.toggleLastSwitch(last, tail: tail) }
                return nil
            }
            // Иначе пропускаем Esc как обычно
            word.removeAll()
            droppedPrefix = ""
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
            droppedPrefix = ""
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
                    self.droppedPrefix = ""
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
            droppedPrefix = ""
            return Unmanaged.passUnretained(event)
        }

        // Символ берём СВОИМ переводом по актуальной раскладке.
        // event.keyboardGetUnicodeString() отдаёт символ по раскладке, закэшированной
        // в нашем процессе, и она не следует за TISSelectInputSource — в логах ловили
        // расхождение на десятки секунд (на экране 'rfrf', в буфере 'кака').
        let chars: String = {
            if let c = KeyTranslate.char(keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                                         flags: event.flags) {
                return c
            }
            // Fallback если раскладка недоступна (например экзотический IME)
            var len = 0
            var buf = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
            return len > 0 ? String(utf16CodeUnits: buf, count: len) : ""
        }()

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
            else if !droppedPrefix.isEmpty { droppedPrefix.removeLast() }
            lastSwitch = nil
            lastCompletedWord = nil
            return Unmanaged.passUnretained(event)
        }

        // EN-пунктуация которая на RU-раскладке даёт букву.
        // Эти символы — часть слова, не граница: `[h.` (хр.), `;му` (жму), `'kkf` (элла).
        let layoutPunctChars: Set<Character> = [";", "[", "]", "'", "`", "\\", ",", "."]
        let firstChar = chars.first
        let isLayoutPunct = firstChar.map { layoutPunctChars.contains($0) } ?? false

        // Знаки с «двухсимвольных» клавиш, зависящих от раскладки. Это цифровой
        // ряд с Shift (RU Shift+2='"', EN='@') и Shift-варианты буквенно-
        // пунктуационных клавиш (EN Shift+скобка даёт фиг.скобку, RU той же клавиши='Х').
        // Если слова с буквами нет — знак часть набора: ручной свап переведёт
        // его по КЕЙКОДУ через другую раскладку. При наборе обычного слова
        // знак остаётся границей, как раньше.
        let dualLayoutKeys: Set<CGKeyCode> = [
            18, 19, 20, 21, 23, 22, 26, 28, 25, 29,  // цифровой ряд 1-0
            33, 30, 41, 39, 50, 42, 43, 47, 44,      // [ ] ; ' ` \ , . /
        ]
        let bufferLacksLetters = !word.contains { $0.chars.contains { $0.isLetter } }
        let isShiftedDigitInNumericRun =
            dualLayoutKeys.contains(keyCode)
            && isPunctuation(chars) && bufferLacksLetters

        // Граница слова: пробел/Enter/Tab или «настоящая» пунктуация (но не layout-punct)
        let isWordEnd =
            keyCode == 49 || keyCode == 36 || keyCode == 76 || keyCode == 48 ||
            (isPunctuation(chars) && !isLayoutPunct && !isShiftedDigitInNumericRun)

        if isWordEnd {
            if !word.isEmpty {
                let text = word.map { $0.chars }.joined()
                let cur = InputSource.currentLanguage()
                // Обновляем контекст: добавляем слово в историю ДО решения о свапе
                // (для самого слова контекст = что было ДО него)
                let context = computeContext()
                // Диагностика рассинхрона: символы в буфере — истина, currentLanguage() врёт
                if let actual = Switcher.langOf(text), actual != cur {
                    print("[\(Switcher.ts())] [!] система говорит \(cur), а набрано \(actual) — доверяем набранному")
                }
                let willSwitch = Detector.shouldSwitch(word: text, currentLang: cur, context: context)
                // Владелец фокуса ввода, а не «активное приложение»: системные
                // накладки frontmost не занимают и остаются невидимыми для него.
                let focusApp = AXSelection.focusedAppBundleIDCached()
                // Берём отслеживаемое по уведомлениям значение, а не спрашиваем
                // систему: в обработчике тапа любой лишний запрос — риск задержать
                // ввод во всей системе.
                let frontApp = lastUserAppBundleId ?? "?"
                let appMark = (focusApp != nil && focusApp != frontApp)
                    ? "\(frontApp)/фокус:\(focusApp!)" : frontApp
                print("[\(Switcher.ts())] [boundary] '\(text)' (\(cur), ctx=\(context.map { String(describing: $0) } ?? "nil"), app=\(appMark)) → \(willSwitch ? "SWITCH" : "keep")")
                SecureLog.shared.append("[boundary] '\(text)' (\(cur)) → \(willSwitch ? "SWITCH" : "keep")")
                if willSwitch {
                    let replay = word
                    let trigger = Keystroke(keyCode: keyCode, flags: flags, chars: chars)
                    word.removeAll()
                    droppedPrefix = ""
                    // В истории сохраняем уже свапнутую версию
                    let swapped = Detector.shared.swap(text)
                    appendToHistory(swapped)
                    // Шлюз открываем СИНХРОННО здесь, а не внутри performSwitch:
                    // между return nil и async-блоком следующее нажатие успевает
                    // проскочить в приложение и попасть под backspace.
                    beginGate()
                    DispatchQueue.main.async { [weak self] in
                        self?.performSwitch(replay: replay, trigger: trigger, fromLang: cur)
                    }
                    return nil
                }
                // Не свапаем — значит раскладка верная, серия конвертаций прервана
                consecutiveConversions = 0
                lastConversionTarget = nil
                appendToHistory(text)
                lastCompletedWord = LastCompletedWord(
                    chars: text,
                    triggerKeyCode: keyCode,
                    lang: cur,
                    prefix: droppedPrefix,
                    keys: word
                )
                word.removeAll()
                droppedPrefix = ""
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
            droppedPrefix = ""
            lastSwitch = nil
            lastCompletedWord = nil
            return Unmanaged.passUnretained(event)
        }

        if !chars.isEmpty {
            // Layout-пунктуация ('.', ',', ';' …) — палка о двух концах. Она нужна
            // как часть слова, иначе не починить '.,rf' → 'юбка'. Но она же склеивает
            // обычную пунктуацию со следующим словом: '...' набранное четыре минуты
            // назад приклеилось к 'миграция' и превратилось в 'юююмиграция'.
            //
            // Различаем по алфавиту. Кириллица в буфере означает что человек в русской
            // раскладке, где точка — настоящая пунктуация, а не артефакт раскладки.
            // Латиница оставляет надежду что это русское слово набранное не там.
            let incoming = chars.first
            let incomingIsCyrillic = incoming.map { Switcher.isCyrillicLetter($0) } ?? false
            let incomingIsLetter = incoming.map { $0.isLetter } ?? false

            let bufferText = word.map { $0.chars }.joined()
            let bufferHasCyrillic = bufferText.contains { Switcher.isCyrillicLetter($0) }
            let bufferHasLetters = bufferText.contains { $0.isLetter }
            let bufferIsOnlyPunct = !bufferText.isEmpty && !bufferHasLetters

            if incomingIsCyrillic && bufferIsOnlyPunct {
                // Накопленная пунктуация была самостоятельной — слово начинается здесь
                print("[buf] пунктуация '\(bufferText)' отброшена — дальше кириллица (префикс сохранён)")
                droppedPrefix = bufferText
                word.removeAll()
            } else if !incomingIsLetter && layoutPunctChars.contains(incoming ?? " ") && bufferHasCyrillic {
                // Пунктуация после кириллического слова — это конец слова, не его часть
                word.removeAll()
                droppedPrefix = ""
                lastCompletedWord = nil
                return Unmanaged.passUnretained(event)
            }

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

    /// Привести историю в соответствие с тем что РЕАЛЬНО на экране после ручного свапа.
    ///
    /// Зачем: computeContext() определяет язык по последним словам истории, а контекст
    /// влияет на решения детектора. Если ручной свап или тоггл не обновили историю —
    /// контекст врёт («думаем что пишем по-русски», хотя уже перешли на латиницу),
    /// и дальше начинаются ложные автосвапы.
    ///
    /// text — то что теперь на экране (может быть несколько слов, например при свапе
    /// выделенной фразы). Заменяем хвост истории на слова из него.
    private func syncHistoryTail(with text: String) {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return }

        // Убираем из хвоста столько записей сколько заменяем (но не больше чем есть)
        let replaceCount = min(words.count, wordHistory.count)
        if replaceCount > 0 {
            wordHistory.removeLast(replaceCount)
        }
        for w in words.suffix(historyCapacity) {
            appendToHistory(w)
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
        // Всё в фоне: и AX (может блокировать при неотвечающем приложении),
        // и клипбордный fallback (usleep в ожидании ⌘C/⌘V).
        // Главный поток продолжает крутить RunLoop и доставлять события.
        emitQueue.async { [weak self] in
            guard let self = self else { return }

            // ПУТЬ 1 — Accessibility API: читаем и пишем выделение напрямую
            // у элемента, без буфера обмена. Без гонок, не портит клипборд.
            var swappedTo: String? = nil
            let original = AXSelection.swapSelection { text in
                guard text.count <= 5000 else { return text }
                let result = Detector.shared.hardSwap(text)
                swappedTo = result
                return result
            }

            if let original = original, let result = swappedTo, result != original {
                print("[selSwap/AX] выделение (\(original.count) симв) → swap")
                print("[manual-sel] '\(original.prefix(40))' → '\(result.prefix(40))'")
                SecureLog.shared.append("[selSwap/AX] \(original.count) симв")
                DispatchQueue.main.async {
                    self.word.removeAll()
                    self.droppedPrefix = ""
                    self.lastSwitch = nil
                    self.lastCompletedWord = nil
                    self.syncHistoryTail(with: result)
                    self.switchLayoutFor(result)
                }
                self.playSound()
                return
            }

            // ПУТЬ 2 — fallback на ⌘C/⌘V для приложений без поддержки AX
            // (Electron: Telegram, VS Code; часть Java/Qt).
            print("[selSwap] AX недоступен → fallback на буфер обмена")
            guard let selected = self.readSelection(restoreClipboard: false),
                  !selected.isEmpty, selected.count <= 5000 else {
                print("[selSwap] нет выделения — ничего")
                return
            }
            print("[selSwap] выделение (\(selected.count) симв) → swap")
            DispatchQueue.main.async {
                self.word.removeAll()
                self.droppedPrefix = ""
                self.lastSwitch = nil
                self.lastCompletedWord = nil
            }
            self.swapSelectedTextSync(selected)
        }
    }

    /// Определить язык по СОДЕРЖИМОМУ текста.
    ///
    /// Почему не InputSource.currentLanguage(): она врёт. В логах ловили прямое
    /// противоречие — буфер содержит латиницу 'pfdnhf', а API говорит «сейчас ru»;
    /// и наоборот, буфер 'будет' кириллицей, а API — «en». Причины разные
    /// (кэш TIS, «своя раскладка для каждого приложения», задержка после switchTo),
    /// но нам они не важны: символы в буфере произвела сама система при нажатии,
    /// это истина. Раскладку выбираем по ним.
    static func isCyrillicLetter(_ c: Character) -> Bool {
        ("а"..."я").contains(c) || c == "ё" || ("А"..."Я").contains(c) || c == "Ё"
    }

    static func langOf(_ text: String) -> InputSource.Lang? {
        let cyr = text.filter { ("а"..."я").contains($0) || $0 == "ё"
                              || ("А"..."Я").contains($0) || $0 == "Ё" }.count
        let lat = text.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
        if cyr > lat { return .ru }
        if lat > cyr { return .en }
        return nil
    }

    /// Переключить системную раскладку под содержимое текста.
    private func switchLayoutFor(_ text: String) {
        guard let target = Switcher.langOf(text) else { return }
        InputSource.switchTo(target)
    }

    // MARK: - Tap recovery

    private var tapRecoveryTimer: Timer?

    /// Ждём возврата прав Accessibility и только тогда включаем tap обратно.
    private func scheduleTapRecovery() {
        guard tapRecoveryTimer == nil else { return }
        tapRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard AXIsProcessTrusted() else { return }
            if let tap = self.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("[tap] права вернулись — tap включён")
            }
            self.tapRecoveryTimer?.invalidate()
            self.tapRecoveryTimer = nil
        }
    }

    // MARK: - Input gate

    /// Открыть шлюз перед заданием замены. Вызывать на main СИНХРОННО с решением
    /// о замене — до emitQueue.async, иначе следующее нажатие успевает проскочить.
    private func beginGate() {
        activeReplays += 1
        gateWatchdog?.invalidate()
        gateWatchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self = self, self.activeReplays > 0 else { return }
            print("[gate] watchdog: замена не завершилась за 2с — принудительно открываю ввод")
            self.activeReplays = 0
            self.flushPendingInput()
        }
    }

    /// Закрыть шлюз. Вызывать в КОНЦЕ блока на emitQueue (через defer).
    private func endGate() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.activeReplays = max(0, self.activeReplays - 1)
            if self.activeReplays == 0 {
                self.gateWatchdog?.invalidate()
                self.gateWatchdog = nil
                self.flushPendingInput()
            }
        }
    }

    /// Доввод задержанного реального ввода (на main, без пауз).
    /// Печатные клавиши — юникодом с символом раскладки НА МОМЕНТ НАЖАТИЯ,
    /// и сразу в буфер слова (юникод-события идут с magic мимо tap'а).
    /// Контрольные (границы, backspace, навигация) — репостом оригинального
    /// события без magic: пройдут через tap штатно как границы и сбросы.
    private func flushPendingInput() {
        guard !pendingRealEvents.isEmpty else { return }
        let pending = pendingRealEvents
        pendingRealEvents.removeAll()
        // Клавиши, которые обязаны пройти обычную обработку tap'а
        let controlKeys: Set<CGKeyCode> = [
            49, 36, 76, 48, 51, 53,
            123, 124, 125, 126,
            115, 116, 117, 119, 121,
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111
        ]
        var typed = ""
        for item in pending {
            let kc = CGKeyCode(item.event.getIntegerValueField(.keyboardEventKeycode))
            let printable = !item.chars.isEmpty
                && !controlKeys.contains(kc)
                && item.chars.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                && item.event.flags.intersection([.maskCommand, .maskControl]).isEmpty
            if printable {
                postUnicode(item.chars)
                word.append(Keystroke(keyCode: kc, flags: item.event.flags, chars: item.chars))
                typed += item.chars
            } else {
                item.event.post(tap: .cghidEventTap)
            }
        }
        print("[gate] доввод \(pending.count) задержанных нажатий"
            + (typed.isEmpty ? "" : ", юникодом: '\(typed)'"))
    }

    /// ПРАВЫЙ Option — свап набранного / тоггл. Не трогает выделение вообще
    /// (не дёргает ⌘C), поэтому работает стабильно.
    /// Максимальная длина слова для АВТОМАТИЧЕСКОГО обучения.
    /// Короткие слова неоднозначны по своей природе — там решает пользователь.
    /// Длинные надёжно разбирает словарь, и разовый ручной свап (процитировать,
    /// показать как выглядит) не должен превращаться в постоянное правило.
    private static let autoLearnMaxLength = 3

    /// explicitLearn — пользователь держал Shift, то есть явно просит запомнить
    /// независимо от длины слова.
    private func handleBufferSwap(explicitLearn: Bool = false) {
        pendingExplicitLearn = explicitLearn
        defer { pendingExplicitLearn = false }
        // Текущий незавершённый набор. Критерий — меняет ли его КЕЙКОДНЫЙ свап:
        // '3,3' (numpad-точка в RU) → '3.3' меняет — свапаем БУФЕР; чистое '3'
        // свап не меняет — это ХВОСТ: при свапе завершённого слова его нужно
        // стереть вместе со словом и вернуть на место, иначе стирание сносило
        // его («гит 3» превращалось в «гubn»: съедало пробел и цифры).
        let bufText = word.map { $0.chars }.joined()
        let bufFull = droppedPrefix + bufText
        var bufSwapProbe = bufFull
        if !word.isEmpty {
            let cur = InputSource.currentLanguage()
            bufSwapProbe = droppedPrefix
                + (swapByKeycodes(word, from: cur) ?? Detector.shared.swap(bufText))
        }
        let tail = (bufSwapProbe == bufFull) ? bufFull : ""

        // Набор со ЗНАКАМИ, который свап не меняет ('3/3': '/' одинаков в
        // обеих раскладках) — не трогаем ничего: каскад к предыдущему слову
        // здесь портил соседний текст. Каскад разрешён только чисто
        // цифровому хвосту («гит 3» — намерение однозначно).
        if !tail.isEmpty && !tail.allSatisfy({ $0.isNumber }) {
            print("[bufSwap] набор '\(tail)' свап не меняет — ничего не делаю")
            return
        }

        // 1. Буфер есть и его свап что-то меняет — свапаем буфер
        if !word.isEmpty && tail.isEmpty {
            print("[bufSwap] свап буфера ('\(bufText)')")
            lastSwitch = nil
            forceSwitchLastWord()
            return
        }
        // 2. Тоггл последнего свитча
        if let last = lastSwitch {
            print("[bufSwap] тоггл последнего свитча" + (tail.isEmpty ? "" : ", хвост '\(tail)'"))
            toggleLastSwitch(last, tail: tail)
            return
        }
        // 3. Последнее завершённое слово
        if let lastWord = lastCompletedWord {
            print("[bufSwap] свап последнего завершённого слова '\(lastWord.chars)'"
                + (tail.isEmpty ? "" : ", хвост '\(tail)'"))
            swapLastCompletedWord(lastWord, tail: tail)
            return
        }
        print("[bufSwap] нечего свапать")
    }

    /// Свапнуть последнее завершённое слово задним числом.
    /// Курсор сейчас стоит ПОСЛЕ триггера (например после пробела).
    /// Удаляем триггер + слово, печатаем свапнутое слово + тот же триггер.
    private func swapLastCompletedWord(_ last: LastCompletedWord, tail: String = "") {
        let original = last.prefix + last.chars
        let translated = last.prefix + (
            last.keys.isEmpty
                ? Detector.shared.swap(last.chars)
                : (swapByKeycodes(last.keys, from: last.lang) ?? Detector.shared.swap(last.chars))
        )
        guard translated != original else {
            print("[manual-completed] свап равен оригиналу — нечего менять")
            return
        }

        // Раскладка по содержимому результата, не по last.lang (он из currentLanguage())
        let target: InputSource.Lang = Switcher.langOf(translated)
            ?? ((last.lang == .ru) ? .en : .ru)
        let triggerCount = (last.triggerKeyCode != 0) ? 1 : 0
        // Хвост — уже набранное после триггера (цифровой префикс нового слова):
        // стираем вместе со словом и возвращаем на место после триггера.
        let toDelete = original.count + triggerCount + tail.count

        beginGate()
        emitQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.endGate() }
            self.sendBackspaces(toDelete)
            InputSource.switchTo(target)
            self.postUnicode(translated)
            // Триггер возвращаем ЗДЕСЬ и только здесь. Раньше он отправлялся
            // дважды — второй раз снаружи async-блока — и плодил лишние пробелы.
            if triggerCount > 0 { self.postVirtualKey(last.triggerKeyCode) }
            if !tail.isEmpty { self.postUnicode(tail) }
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
        // Обучение — ТОЛЬКО по явной команде Shift + правый Option.
        // Обычный свап это разовое действие, а не заявка на вечное правило.
        if pendingExplicitLearn {
            // Учим само слово, без цифро-пунктуационного префикса
            LearnedRules.shared.learnForce(last.chars)
        }
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
        let target: InputSource.Lang? = Switcher.langOf(swapped)

        print("[manual-sel] '\(text.prefix(40))' → '\(swapped.prefix(40))'")
        DispatchQueue.main.async { [weak self] in
            self?.syncHistoryTail(with: swapped)
        }
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
        let original = replay.map { $0.chars }.joined()
        // Свап решает по содержимому — направление задавать не нужно
        let translated: String = Detector.shared.swap(original)
        // Раскладку выбираем по тому что РЕАЛЬНО вставляем, а не по fromLang:
        // currentLanguage() может врать и тогда переключение уходит в обратную сторону
        // (вставили кириллицу, а раскладку поставили EN → дальше набор идёт латиницей).
        let target: InputSource.Lang = Switcher.langOf(translated)
            ?? ((fromLang == .ru) ? .en : .ru)

        // Считаем подряд идущие конвертации в одну сторону
        if lastConversionTarget == target {
            consecutiveConversions += 1
        } else {
            lastConversionTarget = target
            consecutiveConversions = 1
        }
        // Раскладку меняем только при подтверждённой смене языка.
        // Одиночная вставка ('NL' в русском тексте) текст исправит, но раскладку
        // не тронет — и ты продолжаешь писать по-русски как ни в чём не бывало.
        let threshold = Config.shared.switchLayoutAfter
        let shouldSwitchLayout = threshold > 0 && consecutiveConversions >= threshold
        if !shouldSwitchLayout {
            print("[layout] раскладку не трогаем (\(consecutiveConversions)/\(threshold) подряд)")
        }

        // Ретроконверсия: цепочка одиночных букв перед текущим словом
        let retro = retroactiveChain(targetLang: target)

        if !retro.isEmpty {
            // Удаляем: каждое retro-слово (1 символ) + пробел после него, и текущее слово
            let charsToDelete = retro.count * 2 + original.count
            print("[retro] цепочка: \(retro.map { "\($0.original)→\($0.swapped)" }.joined(separator: ", "))")
            print("[switch] '\(original)' → '\(translated)' с ретро (\(fromLang) → \(target))")

            let retroPairs = retro
            emitQueue.async { [weak self] in
                guard let self = self else { return }
                defer { self.endGate() }
                self.sendBackspaces(charsToDelete)
                if shouldSwitchLayout { InputSource.switchTo(target) }
                let text = retroPairs.map { $0.swapped }.joined(separator: " ")
                    + " " + translated
                self.postUnicode(text)
                self.emitTrigger(trigger)
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
            // Отправка в фоне: usleep на главном потоке замораживает RunLoop
            // и ломает доставку событий — на этом мы уже обжигались.
            // Удаляем по числу ГРАФЕМ на экране, не по числу кейстроков:
            // dead keys и композиция дают одну графему из нескольких нажатий.
            let count = original.count
            emitQueue.async { [weak self] in
                guard let self = self else { return }
                defer { self.endGate() }
                self.sendBackspaces(count)
                if shouldSwitchLayout { InputSource.switchTo(target) }
                self.postUnicode(translated)
                self.emitTrigger(trigger)
            }
        }


        lastSwitch = LastSwitch(
            originalChars: original,
            convertedChars: translated,
            triggerKeyCode: trigger.keyCode,
            state: .converted,
            wasAutomatic: true
        )
        lastCompletedWord = nil

        playSound(shouldSwitchLayout ? .convertAndSwitch : .convertOnly)
    }

    /// Свап кейстроков по кейкодам через ПРОТИВОПОЛОЖНУЮ раскладку — как Punto.
    /// Символьная карта для знаков неоднозначна: '\"' это и RU-Shift+2, и
    /// EN-клавиша «э», по символу '2\"' свапалось в '2Э' вместо '2@'.
    /// По кейкоду однозначно. nil — нет данных раскладок, откат на символьный swap.
    private func swapByKeycodes(_ keys: [Keystroke], from cur: InputSource.Lang) -> String? {
        let target: InputSource.Lang = (cur == .ru) ? .en : .ru
        var out = ""
        for k in keys {
            let shift = k.flags.contains(.maskShift)
            let caps = k.flags.contains(.maskAlphaShift)
            guard var s = LayoutResolver.translate(
                keyCode: k.keyCode, shift: shift, capsLock: caps,
                to: target), !s.isEmpty else { return nil }
            // Знак одинаков в обеих раскладках ('/' на kc44) — свапу нечего
            // менять: инвертируем Shift той же клавиши ('3/3' → '3?3').
            // Только знак→знак: буквы и цифры не трогаем, иначе '%'→'5'.
            if s == k.chars, let c = s.first, !c.isLetter, !c.isNumber,
               let alt = LayoutResolver.translate(
                   keyCode: k.keyCode, shift: !shift, capsLock: caps, to: target),
               let a = alt.first, !a.isLetter, !a.isNumber {
                s = alt
            }
            out += s
        }
        return out
    }

    func forceSwitchLastWord() {
        guard !word.isEmpty else { return }
        let cur = InputSource.currentLanguage()
        let replay = word
        let prefix = droppedPrefix
        word.removeAll()
        droppedPrefix = ""

        // Ручной свап — как Punto: конвертируем весь набранный кусок, включая
        // цифро-пунктуационный префикс ('10ю0ю0ю1' → '10.0.0.1' целиком).
        // Цифры проходят через swap как есть.
        let wordText = replay.map { $0.chars }.joined()
        let original = prefix + wordText
        let translated: String = prefix
            + (swapByKeycodes(replay, from: cur) ?? Detector.shared.swap(wordText))
        // Целевая раскладка — по содержимому результата, не по currentLanguage()
        let target: InputSource.Lang = Switcher.langOf(translated)
            ?? ((cur == .ru) ? .en : .ru)
        print("[manual] '\(original)' → '\(translated)'  (\(cur) → \(target))")

        let deleteCount = original.count
        beginGate()
        emitQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.endGate() }
            self.sendBackspaces(deleteCount)
            InputSource.switchTo(target)
            self.postUnicode(translated)
        }

        lastSwitch = LastSwitch(
            originalChars: original,
            convertedChars: translated,
            triggerKeyCode: 0,
            state: .converted,
            wasAutomatic: true
        )
        lastCompletedWord = nil
        // История должна отражать то что теперь на экране, иначе контекст соврёт
        syncHistoryTail(with: translated)
        playSound()
    }

    /// Тоггл последнего свитча — переключает между исходным и конвертированным.
    /// Без лимита по времени — пока буфер не разрушен пользовательским действием.
    private func toggleLastSwitch(_ last: LastSwitch, tail: String = "") {
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

        let deleteCount = currentText.count + triggerCount + tail.count
        let triggerKey = last.triggerKeyCode
        beginGate()
        emitQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.endGate() }
            self.sendBackspaces(deleteCount)
            if let target = Switcher.langOf(targetText) {
                InputSource.switchTo(target)
            }
            self.postUnicode(targetText)
            if triggerKey != 0 { self.postVirtualKey(triggerKey) }
            if !tail.isEmpty { self.postUnicode(tail) }
        }

        // Тоггл НЕ обучает.
        //
        // Он служит просмотром: человек жмёт туда-обратно, чтобы увидеть оба
        // варианта. Раньше каждое нажатие переписывало правило в противоположную
        // сторону, и в логе получалась чехарда «больше не переключаем» /
        // «впредь переключаем» подряд. Правило меняется только по явной команде.
        if pendingExplicitLearn && last.state == .original {
            LearnedRules.shared.learnStop(last.originalChars)
        }

        // История должна отражать то что теперь на экране
        syncHistoryTail(with: targetText)

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

        // Ожидание восстановления буфера здесь НЕ нужно и опасно: восстановление
        // запланировано на этой же последовательной очереди, поэтому крутить цикл
        // означало бы блокировать очередь в ожидании задачи из неё же — вечный клинч.
        // Порядок гарантирует сама очередь.

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
        //
        // ГОНКА которую это порождало: отложенное восстановление возвращало старое
        // содержимое в буфер, changeCount дёргался, и если в этот момент шло новое
        // чтение выделения — оно принимало восстановленный буфер за «скопированное
        // выделение» и вставляло чужой текст. Поэтому: помечаем что восстановление
        // запланировано, и readSelection ждёт его завершения перед своим ⌘C.
        pendingClipboardRestore = true
        let snapshotChangeCount = pb.changeCount
        // Восстановление — на той же последовательной очереди что и чтение,
        // иначе запись флага и его проверка идут из разных потоков.
        emitQueue.asyncAfter(deadline: .now() + 1.0) {
            defer { self.pendingClipboardRestore = false }
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

    /// Что именно произошло — от этого зависит звук.
    enum SoundKind {
        /// Текст исправлен, раскладка осталась прежней.
        case convertOnly
        /// Текст исправлен И раскладка переключена.
        case convertAndSwitch
    }

    /// Звуковая обратная связь. Два разных сигнала, чтобы на слух отличать
    /// «просто исправил слово» от «исправил и сменил раскладку» — иначе
    /// непонятно в какой раскладке продолжать печатать.
    private func playSound(_ kind: SoundKind = .convertAndSwitch) {
        guard Config.shared.soundEnabled else { return }
        let name: String
        let volume: Float
        switch kind {
        case .convertOnly:
            name = Config.shared.soundConvertOnly
            volume = 0.25
        case .convertAndSwitch:
            name = Config.shared.soundConvertAndSwitch
            volume = 0.3
        }
        DispatchQueue.main.async {
            if let s = NSSound(named: NSSound.Name(name)) {
                s.volume = volume
                s.play()
            }
        }
    }

    // MARK: - Synthetic events

    /// Инъекция строки синтетическими событиями. Строка режется на чанки
    /// по ~16 UTF-16 юнитов: одно событие со слишком длинной строкой часть
    /// приложений обрезает. Пауз между чанками НЕТ — порядок гарантирует
    /// системная очередь событий, пейсинг ничего не добавляет и только
    /// растягивает окно, в которое может вклиниться чужой ввод.
    private func postUnicode(_ s: String) {
        let utf16 = Array(s.utf16)
        guard !utf16.isEmpty else { return }
        let src = CGEventSource(stateID: .privateState)
        var i = 0
        while i < utf16.count {
            var end = min(i + 16, utf16.count)
            // Не рвём суррогатную пару на границе чанка
            if end < utf16.count, (0xD800...0xDBFF).contains(utf16[end - 1]) {
                end += 1
            }
            let chunk = Array(utf16[i..<end])
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.flags = []
                down.setIntegerValueField(.eventSourceUserData, value: Switcher.magic)
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.flags = []
                up.setIntegerValueField(.eventSourceUserData, value: Switcher.magic)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.post(tap: .cghidEventTap)
            }
            i = end
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

    /// Отправка backspace для стирания уже набранного.
    ///
    /// Пауза ПЕРЕД первым нажатием обязательна. Наш тап видит символ раньше, чем
    /// его успевает принять целевое поле, и backspace прилетает в пустоту: символ
    /// остаётся, а замена дописывается следом — так `й` превращался в `йq`
    /// в поиске приложений. Системным полям (Spotlight, поиск программ) нужно
    /// заметно больше времени, чем обычным текстовым.
    /// Печать клавиши-границы (пробел/Enter/пунктуация) после замены.
    private func emitTrigger(_ trigger: Keystroke) {
        let controlKeys: Set<CGKeyCode> = [49, 36, 48, 76]
        if controlKeys.contains(trigger.keyCode) {
            postVirtualKey(trigger.keyCode)
        } else if !trigger.chars.isEmpty {
            postUnicode(trigger.chars)
        }
    }

    private func sendBackspaces(_ n: Int) {
        guard n > 0 else { return }
        // Settle ПЕРЕД первым backspace остаётся: медленным системным полям
        // нужно принять последний реальный символ (см. коммент выше про 'йq').
        usleep(UInt32(Config.shared.replaceStartDelayMs) * 1000)
        // Между backspace пауз нет: события идут одной системной очередью,
        // приложение обработает их по порядку в своём темпе.
        for _ in 0..<n {
            postVirtualKey(51)
        }
        // Короткий settle перед печатью замены
        usleep(20_000)
    }
}
