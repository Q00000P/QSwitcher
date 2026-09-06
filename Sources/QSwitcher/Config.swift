import Foundation
import Cocoa

/// Конфиг приложения. Хранится в
/// ~/Library/Application Support/QSwitcher/config.json
/// Перечитывается с диска по mtime каждые 2 секунды — можно редактировать
/// файл в любом редакторе и изменения применяются на лету.
final class Config {

    static let shared = Config()

    private(set) var enabled: Bool = true
    private(set) var soundEnabled: Bool = true
    private(set) var excludedApps: Set<String> = []
    private(set) var stopWords: Set<String> = []
    private(set) var forceWords: Set<String> = []
    private(set) var minWordLength: Int = 2
    private(set) var maxConsonantRunEn: Int = 4
    private(set) var maxConsonantRunRu: Int = 5

    /// После скольких подряд сконвертированных слов переключать раскладку.
    /// 0 — не переключать никогда (только исправлять текст),
    /// 1 — сразу после первого слова (прежнее поведение),
    /// 2 — по умолчанию: разовая вставка раскладку не трогает.
    private(set) var switchLayoutAfter: Int = 2

    /// Пауза перед первым backspace, миллисекунды. По умолчанию НОЛЬ.
    ///
    /// Была попытка лечить паузой поле поиска программ, которое не принимает
    /// синтетический backspace. Не помогло даже 300 мс, зато сломало обычные поля:
    /// пока мы ждём, человек успевает набрать следующий символ, и стирание
    /// попадает не туда. Замена должна идти вплотную к нажатию.
    private(set) var replaceStartDelayMs: Int = 0

    /// Движок ввода: "v4" — замена изнутри tap-callback, без пауз и шлюза
    /// (по умолчанию); "legacy" — прежняя схема (emitQueue + usleep + шлюз).
    /// Откат на случай регрессий, применяется после перезапуска.
    private(set) var engine: String = "v4"

    // Семантика (nn/sem/qsvec.bin + profile.json). Меняются на лету.
    /// Включён ли профиль чтений с семантикой.
    private(set) var semEnabled: Bool = true
    /// Отрыв лидера, ниже которого профиль не вмешивается.
    private(set) var semMargin: Double = 0.10
    /// Нулевой режим: коллизии, где оба чтения — слова корпуса, решаются базой без обучения.
    private(set) var semZeroShot: Bool = true
    /// Учить профиль на ОБЫЧНОМ ручном свапе/тоггле (по умолчанию нет: свап — просто свап).
    private(set) var semLearnOnSwap: Bool = false
    /// Учить профиль на принятом без исправления (после уверенного решения профиля).
    private(set) var semLearnOnAccept: Bool = false

    // Сеть-детектор (nn/qsnet.bin). Меняются на лету через config.json.
    /// Включена ли сеть вообще.
    private(set) var nnEnabled: Bool = true
    /// Уверенность (max(p, 1−p)), ниже которой сеть молчит и решают словари.
    private(set) var nnThreshold: Double = 0.85
    /// Порог для коротких слов (≤3 букв) — строже: ложный свап короткого дороже пропуска.
    private(set) var nnThresholdShort: Double = 0.95
    /// "primary" — сеть решает до словарей; "arbiter" — только когда словари промолчали.
    private(set) var nnMode: String = "primary"
    /// Слова короче — сети не показываем (одиночные буквы и пары — правила/щит).
    private(set) var nnMinLen: Int = 3
    /// Класс приложения по подстроке bundle id (без учёта регистра). Пользовательские
    /// записи из config.json ("appClasses": {"terminal": ["qterm"], …}) дополняют встроенные.
    private(set) var appClasses: [String: [String]] = [:]
    private static let builtinAppClasses: [String: [String]] = [
        "terminal": ["com.apple.terminal", "iterm", "qterm", "alacritty", "kitty", "hyper", "warp", "ghostty", "wezterm"],
        "code":     ["vscode", "xcode", "jetbrains", "sublime", "cursor", "todesktop", "zed", "nova", "bbedit", "textmate"],
        "browser":  ["safari", "chrome", "firefox", "arc", "brave", "edge", "opera", "yandex", "vivaldi", "orion"],
        "chat":     ["telegram", "slack", "discord", "whatsapp", "claude", "mobilesms", "messages", "mail", "zoom",
                     "skype", "teams", "viber", "signal", "max"],
    ]

    /// Класс приложения для сети: сначала пользовательские подстроки, потом встроенные.
    func appClass(for bundleId: String?) -> LayoutNet.AppClass {
        guard let id = bundleId?.lowercased(), !id.isEmpty else { return .other }
        for cls in LayoutNet.AppClass.allCases where cls != .other {
            let subs = (appClasses[cls.name] ?? []) + (Config.builtinAppClasses[cls.name] ?? [])
            if subs.contains(where: { id.contains($0.lowercased()) }) { return cls }
        }
        return .other
    }

    /// Горячие клавиши — назначаемые (меню → «Настроить горячие клавиши…»).
    let hotkeys = HotkeyMap()

    func saveHotkeys() {
        patchOnDisk { $0["hotkeys"] = self.hotkeys.json }
    }
    var engineV4: Bool { engine.lowercased() != "legacy" }

    /// Пауза между отдельными нажатиями при стирании и печати, миллисекунды.
    private(set) var keyIntervalMs: Int = 3

    // MARK: - Обновления
    /// Манифест на своём сервере. Домен, а не IP — чтобы пережить переезд;
    /// порт нестандартный. Меняется в config.json без пересборки.
    private(set) var updateManifestURL = "https://qsw.05.gs:8843/qswitcher/version-mac.json"
    private(set) var updateRepo = "Q00000P/QSwitcher"
    private(set) var updateReleasesPage = "https://github.com/Q00000P/QSwitcher/releases"
    /// Автопроверка при запуске и раз в сутки.
    private(set) var updateCheckOnLaunch = true

    /// Звук когда текст исправлен, но раскладка НЕ менялась.
    private(set) var soundConvertOnly: String = "Tink"
    /// Звук когда исправлен текст И переключена раскладка.
    private(set) var soundConvertAndSwitch: String = "Pop"
    // Доступные системные: Basso, Blow, Bottle, Frog, Funk, Glass, Hero,
    // Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink

    // === SecureLog ===
    private(set) var logEnabled: Bool = false
    private(set) var logSecureInput: Bool = true
    private(set) var logBufferFlushMB: Int = 20
    private(set) var logDbSizeLimitMB: Int = 500
    private(set) var logFlushIntervalMinutes: Int = 0

    var path: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("QSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    private var lastMtime: Date = .distantPast
    private var pollTimer: Timer?

    private init() {
        ensureExists()
        reload()
        startPolling()
    }

    // MARK: - Mutations

    func setEnabled(_ flag: Bool) {
        enabled = flag
        patchOnDisk { $0["enabled"] = flag }
    }

    func setSoundEnabled(_ flag: Bool) {
        soundEnabled = flag
        patchOnDisk { $0["soundEnabled"] = flag }
    }

    func toggleExcludedApp(_ bundleId: String) {
        if excludedApps.contains(bundleId) {
            excludedApps.remove(bundleId)
        } else {
            excludedApps.insert(bundleId)
        }
        patchOnDisk { json in
            json["excludedApps"] = self.excludedApps.sorted()
        }
    }

    func addStopWord(_ word: String) {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        stopWords.insert(w)
        patchOnDisk { json in json["stopWords"] = self.stopWords.sorted() }
    }

    func removeStopWord(_ word: String) {
        stopWords.remove(word.lowercased())
        patchOnDisk { json in json["stopWords"] = self.stopWords.sorted() }
    }

    func addForceWord(_ word: String) {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        forceWords.insert(w)
        patchOnDisk { json in json["forceWords"] = self.forceWords.sorted() }
    }

    func removeForceWord(_ word: String) {
        forceWords.remove(word.lowercased())
        patchOnDisk { json in json["forceWords"] = self.forceWords.sorted() }
    }

    func openInEditor() {
        NSWorkspace.shared.open(path)
    }

    // MARK: - Loading

    func reload() {
        do {
            let data = try Data(contentsOf: path)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fputs("⚠️ config.json: ожидался JSON-объект.\n", stderr)
                return
            }
            enabled            = json["enabled"]            as? Bool ?? true
            soundEnabled       = json["soundEnabled"]       as? Bool ?? true
            excludedApps       = Set((json["excludedApps"]  as? [String]) ?? [])
            // Как написано: строчное слово матчится без учёта регистра (сравниваем с
            // lowercased), слово с заглавными — только точно ("РФ" ≠ "рф").
            stopWords          = Set(((json["stopWords"]   as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespaces) })
            forceWords         = Set(((json["forceWords"]  as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespaces) })
            minWordLength      = json["minWordLength"]      as? Int ?? 2
            maxConsonantRunEn  = json["maxConsonantRunEn"]  as? Int ?? 4
            maxConsonantRunRu  = json["maxConsonantRunRu"]  as? Int ?? 5
            switchLayoutAfter  = json["switchLayoutAfter"]  as? Int ?? 2
            replaceStartDelayMs = json["replaceStartDelayMs"] as? Int ?? 0
            engine              = json["engine"]              as? String ?? "v4"
            semEnabled          = json["semEnabled"]          as? Bool ?? true
            semMargin           = json["semMargin"]           as? Double ?? 0.10
            semZeroShot         = json["semZeroShot"]         as? Bool ?? true
            semLearnOnSwap      = json["semLearnOnSwap"]      as? Bool ?? false
            semLearnOnAccept    = json["semLearnOnAccept"]    as? Bool ?? false
            nnEnabled           = json["nnEnabled"]           as? Bool ?? true
            nnThreshold         = json["nnThreshold"]         as? Double ?? 0.85
            nnThresholdShort    = json["nnThresholdShort"]    as? Double ?? 0.95
            nnMode              = (json["nnMode"]             as? String ?? "primary").lowercased()
            nnMinLen            = json["nnMinLen"]            as? Int ?? 3
            appClasses          = (json["appClasses"]         as? [String: [String]]) ?? [:]
            hotkeys.load(json: json["hotkeys"] as? [String: Any])
            keyIntervalMs       = json["keyIntervalMs"]       as? Int ?? 3
            updateManifestURL   = json["updateManifestURL"]   as? String ?? updateManifestURL
            updateRepo          = json["updateRepo"]          as? String ?? updateRepo
            updateReleasesPage  = json["updateReleasesPage"]  as? String ?? updateReleasesPage
            updateCheckOnLaunch = json["updateCheckOnLaunch"] as? Bool ?? true
            soundConvertOnly      = json["soundConvertOnly"]      as? String ?? "Tink"
            soundConvertAndSwitch = json["soundConvertAndSwitch"] as? String ?? "Pop"

            logEnabled             = json["logEnabled"]             as? Bool ?? false
            logSecureInput         = json["logSecureInput"]         as? Bool ?? true
            logBufferFlushMB       = json["logBufferFlushMB"]       as? Int ?? 20
            logDbSizeLimitMB       = json["logDbSizeLimitMB"]       as? Int ?? 500
            logFlushIntervalMinutes = json["logFlushIntervalMinutes"] as? Int ?? 0
        } catch {
            fputs("⚠️ config.json: \(error.localizedDescription)\n", stderr)
        }
    }

    // MARK: - SecureLog setters (вызываются после Touch ID)

    func setLogEnabled(_ v: Bool) { logEnabled = v; patchOnDisk { $0["logEnabled"] = v } }
    func setLogSecureInput(_ v: Bool) { logSecureInput = v; patchOnDisk { $0["logSecureInput"] = v } }
    func setLogBufferFlushMB(_ v: Int) { logBufferFlushMB = v; patchOnDisk { $0["logBufferFlushMB"] = v } }
    func setLogDbSizeLimitMB(_ v: Int) { logDbSizeLimitMB = v; patchOnDisk { $0["logDbSizeLimitMB"] = v } }
    func setLogFlushIntervalMinutes(_ v: Int) { logFlushIntervalMinutes = v; patchOnDisk { $0["logFlushIntervalMinutes"] = v } }

    // MARK: - Internal

    private func patchOnDisk(_ patch: (inout [String: Any]) -> Void) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = parsed
        }
        patch(&json)
        guard let out = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? out.write(to: path, options: .atomic)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let m = attrs[.modificationDate] as? Date {
            lastMtime = m
        }
    }

    private func ensureExists() {
        if FileManager.default.fileExists(atPath: path.path) { return }
        let defaultJson = """
        {
          "enabled": true,
          "soundEnabled": true,
          "minWordLength": 2,
          "maxConsonantRunEn": 4,
          "maxConsonantRunRu": 5,
          "excludedApps": [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "co.zeit.hyper",
            "io.alacritty",
            "net.kovidgoyal.kitty",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
            "com.jetbrains.intellij",
            "com.jetbrains.pycharm",
            "com.jetbrains.WebStorm",
            "com.jetbrains.goland",
            "com.jetbrains.CLion",
            "com.sublimetext.4",
            "1password.com.agilebits",
            "com.apple.keychainaccess"
          ],
          "stopWords": [
            "ssh", "scp", "ssl", "tls", "tcp", "udp", "dns", "vpn",
            "url", "uri", "api", "cli", "gui", "ide", "sdk", "sql",
            "json", "xml", "yaml", "html", "css", "ftp", "smtp",
            "pgp", "gpg", "rsa", "dhcp", "nat", "git", "npm", "pip",
            "docker", "nginx", "vps", "wifi", "lan", "wan"
          ],
          "forceWords": []
        }
        """
        try? defaultJson.write(to: path, atomically: true, encoding: .utf8)
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkChangesOnDisk()
        }
    }

    private func checkChangesOnDisk() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let mtime = attrs[.modificationDate] as? Date else { return }
        if mtime > lastMtime {
            lastMtime = mtime
            reload()
        }
    }
}
