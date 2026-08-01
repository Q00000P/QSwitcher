import Cocoa
import Carbon

/// Перевод кода клавиши в символ ПО АКТУАЛЬНОЙ раскладке.
///
/// Зачем свой перевод вместо `CGEvent.keyboardGetUnicodeString()`:
/// встроенный отдаёт символ по раскладке, закэшированной в нашем процессе, и она
/// НЕ следует за сменой раскладки, которую мы же и сделали через TISSelectInputSource.
/// В логах ловили: приложение печатает латиницу `rfrf`, а тап видит кириллицу `кака` —
/// и так десятки секунд подряд. Детектор при этом получает валидные русские слова
/// и резонно ничего не исправляет, хотя на экране абракадабра.
///
/// Здесь раскладка берётся из TIS напрямую и сбрасывается по системному
/// уведомлению о смене — расхождение становится невозможным.
enum KeyTranslate {

    /// Закэшированные данные раскладки (UCKeyboardLayout).
    ///
    /// К кэшу обращаются ДВА потока: тап читает его на каждое нажатие с главного,
    /// а сброс приходит из фоновой очереди отправки (там вызывается switchTo).
    /// Одновременные чтение и запись Data? роняют процесс на счётчиках ссылок —
    /// именно так приложение и падало. Поэтому доступ только под замком.
    private static let lock = NSLock()
    private static var cachedLayout: Data?
    private static var cachedSourceID: String?
    private static var observerInstalled = false

    /// Вызывается при смене раскладки — чтобы потребитель мог сбросить
    /// незавершённое состояние (например накопленное слово).
    static var onLayoutChanged: (() -> Void)?

    /// Подписаться на смену раскладки, чтобы сбрасывать кэш.
    static func installObserver() {
        guard !observerInstalled else { return }
        observerInstalled = true
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { _ in
            invalidate()
            onLayoutChanged?()
        }
    }

    /// Сбросить кэш раскладки. Вызывать после собственного переключения тоже.
    static func invalidate() {
        lock.lock()
        cachedLayout = nil
        cachedSourceID = nil
        lock.unlock()
    }

    /// Сбросить кэш И уведомить о смене (для собственных переключений,
    /// когда системное уведомление может прийти с задержкой).
    static func invalidateAndNotify() {
        invalidate()
        onLayoutChanged?()
    }

    /// Актуальные данные раскладки.
    private static func currentLayoutData() -> Data? {
        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }

        // Сверяем идентификатор — если источник тот же, отдаём кэш
        var sourceID: String? = nil
        if let idPtr = TISGetInputSourceProperty(sourceRef, kTISPropertyInputSourceID) {
            sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        }
        lock.lock()
        if let cached = cachedLayout, sourceID != nil, sourceID == cachedSourceID {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let layoutPtr = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData) else {
            // Некоторые источники (например, часть IME) не отдают UCKeyboardLayout
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        lock.lock()
        cachedLayout = data
        cachedSourceID = sourceID
        lock.unlock()
        return data
    }

    /// Перевести код клавиши в символ по текущей раскладке.
    /// Возвращает nil если раскладка недоступна — вызывающий откатывается
    /// на встроенный keyboardGetUnicodeString.
    static func char(keyCode: CGKeyCode, flags: CGEventFlags) -> String? {
        guard let layoutData = currentLayoutData() else { return nil }

        // Модификаторы в формате UCKeyTranslate (старший байт сдвинут)
        var modifiers: UInt32 = 0
        if flags.contains(.maskShift)      { modifiers |= UInt32(shiftKey  >> 8) }
        if flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock >> 8) }
        if flags.contains(.maskAlternate)  { modifiers |= UInt32(optionKey >> 8) }
        if flags.contains(.maskControl)    { modifiers |= UInt32(controlKey >> 8) }

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0

        let status: OSStatus = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                base,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                modifiers,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
