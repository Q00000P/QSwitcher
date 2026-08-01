import Carbon

/// Обёртка над Text Input Services (Carbon): получить текущую раскладку
/// и переключиться на нужную.
enum InputSource {

    enum Lang { case en, ru }

    static func currentLanguage() -> Lang {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return .en }
        return language(of: src)
    }

    static func switchTo(_ target: Lang) {
        // TIS рассчитан на главный поток, а вызывать нас могут из очереди отправки.
        // Перенаправляем, иначе поведение непредсказуемое вплоть до падения.
        if !Thread.isMainThread {
            DispatchQueue.main.async { switchTo(target) }
            return
        }
        // Раскладка меняется — сбрасываем кэш нашего переводчика клавиш
        KeyTranslate.invalidateAndNotify()
        guard let listRaw = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return }
        let list = listRaw as! [TISInputSource]
        for src in list {
            // Только клавиатурные раскладки
            guard let catRaw = TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory) else { continue }
            let cat = Unmanaged<CFString>.fromOpaque(catRaw).takeUnretainedValue() as String
            if cat != (kTISCategoryKeyboardInputSource as String) { continue }

            // Должна быть выбираемой
            guard let selRaw = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable) else { continue }
            let sel = Unmanaged<CFBoolean>.fromOpaque(selRaw).takeUnretainedValue()
            if !CFBooleanGetValue(sel) { continue }

            if language(of: src) == target {
                TISSelectInputSource(src)
                return
            }
        }
    }

    private static func language(of source: TISInputSource) -> Lang {
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            let low = id.lowercased()
            if low.contains("russian") || low.contains(".ru") { return .ru }
        }
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            if let langs = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] {
                if langs.contains("ru") { return .ru }
            }
        }
        return .en
    }
}
