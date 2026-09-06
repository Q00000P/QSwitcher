import Cocoa
import Carbon

/// Действия, на которые вешаются горячие клавиши. Паритет с виндой.
enum HotkeyAction: String, CaseIterable {
    case swapWord        // свап набранного / тоггл
    case swapAndLearn    // свап + правило
    case swapSelection   // свап выделенного
    case swapSelectionLetters // свап выделенного — только буквы, знаки не трогаем (формулы)
    case swapAndRule     // свап и ЖЁСТКОЕ правило (без контекста); по умолчанию не назначен
    case universal       // выделение если есть, иначе набранное
    case changeCase      // регистр выделенного
    case translit        // транслит выделенного
    case togglePause     // пауза свитчера
    case undoLast        // отменить последнее автопереключение

    var title: String {
        switch self {
        case .swapWord:      return "Свап слова / тоггл"
        case .swapAndLearn:  return "Свап и обучить профиль"
        case .swapSelection: return "Свап выделенного"
        case .swapSelectionLetters: return "Свап выделенного — только буквы"
        case .swapAndRule: return "Свап и жёсткое правило"
        case .universal:     return "Универсально (выделение → слово)"
        case .changeCase:    return "Регистр выделенного"
        case .translit:      return "Транслит выделенного"
        case .togglePause:   return "Пауза свитчера"
        case .undoLast:      return "Отменить переключение"
        }
    }
}

/// Привязка клавиши к действию.
///
///  • Tap — нажать и отпустить модификатор (Option/Control/Command/Fn), не
///    задев других клавиш. keyCode — код самого модификатора.
///  • Combo — обычное сочетание: keyCode клавиши + набор модификаторов.
struct HotkeyBinding: Equatable {
    /// -1 — не назначено. (0 нельзя: это kVK_ANSI_A.)
    var keyCode: Int = -1
    var isTap: Bool = false
    /// Для tap — нужен ли Shift; для combo — часть набора модификаторов.
    var shift: Bool = false
    var command: Bool = false
    var control: Bool = false
    var option: Bool = false

    var isBound: Bool { keyCode >= 0 }

    /// Модификаторы combo как флаги события.
    var comboFlags: CGEventFlags {
        var f: CGEventFlags = []
        if shift { f.insert(.maskShift) }
        if command { f.insert(.maskCommand) }
        if control { f.insert(.maskControl) }
        if option { f.insert(.maskAlternate) }
        return f
    }

    var display: String {
        guard isBound else { return "—" }
        let name = HotkeyBinding.keyName(keyCode)
        if isTap { return shift ? "⇧ + тап \(name)" : "тап \(name)" }
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        return parts.joined() + name
    }

    static func keyName(_ kc: Int) -> String {
        switch kc {
        case 58: return "левый Option"
        case 61: return "правый Option"
        case 59: return "левый Control"
        case 62: return "правый Control"
        case 55: return "левый Command"
        case 54: return "правый Command"
        case 56: return "левый Shift"
        case 60: return "правый Shift"
        case 63: return "Fn"
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Esc"
        case 51: return "Backspace"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            // Буква/цифра — по текущей раскладке через Carbon; иначе код
            if let s = LayoutResolver.translate(keyCode: CGKeyCode(kc), shift: false, capsLock: false, to: .en),
               !s.isEmpty {
                return s.uppercased()
            }
            return "kc\(kc)"
        }
    }

    /// keyCode модификатора → его флаг (для tap-детекции).
    static func modifierFlag(for kc: Int) -> CGEventFlags? {
        switch kc {
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 55, 54: return .maskCommand
        case 56, 60: return .maskShift
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    // MARK: - JSON

    var json: [String: Any] {
        ["keyCode": keyCode, "isTap": isTap, "shift": shift,
         "command": command, "control": control, "option": option]
    }

    init() {}

    init(keyCode: Int, isTap: Bool = false, shift: Bool = false,
         command: Bool = false, control: Bool = false, option: Bool = false) {
        self.keyCode = keyCode; self.isTap = isTap; self.shift = shift
        self.command = command; self.control = control; self.option = option
    }

    init?(json: [String: Any]) {
        guard let kc = json["keyCode"] as? Int else { return nil }
        keyCode = kc
        isTap   = json["isTap"]   as? Bool ?? false
        shift   = json["shift"]   as? Bool ?? false
        command = json["command"] as? Bool ?? false
        control = json["control"] as? Bool ?? false
        option  = json["option"]  as? Bool ?? false
    }
}

/// Набор привязок. Умолчания — то, что было зашито до 4.0:
/// правый Option — свап, левый — выделение, ⌘⇧Space, ⌃⇧U/T, Esc.
final class HotkeyMap {
    private(set) var bindings: [HotkeyAction: HotkeyBinding] = HotkeyMap.defaults

    static let defaults: [HotkeyAction: HotkeyBinding] = [
        .swapWord:      HotkeyBinding(keyCode: 61, isTap: true),
        .swapAndLearn:  HotkeyBinding(keyCode: 61, isTap: true, shift: true),
        .swapSelection: HotkeyBinding(keyCode: 58, isTap: true),
        .swapSelectionLetters: HotkeyBinding(keyCode: 58, isTap: true, shift: true),
        .swapAndRule: HotkeyBinding(),   // не назначен — назначается в настройках хоткеев
        .universal:     HotkeyBinding(keyCode: 49, shift: true, command: true),
        .changeCase:    HotkeyBinding(keyCode: 32, shift: true, control: true),
        .translit:      HotkeyBinding(keyCode: 17, shift: true, control: true),
        .togglePause:   HotkeyBinding(),
        .undoLast:      HotkeyBinding(keyCode: 53),
    ]

    func binding(for action: HotkeyAction) -> HotkeyBinding {
        bindings[action] ?? HotkeyBinding()
    }

    func set(_ b: HotkeyBinding, for action: HotkeyAction) {
        bindings[action] = b
    }

    func reset() { bindings = HotkeyMap.defaults }

    /// keyCode'ы модификаторов, по которым есть тапы.
    var tapKeyCodes: Set<Int> {
        Set(bindings.values.filter { $0.isBound && $0.isTap }.map { $0.keyCode })
    }

    /// Действие для тапа по модификатору. Shift-вариант в приоритете, если есть.
    func tapAction(keyCode: Int, withShift: Bool) -> HotkeyAction? {
        let candidates = bindings.filter { $0.value.isBound && $0.value.isTap && $0.value.keyCode == keyCode }
        if withShift, let s = candidates.first(where: { $0.value.shift }) { return s.key }
        return candidates.first(where: { !$0.value.shift })?.key
    }

    /// Действие для сочетания: keyCode + ТОЧНО такой набор модификаторов.
    func comboAction(keyCode: Int, flags: CGEventFlags) -> HotkeyAction? {
        let mask: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskAlternate]
        let pressed = flags.intersection(mask)
        for (action, b) in bindings where b.isBound && !b.isTap && b.keyCode == keyCode {
            if b.comboFlags == pressed { return action }
        }
        return nil
    }

    // MARK: - JSON

    var json: [String: Any] {
        var out: [String: Any] = [:]
        for (a, b) in bindings { out[a.rawValue] = b.json }
        return out
    }

    func load(json: [String: Any]?) {
        var result = HotkeyMap.defaults
        guard let json = json else { bindings = result; return }
        for (key, value) in json {
            guard let action = HotkeyAction(rawValue: key),
                  let dict = value as? [String: Any],
                  let b = HotkeyBinding(json: dict) else { continue }
            result[action] = b
        }
        bindings = result
    }
}

// MARK: - Окно назначения

/// Окно «Настроить горячие клавиши»: строка на действие, кнопка «Назначить»
/// ловит следующее нажатие через tap свитчера (тап модификатора или
/// сочетание), «Сбросить» возвращает умолчания.
final class HotkeySettingsWindow: NSObject {
    private var window: NSWindow?
    private var labels: [HotkeyAction: NSTextField] = [:]
    private let map: HotkeyMap
    private let capture: (@escaping (HotkeyBinding?) -> Void) -> Void
    private let onChange: () -> Void
    private var hint: NSTextField!

    /// capture — попросить свитчер поймать следующее нажатие; в замыкание
    /// приходит привязка (nil — отмена).
    init(map: HotkeyMap,
         capture: @escaping (@escaping (HotkeyBinding?) -> Void) -> Void,
         onChange: @escaping () -> Void) {
        self.map = map
        self.capture = capture
        self.onChange = onChange
        super.init()
    }

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let actions = HotkeyAction.allCases
        let rowH: CGFloat = 30
        let width: CGFloat = 520
        let height = CGFloat(actions.count) * rowH + 90

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "QSwitcher — горячие клавиши"
        w.isReleasedWhenClosed = false
        w.center()
        let content = NSView(frame: w.contentView!.bounds)
        w.contentView = content

        var y = height - 40
        for action in actions {
            let name = NSTextField(labelWithString: action.title)
            name.frame = NSRect(x: 16, y: y, width: 230, height: 20)
            content.addSubview(name)

            let value = NSTextField(labelWithString: map.binding(for: action).display)
            value.frame = NSRect(x: 250, y: y, width: 160, height: 20)
            value.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            content.addSubview(value)
            labels[action] = value

            let btn = NSButton(title: "Назначить", target: self, action: #selector(assign(_:)))
            btn.frame = NSRect(x: 420, y: y - 4, width: 90, height: 26)
            btn.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            content.addSubview(btn)
            y -= rowH
        }

        hint = NSTextField(wrappingLabelWithString:
            "Тап — нажать и отпустить модификатор, ничего больше не задев. Сочетание — клавиша с ⌘/⌃/⌥/⇧.")
        hint.frame = NSRect(x: 16, y: 14, width: 340, height: 34)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)

        let reset = NSButton(title: "Сбросить", target: self, action: #selector(resetAll))
        reset.frame = NSRect(x: 420, y: 14, width: 90, height: 26)
        content.addSubview(reset)

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func assign(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let action = HotkeyAction(rawValue: id) else { return }
        hint.stringValue = "Нажми сочетание или тапни модификатор для «\(action.title)»… (Esc — оставить как есть)"
        hint.textColor = .systemBlue
        capture { [weak self] binding in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.hint.textColor = .secondaryLabelColor
                if let b = binding {
                    self.map.set(b, for: action)
                    self.labels[action]?.stringValue = b.display
                    self.hint.stringValue = "«\(action.title)» → \(b.display)"
                    self.onChange()
                } else {
                    self.hint.stringValue = "Отменено"
                }
            }
        }
    }

    @objc private func resetAll() {
        map.reset()
        for (action, label) in labels { label.stringValue = map.binding(for: action).display }
        hint.stringValue = "Умолчания восстановлены"
        onChange()
    }
}
