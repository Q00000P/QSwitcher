import Cocoa

/// Синхронизация навыков с другими устройствами (винда, другие маки): личный слой, выученные
/// правила, стоп- и форс-слова, исключённые приложения и английский ввод (свои для мака),
/// ожидание языка по приложениям, журнал профиля. Круг — SyncEngine (SyncModel.swift), зеркало
/// на винде — SyncService.cs.
///
/// Когда: через 15 с после запуска; раз в минуту (чужие файлы — если изменились, свои правила
/// и списки — если изменились; личный слой — не чаще раза в 5 минут); блокировка экрана, сон,
/// выход — отправить сразу; разблокировка, пробуждение — забрать сразу; «Синхронизировать
/// сейчас» — вручную.
///
/// Настройки — sync.json (без секретов), пароль синхронизации и входы в хранилища —
/// sync-secrets.qsp ("QSS1" + AES-GCM ключом данных QSwitcher из связки ключей, как личный слой).
final class SyncService: SyncHost {
    static let shared = SyncService()
    static let platformName = "mac"

    struct Settings: Codable {
        var backend = ""                                  // "gdrive" | "webdav" | ""
        var auto = true
        var webdavUrl = WebDAVTransport.defaultURL
        var webdavUser = ""
    }

    struct Secrets: Codable {
        var password = ""
        var gdriveRefresh = ""
        var webdavPassword = ""
    }

    private let queue = DispatchQueue(label: "qswitcher.sync", qos: .utility)
    private let lk = NSLock()
    private var settings = Settings()
    private var secrets = Secrets()
    private var cachedTransport: SyncTransport?
    private var lastError = "", loggedError = ""
    private var statusOk: Int64 = 0
    private var statusDevices: [String] = []
    private var queued = false, queuedForce = false
    private var stopping = false
    private var inlineMain = false
    private var timer: DispatchSourceTimer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Только на очереди синхронизации.
    private lazy var engine = SyncEngine(host: self, statePath: dir.appendingPathComponent("sync-state.json"),
                                         log: { print($0) })
    private var deviceId = ""

    private var dir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = appSupport.appendingPathComponent("QSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var settingsURL: URL { dir.appendingPathComponent("sync.json") }
    private var secretsURL: URL { dir.appendingPathComponent("sync-secrets.qsp") }
    private static let secretsMagic = Data("QSS1".utf8)

    private init() {
        if let d = try? Data(contentsOf: settingsURL), let s = try? JSONDecoder().decode(Settings.self, from: d) { settings = s }
        if let d = try? Data(contentsOf: secretsURL) {
            do {
                guard d.count > 4, d.prefix(4) == SyncService.secretsMagic else { throw SyncError("не QSS1") }
                secrets = try JSONDecoder().decode(Secrets.self, from: try DataKey.open(Data(d.dropFirst(4))))
            } catch {
                print("[sync] секреты не прочитались — подключение и пароль нужно задать заново")
            }
        }
    }

    private func locked<T>(_ f: () -> T) -> T { lk.lock(); defer { lk.unlock() }; return f() }
    private var isStopping: Bool { locked { stopping } }

    private func saveAll() {
        let (s, sec) = locked { (settings, secrets) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(s) { try? d.write(to: settingsURL, options: .atomic) }
        do {
            var out = SyncService.secretsMagic
            out.append(try DataKey.seal(try JSONEncoder().encode(sec)))
            try out.write(to: secretsURL, options: .atomic)
        } catch {
            print("[sync] ⚠️ секреты не записались: \(error)")
        }
    }

    // MARK: - Состояние для меню

    var configured: Bool { locked { settings.backend == "gdrive" || settings.backend == "webdav" } }
    var auto: Bool { locked { settings.auto } }
    var backend: String { locked { settings.backend } }
    var hasPassword: Bool { locked { !secrets.password.isEmpty } }
    var webdavURL: String { locked { settings.webdavUrl } }
    var webdavUser: String { locked { settings.webdavUser } }

    var whereTitle: String {
        let (b, url) = locked { (settings.backend, settings.webdavUrl) }
        switch b {
        case "gdrive": return "Google Drive"
        case "webdav": return "WebDAV (\(URL(string: url)?.host ?? url))"
        default: return "не настроена"
        }
    }

    func statusLine() -> String {
        guard configured else { return "Не настроена" }
        let (err, ok) = locked { (lastError, statusOk) }
        if !err.isEmpty { return "\(whereTitle): ⚠️ \(err)" }
        return ok == 0 ? "\(whereTitle): ещё не было" : "\(whereTitle): \(SyncService.ago(ok))"
    }

    func deviceLines() -> [String] {
        ["\(SkillsFile.computerName) (этот мак)"] + locked { statusDevices }
    }

    static func ago(_ ms: Int64) -> String {
        guard ms > 0 else { return "—" }
        let t = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let d = Date().timeIntervalSince(t)
        if d < 60 { return "только что" }
        if d < 3600 { return "\(Int(d / 60)) мин назад" }
        let f = DateFormatter()
        if Calendar.current.isDateInToday(t) { f.dateFormat = "HH:mm"; return "сегодня в \(f.string(from: t))" }
        f.dateFormat = "dd.MM HH:mm"
        return f.string(from: t)
    }

    /// Только на очереди: снимок для меню.
    private func updateStatus() {
        let st = engine.state
        let lines = st.remote.values.sorted { $0.deviceName < $1.deviceName }.map { r -> String in
            let name = r.deviceName.isEmpty ? r.name : r.deviceName
            let plat = r.platform == "mac" ? "мак" : r.platform == "win" ? "винда" : (r.platform.isEmpty ? "?" : r.platform)
            return r.error.isEmpty ? "\(name) (\(plat)), файл \(SyncService.ago(r.updated))" : "\(name): \(r.error)"
        }
        locked { statusOk = st.lastOk; statusDevices = lines }
    }

    // MARK: - Google client (из переменных окружения при сборке)

    /// Client ID и secret Desktop-клиента Google: make-app.sh кладёт их в Info.plist из переменных
    /// окружения QS_GOOGLE_CLIENT_ID / QS_GOOGLE_CLIENT_SECRET (при запуске из терминала — и прямо
    /// из переменных). В исходниках их нет.
    static func googleClient() -> (id: String, secret: String) {
        let env = ProcessInfo.processInfo.environment
        if let i = env["QS_GOOGLE_CLIENT_ID"], let s = env["QS_GOOGLE_CLIENT_SECRET"],
           !i.trimmingCharacters(in: .whitespaces).isEmpty, !s.trimmingCharacters(in: .whitespaces).isEmpty {
            return (i.trimmingCharacters(in: .whitespaces), s.trimmingCharacters(in: .whitespaces))
        }
        let i = (Bundle.main.object(forInfoDictionaryKey: "QSGoogleClientID") as? String ?? "").trimmingCharacters(in: .whitespaces)
        let s = (Bundle.main.object(forInfoDictionaryKey: "QSGoogleClientSecret") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return (i, s)
    }

    static var googleAvailable: Bool { let g = googleClient(); return !g.id.isEmpty && !g.secret.isEmpty }

    /// Хранилище по настройкам (кэшируется: токен Google живёт час).
    private func transport() -> (SyncTransport?, String, String) {
        lk.lock(); defer { lk.unlock() }
        let pw = secrets.password
        guard !pw.isEmpty else { return (nil, "нет пароля синхронизации", pw) }
        if let t = cachedTransport { return (t, "", pw) }
        switch settings.backend {
        case "gdrive":
            let g = SyncService.googleClient()
            guard !g.id.isEmpty, !g.secret.isEmpty else { return (nil, "в этой сборке нет ключа Google (QS_GOOGLE_CLIENT_ID)", pw) }
            guard !secrets.gdriveRefresh.isEmpty else { return (nil, "нет входа в Google — «Подключить Google Drive…»", pw) }
            cachedTransport = GoogleDriveTransport(clientId: g.id, clientSecret: g.secret,
                                                   refreshToken: secrets.gdriveRefresh, device: deviceId)
        case "webdav":
            guard !settings.webdavUser.isEmpty, !secrets.webdavPassword.isEmpty else { return (nil, "нет логина WebDAV", pw) }
            cachedTransport = try? WebDAVTransport(baseURL: settings.webdavUrl, user: settings.webdavUser,
                                                   password: secrets.webdavPassword)
            if cachedTransport == nil { return (nil, "WebDAV: неверный адрес", pw) }
        default:
            return (nil, "не настроена", pw)
        }
        return (cachedTransport, "", pw)
    }

    // MARK: - Запуск и события

    /// Таймер и системные события (на главном потоке, после загрузки личного слоя).
    func start() {
        deviceId = PersonalLM.shared.local.device
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 60)
        t.setEventHandler { [weak self] in self?.request(forcePush: false, reason: "таймер") }
        t.resume()
        timer = t

        let ws = NSWorkspace.shared.notificationCenter
        func on(_ c: NotificationCenter, _ name: Notification.Name, _ f: @escaping () -> Void) {
            observers.append((c, c.addObserver(forName: name, object: nil, queue: .main) { _ in f() }))
        }
        // Сон — отправить, дождавшись (пара секунд до засыпания есть); пробуждение — забрать,
        // когда поднимется сеть
        on(ws, NSWorkspace.willSleepNotification) { [weak self] in self?.pushBlocking(timeout: 5, reason: "сон") }
        on(ws, NSWorkspace.didWakeNotification) { [weak self] in self?.request(forcePush: false, reason: "пробуждение", delay: 10) }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.request(forcePush: true, reason: "смена пользователя") }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.request(forcePush: false, reason: "возврат", delay: 3) }
        let dn = DistributedNotificationCenter.default()
        on(dn, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.request(forcePush: true, reason: "блокировка") }
        on(dn, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.request(forcePush: false, reason: "разблокировка", delay: 3) }
        queue.async { [weak self] in self?.updateStatus() }
        if configured { print("[sync] \(whereTitle): авто \(auto ? "вкл" : "выкл"), устройство \(deviceId)") }
    }

    /// Выход из приложения: отправить своё (не дольше нескольких секунд).
    func shutdown() {
        guard !isStopping else { return }
        locked { stopping = true }
        timer?.cancel()
        for (c, o) in observers { c.removeObserver(o) }
        observers = []
        pushBlocking(timeout: 6, reason: "выход")
    }

    /// Отправить своё, ожидая не дольше timeout (главный поток ждёт — своё читается прямо в круге).
    private func pushBlocking(timeout: TimeInterval, reason: String) {
        guard configured else { return }
        locked { inlineMain = true }
        let sem = DispatchSemaphore(value: 0)
        queue.async { [self] in
            defer { sem.signal() }
            let (t, _, pw) = transport()
            guard let tr = t else { return }
            do {
                let rep = try engine.run(tr, password: pw, forcePush: true, pull: false)
                if rep.pushed { print("[sync] \(reason): своё отправлено") }
            } catch {
                print("[sync] \(reason): не отправилось (\(error.localizedDescription))")
            }
        }
        _ = sem.wait(timeout: .now() + timeout)
        if !isStopping { locked { inlineMain = false } }
    }

    /// Попросить круг. forcePush — своё отправить сразу (личный слой тоже).
    func request(forcePush: Bool, reason: String, delay: TimeInterval = 0) {
        guard !isStopping, configured, auto else { return }
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.request(forcePush: forcePush, reason: reason) }
            return
        }
        let enqueue: Bool = locked {
            queuedForce = queuedForce || forcePush
            if queued { return false }
            queued = true
            return true
        }
        guard enqueue else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let force: Bool = self.locked {
                let v = self.queuedForce
                self.queued = false
                self.queuedForce = false
                return v
            }
            self.runOnce(forcePush: force, reason: reason, manual: false)
        }
    }

    /// «Синхронизировать сейчас»: круг с отправкой своего; итог — на главный поток.
    func syncNow(_ done: @escaping (Bool, String) -> Void) {
        guard configured else { done(false, "Синхронизация не настроена: подключите Google Drive или WebDAV."); return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let rep = self.runOnce(forcePush: true, reason: "вручную", manual: true)
            let err = self.locked { self.lastError }
            DispatchQueue.main.async {
                if let r = rep { done(r.problems.isEmpty, r.summary()) } else { done(false, err.isEmpty ? "Не удалось." : err) }
            }
        }
    }

    /// Только на очереди.
    @discardableResult
    private func runOnce(forcePush: Bool, reason: String, manual: Bool) -> SyncReport? {
        defer { updateStatus() }
        let (t, why, pw) = transport()
        guard let tr = t else { setError(why); return nil }
        do {
            let rep = try engine.run(tr, password: pw, forcePush: forcePush, pull: true)
            let hadError: Bool = locked {
                let had = !lastError.isEmpty
                lastError = ""; loggedError = ""
                return had
            }
            if hadError { print("[sync] снова работает (\(tr.title))") }
            if manual || rep.files > 0 || rep.appliedTotal > 0 || rep.personalTables > 0 || rep.pushed {
                print("[sync] \(reason): \(rep.summary().replacingOccurrences(of: "\n", with: "; "))")
            }
            return rep
        } catch let e as SyncError {
            if e.auth { locked { cachedTransport = nil } }
            setError(e.message)
        } catch {
            setError(error.localizedDescription)
        }
        return nil
    }

    private func setError(_ text: String) {
        let log: Bool = locked {
            lastError = text
            if loggedError == text { return false }
            loggedError = text
            return true
        }
        if log { print("[sync] ⚠️ \(text)") }
    }

    // MARK: - Подключение (вызовы с главного потока, итог — на главный поток)

    /// Пароль синхронизации (одинаковый на всех устройствах). Чужие файлы перечитываются, свой —
    /// перешифровывается.
    func setPassword(_ pw: String) {
        locked { secrets.password = pw }
        saveAll()
        queue.async { [weak self] in self?.engine.reset() }
        print("[sync] пароль синхронизации задан")
    }

    func connectGoogle(_ done: @escaping (Bool, String) -> Void) {
        let g = SyncService.googleClient()
        guard !g.id.isEmpty, !g.secret.isEmpty else {
            done(false, "Эта сборка без ключа Google. Задайте переменные окружения QS_GOOGLE_CLIENT_ID и "
                 + "QS_GOOGLE_CLIENT_SECRET и пересоберите (./make-app.sh). WebDAV работает и так.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let refresh = try GoogleOAuth.signIn(clientId: g.id, clientSecret: g.secret, openBrowser: { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }, cancelled: { [weak self] in self?.isStopping ?? true })
                let changed: Bool = self.locked {
                    self.secrets.gdriveRefresh = refresh
                    let c = self.settings.backend != "gdrive"
                    self.settings.backend = "gdrive"
                    self.cachedTransport = nil
                    self.lastError = ""
                    return c
                }
                self.saveAll()
                print("[sync] Google Drive подключён")
                PersonalLM.shared.save()          // закрепить id устройства: по нему назван свой файл
                self.queue.async {
                    if changed { self.engine.reset() }
                    let rep = self.runOnce(forcePush: true, reason: "подключение", manual: true)
                    let err = self.locked { self.lastError }
                    DispatchQueue.main.async {
                        if let r = rep { done(r.problems.isEmpty, r.summary()) } else { done(false, err) }
                    }
                }
            } catch {
                let text = (error as? SyncError)?.message ?? error.localizedDescription
                DispatchQueue.main.async { done(false, text) }
            }
        }
    }

    func connectWebDAV(url: String, user: String, password: String, _ done: @escaping (Bool, String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try WebDAVTransport(baseURL: url, user: user, password: password).test()
            } catch {
                let text = (error as? SyncError)?.message ?? error.localizedDescription
                DispatchQueue.main.async { done(false, text) }
                return
            }
            let changed: Bool = self.locked {
                let c = self.settings.backend != "webdav" || self.settings.webdavUrl != url || self.settings.webdavUser != user
                self.settings.backend = "webdav"
                self.settings.webdavUrl = url
                self.settings.webdavUser = user
                self.secrets.webdavPassword = password
                self.cachedTransport = nil
                self.lastError = ""
                return c
            }
            self.saveAll()
            print("[sync] WebDAV подключён: \(URL(string: url)?.host ?? url)")
            PersonalLM.shared.save()
            if changed { self.engine.reset() }
            let rep = self.runOnce(forcePush: true, reason: "подключение", manual: true)
            let err = self.locked { self.lastError }
            DispatchQueue.main.async {
                if let r = rep { done(r.problems.isEmpty, r.summary()) } else { done(false, err) }
            }
        }
    }

    func setAuto(_ on: Bool) {
        locked { settings.auto = on }
        saveAll()
        if on { request(forcePush: false, reason: "включено") }
    }

    /// Отключить: забыть вход в хранилище. Навыки и файлы в облаке остаются.
    func disconnect() {
        locked {
            settings.backend = ""
            secrets.gdriveRefresh = ""
            secrets.webdavPassword = ""
            cachedTransport = nil
            lastError = ""
        }
        saveAll()
        queue.async { [weak self] in self?.engine.reset(); self?.updateStatus() }
        print("[sync] отключена")
    }

    // MARK: - SyncHost: навыки мака

    var device: String { deviceId.isEmpty ? PersonalLM.shared.local.device : deviceId }
    var deviceName: String { SkillsFile.computerName }
    var platform: String { SyncService.platformName }
    var appTitle: String { AppVersion.fullString }
    var personal: PersonalLM { PersonalLM.shared }

    func readLocal() -> [String: [String: String]] {
        var d: [String: [String: String]] = [:]
        let lr = LearnedRules.shared
        var learned: [String: String] = [:]
        for w in lr.stop { learned[w] = "s" }
        for w in lr.force { learned[w] = "f" }
        d[SyncCollections.learned] = learned
        let cfg = Config.shared
        func set<S: Sequence>(_ xs: S) -> [String: String] where S.Element == String {
            var m: [String: String] = [:]
            for x in xs where !x.trimmingCharacters(in: .whitespaces).isEmpty { m[x] = "1" }
            return m
        }
        d[SyncCollections.stopWords] = set(cfg.stopWords)
        d[SyncCollections.forceWords] = set(cfg.forceWords)
        d[SyncCollections.excluded(platform)] = set(cfg.excludedApps)
        d[SyncCollections.english(platform)] = set(cfg.expectEnglishBundles)
        d[SyncCollections.journal] = SyncJournal.counts(SemProfile.shared.journalText())
        return d
    }

    func apply(_ ops: [SyncOp]) {
        var learned: [(word: String, state: String?)] = []
        var stop: [(String, Bool)] = [], force: [(String, Bool)] = []
        var excl: [(String, Bool)] = [], eng: [(String, Bool)] = []
        var journal: [SyncOp] = []
        let exclC = SyncCollections.excluded(platform), engC = SyncCollections.english(platform)
        for op in ops {
            let on = op.value != nil
            switch op.collection {
            case SyncCollections.learned: learned.append((op.key, op.value))
            case SyncCollections.stopWords: stop.append((op.key, on))
            case SyncCollections.forceWords: force.append((op.key, on))
            case exclC: excl.append((op.key, on))
            case engC: eng.append((op.key, on))
            case SyncCollections.journal: journal.append(op)
            default: break
            }
        }
        if !learned.isEmpty { LearnedRules.shared.applySync(learned) }
        if !(stop.isEmpty && force.isEmpty && excl.isEmpty && eng.isEmpty) {
            Config.shared.applySync(stop: stop, force: force, excluded: excl, english: eng)
        }
        if !journal.isEmpty {
            let prof = SemProfile.shared
            let rep = prof.rebuild(fromJournal: SyncJournal.apply(prof.journalText(), journal))
            print("[sync] журнал профиля обновлён, профиль пересобран: \(rep.text)")
        }
    }

    func appLang() -> [String: [Double]] { AppLangStats.shared.allCounts() }

    func mergeAppLang(_ other: [String: [Double]]) { AppLangStats.shared.mergeMax(other) }

    func savePersonal() { PersonalLM.shared.save() }

    /// На главном потоке (там живут конфиг, правила, профиль). Если главный поток ждёт выхода —
    /// прямо здесь; если не ответил — задача снимается, круг прерывается.
    func onMain(_ block: @escaping () -> Void) throws {
        if Thread.isMainThread || locked({ inlineMain }) { block(); return }
        let job = MainJob(block)
        DispatchQueue.main.async { job.run() }
        try job.wait(timeout: 60) { [weak self] in self?.isStopping ?? true }
    }

    private final class MainJob {
        private let block: () -> Void
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var state = 0            // 0 ждёт, 1 выполняется, 2 готово, 3 снято

        init(_ block: @escaping () -> Void) { self.block = block }

        func run() {
            lock.lock()
            guard state == 0 else { lock.unlock(); return }
            state = 1
            lock.unlock()
            block()
            lock.lock(); state = 2; lock.unlock()
            done.signal()
        }

        func wait(timeout: TimeInterval, cancelled: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while done.wait(timeout: .now() + 0.2) == .timedOut {
                if cancelled() || Date() > deadline {
                    lock.lock()
                    if state == 0 { state = 3; lock.unlock(); throw SyncError("главный поток не ответил") }
                    lock.unlock()
                }
            }
        }
    }
}
