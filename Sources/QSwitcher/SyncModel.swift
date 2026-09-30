import Foundation
import CryptoKit

// Синхронизация навыков между устройствами (мак ↔ винда). Общая часть: реестры изменений,
// файл устройства, слияние, круг синхронизации. Сеть — SyncTransport.swift, привязка к
// приложению — SyncService.swift. Зеркало на винде — SyncModel.cs / SyncEngine.cs; формат
// файла и правила слияния одинаковые (самопроверка — одни и те же сценарии и образец файла).
//
// Схема: каждое устройство пишет ОДИН свой файл <устройство>.qssync в общую папку (Google
// Drive или WebDAV) и читает чужие. Конфликтов записи нет: файл пишет только хозяин. Файл —
// QSX1 (как экспорт навыков) с паролем синхронизации, внутри JSON:
//
//   format "qswitcher-sync", v 1, device, name, platform, app, updated (мс)
//   ledgers  {коллекция: {ключ: [значение|null, метка мс]}}  — реестры (LWW, удаления — null)
//   appLang  {платформа отправителя: {приложение: [ru, en]}} — ожидание языка, слияние по большему
//   personal {v, self, clearedAt, tables: [своя таблица]}   — личный слой этого устройства
//
// Коллекции: learned (слово → "f"/"s"), stopWords, forceWords (слово → "1"),
// apps.<mac|win>.excluded / apps.<mac|win>.english (приложение → "1"),
// journal (строка журнала профиля → сколько раз она в журнале).

/// Запись реестра: значение (nil — удалено) и метка времени (мс Unix).
struct SyncEntry: Equatable {
    var v: String?
    var t: Int64

    /// a важнее b? Позже — важнее; при равенстве наличие важнее удаления, дальше — большее
    /// значение по кодам символов. На всех устройствах одинаково.
    static func beats(_ a: SyncEntry, _ b: SyncEntry) -> Bool {
        if a.t != b.t { return a.t > b.t }
        if (a.v == nil) != (b.v == nil) { return a.v != nil }
        guard let av = a.v, let bv = b.v else { return false }
        return SyncMerge.ordinalLess(bv, av)
    }
}

/// Что поменять у себя: значение (nil — убрать) по ключу коллекции.
struct SyncOp: Equatable {
    let collection: String
    let key: String
    let value: String?
}

enum SyncCollections {
    static let learned = "learned"
    static let stopWords = "stopWords"
    static let forceWords = "forceWords"
    static let journal = "journal"
    static func excluded(_ platform: String) -> String { "apps.\(platform).excluded" }
    static func english(_ platform: String) -> String { "apps.\(platform).english" }
}

/// Что известно о чужом файле: версия (не менялся — не качаем), чей, ошибка.
struct SyncRemoteInfo {
    var version = "", name = "", device = "", deviceName = "", platform = "", error = ""
    var updated: Int64 = 0
}

private func jsonStr(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
private func jsonInt(_ d: [String: Any], _ k: String) -> Int64 {
    guard let n = d[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return 0 }
    return n.int64Value
}

/// Состояние синхронизации устройства (sync-state.json).
final class SyncState {
    /// Реестры всех коллекций (и чужой платформы — их несём дальше как есть).
    var ledgers: [String: [String: SyncEntry]] = [:]
    /// Своё состояние после прошлой синхронизации — по разнице видно свои правки.
    var lastLocal: [String: [String: String]] = [:]
    /// Чужие файлы по id в хранилище.
    var remote: [String: SyncRemoteInfo] = [:]
    /// Кэш транспорта (id своего файла на Google Drive и т.п.).
    var cache: [String: String] = [:]
    var pushedLedgerHash = "", pushedSoftHash = ""
    var pushedAt: Int64 = 0, pushedSoftAt: Int64 = 0
    var lastOk: Int64 = 0
    var lastError = ""

    /// Сменили хранилище или пароль — всё чужое перечитать, своё отправить заново.
    func forgetRemote() {
        remote = [:]
        cache = [:]
        pushedLedgerHash = ""
        pushedSoftHash = ""
    }

    func toJSON() -> Data {
        var rem: [String: Any] = [:]
        for (id, r) in remote {
            rem[id] = ["version": r.version, "name": r.name, "device": r.device, "deviceName": r.deviceName,
                       "platform": r.platform, "updated": r.updated, "error": r.error] as [String: Any]
        }
        let doc: [String: Any] = [
            "v": 1,
            "ledgers": SyncPayload.ledgersToJSON(ledgers),
            "lastLocal": lastLocal,
            "remote": rem,
            "cache": cache,
            "pushedLedgerHash": pushedLedgerHash, "pushedSoftHash": pushedSoftHash,
            "pushedAt": pushedAt, "pushedSoftAt": pushedSoftAt,
            "lastOk": lastOk, "lastError": lastError,
        ]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func fromJSON(_ data: Data) throws -> SyncState {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkillsFile.Failure.notSkills
        }
        let st = SyncState()
        st.ledgers = SyncPayload.readLedgers(root["ledgers"])
        for (c, m) in (root["lastLocal"] as? [String: Any]) ?? [:] {
            var out: [String: String] = [:]
            for (k, v) in (m as? [String: Any]) ?? [:] { if let s = v as? String { out[k] = s } }
            st.lastLocal[c] = out
        }
        for (id, r) in (root["remote"] as? [String: Any]) ?? [:] {
            guard let d = r as? [String: Any] else { continue }
            st.remote[id] = SyncRemoteInfo(version: jsonStr(d, "version"), name: jsonStr(d, "name"),
                                           device: jsonStr(d, "device"), deviceName: jsonStr(d, "deviceName"),
                                           platform: jsonStr(d, "platform"), error: jsonStr(d, "error"),
                                           updated: jsonInt(d, "updated"))
        }
        for (k, v) in (root["cache"] as? [String: Any]) ?? [:] { if let s = v as? String { st.cache[k] = s } }
        st.pushedLedgerHash = jsonStr(root, "pushedLedgerHash")
        st.pushedSoftHash = jsonStr(root, "pushedSoftHash")
        st.pushedAt = jsonInt(root, "pushedAt")
        st.pushedSoftAt = jsonInt(root, "pushedSoftAt")
        st.lastOk = jsonInt(root, "lastOk")
        st.lastError = jsonStr(root, "lastError")
        return st
    }
}

/// Правила слияния реестров — чистые функции (самопроверка ниже, та же на винде).
enum SyncMerge {
    /// Удаления помним полгода: устройство, не включавшееся дольше, может вернуть удалённое.
    static let tombstoneKeepMs: Int64 = 180 * 24 * 3600 * 1000
    /// Метка «давнего» — своё содержимое при первой синхронизации: удаление, сделанное где-то
    /// после начала синхронизации, важнее того, что просто лежало на устройстве.
    static let ancient: Int64 = 1

    /// Сравнение по кодам UTF-16 (как string.CompareOrdinal в C#).
    static func ordinalLess(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }

    /// Шаг 1: свои правки с прошлой синхронизации — в реестр. local — только коллекции этого
    /// устройства. Возвращает число правок.
    @discardableResult
    static func noteLocal(_ st: SyncState, _ local: [String: [String: String]], now: Int64) -> Int {
        var n = 0
        for (c, cur) in local {
            var led = st.ledgers[c] ?? [:]
            if let last = st.lastLocal[c] {
                for (k, v) in cur where last[k] != v { stamp(&led, k, v, now); n += 1 }
                for k in last.keys where cur[k] == nil { stamp(&led, k, nil, now); n += 1 }
            }
            // Своё, чего в реестре нет (первая синхронизация, потерянный реестр) — как давнее
            for (k, v) in cur where led[k] == nil { led[k] = SyncEntry(v: v, t: ancient); n += 1 }
            st.ledgers[c] = led
        }
        return n
    }

    /// Своя правка случилась после всего, что устройство уже видело, — метка не меньше.
    private static func stamp(_ led: inout [String: SyncEntry], _ k: String, _ v: String?, _ now: Int64) {
        var t = now
        if let e = led[k], e.t >= t { t = e.t + 1 }
        led[k] = SyncEntry(v: v, t: t)
    }

    /// Шаг 2: слить чужие реестры. Возвращает, сколько записей сменилось.
    @discardableResult
    static func mergeRemote(_ st: SyncState, _ remote: [String: [String: SyncEntry]]) -> Int {
        var n = 0
        for (c, items) in remote {
            var led = st.ledgers[c] ?? [:]
            for (k, e) in items {
                if let cur = led[k], !SyncEntry.beats(e, cur) { continue }
                led[k] = e
                n += 1
            }
            st.ledgers[c] = led
        }
        return n
    }

    /// Шаг 3: что поменять у себя, чтобы совпасть с реестром.
    static func plan(_ st: SyncState, _ local: [String: [String: String]]) -> [SyncOp] {
        var ops: [SyncOp] = []
        for (c, cur) in local {
            guard let led = st.ledgers[c] else { continue }
            for k in led.keys.sorted(by: ordinalLess) {
                let e = led[k]!
                if let v = e.v {
                    if cur[k] != v { ops.append(SyncOp(collection: c, key: k, value: v)) }
                } else if cur[k] != nil {
                    ops.append(SyncOp(collection: c, key: k, value: nil))
                }
            }
        }
        return ops
    }

    /// Шаг 4: запомнить своё состояние после применения (как оно есть на самом деле).
    static func remember(_ st: SyncState, _ local: [String: [String: String]]) {
        for (c, cur) in local { st.lastLocal[c] = cur }
    }

    /// Забыть давние удаления. Возвращает, сколько убрано.
    @discardableResult
    static func prune(_ st: SyncState, now: Int64) -> Int {
        var n = 0
        for (c, led) in st.ledgers {
            let old = led.filter { $0.value.v == nil && now - $0.value.t > tombstoneKeepMs }.map { $0.key }
            if old.isEmpty { continue }
            var l = led
            for k in old { l.removeValue(forKey: k) }
            st.ledgers[c] = l
            n += old.count
        }
        return n
    }

    static func ledgerHash(_ st: SyncState) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: SyncPayload.ledgersToJSON(st.ledgers), options: [.sortedKeys])) ?? Data()
        return hash(d)
    }

    static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02X", $0) }.joined() }
    static func hash(_ s: String) -> String { hash(Data(s.utf8)) }

    // MARK: самопроверка (те же сценарии, что SyncMerge.Selftest в SyncModel.cs)

    static func selftest(log: @escaping (String) -> Void) -> (total: Int, bad: Int) {
        var total = 0, bad = 0
        func check(_ ok: Bool, _ what: String) {
            total += 1
            if !ok { bad += 1; log("  ✗ \(what)") }
        }
        func opsText(_ ops: [SyncOp]) -> String { ops.map { "\($0.collection):\($0.key)=\($0.value ?? "-")" }.joined(separator: " ") }
        let W = SyncCollections.stopWords, R = SyncCollections.learned

        // 1. Первая синхронизация A: всё своё — давнее, менять нечего
        let a = SyncState()
        var la: [String: [String: String]] = [W: ["a": "1", "b": "1"]]
        noteLocal(a, la, now: 1000)
        check(a.ledgers[W]?["a"] == SyncEntry(v: "1", t: ancient), "1: своё при первой синхронизации — давнее")
        check(plan(a, la).isEmpty, "1: менять нечего")
        remember(a, la)

        // 2. Первая синхронизация B со своим {b, c}: получает a
        let b = SyncState()
        var lb: [String: [String: String]] = [W: ["b": "1", "c": "1"]]
        noteLocal(b, lb, now: 1100)
        mergeRemote(b, a.ledgers)
        check(opsText(plan(b, lb)) == "stopWords:a=1", "2: B получает a (\(opsText(plan(b, lb))))")
        lb[W]!["a"] = "1"
        remember(b, lb)

        // 3. A удаляет b; B, получив, убирает b
        la[W]!.removeValue(forKey: "b")
        noteLocal(a, la, now: 2000)
        check(a.ledgers[W]?["b"] == SyncEntry(v: nil, t: 2000), "3: удаление с меткой")
        mergeRemote(b, a.ledgers)
        check(opsText(plan(b, lb)) == "stopWords:b=-", "3: B убирает b (\(opsText(plan(b, lb))))")
        lb[W]!.removeValue(forKey: "b")
        remember(b, lb)
        mergeRemote(a, b.ledgers)
        check(opsText(plan(a, la)) == "stopWords:c=1", "3: A получает c (\(opsText(plan(a, la))))")

        // 4. Конфликт правил в одну миллисекунду: побеждает одно и то же на обоих
        let x = SyncState(), y = SyncState()
        x.ledgers[R] = ["ha": SyncEntry(v: "f", t: 5000)]
        y.ledgers[R] = ["ha": SyncEntry(v: "s", t: 5000)]
        mergeRemote(x, y.ledgers)
        mergeRemote(y, x.ledgers)
        let hx = x.ledgers[R]?["ha"], hy = y.ledgers[R]?["ha"]
        check(hx == hy && hx?.v == "s", "4: ничья — одинаково на обоих")
        let z1 = SyncState(), z2 = SyncState()
        z1.ledgers[W] = ["q": SyncEntry(v: nil, t: 7000)]
        z2.ledgers[W] = ["q": SyncEntry(v: "1", t: 7000)]
        mergeRemote(z1, z2.ledgers)
        check(z1.ledgers[W]?["q"]?.v == "1", "4: ничья — наличие важнее удаления")

        // 5. Чужие часы впереди: своя правка всё равно новее увиденного
        let c5 = SyncState()
        var l5: [String: [String: String]] = [R: ["ok": "f"]]
        noteLocal(c5, l5, now: 1000)
        remember(c5, l5)
        c5.ledgers[R]!["ok"] = SyncEntry(v: "f", t: 9_000)
        l5[R]!["ok"] = "s"
        noteLocal(c5, l5, now: 2000)
        check(c5.ledgers[R]?["ok"] == SyncEntry(v: "s", t: 9_001), "5: своя правка после увиденного")

        // 6. Применение не удалось — не превращается в удаление, повторяется
        let c6 = SyncState()
        let l6: [String: [String: String]] = [W: [:]]
        noteLocal(c6, l6, now: 1000)
        c6.ledgers[W, default: [:]]["new"] = SyncEntry(v: "1", t: 1500)
        check(opsText(plan(c6, l6)) == "stopWords:new=1", "6: план — добавить")
        remember(c6, l6)
        noteLocal(c6, l6, now: 3000)
        check(c6.ledgers[W]?["new"] == SyncEntry(v: "1", t: 1500), "6: неудача не стала удалением")
        check(opsText(plan(c6, l6)) == "stopWords:new=1", "6: повтор на следующем круге")

        // 7. Давние удаления забываются, наличие — нет
        let c7 = SyncState()
        c7.ledgers[W] = ["old": SyncEntry(v: nil, t: 1000), "keep": SyncEntry(v: "1", t: 1000),
                         "fresh": SyncEntry(v: nil, t: tombstoneKeepMs)]
        let pruned = prune(c7, now: tombstoneKeepMs + 2000)
        let led7 = c7.ledgers[W] ?? [:]
        let gone7 = led7["old"] == nil
        let kept7 = led7["keep"] != nil && led7["fresh"] != nil
        check(pruned == 1 && gone7 && kept7, "7: подрезка удалений")

        // 8. Журнал: строка → сколько раз; применение сохраняет порядок
        let text = "a *b* # x\r\nc *d*\n\na *b* # x\n"
        let jc = SyncJournal.counts(text)
        check(jc.count == 2 && jc["a *b* # x"] == "2" && jc["c *d*"] == "1", "8: подсчёт строк журнала")
        let j2 = SyncJournal.apply(text, [SyncOp(collection: SyncCollections.journal, key: "a *b* # x", value: "1"),
                                          SyncOp(collection: SyncCollections.journal, key: "e *f*", value: "2"),
                                          SyncOp(collection: SyncCollections.journal, key: "c *d*", value: nil)])
        check(j2 == "a *b* # x\ne *f*\ne *f*\n", "8: применение к журналу (\(j2.replacingOccurrences(of: "\n", with: "⏎")))")

        // 9. Файл устройства: запись и чтение без потерь
        let st9 = SyncState()
        st9.ledgers[R] = ["ёж": SyncEntry(v: "f", t: 123)]
        st9.ledgers[W] = ["gone": SyncEntry(v: nil, t: 456)]
        let personal: [String: Any] = ["v": 1, "self": "dev1", "clearedAt": 0, "tables": [[String: Any]]()]
        let doc = SyncPayload.build(st9, device: "dev1", name: "Комп", platform: "win", app: "test",
                                    appLang: ["chrome": [12.5, 3.0]], personal: personal, now: 777)
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]),
           let p = try? SyncPayload.parse(data) {
            let head9 = p.device == "dev1" && p.name == "Комп" && p.platform == "win" && p.updated == 777
            check(head9, "9: шапка файла")
            let e1: Bool = p.ledgers[R]?["ёж"] == SyncEntry(v: "f", t: 123)
            let e2: Bool = p.ledgers[W]?["gone"] == SyncEntry(v: nil, t: 456)
            check(e1 && e2, "9: реестры")
            let chrome: [Double] = p.appLang["chrome"] ?? []
            check(chrome == [12.5, 3.0], "9: ожидание языка")
            check((p.personal?["self"] as? String) == "dev1", "9: личный слой")
        } else {
            for w in ["9: шапка файла", "9: реестры", "9: ожидание языка", "9: личный слой"] { check(false, w) }
        }

        // 10. Шифр: свой ключ кэшируется, чужой пароль не подходит
        let json = Data("{\"format\":\"qswitcher-sync\"}".utf8)
        if let blob = try? SkillsFile.seal(json, password: "пароль", stableSalt: true),
           let blob2 = try? SkillsFile.seal(json, password: "пароль", stableSalt: true) {
            let sameSalt = blob.subdata(in: 4..<20) == blob2.subdata(in: 4..<20)
            let newNonce = blob.subdata(in: 24..<36) != blob2.subdata(in: 24..<36)
            check(sameSalt && newNonce, "10: соль своего файла постоянна, nonce — новый")
            check((try? SkillsFile.open(blob, password: "пароль")) == json, "10: расшифровка")
            var wrong = false
            do { _ = try SkillsFile.open(blob, password: "другой") } catch SkillsFile.Failure.wrongPassword { wrong = true } catch {}
            check(wrong, "10: чужой пароль")
        } else {
            for w in ["10: соль", "10: расшифровка", "10: чужой пароль"] { check(false, w) }
        }
        // Образец файла с винды: один и тот же файл обязан открываться на обеих
        do {
            guard let raw = Data(base64Encoded: sampleBlob) else { throw SkillsFile.Failure.notSkills }
            let s = try SyncPayload.parse(try SkillsFile.open(raw, password: samplePassword))
            let tables = s.personal?["tables"] as? [[String: Any]]
            let uni = tables?.first?["uni"] as? [String: Any]
            let privet = (uni?["ru"] as? [String: Any])?["привет"] as? NSNumber
            let head = s.device == "sample-device" && s.name == "Образец" && s.platform == "mac"
            let r1: Bool = s.ledgers[R]?["рф"] == SyncEntry(v: "s", t: 1727700000000)
            let r2: Bool = s.ledgers[W]?["удалено"] == SyncEntry(v: nil, t: 1727700000001)
            let r3: Bool = s.ledgers[W]?["ssh"] == SyncEntry(v: "1", t: 1)
            let safari: [Double] = s.appLang["com.apple.Safari"] ?? []
            let lang: Bool = safari == [1.5, 2.0]
            let pers: Bool = privet?.doubleValue == 2.0
            check(head && r1 && r2 && r3 && lang && pers, "10: образец файла")
        } catch {
            check(false, "10: образец файла (\(error))")
        }
        return (total, bad)
    }

    /// Образец файла синхронизации (сделан на винде): формат и шифр совпадают на обеих платформах.
    /// Та же строка — в SyncModel.cs.
    static let samplePassword = "qswitcher-test"
    static let sampleBlob =
        "UVNYMV85mZgrUadIhOL8cGMdJwDAJwkA5jPXddGBSpKJwuRkFrb53R0xznwKMRD2LkCN6vZgLtfd6v3M4ofkrV8oI0Qg9uVFJPGM"
        + "iax1MrWiw+OojfHCXKCPqucj+Uu3nqUsZGmffgA4g0lwQv/+wNgzwOqvvspZEUrIOKZJ9DkIK9+c+Y8QkFjH3LQ4nJI7mlueOnTQ"
        + "MCkB6jHZMNbiUo4nFpR44r1OKJATk7kvKdFr+R7LO1u4stlb+WD1L/9tCfOYd9+SYL4nYhj5w/F4N1AHPFGTAbTvUqK0EG7jxMLe"
        + "NqWL8eamAqAS+fQeFYrn/1+zWRLra5TFghm6VLsCQuTK25yOiOgBdVUzs2J4LaYfJT94k02FT1fPtNbmATzqrWbkGN703s5gHyPR"
        + "+qF89cGkGYkEJ6yW4NvX5hVdKqeXpHlk6K3bErglyVGAKpEDpZfep4Jf54YcuR99T6ToSAr8EqAruan+W2OJSwjy3OQtH5x0"
}

/// Файл устройства: сборка и разбор.
struct SyncPayload {
    static let format = "qswitcher-sync"

    var device = "", name = "", platform = "", app = ""
    var updated: Int64 = 0
    var ledgers: [String: [String: SyncEntry]] = [:]
    /// Ожидание языка платформы отправителя.
    var appLang: [String: [Double]] = [:]
    /// Личный слой отправителя (формат PersonalLM: v, self, clearedAt, tables).
    var personal: [String: Any]? = nil

    static func ledgersToJSON(_ ledgers: [String: [String: SyncEntry]]) -> [String: Any] {
        var o: [String: Any] = [:]
        for (c, items) in ledgers {
            var m: [String: Any] = [:]
            for (k, e) in items { m[k] = [e.v.map { $0 as Any } ?? NSNull(), NSNumber(value: e.t)] as [Any] }
            o[c] = m
        }
        return o
    }

    static func readLedgers(_ any: Any?) -> [String: [String: SyncEntry]] {
        var out: [String: [String: SyncEntry]] = [:]
        for (c, m) in (any as? [String: Any]) ?? [:] {
            var items: [String: SyncEntry] = [:]
            for (k, v) in (m as? [String: Any]) ?? [:] {
                guard let a = v as? [Any], a.count == 2, let t = a[1] as? NSNumber,
                      CFGetTypeID(t) != CFBooleanGetTypeID() else { continue }
                if let s = a[0] as? String { items[k] = SyncEntry(v: s, t: t.int64Value) }
                else if a[0] is NSNull { items[k] = SyncEntry(v: nil, t: t.int64Value) }
            }
            out[c, default: [:]].merge(items) { _, new in new }
        }
        return out
    }

    /// Собрать файл устройства. personal — своя таблица (PersonalLM.snapshotLocal) или nil.
    static func build(_ st: SyncState, device: String, name: String, platform: String, app: String,
                      appLang: [String: [Double]], personal: [String: Any]?, now: Int64) -> [String: Any] {
        var lang: [String: Any] = [:]
        for (k, v) in appLang where v.count == 2 {
            lang[k] = [(v[0] * 100).rounded() / 100, (v[1] * 100).rounded() / 100]
        }
        var doc: [String: Any] = [
            "format": format, "v": 1, "device": device, "name": name, "platform": platform, "app": app,
            "updated": now, "ledgers": ledgersToJSON(st.ledgers), "appLang": [platform: lang],
        ]
        if let p = personal { doc["personal"] = p }
        return doc
    }

    /// Отпечаток «мягкой» части — ожидания языка (меняется с каждым словом, поэтому отправляется
    /// не чаще раза в несколько минут).
    static func softHash(_ appLang: [String: [Double]]) -> String {
        var s = ""
        for k in appLang.keys.sorted(by: SyncMerge.ordinalLess) {
            guard let v = appLang[k], v.count == 2 else { continue }
            s += "\(k)=\((v[0] * 100).rounded() / 100),\((v[1] * 100).rounded() / 100);"
        }
        return SyncMerge.hash(s)
    }

    /// Разобрать расшифрованный файл (JSON в UTF-8).
    static func parse(_ json: Data) throws -> SyncPayload {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              root["format"] as? String == format else { throw SkillsFile.Failure.notSkills }
        var p = SyncPayload()
        p.device = jsonStr(root, "device")
        p.name = jsonStr(root, "name")
        p.platform = jsonStr(root, "platform")
        p.app = jsonStr(root, "app")
        p.updated = jsonInt(root, "updated")
        p.ledgers = readLedgers(root["ledgers"])
        if let mine = (root["appLang"] as? [String: Any])?[p.platform] as? [String: Any] {
            for (k, v) in mine {
                if let a = v as? [NSNumber], a.count == 2 { p.appLang[k] = [a[0].doubleValue, a[1].doubleValue] }
            }
        }
        p.personal = root["personal"] as? [String: Any]
        return p
    }
}

/// Журнал профиля как коллекция: строка → сколько раз она в журнале.
enum SyncJournal {
    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { raw -> String in
            var l = raw
            while l.unicodeScalars.last == "\r" { l.unicodeScalars.removeLast() }
            return l
        }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func counts(_ text: String) -> [String: String] {
        var n: [String: Int] = [:]
        for l in lines(text) { n[l, default: 0] += 1 }
        return n.mapValues { String($0) }
    }

    /// Применить к тексту журнала: число повторов строки — как в реестре. Порядок своих строк
    /// сохраняется, лишние повторы убираются с конца, новые — дописываются.
    static func apply(_ text: String, _ ops: [SyncOp]) -> String {
        var want: [String: Int] = [:]
        var order: [String] = []
        for op in ops {
            if want[op.key] == nil { order.append(op.key) }
            want[op.key] = op.value.map { max(0, Int($0) ?? 1) } ?? 0
        }
        var ls = lines(text)
        var have: [String: Int] = [:]
        for l in ls { have[l, default: 0] += 1 }
        var i = ls.count - 1
        while i >= 0 {
            let l = ls[i]
            if let w = want[l], have[l, default: 0] > w {
                ls.remove(at: i)
                have[l, default: 0] -= 1
            }
            i -= 1
        }
        for l in order {
            var h = have[l] ?? 0
            let w = want[l] ?? 0
            while h < w { ls.append(l); h += 1 }
        }
        return ls.isEmpty ? "" : ls.joined(separator: "\n") + "\n"
    }
}

/// Приложение со стороны синхронизации: где лежат навыки и как их менять.
protocol SyncHost: AnyObject {
    var device: String { get }
    var deviceName: String { get }
    var platform: String { get }
    var appTitle: String { get }
    /// Своё состояние по коллекциям этой платформы (вызывается через onMain).
    func readLocal() -> [String: [String: String]]
    /// Применить изменения (через onMain).
    func apply(_ ops: [SyncOp])
    func appLang() -> [String: [Double]]
    func mergeAppLang(_ other: [String: [Double]])
    var personal: PersonalLM { get }
    func savePersonal()
    /// Выполнить на главном потоке и дождаться (там живут списки и правила).
    func onMain(_ block: @escaping () -> Void) throws
}

/// Итог одного круга: что пришло, что ушло, что не так.
final class SyncReport {
    var files = 0
    var applied: [String: Int] = [:]
    var personalTables = 0
    var pushed = false
    var problems: [String] = []
    var appliedTotal: Int { applied.values.reduce(0, +) }

    func summary() -> String {
        var parts: [String] = []
        if files > 0 { parts.append("прочитано файлов других устройств: \(files)") }
        for c in applied.keys.sorted() { parts.append("\(SyncEngine.title(c)): \(applied[c]!)") }
        if personalTables > 0 { parts.append("личный слой: таблиц других устройств \(personalTables)") }
        parts.append(pushed ? "свой файл отправлен" : "своё без изменений")
        parts += problems.map { "⚠️ " + $0 }
        return parts.joined(separator: "\n")
    }
}

/// Круг синхронизации: чужие файлы → слияние → применение у себя → свой файл. Синхронный
/// (сеть — через семафоры), вызывается на своей очереди; один круг за раз.
final class SyncEngine {
    /// «Мягкое» (личный слой, ожидание языка) — не чаще раза в 5 минут, если не просили сразу.
    static let softIntervalMs: Int64 = 5 * 60 * 1000

    private unowned let host: SyncHost
    private let statePath: URL
    private let log: (String) -> Void
    private var pushedPersonalVersion: Int64 = -1
    private(set) var state = SyncState()

    init(host: SyncHost, statePath: URL, log: @escaping (String) -> Void) {
        self.host = host
        self.statePath = statePath
        self.log = log
        if let d = try? Data(contentsOf: statePath) {
            do { state = try SyncState.fromJSON(d) } catch {
                log("[sync] состояние не прочиталось — начинаю заново")
                let broken = statePath.appendingPathExtension("broken")
                try? FileManager.default.removeItem(at: broken)
                try? FileManager.default.moveItem(at: statePath, to: broken)
            }
        }
    }

    var ownFileName: String {
        String(host.device.unicodeScalars.filter {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }.map(Character.init)) + ".qssync"
    }

    func saveState() {
        do { try state.toJSON().write(to: statePath, options: .atomic) }
        catch { log("[sync] состояние не записалось: \(error.localizedDescription)") }
    }

    /// Сменили хранилище или пароль: всё чужое перечитать, своё отправить заново.
    func reset() {
        state.forgetRemote()
        pushedPersonalVersion = -1
        saveState()
    }

    static func title(_ c: String) -> String {
        switch c {
        case SyncCollections.learned: return "выученные правила"
        case SyncCollections.stopWords: return "стоп-слова"
        case SyncCollections.forceWords: return "форс-слова"
        case SyncCollections.journal: return "журнал профиля"
        default:
            if c.hasSuffix(".excluded") { return "исключённые приложения" }
            if c.hasSuffix(".english") { return "приложения с английским вводом" }
            return c
        }
    }

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Один круг. pull — читать чужие файлы (на выходе из приложения — только отправка);
    /// forcePush — отправить своё сразу, даже если с прошлой отправки прошло мало времени.
    func run(_ transport: SyncTransport, password: String, forcePush: Bool, pull: Bool) throws -> SyncReport {
        let rep = SyncReport()
        let now = SyncEngine.now()
        var fresh: [SyncPayload] = []
        var infos: [String: SyncRemoteInfo] = [:]
        var present = Set<String>()
        var ownMissing = false
        let own = ownFileName

        if pull {
            let files = try transport.list()
            ownMissing = !files.contains { $0.name == own }
            for f in files where f.name != own {
                present.insert(f.id)
                if let known = state.remote[f.id], known.version == f.version { continue }
                var info = SyncRemoteInfo(version: f.version, name: f.name)
                let data: Data
                do { data = try transport.get(f) } catch let e as SyncError where !e.auth {
                    // Один файл не скачался — остальные не ждут; этот повторится на следующем круге
                    rep.problems.append("\(f.name): \(e.message)")
                    continue
                }
                do {
                    let p = try SyncPayload.parse(try SkillsFile.open(data, password: password))
                    info.device = p.device
                    info.deviceName = p.name
                    info.platform = p.platform
                    info.updated = p.updated
                    if p.device != host.device { fresh.append(p) }
                } catch SkillsFile.Failure.wrongPassword {
                    info.error = "другой пароль синхронизации"
                } catch {
                    info.error = "файл не читается"
                }
                infos[f.id] = info
            }
        }

        // Своё и чужое — одним куском на главном потоке: между чтением своего и применением
        // человек ничего не успеет поменять
        var applied: [SyncOp] = []
        let st = state
        let h = host
        let incoming = fresh
        try h.onMain {
            var local = h.readLocal()
            SyncMerge.noteLocal(st, local, now: now)
            for p in incoming { SyncMerge.mergeRemote(st, p.ledgers) }
            if pull {
                let ops = SyncMerge.plan(st, local)
                if !ops.isEmpty {
                    h.apply(ops)
                    applied = ops
                    local = h.readLocal()
                }
            }
            SyncMerge.remember(st, local)
        }
        for op in applied { rep.applied[op.collection, default: 0] += 1 }

        // Ожидание языка — только от устройств той же платформы (имена приложений свои)
        for p in fresh where p.platform == host.platform && !p.appLang.isEmpty { host.mergeAppLang(p.appLang) }
        // Личный слой других устройств: их таблицы целиком, если свежее
        let clearedBefore = host.personal.clearedAt
        for p in fresh { if let pe = p.personal { rep.personalTables += host.personal.merge(pe) } }
        if rep.personalTables > 0 || host.personal.clearedAt != clearedBefore { host.savePersonal() }
        rep.files = fresh.count

        if pull {
            for (id, info) in infos { state.remote[id] = info }
            for id in state.remote.keys where !present.contains(id) { state.remote.removeValue(forKey: id) }
            for info in state.remote.values where !info.error.isEmpty {
                rep.problems.append("\(info.deviceName.isEmpty ? info.name : info.deviceName): \(info.error)")
            }
        }
        SyncMerge.prune(state, now: now)

        // Своё: реестры (и очистка личного слоя) — сразу; личный слой и ожидание языка — не чаще
        // раза в softIntervalMs, если не просили сразу
        let hard = SyncMerge.ledgerHash(state) + "|\(host.personal.clearedAt)"
        let appLang = host.appLang()
        let soft = SyncPayload.softHash(appLang)
        let pv = host.personal.localVersion
        let hardChanged = hard != state.pushedLedgerHash || ownMissing
        let softChanged = soft != state.pushedSoftHash || pv != pushedPersonalVersion
        let due = forcePush || now - state.pushedSoftAt >= SyncEngine.softIntervalMs
        if hardChanged || (softChanged && due) {
            let doc = SyncPayload.build(state, device: host.device, name: host.deviceName, platform: host.platform,
                                        app: host.appTitle, appLang: appLang, personal: host.personal.snapshotLocal(), now: now)
            let json = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
            let blob = try SkillsFile.seal(json, password: password, stableSalt: true)
            try transport.put(name: own, data: blob, cache: &state.cache)
            state.pushedLedgerHash = hard
            state.pushedSoftHash = soft
            state.pushedAt = now
            state.pushedSoftAt = now
            pushedPersonalVersion = pv
            rep.pushed = true
        }
        state.lastOk = now
        state.lastError = ""
        saveState()
        return rep
    }
}
