import Foundation
import CryptoKit

// Хранилища синхронизации: Google Drive (доступ drive.file — приложение видит только свои файлы)
// и WebDAV (Яндекс Диск и любой другой). Протокол одинаковый: список файлов *.qssync с версиями,
// скачать чужой, записать свой. Зеркало на винде — SyncTransport.cs. Вызовы синхронные: круг
// синхронизации идёт на своей очереди (SyncService), сеть — через URLSession с ожиданием.

/// Ошибка хранилища. auth — вход больше не действует (подключить заново).
struct SyncError: Error, LocalizedError {
    let message: String
    let auth: Bool
    init(_ message: String, auth: Bool = false) { self.message = message; self.auth = auth }
    var errorDescription: String? { message }
}

/// Файл в хранилище: id (для скачивания), имя, версия (не менялась — не качаем).
struct RemoteFile {
    let id: String
    let name: String
    let version: String
}

protocol SyncTransport: AnyObject {
    /// Для человека: «Google Drive», «WebDAV (webdav.yandex.ru)».
    var title: String { get }
    /// Все файлы синхронизации в общей папке (свой тоже).
    func list() throws -> [RemoteFile]
    func get(_ file: RemoteFile) throws -> Data
    /// Записать свой файл. cache — между вызовами (id файла на Drive).
    func put(name: String, data: Data, cache: inout [String: String]) throws
}

enum SyncHTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 120          // личный слой — мегабайты
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// Запрос с ожиданием ответа (вызывать не с главного потока).
    static func send(_ r: URLRequest) throws -> (data: Data, code: Int) {
        let sem = DispatchSemaphore(value: 0)
        var out: (Data, Int)? = nil
        var failure: Error? = nil
        let task = session.dataTask(with: r) { d, resp, e in
            if let e = e { failure = e } else { out = (d ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0) }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 130) == .timedOut {
            task.cancel()
            throw SyncError("сервер не ответил вовремя")
        }
        if let e = failure {
            let ns = e as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut { throw SyncError("сервер не ответил вовремя") }
            throw SyncError("нет связи (\(e.localizedDescription))")
        }
        guard let o = out else { throw SyncError("нет ответа") }
        return o
    }

    /// Кодирование для URL и форм: только незарезервированные символы остаются как есть.
    static func enc(_ s: String) -> String {
        let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? s
    }

    static func query(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    }

    static func detail(_ d: Data) -> String {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        let m = ((j["error"] as? [String: Any])?["message"] as? String) ?? (j["error_description"] as? String) ?? ""
        return m.isEmpty ? "" : ": " + (m.count > 160 ? String(m.prefix(160)) + "…" : m)
    }

    static func json(_ d: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:] }
}

/// Google Drive: папка QSwitcher, файлы помечены appProperties qswitcher=sync.
final class GoogleDriveTransport: SyncTransport {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let folderName = "QSwitcher"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let mine = "appProperties has { key='qswitcher' and value='sync' } and trashed = false"

    private let clientId: String, clientSecret: String, refresh: String, device: String
    private let api: String, uploadApi: String, tokenUrl: String
    private var token: String?
    private var tokenUntil = Date.distantPast

    var title: String { "Google Drive" }

    init(clientId: String, clientSecret: String, refreshToken: String, device: String,
         apiRoot: String = "https://www.googleapis.com", tokenUrl: String = GoogleDriveTransport.tokenURL) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.refresh = refreshToken
        self.device = device
        let root = apiRoot.hasSuffix("/") ? String(apiRoot.dropLast()) : apiRoot
        api = root + "/drive/v3/files"
        uploadApi = root + "/upload/drive/v3/files"
        self.tokenUrl = tokenUrl
    }

    private func accessToken() throws -> String {
        if let t = token, Date() < tokenUntil { return t }
        var r = URLRequest(url: URL(string: tokenUrl)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(SyncHTTP.query([("client_id", clientId), ("client_secret", clientSecret),
                                          ("refresh_token", refresh), ("grant_type", "refresh_token")]).utf8)
        let (data, code) = try SyncHTTP.send(r)
        let j = SyncHTTP.json(data)
        guard code == 200, let t = j["access_token"] as? String, !t.isEmpty else {
            let err = (j["error"] as? String) ?? "HTTP \(code)"
            let auth = ["invalid_grant", "unauthorized_client", "invalid_client"].contains(err)
            throw SyncError(auth ? "Google: вход больше не действует (\(err)) — «Подключить Google Drive…» заново"
                                 : "Google: токен не обновился (\(err))", auth: auth)
        }
        let exp = (j["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        token = t
        tokenUntil = Date().addingTimeInterval(max(60, exp - 120))
        return t
    }

    private func send(_ make: () -> URLRequest, ctx: String, allow404: Bool = false) throws -> (data: Data, code: Int) {
        for attempt in 0..<2 {
            let tok = try accessToken()
            var r = make()
            r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            let (data, code) = try SyncHTTP.send(r)
            if code == 401 && attempt == 0 { token = nil; continue }      // токен протух раньше срока
            if (200..<300).contains(code) || (allow404 && code == 404) { return (data, code) }
            throw SyncError("Google Drive: HTTP \(code) (\(ctx))\(SyncHTTP.detail(data))")
        }
        throw SyncError("Google Drive: доступ не принят (\(ctx))")
    }

    private func query(_ q: String, fields: String, ctx: String, orderBy: String? = nil) throws -> [[String: Any]] {
        var pairs = [("q", q), ("spaces", "drive"), ("pageSize", "1000"), ("fields", "files(\(fields))")]
        if let o = orderBy { pairs.append(("orderBy", o)) }
        let url = URL(string: api + "?" + SyncHTTP.query(pairs))!
        let (data, _) = try send({ URLRequest(url: url) }, ctx: ctx)
        return (SyncHTTP.json(data)["files"] as? [[String: Any]]) ?? []
    }

    private static func quote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    func list() throws -> [RemoteFile] {
        try query(GoogleDriveTransport.mine, fields: "id,name,md5Checksum,modifiedTime,size", ctx: "список файлов").compactMap { f in
            guard let id = f["id"] as? String, let name = f["name"] as? String, name.lowercased().hasSuffix(".qssync") else { return nil }
            let version = (f["md5Checksum"] as? String) ?? "\(f["modifiedTime"] as? String ?? "")|\(f["size"] as? String ?? "")"
            return RemoteFile(id: id, name: name, version: version)
        }
    }

    func get(_ file: RemoteFile) throws -> Data {
        let url = URL(string: "\(api)/\(SyncHTTP.enc(file.id))?alt=media")!
        return try send({ URLRequest(url: url) }, ctx: "скачивание").data
    }

    func put(name: String, data: Data, cache: inout [String: String]) throws {
        var id = cache["gdrive.own"]
        if id == nil || id!.isEmpty {
            id = try query("name = '\(GoogleDriveTransport.quote(name))' and \(GoogleDriveTransport.mine)",
                           fields: "id", ctx: "поиск своего файла").first?["id"] as? String
        }
        if let i = id, !i.isEmpty, try upload(i, data) {
            cache["gdrive.own"] = i
            return
        }
        // Своего файла нет (первый раз или удалили руками) — создать в папке QSwitcher
        let folder = try folderId()
        let meta: [String: Any] = [
            "name": name, "parents": [folder], "mimeType": "application/octet-stream",
            "appProperties": ["qswitcher": "sync", "device": device],
        ]
        let body = try JSONSerialization.data(withJSONObject: meta)
        let (created, _) = try send({
            var r = URLRequest(url: URL(string: api + "?fields=id")!)
            r.httpMethod = "POST"
            r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
            return r
        }, ctx: "создание файла")
        guard let newId = SyncHTTP.json(created)["id"] as? String, !newId.isEmpty else {
            throw SyncError("Google Drive: файл не создался (нет id)")
        }
        guard try upload(newId, data) else { throw SyncError("Google Drive: созданный файл не найден при записи") }
        cache["gdrive.own"] = newId
    }

    /// Записать содержимое. false — файла с таким id больше нет.
    private func upload(_ id: String, _ data: Data) throws -> Bool {
        let url = URL(string: "\(uploadApi)/\(SyncHTTP.enc(id))?uploadType=media")!
        let (_, code) = try send({
            var r = URLRequest(url: url)
            r.httpMethod = "PATCH"
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            r.httpBody = data
            return r
        }, ctx: "отправка", allow404: true)
        return code != 404
    }

    /// Папка QSwitcher: самая ранняя из найденных (два устройства, создавшие её одновременно,
    /// сходятся в одну), нет — создать.
    private func folderId() throws -> String {
        let found = try query("name = '\(GoogleDriveTransport.folderName)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
                              fields: "id", ctx: "поиск папки", orderBy: "createdTime")
        if let id = found.first?["id"] as? String, !id.isEmpty { return id }
        let body = try JSONSerialization.data(withJSONObject: ["name": GoogleDriveTransport.folderName,
                                                              "mimeType": "application/vnd.google-apps.folder"])
        let (data, _) = try send({
            var r = URLRequest(url: URL(string: api + "?fields=id")!)
            r.httpMethod = "POST"
            r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
            return r
        }, ctx: "создание папки")
        guard let id = SyncHTTP.json(data)["id"] as? String, !id.isEmpty else { throw SyncError("Google Drive: папка не создалась") }
        return id
    }
}

/// WebDAV: папка QSwitcher на сервере (Яндекс Диск — https://webdav.yandex.ru, пароль
/// приложения из настроек Яндекс ID).
final class WebDAVTransport: SyncTransport {
    static let defaultURL = "https://webdav.yandex.ru"
    private static let propfind = "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop>"
        + "<d:getetag/><d:getlastmodified/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>"

    private let base: URL, folder: URL
    private let auth: String
    let title: String

    init(baseURL: String, user: String, password: String, folder: String = "QSwitcher") throws {
        var b = baseURL.trimmingCharacters(in: .whitespaces)
        if b.isEmpty { b = WebDAVTransport.defaultURL }
        if !b.hasSuffix("/") { b += "/" }
        guard let u = URL(string: b), let f = URL(string: SyncHTTP.enc(folder) + "/", relativeTo: u) else {
            throw SyncError("WebDAV: неверный адрес")
        }
        base = u
        self.folder = f.absoluteURL
        auth = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        title = "WebDAV (\(u.host ?? b))"
    }

    private func req(_ method: String, _ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        return r
    }

    private func fail(_ code: Int, _ ctx: String) -> SyncError {
        switch code {
        case 401: return SyncError("WebDAV: неверный логин или пароль (401). Для Яндекса нужен пароль приложения", auth: true)
        case 403: return SyncError("WebDAV: доступ запрещён (403, \(ctx))")
        case 507: return SyncError("WebDAV: на диске нет места (507)")
        default: return SyncError("WebDAV: HTTP \(code) (\(ctx))")
        }
    }

    /// Проверка подключения: корень отвечает на PROPFIND.
    func test() throws {
        var r = req("PROPFIND", base)
        r.setValue("0", forHTTPHeaderField: "Depth")
        r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(WebDAVTransport.propfind.utf8)
        let (_, code) = try SyncHTTP.send(r)
        guard (200..<300).contains(code) else { throw fail(code, "проверка") }
    }

    func list() throws -> [RemoteFile] {
        var r = req("PROPFIND", folder)
        r.setValue("1", forHTTPHeaderField: "Depth")
        r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(WebDAVTransport.propfind.utf8)
        let (data, code) = try SyncHTTP.send(r)
        if code == 404 { return [] }                          // папки ещё нет
        guard (200..<300).contains(code) else { throw fail(code, "список файлов") }
        let parser = MultistatusParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        guard xml.parse() else { throw SyncError("WebDAV: ответ не разобрался") }
        return parser.items.compactMap { it in
            guard !it.collection, !it.href.isEmpty else { return nil }
            let trimmed = it.href.hasSuffix("/") ? String(it.href.dropLast()) : it.href
            let last = trimmed.components(separatedBy: "/").last ?? ""
            let name = last.removingPercentEncoding ?? last
            guard name.lowercased().hasSuffix(".qssync"), let u = URL(string: it.href, relativeTo: folder) else { return nil }
            let version = it.etag.isEmpty ? "\(it.modified)|\(it.length)" : it.etag
            return RemoteFile(id: u.absoluteString, name: name, version: version)
        }
    }

    func get(_ file: RemoteFile) throws -> Data {
        guard let u = URL(string: file.id) else { throw SyncError("WebDAV: неверный адрес файла") }
        let (data, code) = try SyncHTTP.send(req("GET", u))
        guard (200..<300).contains(code) else { throw fail(code, "скачивание") }
        return data
    }

    func put(name: String, data: Data, cache: inout [String: String]) throws {
        guard let u = URL(string: SyncHTTP.enc(name), relativeTo: folder)?.absoluteURL else { throw SyncError("WebDAV: неверное имя") }
        var code = try putOnce(u, data)
        if code == 404 || code == 409 {
            // Папки ещё нет — создать и повторить (405 — уже есть, это нормально)
            let (_, mk) = try SyncHTTP.send(req("MKCOL", folder))
            guard (200..<300).contains(mk) || mk == 405 else { throw fail(mk, "создание папки") }
            code = try putOnce(u, data)
            if code == 404 || code == 409 { throw SyncError("WebDAV: папка не создалась (HTTP \(code))") }
        }
    }

    private func putOnce(_ u: URL, _ data: Data) throws -> Int {
        var r = req("PUT", u)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        let (_, code) = try SyncHTTP.send(r)
        if (200..<300).contains(code) || code == 404 || code == 409 { return code }
        throw fail(code, "отправка")
    }

    /// Разбор ответа PROPFIND (multistatus).
    private final class MultistatusParser: NSObject, XMLParserDelegate {
        struct Item { var href = "", etag = "", modified = "", length = ""; var collection = false }
        var items: [Item] = []
        private var cur: Item? = nil
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "response" { cur = Item() }
            if name == "collection" { cur?.collection = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href": cur?.href = t
            case "getetag": cur?.etag = t
            case "getlastmodified": cur?.modified = t
            case "getcontentlength": cur?.length = t
            case "response": if let c = cur { items.append(c) }; cur = nil
            default: break
            }
            text = ""
        }
    }
}

/// Вход в Google для десктопа: браузер + редирект на 127.0.0.1 (loopback), PKCE. Возвращает
/// refresh token (хранится у приложения зашифрованным). Блокирует — вызывать не с главного потока.
enum GoogleOAuth {
    static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"

    static func signIn(clientId: String, clientSecret: String, openBrowser: (URL) -> Void,
                       timeout: TimeInterval = 300, cancelled: () -> Bool = { false },
                       authUrl: String = authURL, tokenUrl: String = GoogleDriveTransport.tokenURL) throws -> String {
        let server = try LoopbackServer()
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(server.port)"
        let state = b64url(randomBytes(16))
        let verifier = b64url(randomBytes(48))
        let challenge = b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let url = authUrl + "?" + SyncHTTP.query([
            ("client_id", clientId), ("redirect_uri", redirect), ("response_type", "code"),
            ("scope", GoogleDriveTransport.scope), ("access_type", "offline"), ("prompt", "consent"),
            ("state", state), ("code_challenge", challenge), ("code_challenge_method", "S256"),
        ])
        openBrowser(URL(string: url)!)

        let deadline = Date().addingTimeInterval(timeout)
        var q: [String: String]? = nil
        while q == nil {
            guard let fd = server.accept(until: deadline, cancelled: cancelled) else {
                throw SyncError(cancelled() ? "Вход в Google прерван" : "Вход в Google не завершён за 5 минут")
            }
            q = server.handle(fd)
        }
        let params = q!
        if let err = params["error"] {
            throw SyncError(err == "access_denied" ? "Доступ не выдан (отменено в браузере)" : "Google: \(err)")
        }
        guard params["state"] == state, let code = params["code"] else { throw SyncError("Google: в ответе нет кода или он чужой") }

        var r = URLRequest(url: URL(string: tokenUrl)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(SyncHTTP.query([("code", code), ("client_id", clientId), ("client_secret", clientSecret),
                                          ("redirect_uri", redirect), ("grant_type", "authorization_code"),
                                          ("code_verifier", verifier)]).utf8)
        let (data, status) = try SyncHTTP.send(r)
        guard status == 200, let refresh = SyncHTTP.json(data)["refresh_token"] as? String, !refresh.isEmpty else {
            throw SyncError("Google: обмен кода не удался\(SyncHTTP.detail(data))")
        }
        return refresh
    }

    private static func randomBytes(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}

/// Одноразовый HTTP-листенер на 127.0.0.1: ловит редирект Google, отвечает «можно закрыть».
final class LoopbackServer {
    private let fd: Int32
    let port: UInt16

    init() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw SyncError("не открылся локальный порт для входа в Google") }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(s, 4) == 0 else {
            close(s)
            throw SyncError("не открылся локальный порт для входа в Google")
        }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        fd = s
        port = UInt16(bigEndian: got.sin_port)
    }

    func stop() { close(fd) }

    /// Ждать подключения браузера до срока. nil — не дождались.
    func accept(until deadline: Date, cancelled: () -> Bool) -> Int32? {
        while Date() < deadline && !cancelled() {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 1000) > 0 {
                let c = Darwin.accept(fd, nil, nil)
                if c >= 0 { return c }
            }
        }
        return nil
    }

    /// Один запрос браузера: редирект с кодом — ответить и вернуть параметры; прочее (favicon) —
    /// 404 и nil.
    func handle(_ c: Int32) -> [String: String]? {
        defer { close(c) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 8192)
        var n = 0
        while n < buf.count {
            let r = buf.withUnsafeMutableBytes { read(c, $0.baseAddress! + n, $0.count - n) }
            if r <= 0 { break }
            n += r
            if String(decoding: buf[0..<n], as: UTF8.self).contains("\r\n\r\n") { break }
        }
        let head = String(decoding: buf[0..<n], as: UTF8.self)
        let line = head.components(separatedBy: "\r\n").first ?? ""
        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        var q: [String: String] = [:]
        if let i = target.firstIndex(of: "?") {
            for part in target[target.index(after: i)...].split(separator: "&") {
                let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { String($0).replacingOccurrences(of: "+", with: " ") }
                let k = kv[0].removingPercentEncoding ?? kv[0]
                q[k] = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
            }
        }
        let callback = q["code"] != nil || q["error"] != nil
        let html = !callback ? "" : (q["code"] != nil
            ? "<h3>QSwitcher подключён к Google Drive</h3><p>Окно можно закрыть.</p>"
            : "<h3>QSwitcher: доступ не выдан</h3><p>Окно можно закрыть.</p>")
        let page = Data(("<!doctype html><html><head><meta charset=\"utf-8\"><title>QSwitcher</title></head>"
            + "<body style=\"font-family:-apple-system,system-ui,sans-serif;margin:3em\">\(html)</body></html>").utf8)
        let status = callback ? "200 OK" : "404 Not Found"
        var resp = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(callback ? page.count : 0)\r\nConnection: close\r\n\r\n".utf8)
        if callback { resp.append(page) }
        resp.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let w = write(c, p.baseAddress! + off, p.count - off)
                if w <= 0 { break }
                off += w
            }
        }
        return callback ? q : nil
    }
}
