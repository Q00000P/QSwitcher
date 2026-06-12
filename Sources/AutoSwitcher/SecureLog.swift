import Foundation
import SQLite3
import Cocoa

/// Защищённый лог.
///
/// Горячий буфер (RAM): строки копятся в памяти, на диск не пишутся.
/// Холодная база (SQLite): по триггеру буфер жмётся gzip → шифруется Enclave →
/// пишется одним блоком в таблицу. В базе строки вида (start_ts, end_ts, blob).
///
/// Триггеры сброса: размер буфера > лимита, ребут/выход, ручная кнопка,
/// опциональный интервал по таймеру.
///
/// Очистка: по возрасту (всё / >месяца / >полугода / >года / >3 лет),
/// авто-вытеснение старых блоков при превышении лимита базы.
final class SecureLog {

    static let shared = SecureLog()

    // MARK: - Конфигурация (управляется через Config, меняется под Touch ID)

    /// Включён ли лог вообще.
    var enabled: Bool = false
    /// Логировать ли в полях ввода паролей (Secure Input).
    var logSecureInput: Bool = true
    /// Лимит RAM-буфера в байтах до принудительного сброса.
    var bufferFlushBytes: Int = 20 * 1024 * 1024  // 20 МБ
    /// Лимит базы в байтах (старое вытесняется).
    var dbSizeLimitBytes: Int = 500 * 1024 * 1024  // 500 МБ
    /// Интервал авто-сброса в минутах (0 = только триггеры).
    var flushIntervalMinutes: Int = 0

    // MARK: - Внутреннее состояние

    private var db: OpaquePointer?
    private var buffer: [String] = []
    private var bufferBytes: Int = 0
    private let queue = DispatchQueue(label: "local.AutoSwitcher.securelog", qos: .utility)
    private var flushTimer: Timer?

    private var dbPath: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AutoSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("securelog.db")
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard enabled else { return }
        guard SecureLogCrypto.isAvailable else {
            NSLog("SecureLog: крипто недоступно — лог отключён")
            enabled = false
            return
        }
        openDB()
        registerSystemTriggers()
        restartFlushTimer()
        append("===== SecureLog старт \(Self.fullTimestamp()) =====")
    }

    /// Полностью остановить: сбросить буфер и закрыть базу.
    func stop() {
        flushNow(reason: "stop")
        flushTimer?.invalidate()
        flushTimer = nil
        queue.sync {
            if db != nil { sqlite3_close(db); db = nil }
        }
    }

    func restartFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard flushIntervalMinutes > 0 else { return }
        let interval = TimeInterval(flushIntervalMinutes * 60)
        flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.flushNow(reason: "timer")
        }
    }

    // MARK: - Запись (горячий буфер)

    /// Добавить строку в горячий буфер (RAM).
    func append(_ line: String) {
        guard enabled else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let stamped = "[\(Self.fullTimestamp())] \(line)"
            self.buffer.append(stamped)
            self.bufferBytes += stamped.utf8.count + 1
            if self.bufferBytes >= self.bufferFlushBytes {
                self.flushLocked(reason: "buffer-full")
            }
        }
    }

    // MARK: - Сброс в базу

    func flushNow(reason: String) {
        queue.sync { [weak self] in
            self?.flushLocked(reason: reason)
        }
    }

    private func flushLocked(reason: String) {
        guard enabled, !buffer.isEmpty, db != nil else { return }

        let joined = buffer.joined(separator: "\n")
        guard let raw = joined.data(using: .utf8) else { buffer.removeAll(); bufferBytes = 0; return }

        // gzip → шифрование Enclave
        guard let compressed = SecureLog.gzip(raw) else { return }
        let encrypted: Data
        do {
            encrypted = try SecureLogCrypto.encrypt(compressed)
        } catch {
            NSLog("SecureLog: ошибка шифрования: \(error)")
            return
        }

        let now = Date().timeIntervalSince1970
        let startTs = now  // приблизительно; точные таймстампы внутри строк
        let endTs = now

        var stmt: OpaquePointer?
        let sql = "INSERT INTO logblocks (start_ts, end_ts, line_count, blob) VALUES (?, ?, ?, ?);"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, startTs)
            sqlite3_bind_double(stmt, 2, endTs)
            sqlite3_bind_int(stmt, 3, Int32(buffer.count))
            encrypted.withUnsafeBytes { bytes in
                // SQLITE_TRANSIENT (-1) — SQLite сделает свою копию данных
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_blob(stmt, 4, bytes.baseAddress, Int32(encrypted.count), SQLITE_TRANSIENT)
            }
            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("SecureLog: ошибка вставки: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        sqlite3_finalize(stmt)

        buffer.removeAll()
        bufferBytes = 0

        enforceDbSizeLimit()
    }

    // MARK: - Очистка

    enum CleanupAge {
        case all
        case olderThanMonths(Int)
        case olderThanYears(Int)

        var cutoffTimestamp: Double {
            switch self {
            case .all: return Date().timeIntervalSince1970 + 1  // всё
            case .olderThanMonths(let m):
                return Date().addingTimeInterval(-Double(m) * 30 * 86400).timeIntervalSince1970
            case .olderThanYears(let y):
                return Date().addingTimeInterval(-Double(y) * 365 * 86400).timeIntervalSince1970
            }
        }
    }

    func cleanup(_ age: CleanupAge, completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            guard let self = self, self.db != nil else {
                DispatchQueue.main.async { completion(0) }
                return
            }
            let cutoff = age.cutoffTimestamp
            var stmt: OpaquePointer?
            let sql: String
            if case .all = age {
                sql = "DELETE FROM logblocks;"
            } else {
                sql = "DELETE FROM logblocks WHERE end_ts < ?;"
            }
            var deleted = 0
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                if case .all = age {} else {
                    sqlite3_bind_double(stmt, 1, cutoff)
                }
                if sqlite3_step(stmt) == SQLITE_DONE {
                    deleted = Int(sqlite3_changes(self.db))
                }
            }
            sqlite3_finalize(stmt)
            self.vacuum()
            DispatchQueue.main.async { completion(deleted) }
        }
    }

    /// Экспортировать расшифрованный лог в текстовый файл (для пересылки/просмотра).
    /// Требует Enclave-доступа (разблокированный мак).
    func exportDecrypted(to url: URL, completion: @escaping (Bool, String?) -> Void) {
        queue.async { [weak self] in
            guard let self = self, self.db != nil else {
                DispatchQueue.main.async { completion(false, "база недоступна") }
                return
            }
            // Сбросим текущий буфер чтобы попал в экспорт
            self.flushLocked(reason: "export")

            var stmt: OpaquePointer?
            let sql = "SELECT blob FROM logblocks ORDER BY start_ts ASC;"
            var output = Data()
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let blobPtr = sqlite3_column_blob(stmt, 0) {
                        let size = Int(sqlite3_column_bytes(stmt, 0))
                        let encrypted = Data(bytes: blobPtr, count: size)
                        do {
                            let compressed = try SecureLogCrypto.decrypt(encrypted)
                            if let raw = SecureLog.gunzip(compressed) {
                                output.append(raw)
                                output.append(0x0A)  // newline
                            }
                        } catch {
                            // пропускаем битый блок
                        }
                    }
                }
            }
            sqlite3_finalize(stmt)

            do {
                try output.write(to: url)
                DispatchQueue.main.async { completion(true, nil) }
            } catch {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
            }
        }
    }

    // MARK: - DB internals

    private func openDB() {
        queue.sync {
            if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
                NSLog("SecureLog: не удалось открыть базу")
                db = nil
                return
            }
            let createSQL = """
            CREATE TABLE IF NOT EXISTS logblocks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                start_ts REAL NOT NULL,
                end_ts REAL NOT NULL,
                line_count INTEGER NOT NULL,
                blob BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_end_ts ON logblocks(end_ts);
            """
            sqlite3_exec(db, createSQL, nil, nil, nil)
            // WAL для надёжности и меньшего износа
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        }
    }

    private func enforceDbSizeLimit() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath.path),
              let size = attrs[.size] as? Int else { return }
        guard size > dbSizeLimitBytes else { return }

        // Удаляем старые блоки пока не уложимся (~80% лимита)
        let target = Int(Double(dbSizeLimitBytes) * 0.8)
        var stmt: OpaquePointer?
        // Удаляем самые старые 10% записей за раз
        let sql = "DELETE FROM logblocks WHERE id IN (SELECT id FROM logblocks ORDER BY start_ts ASC LIMIT (SELECT MAX(1, COUNT(*)/10) FROM logblocks));"
        var guardCounter = 0
        repeat {
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            guardCounter += 1
            guard let a = try? FileManager.default.attributesOfItem(atPath: dbPath.path),
                  let s = a[.size] as? Int else { break }
            if s <= target { break }
        } while guardCounter < 50
        vacuum()
    }

    private func vacuum() {
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        sqlite3_exec(db, "VACUUM;", nil, nil, nil)
    }

    // MARK: - System triggers

    private func registerSystemTriggers() {
        let nc = NSWorkspace.shared.notificationCenter
        // Выключение / выход из системы
        nc.addObserver(self, selector: #selector(systemWillPowerOff),
                       name: NSWorkspace.willPowerOffNotification, object: nil)
        // Завершение приложения
        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc private func systemWillPowerOff() { flushNow(reason: "power-off") }
    @objc private func appWillTerminate() { flushNow(reason: "app-terminate") }

    // MARK: - Helpers

    static func fullTimestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.string(from: Date())
    }

    func currentStats(completion: @escaping (_ blocks: Int, _ dbBytes: Int, _ bufferLines: Int) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var blocks = 0
            if self.db != nil {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(self.db, "SELECT COUNT(*) FROM logblocks;", -1, &stmt, nil) == SQLITE_OK {
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        blocks = Int(sqlite3_column_int(stmt, 0))
                    }
                }
                sqlite3_finalize(stmt)
            }
            let dbBytes = (try? FileManager.default.attributesOfItem(atPath: self.dbPath.path))?[.size] as? Int ?? 0
            let bufLines = self.buffer.count
            DispatchQueue.main.async { completion(blocks, dbBytes, bufLines) }
        }
    }

    // MARK: - gzip via zlib

    static func gzip(_ data: Data) -> Data? {
        return zlibProcess(data, compress: true)
    }
    static func gunzip(_ data: Data) -> Data? {
        return zlibProcess(data, compress: false)
    }

    private static func zlibProcess(_ data: Data, compress: Bool) -> Data? {
        // Используем простое сжатие через Compression framework
        // (тут реализовано в Compression.swift расширении)
        return compress ? data.compressed() : data.decompressed()
    }
}
