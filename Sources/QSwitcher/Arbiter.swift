import Foundation

/// Клиент LLM-арбитра (модуль «Full»). Процесс — nn/llm/arbiter.py (или любой
/// другой, говорящий тем же протоколом) на Unix-сокете; приложение ни с чем не
/// линкуется: сокета нет — модуля нет, работает Lite.
///
/// Спрашиваем ТОЛЬКО когда профиль сказал «не уверен». В живом вводе — асинхронно
/// (хук не ждёт), ответ применяется ретро-заменой уже напечатанного слова, если
/// человек ещё ничего не набрал дальше. В прогоне (--test --arbiter) — синхронно.
final class Arbiter {
    static let shared = Arbiter()

    struct Query {
        let typed: String, swapped: String
        let left: [String], topic: [String], app: String
    }
    struct Answer { let reading: String?; let p: Double; let ms: Int; let raw: String }

    /// Синхронный режим (прогон): ждём ответ прямо в детекторе.
    var syncMode = false
    private let queue = DispatchQueue(label: "local.QSwitcher.arbiter", qos: .userInitiated)

    var socketPath: String {
        let p = Config.shared.arbiterSocket
        if !p.isEmpty { return p }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("QSwitcher/arbiter.sock").path
    }
    var available: Bool { Config.shared.arbiterEnabled && FileManager.default.fileExists(atPath: socketPath) }

    /// Один запрос — одно соединение: Unix-сокет, подключение — микросекунды,
    /// зато процесс можно перезапустить с другой моделью в любой момент.
    private func roundtrip(_ json: [String: Any], timeoutMs: Int) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        let ok = withUnsafeMutablePointer(to: &addr.sun_path) { ptr -> Bool in
            let cap = MemoryLayout.size(ofValue: ptr.pointee)
            guard path.utf8.count < cap else { return false }
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            path.withCString { strncpy(raw, $0, cap) }
            return true
        }
        guard ok else { return nil }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
        guard rc == 0 else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        var out = data; out.append(0x0A)
        let sent = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        guard sent == out.count else { return nil }
        var buf = [UInt8](repeating: 0, count: 4096), acc = Data()
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            acc.append(buf, count: n)
            if acc.last == 0x0A { break }
        }
        guard !acc.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: acc)) as? [String: Any]
    }

    func info() -> String? {
        guard available, let r = roundtrip(["cmd": "info"], timeoutMs: 1000) else { return nil }
        let m = r["model"] as? String ?? "?", mb = r["size_mb"] as? Int ?? 0
        return "\(m) (\(mb) МБ\((r["double"] as? Bool) == true ? ", двойной опрос" : ""))"
    }

    func ask(_ q: Query, timeoutMs: Int) -> Answer? {
        let json: [String: Any] = ["typed": q.typed, "swapped": q.swapped, "left": q.left,
                                   "right": [], "topic": q.topic, "app": q.app]
        guard let r = roundtrip(json, timeoutMs: timeoutMs) else { return nil }
        return Answer(reading: r["reading"] as? String, p: r["p"] as? Double ?? 0,
                      ms: r["ms"] as? Int ?? 0, raw: r["raw"] as? String ?? "")
    }

    /// Асинхронно: ответ придёт в completion на фоновой очереди.
    func askAsync(_ q: Query, completion: @escaping (Answer?) -> Void) {
        let t = Config.shared.arbiterTimeoutMs
        queue.async { completion(self.ask(q, timeoutMs: t)) }
    }
}
