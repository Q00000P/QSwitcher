using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace QSwitcher.Core;

// Синхронизация навыков между устройствами (мак ↔ винда). Общая часть: реестры изменений,
// файл устройства, слияние. Сеть — SyncTransport.cs, привязка к приложению — SyncService
// (App). Зеркало на маке — SyncModel.swift; формат файла и правила слияния одинаковые.
//
// Схема: каждое устройство пишет ОДИН свой файл <устройство>.qssync в общую папку
// (Google Drive или WebDAV) и читает чужие. Конфликтов записи нет: файл пишет только
// хозяин. Файл — QSX1 (как экспорт навыков) с паролем синхронизации, внутри JSON:
//
//   format "qswitcher-sync", v 1, device, name, platform, app, updated (мс)
//   ledgers  {коллекция: {ключ: [значение|null, метка мс]}}  — реестры (LWW, удаления — null)
//   appLang  {платформа отправителя: {приложение: [ru, en]}} — ожидание языка, слияние по большему
//   personal {v, self, clearedAt, tables: [своя таблица]}   — личный слой этого устройства
//
// Коллекции: learned (слово → "f"/"s"), stopWords, forceWords (слово → "1"),
// apps.<mac|win>.excluded / apps.<mac|win>.english (приложение → "1"),
// journal (строка журнала профиля → сколько раз она в журнале).
//
// Свои правки находятся сравнением с тем, что было после прошлой синхронизации (LastLocal),
// поэтому ловятся любые пути изменения: меню, окно правил, импорт, правка config.json руками.

/// <summary>Запись реестра: значение (null — удалено) и метка времени (мс Unix).</summary>
public readonly record struct SyncEntry(string? V, long T)
{
    /// <summary>a важнее b? Позже — важнее; при равенстве наличие важнее удаления, дальше —
    /// большее значение по кодам символов. На всех устройствах одинаково.</summary>
    public static bool Beats(SyncEntry a, SyncEntry b)
    {
        if (a.T != b.T) return a.T > b.T;
        if ((a.V is null) != (b.V is null)) return a.V is not null;
        return a.V is not null && string.CompareOrdinal(a.V, b.V) > 0;
    }
}

/// <summary>Что поменять у себя: значение (null — убрать) по ключу коллекции.</summary>
public sealed record SyncOp(string Collection, string Key, string? Value);

/// <summary>Имена коллекций.</summary>
public static class SyncCollections
{
    public const string Learned = "learned";
    public const string StopWords = "stopWords";
    public const string ForceWords = "forceWords";
    public const string Journal = "journal";
    public static string Excluded(string platform) => $"apps.{platform}.excluded";
    public static string English(string platform) => $"apps.{platform}.english";
}

/// <summary>Что известно о чужом файле: версия (не менялся — не качаем), чей, ошибка.</summary>
public sealed class SyncRemoteInfo
{
    public string Version = "", Name = "", Device = "", DeviceName = "", Platform = "", Error = "";
    public long Updated;
}

/// <summary>Состояние синхронизации устройства (sync-state.json).</summary>
public sealed class SyncState
{
    /// Реестры всех коллекций (и чужой платформы — их несём дальше как есть).
    public readonly Dictionary<string, Dictionary<string, SyncEntry>> Ledgers = new(StringComparer.Ordinal);
    /// Своё состояние после прошлой синхронизации — по разнице видно свои правки.
    public readonly Dictionary<string, Dictionary<string, string>> LastLocal = new(StringComparer.Ordinal);
    /// Чужие файлы по id в хранилище.
    public readonly Dictionary<string, SyncRemoteInfo> Remote = new(StringComparer.Ordinal);
    /// Кэш транспорта (id своего файла на Google Drive и т.п.).
    public readonly Dictionary<string, string> Cache = new(StringComparer.Ordinal);
    /// Отпечаток отправленных реестров и «мягкой» части (ожидание языка), время отправки.
    public string PushedLedgerHash = "", PushedSoftHash = "";
    public long PushedAt, PushedSoftAt;
    /// Последняя удачная синхронизация и последняя ошибка.
    public long LastOk;
    public string LastError = "";

    public Dictionary<string, SyncEntry> LedgerOf(string collection)
    {
        if (!Ledgers.TryGetValue(collection, out var l)) Ledgers[collection] = l = new(StringComparer.Ordinal);
        return l;
    }

    /// <summary>Сбросить знание о чужих файлах (сменили хранилище или пароль — перечитать всё).</summary>
    public void ForgetRemote()
    {
        Remote.Clear();
        Cache.Clear();
        PushedLedgerHash = "";
        PushedSoftHash = "";
    }

    public string ToJson()
    {
        var remote = new JsonObject();
        foreach (var (id, r) in Remote.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            remote[id] = new JsonObject
            {
                ["version"] = r.Version, ["name"] = r.Name, ["device"] = r.Device, ["deviceName"] = r.DeviceName,
                ["platform"] = r.Platform, ["updated"] = r.Updated, ["error"] = r.Error,
            };
        var last = new JsonObject();
        foreach (var (c, m) in LastLocal.OrderBy(kv => kv.Key, StringComparer.Ordinal))
        {
            var o = new JsonObject();
            foreach (var (k, v) in m.OrderBy(kv => kv.Key, StringComparer.Ordinal)) o[k] = v;
            last[c] = o;
        }
        var cache = new JsonObject();
        foreach (var (k, v) in Cache.OrderBy(kv => kv.Key, StringComparer.Ordinal)) cache[k] = v;
        return new JsonObject
        {
            ["v"] = 1,
            ["ledgers"] = SyncPayload.LedgersToJson(Ledgers),
            ["lastLocal"] = last,
            ["remote"] = remote,
            ["cache"] = cache,
            ["pushedLedgerHash"] = PushedLedgerHash, ["pushedSoftHash"] = PushedSoftHash,
            ["pushedAt"] = PushedAt, ["pushedSoftAt"] = PushedSoftAt,
            ["lastOk"] = LastOk, ["lastError"] = LastError,
        }.ToJsonString(SkillsFile.JsonIndented);
    }

    public static SyncState FromJson(string json)
    {
        var st = new SyncState();
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.TryGetProperty("ledgers", out var led)) SyncPayload.ReadLedgers(led, st.Ledgers);
        if (root.TryGetProperty("lastLocal", out var last) && last.ValueKind == JsonValueKind.Object)
            foreach (var c in last.EnumerateObject())
            {
                var m = new Dictionary<string, string>(StringComparer.Ordinal);
                if (c.Value.ValueKind == JsonValueKind.Object)
                    foreach (var kv in c.Value.EnumerateObject())
                        if (kv.Value.ValueKind == JsonValueKind.String) m[kv.Name] = kv.Value.GetString()!;
                st.LastLocal[c.Name] = m;
            }
        if (root.TryGetProperty("remote", out var rem) && rem.ValueKind == JsonValueKind.Object)
            foreach (var r in rem.EnumerateObject())
                st.Remote[r.Name] = new SyncRemoteInfo
                {
                    Version = Str(r.Value, "version"), Name = Str(r.Value, "name"), Device = Str(r.Value, "device"),
                    DeviceName = Str(r.Value, "deviceName"), Platform = Str(r.Value, "platform"),
                    Updated = Num(r.Value, "updated"), Error = Str(r.Value, "error"),
                };
        if (root.TryGetProperty("cache", out var cache) && cache.ValueKind == JsonValueKind.Object)
            foreach (var kv in cache.EnumerateObject())
                if (kv.Value.ValueKind == JsonValueKind.String) st.Cache[kv.Name] = kv.Value.GetString()!;
        st.PushedLedgerHash = Str(root, "pushedLedgerHash");
        st.PushedSoftHash = Str(root, "pushedSoftHash");
        st.PushedAt = Num(root, "pushedAt");
        st.PushedSoftAt = Num(root, "pushedSoftAt");
        st.LastOk = Num(root, "lastOk");
        st.LastError = Str(root, "lastError");
        return st;
    }

    internal static string Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    internal static long Num(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var x) ? x : 0;
}

/// <summary>Правила слияния реестров — чистые функции (самопроверка ниже, та же на маке).</summary>
public static class SyncMerge
{
    /// Удаления помним полгода: устройство, не включавшееся дольше, может вернуть удалённое.
    public const long TombstoneKeepMs = 180L * 24 * 3600 * 1000;
    /// Метка «давнего» — своё содержимое при первой синхронизации: удаление, сделанное где-то
    /// после начала синхронизации, важнее того, что просто лежало на устройстве.
    public const long Ancient = 1;

    /// <summary>Шаг 1: свои правки с прошлой синхронизации — в реестр. local — только коллекции
    /// этого устройства. Возвращает число правок.</summary>
    public static int NoteLocal(SyncState st, IReadOnlyDictionary<string, Dictionary<string, string>> local, long now)
    {
        int n = 0;
        foreach (var (c, cur) in local)
        {
            var led = st.LedgerOf(c);
            if (st.LastLocal.TryGetValue(c, out var last))
            {
                foreach (var (k, v) in cur)
                    if (!last.TryGetValue(k, out var lv) || lv != v) { Stamp(led, k, v, now); n++; }
                foreach (var k in last.Keys)
                    if (!cur.ContainsKey(k)) { Stamp(led, k, null, now); n++; }
            }
            // Своё, чего в реестре нет (первая синхронизация, потерянный реестр) — как давнее
            foreach (var (k, v) in cur)
                if (!led.ContainsKey(k)) { led[k] = new SyncEntry(v, Ancient); n++; }
        }
        return n;
    }

    /// Своя правка случилась после всего, что устройство уже видело, — метка не меньше.
    private static void Stamp(Dictionary<string, SyncEntry> led, string k, string? v, long now)
    {
        long t = now;
        if (led.TryGetValue(k, out var e) && e.T >= t) t = e.T + 1;
        led[k] = new SyncEntry(v, t);
    }

    /// <summary>Шаг 2: слить чужие реестры. Возвращает, сколько записей сменилось.</summary>
    public static int MergeRemote(SyncState st, IReadOnlyDictionary<string, Dictionary<string, SyncEntry>> remote)
    {
        int n = 0;
        foreach (var (c, items) in remote)
        {
            var led = st.LedgerOf(c);
            foreach (var (k, e) in items)
                if (!led.TryGetValue(k, out var cur) || SyncEntry.Beats(e, cur)) { led[k] = e; n++; }
        }
        return n;
    }

    /// <summary>Шаг 3: что поменять у себя, чтобы совпасть с реестром.</summary>
    public static List<SyncOp> Plan(SyncState st, IReadOnlyDictionary<string, Dictionary<string, string>> local)
    {
        var ops = new List<SyncOp>();
        foreach (var (c, cur) in local)
        {
            if (!st.Ledgers.TryGetValue(c, out var led)) continue;
            foreach (var (k, e) in led.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            {
                if (e.V is null) { if (cur.ContainsKey(k)) ops.Add(new SyncOp(c, k, null)); }
                else if (!cur.TryGetValue(k, out var v) || v != e.V) ops.Add(new SyncOp(c, k, e.V));
            }
        }
        return ops;
    }

    /// <summary>Шаг 4: запомнить своё состояние после применения (как оно есть на самом деле).</summary>
    public static void Remember(SyncState st, IReadOnlyDictionary<string, Dictionary<string, string>> local)
    {
        foreach (var (c, cur) in local) st.LastLocal[c] = new Dictionary<string, string>(cur, StringComparer.Ordinal);
    }

    /// <summary>Забыть давние удаления. Возвращает, сколько убрано.</summary>
    public static int Prune(SyncState st, long now)
    {
        int n = 0;
        foreach (var led in st.Ledgers.Values)
            foreach (var k in led.Where(kv => kv.Value.V is null && now - kv.Value.T > TombstoneKeepMs).Select(kv => kv.Key).ToList())
            {
                led.Remove(k);
                n++;
            }
        return n;
    }

    /// <summary>Отпечаток реестров (менялись ли с прошлой отправки).</summary>
    public static string LedgerHash(SyncState st) => Hash(SyncPayload.LedgersToJson(st.Ledgers).ToJsonString(SkillsFile.Json));

    public static string Hash(string s) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(s)));

    // ------------------------------------------------------------ самопроверка (та же на маке)

    /// <summary>Сценарии слияния: первая синхронизация, удаления, конфликт, часы впереди,
    /// неудавшееся применение, давние удаления, журнал, формат файла, шифр. (всего, не сошлось).</summary>
    public static (int Total, int Bad) Selftest(Action<string>? log = null)
    {
        int total = 0, bad = 0;
        void Check(bool ok, string what)
        {
            total++;
            if (!ok) { bad++; log?.Invoke($"  ✗ {what}"); }
        }
        Dictionary<string, Dictionary<string, string>> L(params (string c, string k, string v)[] xs)
        {
            var d = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
            foreach (var (c, k, v) in xs)
            {
                if (!d.TryGetValue(c, out var m)) d[c] = m = new(StringComparer.Ordinal);
                if (k.Length > 0) m[k] = v;
            }
            return d;
        }
        string Ops(List<SyncOp> ops) => string.Join(" ", ops.Select(o => $"{o.Collection}:{o.Key}={o.Value ?? "-"}"));
        const string W = SyncCollections.StopWords, R = SyncCollections.Learned;

        // 1. Первая синхронизация A: всё своё — давнее, менять нечего
        var a = new SyncState();
        var la = L((W, "a", "1"), (W, "b", "1"));
        NoteLocal(a, la, 1000);
        Check(a.Ledgers[W]["a"] == new SyncEntry("1", Ancient), "1: своё при первой синхронизации — давнее");
        Check(Plan(a, la).Count == 0, "1: менять нечего");
        Remember(a, la);

        // 2. Первая синхронизация B со своим {b, c}: получает a
        var b = new SyncState();
        var lb = L((W, "b", "1"), (W, "c", "1"));
        NoteLocal(b, lb, 1100);
        MergeRemote(b, a.Ledgers);
        Check(Ops(Plan(b, lb)) == "stopWords:a=1", $"2: B получает a ({Ops(Plan(b, lb))})");
        lb[W]["a"] = "1";
        Remember(b, lb);

        // 3. A удаляет b; B, получив, убирает b
        la[W].Remove("b");
        NoteLocal(a, la, 2000);
        Check(a.Ledgers[W]["b"] == new SyncEntry(null, 2000), "3: удаление с меткой");
        MergeRemote(b, a.Ledgers);
        Check(Ops(Plan(b, lb)) == "stopWords:b=-", $"3: B убирает b ({Ops(Plan(b, lb))})");
        lb[W].Remove("b");
        Remember(b, lb);
        MergeRemote(a, b.Ledgers);
        Check(Ops(Plan(a, la)) == "stopWords:c=1", $"3: A получает c ({Ops(Plan(a, la))})");

        // 4. Конфликт правил в одну миллисекунду: побеждает одно и то же на обоих
        var x = new SyncState();
        var y = new SyncState();
        x.LedgerOf(R)["ha"] = new SyncEntry("f", 5000);
        y.LedgerOf(R)["ha"] = new SyncEntry("s", 5000);
        MergeRemote(x, y.Ledgers);
        MergeRemote(y, x.Ledgers);
        Check(x.Ledgers[R]["ha"] == y.Ledgers[R]["ha"] && x.Ledgers[R]["ha"].V == "s", "4: ничья — одинаково на обоих");
        var z1 = new SyncState();
        z1.LedgerOf(W)["q"] = new SyncEntry(null, 7000);
        var z2 = new SyncState();
        z2.LedgerOf(W)["q"] = new SyncEntry("1", 7000);
        MergeRemote(z1, z2.Ledgers);
        Check(z1.Ledgers[W]["q"].V == "1", "4: ничья — наличие важнее удаления");

        // 5. Чужие часы впереди: своя правка всё равно новее увиденного
        var c5 = new SyncState();
        var l5 = L((R, "ok", "f"));
        NoteLocal(c5, l5, 1000);
        Remember(c5, l5);
        c5.LedgerOf(R)["ok"] = new SyncEntry("f", 9_000);   // пришло с устройства, у которого часы впереди
        l5[R]["ok"] = "s";
        NoteLocal(c5, l5, 2000);
        Check(c5.Ledgers[R]["ok"] == new SyncEntry("s", 9_001), "5: своя правка после увиденного");

        // 6. Применение не удалось — не превращается в удаление, повторяется
        var c6 = new SyncState();
        var l6 = L((W, "", ""));
        NoteLocal(c6, l6, 1000);
        c6.LedgerOf(W)["new"] = new SyncEntry("1", 1500);
        Check(Ops(Plan(c6, l6)) == "stopWords:new=1", "6: план — добавить");
        Remember(c6, l6);                                   // не применилось: new так и нет
        NoteLocal(c6, l6, 3000);
        Check(c6.Ledgers[W]["new"] == new SyncEntry("1", 1500), "6: неудача не стала удалением");
        Check(Ops(Plan(c6, l6)) == "stopWords:new=1", "6: повтор на следующем круге");

        // 7. Давние удаления забываются, наличие — нет
        var c7 = new SyncState();
        c7.LedgerOf(W)["old"] = new SyncEntry(null, 1000);
        c7.LedgerOf(W)["keep"] = new SyncEntry("1", 1000);
        c7.LedgerOf(W)["fresh"] = new SyncEntry(null, TombstoneKeepMs);
        Check(Prune(c7, TombstoneKeepMs + 2000) == 1 && !c7.Ledgers[W].ContainsKey("old")
              && c7.Ledgers[W].ContainsKey("keep") && c7.Ledgers[W].ContainsKey("fresh"), "7: подрезка удалений");

        // 8. Журнал: строка → сколько раз; применение сохраняет порядок
        const string text = "a *b* # x\r\nc *d*\n\na *b* # x\n";
        var jc = SyncJournal.Counts(text);
        Check(jc.Count == 2 && jc["a *b* # x"] == "2" && jc["c *d*"] == "1", "8: подсчёт строк журнала");
        string j2 = SyncJournal.Apply(text, new[]
        {
            new SyncOp(SyncCollections.Journal, "a *b* # x", "1"),
            new SyncOp(SyncCollections.Journal, "e *f*", "2"),
            new SyncOp(SyncCollections.Journal, "c *d*", null),
        });
        Check(j2 == "a *b* # x\ne *f*\ne *f*\n", $"8: применение к журналу ({j2.Replace("\n", "⏎")})");

        // 9. Файл устройства: запись и чтение без потерь
        var st9 = new SyncState();
        st9.LedgerOf(R)["ёж"] = new SyncEntry("f", 123);
        st9.LedgerOf(W)["gone"] = new SyncEntry(null, 456);
        var appLang = new Dictionary<string, double[]> { ["chrome"] = new[] { 12.5, 3.0 } };
        var personal = new JsonObject { ["v"] = 1, ["self"] = "dev1", ["clearedAt"] = 0, ["tables"] = new JsonArray() };
        var doc = SyncPayload.Build(st9, "dev1", "Комп", "win", "test", appLang, personal, 777);
        var p = SyncPayload.Parse(Encoding.UTF8.GetBytes(doc.ToJsonString(SkillsFile.Json)));
        Check(p.Device == "dev1" && p.Name == "Комп" && p.Platform == "win" && p.Updated == 777, "9: шапка файла");
        Check(p.Ledgers[R]["ёж"] == new SyncEntry("f", 123) && p.Ledgers[W]["gone"] == new SyncEntry(null, 456), "9: реестры");
        Check(p.AppLang.TryGetValue("chrome", out var al) && al[0] == 12.5 && al[1] == 3.0, "9: ожидание языка");
        Check(p.Personal is { } pe && pe.GetProperty("self").GetString() == "dev1", "9: личный слой");

        // 10. Шифр: свой ключ кэшируется, чужой пароль не подходит
        byte[] blob = SkillsFile.Seal(Encoding.UTF8.GetBytes("{\"format\":\"qswitcher-sync\"}"), "пароль", stableSalt: true);
        byte[] blob2 = SkillsFile.Seal(Encoding.UTF8.GetBytes("{\"format\":\"qswitcher-sync\"}"), "пароль", stableSalt: true);
        Check(blob.AsSpan(4, 16).SequenceEqual(blob2.AsSpan(4, 16)) && !blob.AsSpan(24, 12).SequenceEqual(blob2.AsSpan(24, 12)),
              "10: соль своего файла постоянна, nonce — новый");
        Check(Encoding.UTF8.GetString(SkillsFile.Open(blob, "пароль")) == "{\"format\":\"qswitcher-sync\"}", "10: расшифровка");
        bool wrong = false;
        try { SkillsFile.Open(blob, "другой"); } catch (SkillsFile.WrongPasswordException) { wrong = true; }
        Check(wrong, "10: чужой пароль");
        // Образец с мака/винды: один и тот же файл обязан открываться на обеих (см. SyncModel.swift)
        try
        {
            var sample = SyncPayload.Parse(SkillsFile.Open(Convert.FromBase64String(SampleBlob), SamplePassword));
            Check(sample.Device == "sample-device" && sample.Name == "Образец" && sample.Platform == "mac"
                  && sample.Ledgers[R]["рф"] == new SyncEntry("s", 1727700000000)
                  && sample.Ledgers[W]["удалено"] == new SyncEntry(null, 1727700000001)
                  && sample.Ledgers[W]["ssh"] == new SyncEntry("1", 1)
                  && sample.AppLang.TryGetValue("com.apple.Safari", out var sl) && sl[0] == 1.5 && sl[1] == 2
                  && sample.Personal is { } sp && sp.GetProperty("tables")[0].GetProperty("uni").GetProperty("ru")
                                                    .GetProperty("привет").GetDouble() == 2, "10: образец файла");
        }
        catch (Exception e) { Check(false, $"10: образец файла ({e.Message})"); }

        return (total, bad);
    }

    /// Образец файла синхронизации (пароль ниже): проверяет, что формат и шифр совпадают
    /// на маке и винде. Сделан один раз, в обеих самопроверках — одна и та же строка.
    public const string SamplePassword = "qswitcher-test";
    public const string SampleBlob =
        "UVNYMV85mZgrUadIhOL8cGMdJwDAJwkA5jPXddGBSpKJwuRkFrb53R0xznwKMRD2LkCN6vZgLtfd6v3M4ofkrV8oI0Qg9uVFJPGM" +
        "iax1MrWiw+OojfHCXKCPqucj+Uu3nqUsZGmffgA4g0lwQv/+wNgzwOqvvspZEUrIOKZJ9DkIK9+c+Y8QkFjH3LQ4nJI7mlueOnTQ" +
        "MCkB6jHZMNbiUo4nFpR44r1OKJATk7kvKdFr+R7LO1u4stlb+WD1L/9tCfOYd9+SYL4nYhj5w/F4N1AHPFGTAbTvUqK0EG7jxMLe" +
        "NqWL8eamAqAS+fQeFYrn/1+zWRLra5TFghm6VLsCQuTK25yOiOgBdVUzs2J4LaYfJT94k02FT1fPtNbmATzqrWbkGN703s5gHyPR" +
        "+qF89cGkGYkEJ6yW4NvX5hVdKqeXpHlk6K3bErglyVGAKpEDpZfep4Jf54YcuR99T6ToSAr8EqAruan+W2OJSwjy3OQtH5x0";
}

/// <summary>Файл устройства: сборка и разбор.</summary>
public sealed class SyncPayload
{
    public const string Format = "qswitcher-sync";

    public string Device = "", Name = "", Platform = "", App = "";
    public long Updated;
    public readonly Dictionary<string, Dictionary<string, SyncEntry>> Ledgers = new(StringComparer.Ordinal);
    /// Ожидание языка платформы отправителя.
    public readonly Dictionary<string, double[]> AppLang = new(StringComparer.Ordinal);
    /// Личный слой отправителя (формат PersonalLM: v, self, clearedAt, tables).
    public JsonElement? Personal;

    public static JsonObject LedgersToJson(Dictionary<string, Dictionary<string, SyncEntry>> ledgers)
    {
        var o = new JsonObject();
        foreach (var (c, items) in ledgers.OrderBy(kv => kv.Key, StringComparer.Ordinal))
        {
            var m = new JsonObject();
            foreach (var (k, e) in items.OrderBy(kv => kv.Key, StringComparer.Ordinal))
                m[k] = new JsonArray(e.V is null ? null : JsonValue.Create(e.V), JsonValue.Create(e.T));
            o[c] = m;
        }
        return o;
    }

    public static void ReadLedgers(JsonElement e, Dictionary<string, Dictionary<string, SyncEntry>> into)
    {
        if (e.ValueKind != JsonValueKind.Object) return;
        foreach (var c in e.EnumerateObject())
        {
            if (c.Value.ValueKind != JsonValueKind.Object) continue;
            if (!into.TryGetValue(c.Name, out var m)) into[c.Name] = m = new(StringComparer.Ordinal);
            foreach (var kv in c.Value.EnumerateObject())
            {
                var a = kv.Value;
                if (a.ValueKind != JsonValueKind.Array || a.GetArrayLength() != 2) continue;
                var v = a[0];
                var t = a[1];
                if (t.ValueKind != JsonValueKind.Number || !t.TryGetInt64(out long ts)) continue;
                if (v.ValueKind == JsonValueKind.String) m[kv.Name] = new SyncEntry(v.GetString(), ts);
                else if (v.ValueKind == JsonValueKind.Null) m[kv.Name] = new SyncEntry(null, ts);
            }
        }
    }

    /// <summary>Собрать файл устройства. personal — своя таблица (PersonalLM.SnapshotLocal) или null.</summary>
    public static JsonObject Build(SyncState st, string device, string name, string platform, string app,
                                   IReadOnlyDictionary<string, double[]> appLang, JsonNode? personal, long now)
    {
        var lang = new JsonObject();
        foreach (var (k, v) in appLang.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            if (v is { Length: 2 }) lang[k] = new JsonArray(Math.Round(v[0], 2), Math.Round(v[1], 2));
        var doc = new JsonObject
        {
            ["format"] = Format,
            ["v"] = 1,
            ["device"] = device,
            ["name"] = name,
            ["platform"] = platform,
            ["app"] = app,
            ["updated"] = now,
            ["ledgers"] = LedgersToJson(st.Ledgers),
            ["appLang"] = new JsonObject { [platform] = lang },
        };
        if (personal is not null) doc["personal"] = personal;
        return doc;
    }

    /// <summary>Отпечаток «мягкой» части — ожидания языка (меняется с каждым словом, поэтому
    /// отправляется не чаще раза в несколько минут).</summary>
    public static string SoftHash(IReadOnlyDictionary<string, double[]> appLang)
    {
        var sb = new StringBuilder();
        foreach (var (k, v) in appLang.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            if (v is { Length: 2 })
                sb.Append(k).Append('=').Append(Math.Round(v[0], 2).ToString(System.Globalization.CultureInfo.InvariantCulture))
                  .Append(',').Append(Math.Round(v[1], 2).ToString(System.Globalization.CultureInfo.InvariantCulture)).Append(';');
        return SyncMerge.Hash(sb.ToString());
    }

    /// <summary>Разобрать расшифрованный файл (JSON в UTF-8).</summary>
    public static SyncPayload Parse(byte[] json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (SyncState.Str(root, "format") != Format) throw new InvalidDataException("это не файл синхронизации QSwitcher");
        var p = new SyncPayload
        {
            Device = SyncState.Str(root, "device"),
            Name = SyncState.Str(root, "name"),
            Platform = SyncState.Str(root, "platform"),
            App = SyncState.Str(root, "app"),
            Updated = SyncState.Num(root, "updated"),
        };
        if (root.TryGetProperty("ledgers", out var led)) ReadLedgers(led, p.Ledgers);
        if (root.TryGetProperty("appLang", out var al) && al.ValueKind == JsonValueKind.Object
            && al.TryGetProperty(p.Platform, out var mine) && mine.ValueKind == JsonValueKind.Object)
            foreach (var kv in mine.EnumerateObject())
                if (kv.Value.ValueKind == JsonValueKind.Array && kv.Value.GetArrayLength() == 2
                    && kv.Value[0].ValueKind == JsonValueKind.Number && kv.Value[1].ValueKind == JsonValueKind.Number)
                    p.AppLang[kv.Name] = new[] { kv.Value[0].GetDouble(), kv.Value[1].GetDouble() };
        if (root.TryGetProperty("personal", out var pers) && pers.ValueKind == JsonValueKind.Object)
            p.Personal = pers.Clone();
        return p;
    }
}

/// <summary>Журнал профиля как коллекция: строка → сколько раз она в журнале.</summary>
public static class SyncJournal
{
    private static IEnumerable<string> Lines(string text) =>
        text.Split('\n').Select(l => l.TrimEnd('\r')).Where(l => l.Trim().Length > 0);

    public static Dictionary<string, string> Counts(string text)
    {
        var n = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var l in Lines(text)) n[l] = (n.TryGetValue(l, out var c) ? c : 0) + 1;
        return n.ToDictionary(kv => kv.Key, kv => kv.Value.ToString(System.Globalization.CultureInfo.InvariantCulture),
                              StringComparer.Ordinal);
    }

    /// <summary>Применить к тексту журнала: число повторов строки — как в реестре. Порядок
    /// своих строк сохраняется, лишние повторы убираются с конца, новые — дописываются.</summary>
    public static string Apply(string text, IEnumerable<SyncOp> ops)
    {
        var want = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var op in ops)
            want[op.Key] = op.Value is null ? 0
                : int.TryParse(op.Value, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var k)
                    ? Math.Max(0, k) : 1;
        var lines = Lines(text).ToList();
        var have = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var l in lines) have[l] = (have.TryGetValue(l, out var c) ? c : 0) + 1;
        // Лишние повторы — с конца
        for (int i = lines.Count - 1; i >= 0; i--)
        {
            string l = lines[i];
            if (want.TryGetValue(l, out int w) && have[l] > w)
            {
                lines.RemoveAt(i);
                have[l]--;
            }
        }
        foreach (var (l, w) in want)
        {
            int h = have.TryGetValue(l, out var c) ? c : 0;
            for (; h < w; h++) lines.Add(l);
        }
        return lines.Count == 0 ? "" : string.Join("\n", lines) + "\n";
    }
}
