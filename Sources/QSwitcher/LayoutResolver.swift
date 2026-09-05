import Carbon
import Foundation

/// Динамическое чтение текущей раскладки клавиатуры через UCKeyTranslate.
/// Работает с любой пользовательской раскладкой (Russian, Russian-PC, Russian-Phonetic,
/// ABC, US, US-International и т.п.) — не зависит от хардкода.
enum LayoutResolver {

    typealias Map = [Character: Character]

    /// Построить мапы en↔ru на основе реальных установленных раскладок пользователя.
    /// Если найти пару EN+RU не удалось — возвращает nil (вызывающий должен использовать fallback).
    static func resolve() -> (enToRu: Map, ruToEn: Map)? {
        guard let sources = TISCreateInputSourceList(nil, false)?
                .takeRetainedValue() as? [TISInputSource] else {
            return nil
        }

        // Соберём ВСЕ EN и RU источники, потом выберем «лучшие»
        var enSources: [TISInputSource] = []
        var ruSources: [TISInputSource] = []
        for source in sources {
            guard isKeyboardSource(source) else { continue }
            guard let lang = primaryLanguage(source) else { continue }
            let id = sourceID(source) ?? "<noid>"
            print("source: lang=\(lang) id=\(id)")
            switch lang {
            case "en": enSources.append(source)
            case "ru": ruSources.append(source)
            default: break
            }
        }

        // Предпочитаем «канонические» Apple-раскладки: Russian (без -PC и без -Phonetic)
        // и ABC/US (без -International).
        let enSource = pickPreferred(enSources, preferring: ["com.apple.keylayout.US",
                                                              "com.apple.keylayout.ABC"])
        let ruSource = pickPreferred(ruSources, preferring: ["com.apple.keylayout.Russian"])
        if let id = enSource.flatMap(sourceID) { print("→ chose EN: \(id)") }
        if let id = ruSource.flatMap(sourceID) { print("→ chose RU: \(id)") }

        guard let en = enSource, let ru = ruSource else { return nil }
        guard let enData = layoutData(en), let ruData = layoutData(ru) else { return nil }
        // Сохраняем данные обеих раскладок: ручной свап переводит по кейкодам
        // через ПРОТИВОПОЛОЖНУЮ раскладку — символьная карта для знаков
        // неоднозначна ('\"' — и RU-Shift+2, и EN-клавиша «э»).
        enDataCache = enData
        ruDataCache = ruData

        var enToRu: Map = [:]
        var ruToEn: Map = [:]
        let kbdType = UInt32(LMGetKbdType())

        // Проходим все физические клавиши, без модификаторов и с Shift
        for kc in 0..<128 {
            for shift in [false, true] {
                let mods: UInt32 = shift ? 2 : 0  // Shift = 0x0200 >> 8 = 2
                guard let enChar = translateChar(enData, keycode: UInt16(kc),
                                                  modifiers: mods, kbdType: kbdType) else { continue }
                guard let ruChar = translateChar(ruData, keycode: UInt16(kc),
                                                  modifiers: mods, kbdType: kbdType) else { continue }
                guard let e = enChar.first, let r = ruChar.first else { continue }
                guard e != r else { continue }
                enToRu[e] = r
                ruToEn[r] = e
            }
        }

        enShiftPairs = shiftPairs(enData, kbdType: kbdType)
        ruShiftPairs = shiftPairs(ruData, kbdType: kbdType)

        return (enToRu, ruToEn)
    }

    // MARK: - Знак ↔ его Shift-вариант на той же клавише

    private static var enShiftPairs: Map = [:]
    private static var ruShiftPairs: Map = [:]

    /// Для знака, одинакового в обеих раскладках (на маке `/` и в RU `/`), свап
    /// выделения делает то же, что правый Option по кейкоду: та же клавиша с Shift
    /// (`/` ↔ `?`). Только знак ↔ знак: буквы и цифры не трогаем. Считается один
    /// раз в resolve() на main; читать можно из любого потока.
    static func shiftPairs(for lang: InputSource.Lang) -> Map {
        lang == .ru ? ruShiftPairs : enShiftPairs
    }

    private static func shiftPairs(_ data: Data, kbdType: UInt32) -> Map {
        var pairs: Map = [:]
        for kc in 0..<128 {
            guard let u = translateChar(data, keycode: UInt16(kc), modifiers: 0, kbdType: kbdType)?.first,
                  let sh = translateChar(data, keycode: UInt16(kc), modifiers: 2, kbdType: kbdType)?.first,
                  u != sh, !u.isLetter, !sh.isLetter, !u.isNumber, !sh.isNumber,
                  !u.isWhitespace, !sh.isWhitespace else { continue }
            if pairs[u] == nil { pairs[u] = sh }
            if pairs[sh] == nil { pairs[sh] = u }
        }
        return pairs
    }

    // MARK: - Перевод по конкретной раскладке

    private static var enDataCache: Data?
    private static var ruDataCache: Data?

    /// Перевести keycode по КОНКРЕТНОЙ раскладке (en/ru), независимо от активной.
    /// nil — если resolve() не отработал (нет данных) или клавиша не переводится.
    static func translate(keyCode: CGKeyCode, shift: Bool, capsLock: Bool,
                          to lang: InputSource.Lang) -> String? {
        guard let data = (lang == .ru) ? ruDataCache : enDataCache else { return nil }
        var mods: UInt32 = shift ? 2 : 0
        if capsLock { mods |= UInt32(alphaLock >> 8) }
        return translateChar(data, keycode: UInt16(keyCode),
                             modifiers: mods, kbdType: UInt32(LMGetKbdType()))
    }

    // MARK: - Helpers

    private static func isKeyboardSource(_ source: TISInputSource) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) else {
            return false
        }
        let value = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return value == (kTISCategoryKeyboardInputSource as String)
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func pickPreferred(_ sources: [TISInputSource],
                                       preferring ids: [String]) -> TISInputSource? {
        for preferredID in ids {
            if let s = sources.first(where: { sourceID($0) == preferredID }) {
                return s
            }
        }
        return sources.first
    }

    private static func primaryLanguage(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return nil
        }
        let langs = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] ?? []
        return langs.first
    }

    private static func layoutData(_ source: TISInputSource) -> Data? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let cfData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        return cfData as Data
    }

    private static func translateChar(_ data: Data, keycode: UInt16,
                                       modifiers: UInt32, kbdType: UInt32) -> String? {
        var deadKeyState: UInt32 = 0
        let maxLen = 4
        var buf = [UniChar](repeating: 0, count: maxLen)
        var actualLen = 0

        let status = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return -1
            }
            return UCKeyTranslate(
                layout,
                keycode,
                UInt16(kUCKeyActionDisplay),
                modifiers,
                kbdType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                maxLen,
                &actualLen,
                &buf
            )
        }
        guard status == noErr, actualLen > 0 else { return nil }
        return String(utf16CodeUnits: buf, count: actualLen)
    }
}
