import Cocoa
import ApplicationServices

/// Чтение и запись выделенного текста НАПРЯМУЮ через Accessibility API,
/// без участия буфера обмена (⌘C/⌘V).
///
/// Почему это лучше буфера:
///   - не трогает пользовательский буфер обмена вообще (нечего терять и восстанавливать)
///   - нет гонок между чтением, записью и отложенным восстановлением
///   - мгновенно: нет ожиданий доставки синтетических событий и changeCount
///   - не зависит от того успело ли приложение обработать вставку
///
/// Ограничение: поддерживают не все приложения.
///   Работает: нативные Cocoa (TextEdit, Notes, Mail, поля Safari, Xcode, Terminal…)
///   Не работает / частично: Electron (Telegram, VS Code, Slack), часть Java/Qt.
/// Поэтому вызывающий код при неудаче откатывается на клипбордный путь.
enum AXSelection {

    /// Результат попытки прочитать выделение через AX.
    enum ReadResult {
        /// Успешно прочитали выделенный текст (может быть пустым — значит выделения нет).
        case ok(String)
        /// AX недоступен для этого элемента/приложения — нужен fallback на ⌘C.
        case unsupported
    }

    /// Таймаут AX-запросов. Без него обращение к подвисшему приложению
    /// блокирует поток на десятки секунд.
    private static let messagingTimeout: Float = 0.5

    /// Получить сфокусированный UI-элемент фронтмост-приложения.
    ///
    /// ВАЖНО: вызывать НЕ с главного потока — AX-запрос к неотвечающему
    /// приложению блокирует поток до таймаута, а замороженный main RunLoop
    /// ломает доставку событий (мы уже наступали на это с ⌘C).
    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard err == .success, let f = focused else { return nil }
        let element = f as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Идентификатор процесса, которому принадлежит поле с фокусом ввода.
    ///
    /// Отличается от NSWorkspace.frontmostApplication: системные накладки
    /// (поиск программ, Spotlight) не становятся «активным приложением», и
    /// frontmost продолжает показывать то, что было под ними.
    ///
    /// КРИТИЧНО: этот запрос НИКОГДА не должен выполняться в обработчике тапа.
    /// Тап стоит в общем конвейере ввода всей системы — пока он не вернул
    /// управление, нажатия не доходят ни до одного приложения. Обращение к
    /// чужому процессу через AX может подвиснуть, и тогда встаёт ввод целиком,
    /// вплоть до необходимости держать кнопку питания. Поэтому наружу отдаётся
    /// только закэшированное значение, а обновляется оно в фоне.
    private static let focusLock = NSLock()
    private static var cachedFocusApp: String?
    private static var focusRefreshedAt = Date.distantPast
    private static var focusRefreshInFlight = false
    private static let focusQueue = DispatchQueue(label: "local.QSwitcher.focusprobe", qos: .utility)

    /// Мгновенно: последнее известное значение. Никогда не блокирует.
    static func focusedAppBundleIDCached() -> String? {
        focusLock.lock()
        let value = cachedFocusApp
        let age = Date().timeIntervalSince(focusRefreshedAt)
        let busy = focusRefreshInFlight
        if age > 0.4 && !busy {
            focusRefreshInFlight = true
            focusLock.unlock()
            focusQueue.async { refreshFocusedApp() }
        } else {
            focusLock.unlock()
        }
        return value
    }

    /// Собственно запрос. Только из фоновой очереди.
    private static func refreshFocusedApp() {
        var result: String? = nil
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide,
               kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let f = focused {
            let element = f as! AXUIElement
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success {
                result = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
        }
        focusLock.lock()
        cachedFocusApp = result
        focusRefreshedAt = Date()
        focusRefreshInFlight = false
        focusLock.unlock()
    }

    /// Прочитать выделенный текст.
    static func read() -> ReadResult {
        guard let element = focusedElement() else { return .unsupported }

        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        )

        guard err == .success else {
            // Атрибут не поддерживается этим элементом
            return .unsupported
        }
        guard let str = value as? String else {
            return .unsupported
        }
        return .ok(str)
    }

    /// Заменить выделенный текст новым.
    /// Возвращает true если запись удалась.
    static func write(_ newText: String) -> Bool {
        guard let element = focusedElement() else { return false }

        // Проверяем что атрибут вообще доступен для записи —
        // иначе AXUIElementSetAttributeValue может тихо ничего не сделать.
        var settable: DarwinBoolean = false
        let checkErr = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard checkErr == .success, settable.boolValue else { return false }

        let err = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            newText as CFTypeRef
        )
        return err == .success
    }

    /// Полный цикл: прочитать выделение, преобразовать, записать обратно.
    /// Возвращает исходный выделенный текст если всё удалось, иначе nil
    /// (значит нужен fallback на клипбордный путь).
    ///
    /// transform вызывается только если есть непустое выделение.
    static func swapSelection(_ transform: (String) -> String) -> String? {
        guard let element = focusedElement() else { return nil }

        var value: CFTypeRef?
        let readErr = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        guard readErr == .success, let original = value as? String else { return nil }
        guard !original.isEmpty else { return nil }

        var settable: DarwinBoolean = false
        let checkErr = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard checkErr == .success, settable.boolValue else { return nil }

        let replaced = transform(original)
        guard replaced != original else { return original }

        let writeErr = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replaced as CFTypeRef
        )
        guard writeErr == .success else { return nil }

        return original
    }
}
