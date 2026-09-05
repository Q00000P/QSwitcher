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
            stopWords          = Set(((json["stopWords"]   as? [String]) ?? []).map { $0.lowercased() })
            forceWords         = Set(((json["forceWords"]  as? [String]) ?? []).map { $0.lowercased() })
            minWordLength      = json["minWordLength"]      as? Int ?? 2
            maxConsonantRunEn  = json["maxConsonantRunEn"]  as? Int ?? 4
            maxConsonantRunRu  = json["maxConsonantRunRu"]  as? Int ?? 5
            switchLayoutAfter  = json["switchLayoutAfter"]  as? Int ?? 2
            replaceStartDelayMs = json["replaceStartDelayMs"] as? Int ?? 0
            engine              = json["engine"]              as? String ?? "v4"
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
