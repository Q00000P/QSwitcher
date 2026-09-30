import Foundation
import CryptoKit
import CommonCrypto
import SystemConfiguration

/// Файл навыков QSwitcher — экспорт/импорт и (дальше) синхронизация между устройствами.
/// Один формат с виндой (SkillsFile.cs):
///
///   без пароля — JSON как есть (UTF-8, читается глазами);
///   с паролем  — "QSX1" | соль 16 | итерации u32 LE | nonce 12 | шифротекст | тег 16
///                ключ = PBKDF2-HMAC-SHA256(пароль, соль, итерации, 32 байта),
///                шифр = AES-256-GCM, внутри — JSON, сжатый raw DEFLATE (RFC 1951).
///
/// Содержимое: learned {force, stop}, forceWords, stopWords, apps {mac|win: {excluded,
/// english, lang}}, profileJournal, personal (таблицы личного слоя по устройствам).
enum SkillsFile {
    static let format = "qswitcher-skills"
    static let magic = Data("QSX1".utf8)
    static let iterations: UInt32 = 600_000

    enum Failure: Error {
        case wrongPassword
        case notSkills
    }

    static func isEncrypted(_ d: Data) -> Bool { d.count >= 4 && d.prefix(4) == magic }

    private static func randomBytes(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    static func pbkdf2(_ password: String, salt: Data, rounds: UInt32) -> Data {
        var derived = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let pwLen = password.utf8.count
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, pwLen,
                                 saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                 &derived, 32)
        return Data(derived)
    }

    /// Упаковать: пустой пароль — открытый JSON с отступами.
    static func pack(_ doc: [String: Any], password: String?) throws -> Data {
        guard let pw = password, !pw.isEmpty else {
            return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        }
        let json = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
        guard let plain = json.compressed() else { throw Failure.notSkills }
        let salt = randomBytes(16)
        let nonceData = randomBytes(12)
        let key = SymmetricKey(data: pbkdf2(pw, salt: salt, rounds: iterations))
        let sealed = try AES.GCM.seal(plain, using: key, nonce: try AES.GCM.Nonce(data: nonceData))
        var out = magic
        out.append(salt)
        out.append(withUnsafeBytes(of: iterations.littleEndian) { Data($0) })
        out.append(nonceData)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Распаковать. Зашифрованный без пароля или с неверным — .wrongPassword.
    static func unpack(_ data: Data, password: String?) throws -> [String: Any] {
        var jsonData: Data
        if isEncrypted(data) {
            guard let pw = password, !pw.isEmpty, data.count >= 4 + 16 + 4 + 12 + 16 else { throw Failure.wrongPassword }
            let b = [UInt8](data)
            let salt = Data(b[4..<20])
            let iters = UInt32(b[20]) | (UInt32(b[21]) << 8) | (UInt32(b[22]) << 16) | (UInt32(b[23]) << 24)
            guard iters >= 1000, iters <= 10_000_000 else { throw Failure.notSkills }
            let nonceData = Data(b[24..<36])
            let ct = Data(b[36..<(b.count - 16)])
            let tag = Data(b[(b.count - 16)...])
            let key = SymmetricKey(data: pbkdf2(pw, salt: salt, rounds: iters))
            let plain: Data
            do {
                let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonceData), ciphertext: ct, tag: tag)
                plain = try AES.GCM.open(box, using: key)
            } catch {
                throw Failure.wrongPassword
            }
            guard let raw = plain.decompressed() else { throw Failure.notSkills }
            jsonData = raw
        } else {
            jsonData = data
            if jsonData.starts(with: [0xEF, 0xBB, 0xBF]) { jsonData = Data(jsonData.dropFirst(3)) }   // BOM
        }
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              obj["format"] as? String == format else { throw Failure.notSkills }
        return obj
    }

    static var computerName: String { (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac" }

    static func newDocument() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "format": format, "v": 1, "created": iso.string(from: Date()),
            "from": ["device": PersonalLM.shared.local.device, "name": computerName, "platform": "mac"],
        ]
    }

    /// Строки журнала, которых ещё нет в текущем (без повторов, порядок файла).
    static func newJournalLines(current: String, incoming: String) -> [String] {
        var have = Set(current.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) })
        var add: [String] = []
        for raw in incoming.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if l.trimmingCharacters(in: .whitespaces).isEmpty || have.contains(l) { continue }
            have.insert(l)
            add.append(l)
        }
        return add
    }
}

/// Навыки в файл и из файла: выученные правила, стоп- и форс-слова, исключённые приложения и
/// английский ввод, ожидание языка по приложениям, личный слой, журнал профиля. Импорт —
/// слияние, ничего не стирает: правила из файла важнее своих, списки объединяются, личный
/// слой — по устройствам. Приложения — только своей платформы (bundle id и процессы винды
/// не совпадают).
enum Skills {
    static let platform = "mac"

    static func export() -> [String: Any] {
        var doc = SkillsFile.newDocument()
        let lr = LearnedRules.shared
        doc["learned"] = ["force": lr.force.sorted(), "stop": lr.stop.sorted()]
        let cfg = Config.shared
        doc["forceWords"] = cfg.forceWords.sorted()
        doc["stopWords"] = cfg.stopWords.sorted()
        var lang: [String: Any] = [:]
        for (app, v) in AppLangStats.shared.allCounts() where v.count == 2 {
            lang[app] = [(v[0] * 100).rounded() / 100, (v[1] * 100).rounded() / 100]
        }
        let mine: [String: Any] = ["excluded": cfg.excludedApps.sorted(), "english": cfg.expectEnglishBundles.sorted(), "lang": lang]
        doc["apps"] = [platform: mine] as [String: Any]
        let journal = SemProfile.shared.journalText()
        if !journal.isEmpty { doc["profileJournal"] = journal }
        doc["personal"] = PersonalLM.shared.snapshot()
        return doc
    }

    /// Слить навыки из файла. Возвращает сводку для человека.
    static func importDoc(_ doc: [String: Any]) -> String {
        var report: [String] = []
        let lr = LearnedRules.shared

        // Выученные правила: из файла важнее (человек импортирует осознанно)
        var rules = 0
        let learned = doc["learned"] as? [String: Any] ?? [:]
        for w in (learned["force"] as? [String]) ?? [] where !w.isEmpty && !lr.force.contains(w.lowercased()) {
            lr.learnForce(w); rules += 1
        }
        for w in (learned["stop"] as? [String]) ?? [] where !w.isEmpty && !lr.stop.contains(w.lowercased()) {
            lr.learnStop(w); rules += 1
        }
        if rules > 0 { report.append("выученных правил: +\(rules)") }

        let mine = (doc["apps"] as? [String: Any])?[platform] as? [String: Any] ?? [:]
        let added = Config.shared.mergeLists(stop: (doc["stopWords"] as? [String]) ?? [],
                                             force: (doc["forceWords"] as? [String]) ?? [],
                                             excluded: (mine["excluded"] as? [String]) ?? [],
                                             english: (mine["english"] as? [String]) ?? [])
        if added > 0 { report.append("в списках (стоп/форс/приложения): +\(added)") }
        if let lo = mine["lang"] as? [String: Any] {
            var d: [String: [Double]] = [:]
            for (app, v) in lo {
                if let a = v as? [NSNumber], a.count == 2 { d[app] = [a[0].doubleValue, a[1].doubleValue] }
            }
            let n = AppLangStats.shared.mergeMax(d)
            if n > 0 { report.append("ожидание языка: \(n) приложений") }
        }

        if let journal = doc["profileJournal"] as? String, !journal.isEmpty {
            let prof = SemProfile.shared
            let cur = prof.journalText()
            let add = SkillsFile.newJournalLines(current: cur, incoming: journal)
            if !add.isEmpty {
                var text = cur
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                text += add.joined(separator: "\n") + "\n"
                _ = prof.rebuild(fromJournal: text)
                report.append("журнал профиля: +\(add.count) строк, профиль пересобран")
            }
        }

        if let pers = doc["personal"] as? [String: Any] {
            let t = PersonalLM.shared.merge(pers)
            PersonalLM.shared.save()
            if t > 0 { report.append("личный слой: таблиц других устройств +\(t)") }
        }

        let from = doc["from"] as? [String: Any]
        let name = from?["name"] as? String ?? "?", plat = from?["platform"] as? String ?? "?"
        if report.isEmpty { return "Из «\(name)» (\(plat)): нового нет — всё уже есть." }
        return "Из «\(name)» (\(plat)):\n" + report.map { "• " + $0 }.joined(separator: "\n")
    }
}
