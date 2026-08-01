import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var switcher: Switcher!

    // Динамические пункты меню
    private var headerItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private var excludeItem: NSMenuItem!
    private var stopWordsMenuItem: NSMenuItem!
    private var forceWordsMenuItem: NSMenuItem!
    private var excludedAppsMenuItem: NSMenuItem!
    private var infoItem: NSMenuItem!
    private var logSubmenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()

        if !trusted {
            updateStatusBar(trusted: false, lang: .en)
            fputs("⚠️  Нет прав Accessibility. Жду выдачи…\n", stderr)
            startWaitingForAccessibility()
            return
        }

        startCore()
    }

    /// Ждём появления прав и стартуем сами, без перезапуска приложения.
    ///
    /// Раньше приложение проверяло права один раз и, не найдя их, сдавалось
    /// навсегда: выдал галку — изволь убить и запустить заново. Теперь опрашиваем
    /// раз в две секунды. Опрос БЕЗ kAXTrustedCheckOptionPrompt, иначе системный
    /// диалог будет выскакивать каждые две секунды.
    private var accessibilityTimer: Timer?

    private func startWaitingForAccessibility() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.accessibilityTimer = nil
            print("✅ Права Accessibility появились — запускаюсь")
            self?.startCore()
        }
        // Таймер должен тикать и когда открыто меню
        if let t = accessibilityTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    /// Основной запуск: конфиг, лог, перехват. Вызывается либо сразу,
    /// либо когда права наконец выданы.
    private func startCore() {

        _ = Config.shared

        // SecureLog инициализация из конфига
        let cfg = Config.shared
        SecureLog.shared.enabled = cfg.logEnabled
        SecureLog.shared.logSecureInput = cfg.logSecureInput
        SecureLog.shared.bufferFlushBytes = cfg.logBufferFlushMB * 1024 * 1024
        SecureLog.shared.dbSizeLimitBytes = cfg.logDbSizeLimitMB * 1024 * 1024
        SecureLog.shared.flushIntervalMinutes = cfg.logFlushIntervalMinutes
        if cfg.logEnabled {
            SecureLog.shared.start()
        }

        switcher = Switcher()
        switcher.onLanguageChanged = { [weak self] lang in
            self?.updateStatusBar(trusted: true, lang: lang)
        }
        switcher.start()
        updateStatusBar(trusted: true, lang: switcher.currentLang)
    }

    // MARK: - Status bar icon

    private func updateStatusBar(trusted: Bool, lang: InputSource.Lang) {
        guard let btn = statusItem.button else { return }

        if !trusted {
            btn.title = "⌨︎!"
            btn.image = nil
            btn.toolTip = "QSwitcher — нет прав Accessibility"
            return
        }

        if !Config.shared.enabled {
            btn.title = "⏸"
            btn.image = nil
            btn.toolTip = "QSwitcher на паузе"
            return
        }

        // Текстовый индикатор RU/EN.
        let label = (lang == .ru) ? "RU" : "EN"
        btn.image = nil
        btn.title = label
        btn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        btn.toolTip = "QSwitcher — текущая раскладка: \(label)"
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        headerItem = NSMenuItem(title: "QSwitcher", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        pauseItem = NSMenuItem(title: "Поставить на паузу", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let manual = NSMenuItem(title: "Переключить последнее слово",
                                action: #selector(forceSwitch), keyEquivalent: " ")
        manual.keyEquivalentModifierMask = [.command, .shift]
        manual.target = self
        menu.addItem(manual)

        soundItem = NSMenuItem(title: "Звук переключения", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        menu.addItem(soundItem)

        menu.addItem(NSMenuItem.separator())

        excludeItem = NSMenuItem(title: "Исключить текущее приложение",
                                 action: #selector(toggleExcludeCurrentApp), keyEquivalent: "")
        excludeItem.target = self
        menu.addItem(excludeItem)

        excludedAppsMenuItem = NSMenuItem(title: "Исключённые приложения", action: nil, keyEquivalent: "")
        excludedAppsMenuItem.submenu = NSMenu()
        menu.addItem(excludedAppsMenuItem)

        menu.addItem(NSMenuItem.separator())

        stopWordsMenuItem = NSMenuItem(title: "Стоп-слова (никогда не переключать)", action: nil, keyEquivalent: "")
        stopWordsMenuItem.submenu = NSMenu()
        menu.addItem(stopWordsMenuItem)

        forceWordsMenuItem = NSMenuItem(title: "Форс-слова (всегда переключать)", action: nil, keyEquivalent: "")
        forceWordsMenuItem.submenu = NSMenu()
        menu.addItem(forceWordsMenuItem)

        menu.addItem(NSMenuItem.separator())

        let openCfg = NSMenuItem(title: "Открыть конфиг…",
                                 action: #selector(openConfig), keyEquivalent: ",")
        openCfg.target = self
        menu.addItem(openCfg)

        let reloadCfg = NSMenuItem(title: "Перезагрузить конфиг",
                                   action: #selector(reloadConfig), keyEquivalent: "r")
        reloadCfg.target = self
        menu.addItem(reloadCfg)

        let logMenu = NSMenuItem(title: "Защищённый лог", action: nil, keyEquivalent: "")
        logMenu.submenu = buildLogSubmenu()
        logSubmenuItem = logMenu
        menu.addItem(logMenu)

        let help = NSMenuItem(title: "Справка / Горячие клавиши…",
                              action: #selector(showHelp), keyEquivalent: "?")
        help.target = self
        menu.addItem(help)

        let learned = NSMenuItem(title: "Выученные правила…", action: #selector(showLearned), keyEquivalent: "")
        learned.target = self
        menu.addItem(learned)

        let resetLearn = NSMenuItem(title: "Сбросить выученное…", action: #selector(resetLearned), keyEquivalent: "")
        resetLearn.target = self
        menu.addItem(resetLearn)

        let about = NSMenuItem(title: "О программе…", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        Config.shared.reload()
        refreshDynamicMenuItems()
        refreshLogSubmenu()
    }

    private func refreshDynamicMenuItems() {
        let cfg = Config.shared
        let trusted = AXIsProcessTrusted()

        headerItem.title = !trusted ? "Нет прав Accessibility"
                          : (cfg.enabled ? "QSwitcher активен (\(switcher?.currentLang == .ru ? "RU" : "EN"))" : "QSwitcher на паузе")

        pauseItem.title = cfg.enabled ? "Поставить на паузу" : "Возобновить"
        soundItem.state = cfg.soundEnabled ? .on : .off

        // Исключение текущего приложения
        let bid = switcher?.lastUserAppBundleId
        if let id = bid {
            if cfg.excludedApps.contains(id) {
                excludeItem.title = "Снять исключение: \(id)"
            } else {
                excludeItem.title = "Исключить: \(id)"
            }
            excludeItem.isEnabled = true
        } else {
            excludeItem.title = "Исключить текущее приложение"
            excludeItem.isEnabled = false
        }

        // Подменю исключённых приложений
        let excludedMenu = excludedAppsMenuItem.submenu!
        excludedMenu.removeAllItems()
        if cfg.excludedApps.isEmpty {
            let empty = NSMenuItem(title: "(пусто)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            excludedMenu.addItem(empty)
        } else {
            for app in cfg.excludedApps.sorted() {
                let item = NSMenuItem(title: "\(app)    ✕", action: #selector(removeExcludedApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app
                item.toolTip = "Клик — удалить из исключений"
                excludedMenu.addItem(item)
            }
        }
        excludedAppsMenuItem.title = "Исключённые приложения (\(cfg.excludedApps.count))"

        // Подменю стоп-слов
        rebuildWordMenu(stopWordsMenuItem,
                        words: cfg.stopWords,
                        addAction: #selector(addStopWord),
                        removeAction: #selector(removeStopWord(_:)),
                        title: "Стоп-слова (никогда не переключать)")

        // Подменю форс-слов
        rebuildWordMenu(forceWordsMenuItem,
                        words: cfg.forceWords,
                        addAction: #selector(addForceWord),
                        removeAction: #selector(removeForceWord(_:)),
                        title: "Форс-слова (всегда переключать)")

        infoItem.title = "Исключений: \(cfg.excludedApps.count) · стоп: \(cfg.stopWords.count) · форс: \(cfg.forceWords.count)"
    }

    private func rebuildWordMenu(_ menuItem: NSMenuItem, words: Set<String>,
                                 addAction: Selector, removeAction: Selector, title: String) {
        let m = menuItem.submenu!
        m.removeAllItems()
        let add = NSMenuItem(title: "+ Добавить…", action: addAction, keyEquivalent: "")
        add.target = self
        m.addItem(add)
        m.addItem(NSMenuItem.separator())
        if words.isEmpty {
            let empty = NSMenuItem(title: "(пусто)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            m.addItem(empty)
        } else {
            for w in words.sorted() {
                let item = NSMenuItem(title: "\(w)    ✕", action: removeAction, keyEquivalent: "")
                item.target = self
                item.representedObject = w
                item.toolTip = "Клик — удалить"
                m.addItem(item)
            }
        }
        menuItem.title = "\(title) (\(words.count))"
    }

    // MARK: - Actions

    @objc private func togglePause() {
        Config.shared.setEnabled(!Config.shared.enabled)
        updateStatusBar(trusted: AXIsProcessTrusted(), lang: switcher?.currentLang ?? .en)
        refreshDynamicMenuItems()
    }

    @objc private func toggleSound() {
        Config.shared.setSoundEnabled(!Config.shared.soundEnabled)
        refreshDynamicMenuItems()
    }

    @objc private func forceSwitch() {
        switcher?.forceSwitchLastWord()
    }

    @objc private func toggleExcludeCurrentApp() {
        guard let bid = switcher?.lastUserAppBundleId else { return }
        Config.shared.toggleExcludedApp(bid)
        refreshDynamicMenuItems()
    }

    @objc private func removeExcludedApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        Config.shared.toggleExcludedApp(bid)    // toggle = снять, раз есть в списке
        refreshDynamicMenuItems()
    }

    @objc private func addStopWord() {
        guard let word = promptForWord(
            title: "Добавить стоп-слово",
            message: "Это слово никогда не будет переключаться (в любой раскладке)."
        ) else { return }
        Config.shared.addStopWord(word)
        refreshDynamicMenuItems()
    }

    @objc private func removeStopWord(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? String else { return }
        Config.shared.removeStopWord(w)
        refreshDynamicMenuItems()
    }

    @objc private func addForceWord() {
        guard let word = promptForWord(
            title: "Добавить форс-слово",
            message: "Это слово будет всегда переключаться, даже если эвристика молчит."
        ) else { return }
        Config.shared.addForceWord(word)
        refreshDynamicMenuItems()
    }

    @objc private func removeForceWord(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? String else { return }
        Config.shared.removeForceWord(w)
        refreshDynamicMenuItems()
    }

    @objc private func openConfig() {
        Config.shared.openInEditor()
    }

    @objc private func reloadConfig() {
        Config.shared.reload()
        refreshDynamicMenuItems()
    }

    // MARK: - SecureLog menu

    private func buildLogSubmenu() -> NSMenu {
        let m = NSMenu()

        let toggle = NSMenuItem(title: "Логирование", action: #selector(toggleLog), keyEquivalent: "")
        toggle.target = self
        toggle.tag = 1
        m.addItem(toggle)

        let secureInput = NSMenuItem(title: "Логировать пароли (Secure Input)",
                                     action: #selector(toggleLogSecureInput), keyEquivalent: "")
        secureInput.target = self
        secureInput.tag = 2
        m.addItem(secureInput)

        m.addItem(NSMenuItem.separator())

        let flushNow = NSMenuItem(title: "Выгрузить в базу сейчас",
                                  action: #selector(logFlushNow), keyEquivalent: "")
        flushNow.target = self
        m.addItem(flushNow)

        let export = NSMenuItem(title: "Экспортировать (расшифровать)…",
                                action: #selector(logExport), keyEquivalent: "")
        export.target = self
        m.addItem(export)

        m.addItem(NSMenuItem.separator())

        // Интервал авто-сброса
        let intervalMenu = NSMenu()
        for (label, mins) in [("Только триггеры", 0), ("Каждые 2 мин", 2),
                              ("Каждые 20 мин", 20), ("Каждые 2 часа", 120),
                              ("Каждые 24 часа", 1440)] {
            let item = NSMenuItem(title: label, action: #selector(setLogInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mins
            intervalMenu.addItem(item)
        }
        let intervalItem = NSMenuItem(title: "Интервал сброса буфера", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        m.addItem(intervalItem)

        // Лимит базы
        let sizeMenu = NSMenu()
        for (label, mb) in [("100 МБ", 100), ("500 МБ", 500), ("1 ГБ", 1024), ("3 ГБ", 3072)] {
            let item = NSMenuItem(title: label, action: #selector(setLogDbLimit(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mb
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Лимит размера базы", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        m.addItem(sizeItem)

        m.addItem(NSMenuItem.separator())

        // Очистка
        let cleanMenu = NSMenu()
        let cleanOptions: [(String, SecureLog.CleanupAge)] = [
            ("Очистить всё", .all),
            ("Старше месяца", .olderThanMonths(1)),
            ("Старше полугода", .olderThanMonths(6)),
            ("Старше года", .olderThanYears(1)),
            ("Старше 3 лет", .olderThanYears(3)),
        ]
        for (label, age) in cleanOptions {
            let item = NSMenuItem(title: label, action: #selector(cleanLog(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = LogCleanupBox(age: age)
            cleanMenu.addItem(item)
        }
        let cleanItem = NSMenuItem(title: "Очистить базу", action: nil, keyEquivalent: "")
        cleanItem.submenu = cleanMenu
        m.addItem(cleanItem)

        m.addItem(NSMenuItem.separator())
        let stats = NSMenuItem(title: "Статистика…", action: #selector(logStats), keyEquivalent: "")
        stats.target = self
        m.addItem(stats)

        return m
    }

    // Box чтобы протащить enum через representedObject
    private final class LogCleanupBox {
        let age: SecureLog.CleanupAge
        init(age: SecureLog.CleanupAge) { self.age = age }
    }

    /// Обёртка: выполнить действие только после Touch ID.
    private func withTouchID(reason: String, _ action: @escaping () -> Void) {
        SecureLogCrypto.authenticate(reason: reason) { ok in
            if ok { action() }
            else { self.showSimpleAlert(title: "Доступ отклонён", text: "Аутентификация не пройдена.") }
        }
    }

    @objc private func toggleLog() {
        withTouchID(reason: "изменить настройку логирования") {
            let new = !Config.shared.logEnabled
            Config.shared.setLogEnabled(new)
            SecureLog.shared.enabled = new
            if new {
                SecureLog.shared.start()
            } else {
                SecureLog.shared.stop()
            }
            self.refreshLogSubmenu()
        }
    }

    @objc private func toggleLogSecureInput() {
        withTouchID(reason: "изменить логирование паролей") {
            let new = !Config.shared.logSecureInput
            Config.shared.setLogSecureInput(new)
            SecureLog.shared.logSecureInput = new
            self.refreshLogSubmenu()
        }
    }

    @objc private func logFlushNow() {
        SecureLog.shared.flushNow(reason: "manual")
        showSimpleAlert(title: "Готово", text: "Буфер выгружен в базу.")
    }

    @objc private func logExport() {
        withTouchID(reason: "экспортировать расшифрованный лог") {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "QSwitcher-log-\(Self.dateStamp()).txt"
            panel.canCreateDirectories = true
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                SecureLog.shared.exportDecrypted(to: url) { ok, err in
                    if ok {
                        self.showSimpleAlert(title: "Экспортировано", text: url.path)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        self.showSimpleAlert(title: "Ошибка", text: err ?? "не удалось")
                    }
                }
            }
        }
    }

    @objc private func setLogInterval(_ sender: NSMenuItem) {
        guard let mins = sender.representedObject as? Int else { return }
        withTouchID(reason: "изменить интервал сброса") {
            Config.shared.setLogFlushIntervalMinutes(mins)
            SecureLog.shared.flushIntervalMinutes = mins
            SecureLog.shared.restartFlushTimer()
            self.refreshLogSubmenu()
        }
    }

    @objc private func setLogDbLimit(_ sender: NSMenuItem) {
        guard let mb = sender.representedObject as? Int else { return }
        withTouchID(reason: "изменить лимит размера базы") {
            Config.shared.setLogDbSizeLimitMB(mb)
            SecureLog.shared.dbSizeLimitBytes = mb * 1024 * 1024
            self.refreshLogSubmenu()
        }
    }

    @objc private func cleanLog(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? LogCleanupBox else { return }
        withTouchID(reason: "очистить базу логов") {
            SecureLog.shared.cleanup(box.age) { deleted in
                self.showSimpleAlert(title: "Очищено", text: "Удалено блоков: \(deleted)")
            }
        }
    }

    @objc private func logStats() {
        SecureLog.shared.currentStats { blocks, dbBytes, bufLines in
            let mb = String(format: "%.1f", Double(dbBytes) / 1024.0 / 1024.0)
            self.showSimpleAlert(
                title: "Статистика лога",
                text: "Блоков в базе: \(blocks)\nРазмер базы: \(mb) МБ\nВ буфере (RAM): \(bufLines) строк"
            )
        }
    }

    private func refreshLogSubmenu() {
        guard let sub = logSubmenuItem?.submenu else { return }
        let cfg = Config.shared
        if let toggle = sub.item(withTag: 1) {
            toggle.state = cfg.logEnabled ? .on : .off
        }
        if let secure = sub.item(withTag: 2) {
            secure.state = cfg.logSecureInput ? .on : .off
        }
        logSubmenuItem.title = cfg.logEnabled ? "Защищённый лог (вкл)" : "Защищённый лог (выкл)"
    }

    private func showSimpleAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func dateStamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        return df.string(from: Date())
    }

    @objc private func showLearned() {
        let r = LearnedRules.shared
        let stopList  = r.stop.sorted().joined(separator: ", ")
        let forceList = r.force.sorted().joined(separator: ", ")
        let body = """
        Свитчер запоминает твои исправления:
        откатил переключение — больше не трогает,
        переключил вручную — впредь делает сам.

        Правила создаются ТОЛЬКО через ⇧ + правый Option.
        Обычный свап и тоггл ничего не меняют — можно спокойно
        смотреть оба варианта, правило не перезапишется.

        ━━━ НЕ ПЕРЕКЛЮЧАТЬ (\(r.stop.count)) ━━━

        \(stopList.isEmpty ? "—" : stopList)

        ━━━ ПЕРЕКЛЮЧАТЬ (\(r.force.count)) ━━━

        \(forceList.isEmpty ? "—" : forceList)

        ━━━━━━━━━━━━━━━━━━━━

        Сбросить: меню → «Сбросить выученное…»
        Файл: ~/Library/Application Support/QSwitcher/learned.json
        """
        showScrollableText(title: "Выученные правила", body: body)
    }

    @objc private func resetLearned() {
        let r = LearnedRules.shared
        let alert = NSAlert()
        alert.messageText = "Сбросить выученные правила?"
        alert.informativeText = "Сейчас записано: \(r.summary).\nПосле сброса свитчер начнёт учиться заново."
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Сбросить")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            LearnedRules.shared.reset()
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = AppVersion.fullString
        alert.informativeText = """
        Автопереключатель раскладки RU↔EN для macOS.
        Автоматически исправляет текст, набранный не в той раскладке.

        Версия: \(AppVersion.version)
        Билд: #\(AppVersion.build)
        Собрано: \(AppVersion.buildDate)

        Словари: github.com/danakt/russian-words,
        github.com/dwyl/english-words
        Детектор: github.com/graninilya/keyswitcher (MIT)
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }


    /// Окно с прокруткой для длинных текстов.
    ///
    /// NSAlert для справки не годится: он не умеет прокрутку и просто растёт по
    /// высоте, пока не уедет за нижнюю границу экрана. При этом он модальный,
    /// поэтому висит поверх всего и не закрывается — приходилось убивать процесс.
    private var textWindows: [NSWindow] = []

    private func showScrollableText(title: String, body: String) {
        // Если такое окно уже открыто — просто выводим его вперёд
        if let existing = textWindows.first(where: { $0.title == title }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let w = min(760, screen.width  * 0.55)
        let h = screen.height * 0.82

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 18, height: 16)
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = body
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true

        scroll.documentView = text
        window.contentView = scroll

        // Прокрутка в начало (NSTextView по умолчанию показывает конец)
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))

        textWindows.append(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.textWindows.removeAll { $0 === window }
        }

        // Уходим в другое приложение — окно убирается. Это утилита из строки меню,
        // её справка не должна висеть поверх работы.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak window] _ in
            window?.orderOut(nil)
        }

        // Esc закрывает
        window.standardWindowButton(.closeButton)?.isEnabled = true

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showHelp() {
        showScrollableText(title: "QSwitcher — горячие клавиши", body: """
        ━━━ ПЕРЕКЛЮЧЕНИЕ ━━━

        ПРАВЫЙ Option — переключить набранное / тоггл
            Свапает последнее набранное слово (буфер).
            Если уже свапнул — тоггл туда-обратно.
            Удобно: рука на клавиатуре, набрал — тапнул правый Option.

        ЛЕВЫЙ Option — переключить ВЫДЕЛЕННЫЙ мышкой текст
            Выделил мышью слово/фразу → тапнул левый Option → свапнулось.
            Работает с любым текстом, без проверки словарей.

        ⇧ + ПРАВЫЙ Option — переключить И ЗАПОМНИТЬ
            Свитчер запомнит решение для этого слова навсегда.
            Без Shift короткие слова (2–3 буквы) запоминаются сами,
            длинные — только по этой команде.

        ⌘⇧Space — универсально (выделение если есть, иначе буфер)

        Esc — отменить последнее автопереключение
            (10 секунд после переключения)

        ━━━ РАБОТА С ВЫДЕЛЕННЫМ ТЕКСТОМ ━━━

        ⌃⇧U — циклическая смена регистра выделенного:
            привет → Привет → ПРИВЕТ → привет

        ⌃⇧T — транслит выделенного: кириллица → латиница
            привет → privet
            (ГОСТ 7.79-2000)

        ━━━ МЕНЮ ━━━

        ⌘P — пауза/возобновить
        ⌘, — открыть конфиг в редакторе
        ⌘R — перезагрузить конфиг
        ⌘? — эта справка
        ⌘Q — выход

        ━━━ ИНДИКАТОР В СТРОКЕ МЕНЮ ━━━

        RU — текущая раскладка русская
        EN — текущая раскладка английская
        ⏸ — приложение на паузе
        ⌨︎! — нет прав Accessibility

        ━━━ СЛОВА ━━━

        • Стоп-слово — НИКОГДА не переключается
        • Форс-слово — ВСЕГДА переключается
        • Свои слова можно добавлять прямо в файл:
          ~/Library/Application Support/QSwitcher/dicts/ru.txt
          ~/Library/Application Support/QSwitcher/dicts/en.txt
          (одно слово на строку, нижний регистр)
        """)
    }

    @objc private func quit() {
        SecureLog.shared.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SecureLog.shared.stop()
    }

    // MARK: - Word input dialog

    private func promptForWord(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Добавить")
        alert.addButton(withTitle: "Отмена")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "слово"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let s = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        return nil
    }
}
