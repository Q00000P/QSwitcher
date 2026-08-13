import AppKit
import CryptoKit
import Foundation

/// Автообновление: скачать архив → сверить sha256 из манифеста → распаковать →
/// подменить бандл → перезапуститься.
///
/// Подмену делает крошечный helper-скрипт: приложение не может заменить само
/// себя, пока работает. Helper ждёт выхода процесса, убирает старый бандл в
/// /tmp (бэкап для отката руками), копирует новый на место и запускает.
///
/// Права Accessibility переживают обновление: бандл подписан тем же
/// самоподписанным сертификатом «QSwitcher Self-Signed» — ради этого он
/// и заводился.
enum UpdateInstaller {

    /// Скачивает и ставит обновление. При успехе ПРИЛОЖЕНИЕ ЗАВЕРШАЕТСЯ
    /// (helper перезапустит новую версию). completion зовётся только при
    /// ошибке — с текстом для показа пользователю.
    static func install(_ r: UpdateChecker.Result, onError: @escaping (String) -> Void) {
        precondition(!r.sha256.isEmpty, "автообновление без sha256 запрещено")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try run(r)
            } catch {
                DispatchQueue.main.async { onError(error.localizedDescription) }
            }
        }
    }

    private struct Err: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    private static func run(_ r: UpdateChecker.Result) throws {
        guard let url = URL(string: r.url) else { throw Err(msg: "кривой URL: \(r.url)") }

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qswitcher-update-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // 1. Скачиваем
        print("[update] качаю \(r.url)")
        let zipPath = work.appendingPathComponent("update.zip")
        let sem = DispatchSemaphore(value: 0)
        var dlError: String?
        let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
            defer { sem.signal() }
            if let err = err { dlError = err.localizedDescription; return }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                dlError = "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"; return
            }
            guard let tmp = tmp else { dlError = "пустой ответ"; return }
            do { try FileManager.default.moveItem(at: tmp, to: zipPath) }
            catch { dlError = error.localizedDescription }
        }
        task.resume()
        if sem.wait(timeout: .now() + 600) == .timedOut { throw Err(msg: "загрузка не уложилась в 10 минут") }
        if let e = dlError { throw Err(msg: "загрузка: \(e)") }

        // 2. Проверяем sha256 ДО любых действий со скачанным
        print("[update] проверяю sha256")
        let data = try Data(contentsOf: zipPath, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == r.sha256.lowercased() else {
            throw Err(msg: "sha256 не совпал: архив повреждён или подменён.\nОжидал \(r.sha256)\nПолучил \(hash)")
        }

        // 3. Распаковываем ditto — он единственный корректно
        // восстанавливает .app со всеми метаданными
        print("[update] распаковываю")
        let unpackDir = work.appendingPathComponent("unpacked")
        try runProcess("/usr/bin/ditto", ["-x", "-k", zipPath.path, unpackDir.path])

        guard let appName = try FileManager.default.contentsOfDirectory(atPath: unpackDir.path)
                .first(where: { $0.hasSuffix(".app") }) else {
            throw Err(msg: "в архиве нет .app")
        }
        let newApp = unpackDir.appendingPathComponent(appName)

        // 4. Снимаем quarantine с нового бандла заранее
        try? runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        // 5. Helper: ждёт нашего выхода, подменяет бандл, запускает
        let target = Bundle.main.bundlePath
        let backup = "/tmp/QSwitcher-prev-\(Int(Date().timeIntervalSince1970)).app"
        let helper = work.appendingPathComponent("swap.sh")
        let script = """
        #!/bin/bash
        # QSwitcher update helper — создан приложением, одноразовый.
        # шаг 1: ждём выхода старого процесса; шаг 2: старый бандл -> бэкап в /tmp;
        # шаг 3: новый на место; шаг 4: запуск. При любой ошибке бэкап остаётся.
        for i in $(seq 1 100); do
            kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break
            sleep 0.2
        done
        mv "\(target)" "\(backup)" || exit 1
        if /usr/bin/ditto "\(newApp.path)" "\(target)"; then
            /usr/bin/xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
            open "\(target)"
        else
            # Копирование сорвалось — возвращаем старую версию
            mv "\(backup)" "\(target)"
            open "\(target)"
        fi
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try runProcess("/bin/chmod", ["+x", helper.path])

        print("[update] перезапускаюсь: \(target)  (бэкап: \(backup))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [helper.path]
        try p.run()   // НЕ ждём — helper переживёт нас

        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }

    private static func runProcess(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Err(msg: "\(path.split(separator: "/").last ?? "") завершился с кодом \(p.terminationStatus)")
        }
    }
}

