using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace QSwitcher.Core;

/// <summary>Режим личного слоя.</summary>
public enum PersonalMode
{
    /// Выключен: ядро решает без него, в слой ничего не пишется.
    Off,
    /// Обучение: только наблюдает и копит, в решениях не участвует.
    Learn,
    /// Работа + обучение: участвует в решениях и продолжает учиться.
    On,
    /// Только работа: участвует в решениях, ничего нового не запоминает.
    Frozen,
}

/// <summary>Таблица одного устройства. Каждое устройство пишет только свою — слияние
/// при импорте и синхронизации без двойного счёта: чужие таблицы заменяются целиком
/// более свежими копиями, в решениях участвует сумма.</summary>
public sealed class PersonalTable
{
    public string Device = "", Name = "", Platform = "";
    /// Когда таблица менялась последний раз (мс Unix).
    public long Updated;
    /// [0] — ru, [1] — en.
    public readonly Dictionary<string, double>[] Uni = { new(), new() };
    public readonly Dictionary<string, double>[] Bi = { new(), new() };
    public readonly Dictionary<string, Dictionary<string, double>>[] Typo = { new(), new() };
    /// Счётчики событий для меню: принятые слова, исправления, опечатки.
    public double Words, Corrections, Typos;

    public bool IsEmpty => Uni[0].Count + Uni[1].Count + Bi[0].Count + Bi[1].Count + Typo[0].Count + Typo[1].Count == 0;
}

/// <summary>
/// Личный слой ядра 5: что человек оставляет на экране — слова, пары соседей (и через смену
/// языка: «сервер HA»), свои опечатки. Эталон — Personal в nn/lm/model.py (самопроверка
/// сверяет стоимости). Веса: принятое слово +1, исправление +3 (тоггл назад, ручной свап,
/// стёр и набрал в другой раскладке). Доводом слово становится с веса 2: одно исправление —
/// сразу, одно случайное слово — нет.
///
/// Наблюдение отложенное: слово засчитывается на следующей границе, если его не тронули;
/// ручная правка заменяет его исправленным. Пароли, исключённые приложения и формулы
/// сюда не попадают (решает вызывающий).
/// </summary>
public sealed class PersonalLM
{
    public const double Min = 2.0;
    public const double Smooth = 50.0;
    public const double PairSmooth = 5.0;
    public static readonly double TypoCost = Math.Log(2);
    public const double WeightAccepted = 1.0;
    public const double WeightCorrection = 3.0;

    // Потолки: год набора — десятки тысяч слов; сверх — отрезаем самые редкие
    private const int MaxUni = 150_000, MaxBi = 400_000, MaxTypo = 20_000;

    private readonly object _lock = new();
    private readonly Dictionary<string, PersonalTable> _tables = new();
    // Сумма по устройствам — то, что видит ядро
    private readonly Dictionary<string, double>[] _uni = { new(), new() };
    private readonly Dictionary<string, double>[] _bi = { new(), new() };
    private readonly Dictionary<string, Dictionary<string, double>>[] _typo = { new(), new() };
    private readonly double[] _n = new double[2];

    /// Это устройство (его таблица — единственная, куда пишем).
    public PersonalTable Local { get; private set; }
    /// Очищено всё — более старые таблицы при слиянии не принимаются.
    public long ClearedAt { get; private set; }
    /// Режим (из конфига, читается на каждое действие).
    public Func<PersonalMode> ModeSource { get; set; } = () => PersonalMode.On;
    public PersonalMode Mode => ModeSource();
    public bool Uses => Mode is PersonalMode.On or PersonalMode.Frozen;
    public bool Learns => Mode is PersonalMode.Learn or PersonalMode.On;
    /// Для «стёр и набрал в другой раскладке»: свап по настоящей раскладке.
    public Func<string, string> Swap { get; set; } = s => s;
    /// Сколько изменений с последнего сохранения.
    public int Dirty { get; private set; }
    /// Сколько раз за запуск менялась своя таблица (или слой очищали) — по нему синхронизация
    /// решает, отправлять ли слой.
    public long LocalVersion => Interlocked.Read(ref _localVersion);
    private long _localVersion;

    public PersonalLM(string device, string name, string platform)
    {
        Local = new PersonalTable { Device = device, Name = name, Platform = platform };
        _tables[device] = Local;
    }

    private static int Li(string lang) => lang == "ru" ? 0 : 1;

    // ------------------------------------------------------------ запросы ядра

    /// <summary>−ln P_личн(слово) или null (вес меньше Min).</summary>
    public double? Cost(string lang, string w)
    {
        if (lang != "ru" && lang != "en") return null;
        lock (_lock)
        {
            int i = Li(lang);
            if (!_uni[i].TryGetValue(w.ToLowerInvariant(), out var v) || v < Min) return null;
            return -Math.Log(v / (_n[i] + Smooth));
        }
    }

    /// <summary>−ln P_личн(слово | предыдущее) — предыдущее любого языка, или null.</summary>
    public double? Pair(string lang, string prev, string w)
    {
        if (lang != "ru" && lang != "en") return null;
        lock (_lock)
        {
            string p = prev.ToLowerInvariant();
            if (!_bi[Li(lang)].TryGetValue(p + "\u001f" + w.ToLowerInvariant(), out var v) || v < Min) return null;
            string pl = Core5.LangOf(p);
            if (pl.Length == 0) pl = lang;
            double c = _uni[Li(pl)].TryGetValue(p, out var cp) ? cp : 0.0;
            return -Math.Log(v / (c + PairSmooth));
        }
    }

    /// <summary>Во что человек обычно исправляет это написание: самое частое, при равенстве —
    /// первое по кодам символов; null — если вес меньше Min.</summary>
    public string? TypoOf(string lang, string w)
    {
        if (lang != "ru" && lang != "en") return null;
        lock (_lock)
        {
            if (!_typo[Li(lang)].TryGetValue(w.ToLowerInvariant(), out var t) || t.Count == 0) return null;
            string? best = null;
            double bv = 0;
            foreach (var (r, v) in t)
                if (best is null || v > bv || (v == bv && string.CompareOrdinal(r, best) < 0)) { best = r; bv = v; }
            return bv >= Min ? best : null;
        }
    }

    // ------------------------------------------------------------ наполнение

    private void AddLocal(string lang, string w, double k, string? prev)
    {
        int i = Li(lang);
        Inc(Local.Uni[i], w, k); Inc(_uni[i], w, k); _n[i] += k;
        if (!string.IsNullOrEmpty(prev))
        {
            string key = prev + "\u001f" + w;
            Inc(Local.Bi[i], key, k); Inc(_bi[i], key, k);
        }
        Touch();
    }

    private void AddTypoLocal(string lang, string wrong, string right, double k)
    {
        int i = Li(lang);
        if (!Local.Typo[i].TryGetValue(wrong, out var t)) Local.Typo[i][wrong] = t = new();
        Inc(t, right, k);
        if (!_typo[i].TryGetValue(wrong, out var m)) _typo[i][wrong] = m = new();
        Inc(m, right, k);
        Local.Typos += 1;
        Touch();
    }

    private static void Inc(Dictionary<string, double> d, string k, double v) =>
        d[k] = (d.TryGetValue(k, out var c) ? c : 0.0) + v;

    private void Touch()
    {
        Local.Updated = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        Dirty++;
        Interlocked.Increment(ref _localVersion);
    }

    /// <summary>Добавить напрямую (импорт текста, тесты): слово и пара с предыдущим.</summary>
    public void Add(string lang, string w, double k = 1.0, string? prev = null)
    {
        if (lang != "ru" && lang != "en") return;
        lock (_lock) AddLocal(lang, w.ToLowerInvariant(), k, prev?.ToLowerInvariant());
    }

    public void AddTypo(string lang, string wrong, string right, double k = 1.0)
    {
        if (lang != "ru" && lang != "en") return;
        lock (_lock) AddTypoLocal(lang, wrong.ToLowerInvariant(), right.ToLowerInvariant(), k);
    }

    // ------------------------------------------------------------ наблюдение за вводом

    private (string Word, string Lang, string? Prev, double W)? _pending;
    private string? _erased;
    private bool _boostNext;

    /// <summary>Ядро слова для слоя: язык по буквам, края без знаков, нижний регистр;
    /// только буквы своего языка (и дефис/апостроф внутри), 2…32 буквы. Иначе null.</summary>
    public static (string Core, string Lang)? CoreOf(string shown)
    {
        string lang = Core5.LangOf(shown);
        if (lang.Length == 0) return null;
        string core = Core5.SplitPunct(shown, lang).Core.ToLowerInvariant();
        int n = Core5.Letters(core, lang);
        if (n < 2 || n > 32) return null;
        foreach (char c in core)
            if (c != '-' && c != '\'' && Core5.Letters(c.ToString(), lang) == 0) return null;
        return (core, lang);
    }

    private void CommitPending()
    {
        if (_pending is not { } p) return;
        _pending = null;
        AddLocal(p.Lang, p.Word, p.W, p.Prev);
        if (p.W >= WeightCorrection) Local.Corrections += 1;
        else Local.Words += 1;
    }

    /// <summary>Граница слова: на экране осталось shown. prevShown — предыдущее слово на экране,
    /// adjacent — стоят вплотную через пробел (для пары).</summary>
    public void Observe(string shown, string? prevShown, bool adjacent)
    {
        if (!Learns) { lock (_lock) { _pending = null; _erased = null; _boostNext = false; } return; }
        lock (_lock)
        {
            CommitPending();
            var c = CoreOf(shown);
            if (c is null) { _erased = null; _boostNext = false; return; }
            double w = WeightAccepted;
            if (_boostNext) w = WeightCorrection;
            if (_erased is not null)
            {
                if (string.Equals(Swap(_erased).ToLowerInvariant(), c.Value.Core, StringComparison.Ordinal))
                    w = WeightCorrection;          // стёр и набрал то же в другой раскладке
                _erased = null;
            }
            _boostNext = false;
            string? prev = adjacent && prevShown is not null ? CoreOf(prevShown)?.Core : null;
            _pending = (c.Value.Core, c.Value.Lang, prev, w);
        }
    }

    /// <summary>Ядро исправило предыдущее слово задним числом — засчитываем исправленное.</summary>
    public void RetroChanged(string newShown)
    {
        lock (_lock)
        {
            if (_pending is not { } p) return;
            var c = CoreOf(newShown);
            _pending = c is null ? null : (c.Value.Core, c.Value.Lang, p.Prev, p.W);
        }
    }

    /// <summary>Человек поменял последнее слово (ручной свап, тоггл): засчитывается то, что
    /// теперь на экране, с весом исправления. Повторный тоггл перезаписывает.</summary>
    public void ManualFix(string to)
    {
        if (!Learns) return;
        var words = to.Split(new[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return;
        var c = CoreOf(words[^1]);
        lock (_lock)
        {
            _erased = null;
            if (c is null) { _pending = null; return; }
            if (_pending is { } p) _pending = (c.Value.Core, c.Value.Lang, p.Prev, WeightCorrection);
            else _pending = (c.Value.Core, c.Value.Lang, null, WeightCorrection);
        }
    }

    /// <summary>Человек свапнул недонабранное слово — оно на экране уже исправленным,
    /// границы для него не будет.</summary>
    public void ManualWord(string to)
    {
        if (!Learns) return;
        lock (_lock)
        {
            CommitPending();
            _erased = null;
            var c = CoreOf(to);
            _pending = c is null ? null : (c.Value.Core, c.Value.Lang, null, WeightCorrection);
        }
    }

    /// <summary>Стирают назад за границу слова: предыдущее больше не довод.</summary>
    public void DropPending()
    {
        lock (_lock) _pending = null;
    }

    /// <summary>Предыдущее слово стёрто целиком: если следующее — оно же в другой раскладке,
    /// это исправление пропущенного свапа.</summary>
    public void Erased(string word)
    {
        lock (_lock) { _pending = null; _erased = word; }
    }

    /// <summary>Внутри слова правили (стёрли часть и набрали): attempt — каким было до первой
    /// правки, final — каким ушло. Та же раскладка и 1–2 правки — личная опечатка; то же слово
    /// в другой раскладке — пропущенный свап (следующее Observe — с весом исправления).</summary>
    public void InWordEdit(string attempt, string final)
    {
        if (!Learns) return;
        var a = CoreOf(attempt);
        var f = CoreOf(final);
        if (a is null || f is null) return;
        lock (_lock)
        {
            if (a.Value.Lang != f.Value.Lang)
            {
                if (string.Equals(Swap(a.Value.Core).ToLowerInvariant(), f.Value.Core, StringComparison.Ordinal))
                    _boostNext = true;
                return;
            }
            string wa = a.Value.Core, wf = f.Value.Core;
            if (wa == wf || wa.Length < 3 || wf.Length < 3) return;
            if (wa.Length < wf.Length || wa.Length > wf.Length + 1) return;   // оборванное — не опечатка
            if (Distance(wa, wf) > 2) return;
            AddTypoLocal(a.Value.Lang, wa, wf, 1.0);
        }
    }

    /// <summary>Конец сеанса ввода (клик, другое окно): отложенное засчитывается.</summary>
    public void Flush()
    {
        lock (_lock) { CommitPending(); _erased = null; _boostNext = false; }
    }

    /// Расстояние Дамерау–Левенштейна (с перестановкой соседних).
    private static int Distance(string a, string b)
    {
        var d = new int[a.Length + 1, b.Length + 1];
        for (int i = 0; i <= a.Length; i++) d[i, 0] = i;
        for (int j = 0; j <= b.Length; j++) d[0, j] = j;
        for (int i = 1; i <= a.Length; i++)
            for (int j = 1; j <= b.Length; j++)
            {
                int cost = a[i - 1] == b[j - 1] ? 0 : 1;
                int v = Math.Min(Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1), d[i - 1, j - 1] + cost);
                if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) v = Math.Min(v, d[i - 2, j - 2] + 1);
                d[i, j] = v;
            }
        return d[a.Length, b.Length];
    }

    // ------------------------------------------------------------ сводка

    public sealed record Summary(int WordsRu, int WordsEn, int Pairs, int TypoForms, double Accepted,
                                 double Corrections, double Typos, int Devices);

    public Summary Stats()
    {
        lock (_lock)
        {
            double acc = 0, cor = 0, typ = 0;
            foreach (var t in _tables.Values) { acc += t.Words; cor += t.Corrections; typ += t.Typos; }
            return new Summary(_uni[0].Count, _uni[1].Count, _bi[0].Count + _bi[1].Count,
                               _typo[0].Count + _typo[1].Count, acc, cor, typ, _tables.Count);
        }
    }

    // ------------------------------------------------------------ хранение и слияние

    private static JsonObject TableToJson(PersonalTable t)
    {
        JsonObject Map(Dictionary<string, double>[] m)
        {
            var o = new JsonObject();
            for (int i = 0; i < 2; i++)
            {
                var x = new JsonObject();
                foreach (var (k, v) in m[i].OrderBy(kv => kv.Key, StringComparer.Ordinal)) x[k] = v;
                o[i == 0 ? "ru" : "en"] = x;
            }
            return o;
        }
        var typo = new JsonObject();
        for (int i = 0; i < 2; i++)
        {
            var x = new JsonObject();
            foreach (var (k, rights) in t.Typo[i].OrderBy(kv => kv.Key, StringComparer.Ordinal))
            {
                var r = new JsonObject();
                foreach (var (rk, rv) in rights.OrderBy(kv => kv.Key, StringComparer.Ordinal)) r[rk] = rv;
                x[k] = r;
            }
            typo[i == 0 ? "ru" : "en"] = x;
        }
        return new JsonObject
        {
            ["device"] = t.Device, ["name"] = t.Name, ["platform"] = t.Platform, ["updated"] = t.Updated,
            ["stats"] = new JsonObject { ["words"] = t.Words, ["corrections"] = t.Corrections, ["typos"] = t.Typos },
            ["uni"] = Map(t.Uni), ["bi"] = Map(t.Bi), ["typo"] = typo,
        };
    }

    private static PersonalTable TableFromJson(JsonElement e, string? deviceOverride = null)
    {
        var t = new PersonalTable
        {
            Device = deviceOverride ?? (e.TryGetProperty("device", out var d) ? d.GetString() ?? "" : ""),
            Name = e.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "",
            Platform = e.TryGetProperty("platform", out var p) ? p.GetString() ?? "" : "",
            Updated = e.TryGetProperty("updated", out var u) && u.ValueKind == JsonValueKind.Number ? u.GetInt64() : 0,
        };
        if (e.TryGetProperty("stats", out var st))
        {
            t.Words = st.TryGetProperty("words", out var w) ? w.GetDouble() : 0;
            t.Corrections = st.TryGetProperty("corrections", out var c) ? c.GetDouble() : 0;
            t.Typos = st.TryGetProperty("typos", out var y) ? y.GetDouble() : 0;
        }
        void Read(string name, Dictionary<string, double>[] m)
        {
            if (!e.TryGetProperty(name, out var o) || o.ValueKind != JsonValueKind.Object) return;
            for (int i = 0; i < 2; i++)
                if (o.TryGetProperty(i == 0 ? "ru" : "en", out var x) && x.ValueKind == JsonValueKind.Object)
                    foreach (var kv in x.EnumerateObject())
                        if (kv.Value.ValueKind == JsonValueKind.Number) m[i][kv.Name] = kv.Value.GetDouble();
        }
        Read("uni", t.Uni);
        Read("bi", t.Bi);
        if (e.TryGetProperty("typo", out var ty) && ty.ValueKind == JsonValueKind.Object)
            for (int i = 0; i < 2; i++)
                if (ty.TryGetProperty(i == 0 ? "ru" : "en", out var x) && x.ValueKind == JsonValueKind.Object)
                    foreach (var kv in x.EnumerateObject())
                    {
                        if (kv.Value.ValueKind != JsonValueKind.Object) continue;
                        var r = new Dictionary<string, double>();
                        foreach (var rv in kv.Value.EnumerateObject())
                            if (rv.Value.ValueKind == JsonValueKind.Number) r[rv.Name] = rv.Value.GetDouble();
                        if (r.Count > 0) t.Typo[i][kv.Name] = r;
                    }
        return t;
    }

    /// <summary>Весь слой (все устройства) — для файла на диске и для экспорта.</summary>
    public JsonObject ToJson()
    {
        lock (_lock)
        {
            var arr = new JsonArray();
            foreach (var t in _tables.Values.OrderBy(t => t.Device == Local.Device ? 0 : 1).ThenBy(t => t.Device, StringComparer.Ordinal))
                arr.Add(TableToJson(t));
            return new JsonObject { ["v"] = 1, ["self"] = Local.Device, ["clearedAt"] = ClearedAt, ["tables"] = arr };
        }
    }

    /// <summary>Загрузить свой файл (при запуске). Своё устройство — из "self".</summary>
    public static PersonalLM FromJson(string json, string defaultDevice, string name, string platform)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        string self = root.TryGetProperty("self", out var s) && s.GetString() is { Length: > 0 } sv ? sv : defaultDevice;
        var lm = new PersonalLM(self, name, platform);
        lm.ClearedAt = root.TryGetProperty("clearedAt", out var c) && c.ValueKind == JsonValueKind.Number ? c.GetInt64() : 0;
        if (root.TryGetProperty("tables", out var tables))
            foreach (var te in tables.EnumerateArray())
            {
                var t = TableFromJson(te);
                if (t.Device.Length == 0) continue;
                if (t.Device == self)
                {
                    t.Name = name; t.Platform = platform;
                    lm.Local = t;
                }
                lm._tables[t.Device] = t;
            }
        lm._tables[lm.Local.Device] = lm.Local;
        lm.Rebuild();
        lm.Dirty = 0;
        return lm;
    }

    /// <summary>Самопроверка: таблица эталона (формат Personal.to_json) как единственная.</summary>
    public static PersonalLM FromReference(JsonElement personal)
    {
        var lm = new PersonalLM("selftest", "selftest", "test");
        var t = TableFromJson(personal, "selftest");
        lm.Local = t;
        lm._tables.Clear();
        lm._tables[t.Device] = t;
        lm.Rebuild();
        return lm;
    }

    /// <summary>Слить слой из файла (импорт, синхронизация): чужие устройства — более свежая
    /// копия целиком, своё — не трогаем. Возвращает, сколько таблиц принято.</summary>
    public int Merge(JsonElement personal)
    {
        int taken = 0;
        lock (_lock)
        {
            long cleared = personal.TryGetProperty("clearedAt", out var c) && c.ValueKind == JsonValueKind.Number ? c.GetInt64() : 0;
            if (cleared > ClearedAt)
            {
                // На другом устройстве всё очистили позже — очищаем и здесь
                ClearedAt = cleared;
                foreach (var key in _tables.Keys.ToList())
                    if (_tables[key].Updated < cleared)
                    {
                        if (key == Local.Device) ResetLocal();
                        else _tables.Remove(key);
                    }
            }
            if (personal.TryGetProperty("tables", out var tables))
                foreach (var te in tables.EnumerateArray())
                {
                    var t = TableFromJson(te);
                    if (t.Device.Length == 0 || t.Device == Local.Device || t.Updated < ClearedAt) continue;
                    if (_tables.TryGetValue(t.Device, out var old) && old.Updated >= t.Updated) continue;
                    _tables[t.Device] = t;
                    taken++;
                }
            Rebuild();
            Dirty++;
        }
        return taken;
    }

    private void ResetLocal()
    {
        var fresh = new PersonalTable { Device = Local.Device, Name = Local.Name, Platform = Local.Platform };
        _tables[Local.Device] = fresh;
        Local = fresh;
        Interlocked.Increment(ref _localVersion);
    }

    /// <summary>Очистить весь слой (все устройства). При синхронизации очистка расходится
    /// по меткe времени.</summary>
    public void Clear()
    {
        lock (_lock)
        {
            ClearedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            _tables.Clear();
            ResetLocal();
            _pending = null; _erased = null; _boostNext = false;
            Rebuild();
            Dirty++;
        }
    }

    /// <summary>Сумма по устройствам заново (после загрузки, слияния, обрезки).</summary>
    private void Rebuild()
    {
        for (int i = 0; i < 2; i++) { _uni[i].Clear(); _bi[i].Clear(); _typo[i].Clear(); _n[i] = 0; }
        foreach (var t in _tables.Values)
            for (int i = 0; i < 2; i++)
            {
                foreach (var (k, v) in t.Uni[i]) { Inc(_uni[i], k, v); _n[i] += v; }
                foreach (var (k, v) in t.Bi[i]) Inc(_bi[i], k, v);
                foreach (var (k, rights) in t.Typo[i])
                {
                    if (!_typo[i].TryGetValue(k, out var m)) _typo[i][k] = m = new();
                    foreach (var (rk, rv) in rights) Inc(m, rk, rv);
                }
            }
    }

    /// <summary>Снимок для записи на диск (в фоне). Заодно обрезает свою таблицу по потолкам.
    /// Под замком — только копия таблиц (миллисекунды: хук ждать не должен), JSON — вне его.</summary>
    public string Snapshot()
    {
        List<PersonalTable> copy;
        string self;
        long cleared;
        lock (_lock)
        {
            bool pruned = false;
            for (int i = 0; i < 2; i++)
            {
                pruned |= Prune(Local.Uni[i], MaxUni);
                pruned |= Prune(Local.Bi[i], MaxBi);
                if (Local.Typo[i].Count > MaxTypo)
                {
                    foreach (var k in Local.Typo[i].OrderBy(kv => kv.Value.Values.Sum()).Take(Local.Typo[i].Count - MaxTypo * 9 / 10)
                                                    .Select(kv => kv.Key).ToList())
                        Local.Typo[i].Remove(k);
                    pruned = true;
                }
            }
            if (pruned) Rebuild();
            Dirty = 0;
            self = Local.Device;
            cleared = ClearedAt;
            copy = _tables.Values.Select(Clone).ToList();
        }
        var arr = new JsonArray();
        foreach (var t in copy.OrderBy(t => t.Device == self ? 0 : 1).ThenBy(t => t.Device, StringComparer.Ordinal))
            arr.Add(TableToJson(t));
        return new JsonObject { ["v"] = 1, ["self"] = self, ["clearedAt"] = cleared, ["tables"] = arr }
            .ToJsonString(SkillsFile.Json);
    }

    /// <summary>Только своя таблица (для файла синхронизации: каждое устройство отправляет своё,
    /// чужие таблицы другие устройства берут из файлов их хозяев). Без обрезки и без сброса Dirty —
    /// запись на диск идёт своим чередом.</summary>
    public JsonObject SnapshotLocal()
    {
        PersonalTable copy;
        long cleared;
        lock (_lock)
        {
            copy = Clone(Local);
            cleared = ClearedAt;
        }
        return new JsonObject
        {
            ["v"] = 1, ["self"] = copy.Device, ["clearedAt"] = cleared, ["tables"] = new JsonArray(TableToJson(copy)),
        };
    }

    private static PersonalTable Clone(PersonalTable t)
    {
        var c = new PersonalTable
        {
            Device = t.Device, Name = t.Name, Platform = t.Platform, Updated = t.Updated,
            Words = t.Words, Corrections = t.Corrections, Typos = t.Typos,
        };
        for (int i = 0; i < 2; i++)
        {
            foreach (var (k, v) in t.Uni[i]) c.Uni[i][k] = v;
            foreach (var (k, v) in t.Bi[i]) c.Bi[i][k] = v;
            foreach (var (k, r) in t.Typo[i]) c.Typo[i][k] = new Dictionary<string, double>(r);
        }
        return c;
    }

    private static bool Prune(Dictionary<string, double> d, int max)
    {
        if (d.Count <= max) return false;
        double th = 1;
        while (d.Count > max * 9 / 10)
        {
            foreach (var k in d.Where(kv => kv.Value <= th).Select(kv => kv.Key).ToList()) d.Remove(k);
            th *= 2;
        }
        return true;
    }
}
