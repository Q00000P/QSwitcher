import Foundation

/// Проверка новой версии.
///
/// Два источника, по порядку:
///   1. Манифест на своём VPS (домен + нестандартный порт из конфига) —
///      основной: не зависит от доступности GitHub и переживает переезд
///      сервера, потому что адресуется доменом, а не IP.
///   2. GitHub Releases API — фолбэк, если VPS недоступен.
///
/// Ничего не скачивает и не устанавливает: только сравнивает версии и
/// сообщает результат. Обновление — по ссылке, руками.
enum UpdateChecker {

    struct Result {
        let latest: String
        let current: String
        let url: String
        let isNewer: Bool
        let source: String
        /// sha256 архива из манифеста. Пустой — автообновление недоступно
        /// (GitHub-фолбэк хеша не даёт), только открыть страницу: запускать
        /// непроверенный бинарь нельзя.
        let sha256: String
    }

    /// Сравнение семверов: 3.10 новее 3.9, «v3.3» == «3.3».
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Проверить обновления. completion вызывается на главном потоке.
    /// nil — проверить не удалось (сеть/оба источника молчат).
    static func check(completion: @escaping (Result?) -> Void) {
        let current = AppVersion.version
        fetchManifest { manifest in
            if let m = manifest {
                finish(m.version, m.url, m.sha256, "сервер обновлений", current, completion)
                return
            }
            print("[update] манифест недоступен — пробую GitHub API")
            fetchGitHub { gh in
                guard let gh = gh else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                finish(gh.version, gh.url, "", "GitHub", current, completion)
            }
        }
    }

    private static func finish(_ latest: String, _ url: String, _ sha256: String,
                               _ source: String, _ current: String,
                               _ completion: @escaping (Result?) -> Void) {
        let newer = isNewer(latest, than: current)
        print("[update] \(source): \(latest), у нас \(current) → \(newer ? "есть обновление" : "актуальна")")
        DispatchQueue.main.async {
            completion(Result(latest: latest, current: current, url: url,
                              isNewer: newer, source: source, sha256: sha256))
        }
    }

    // MARK: - Источники

    private static func fetchManifest(_ completion: @escaping ((version: String, url: String, sha256: String)?) -> Void) {
        guard let url = URL(string: Config.shared.updateManifestURL) else {
            completion(nil); return
        }
        get(url) { data in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String else {
                completion(nil); return
            }
            completion((version,
                        (json["url"] as? String) ?? Config.shared.updateReleasesPage,
                        (json["sha256"] as? String) ?? ""))
        }
    }

    private static func fetchGitHub(_ completion: @escaping ((version: String, url: String)?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(Config.shared.updateRepo)/releases") else {
            completion(nil); return
        }
        get(url) { data in
            guard let data = data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(nil); return
            }
            // Теги мака — v3.3, винды — win-3.3. Берём только свои и самый свежий.
            for rel in arr {
                guard let tag = rel["tag_name"] as? String,
                      tag.hasPrefix("v"),
                      (rel["draft"] as? Bool) != true else { continue }
                let page = (rel["html_url"] as? String) ?? Config.shared.updateReleasesPage
                completion((String(tag.dropFirst()), page))
                return
            }
            completion(nil)
        }
    }

    private static func get(_ url: URL, _ completion: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("QSwitcher/\(AppVersion.version)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                print("[update] \(url.host ?? "?"): \(err.localizedDescription)")
                completion(nil); return
            }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                print("[update] \(url.host ?? "?"): HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                completion(nil); return
            }
            completion(data)
        }.resume()
    }
}
