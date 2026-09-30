using System.Text;
using System.Text.Json;

namespace QSwitcher.Core;

// Ядро решения QSwitcher 5 — одна формула вместо каскада слоёв. Порт Core5.swift;
// эталон и обучение — nn/lm/ (model.py, charlm.py), самопроверка — nn/lm/core5-selftest.json.
//
// На каждое слово — два прочтения одних и тех же клавиш: набранное (язык T) и другое (A).
// Для каждого языка — стоимость = −ln P (меньше — правдоподобнее):
//
//   P_L(слово) = (1−α−τ)·P_частоты + α·P_символы + τ·P_опечатка
//   + пара с предыдущим словом того же языка (если сосед уверенный)
//   + регистр: слово ЦЕЛИКОМ заглавными → −ln P(капсом | слово, L)
//   + переход: −ln(1−π) тот же язык, −ln π смена; без уверенного соседа — ожидание приложения
//   + раскладка: +b_K, если L — не текущая раскладка
//
//   LO = стоимость(T) − стоимость(A);   LO > θ и «другое прочтение — слово» → свап.
//
// Вето нет: всё, что знает ядро, — слагаемые одной суммы; решение раскладывается в лог.
// Короткое неуверенное слово откладывается и решается задним числом по следующему.

/// <summary>
/// Хэш-таблица форматов QSNG2/QSCL1: запись 3 байта (16-битный отпечаток LE + значение),
/// две корзины на ключ, хэши FNV-1a по байтам UTF-8 (как nn/ngram/build.py, nn/lm/charlm.py).
/// Таблица — окно в общем массиве файла, без копий.
/// </summary>
public readonly struct QSTable
{
    private readonly byte[]? _base;
    private readonly int _off;
    private readonly uint _mask;
    private readonly bool _empty;

    public QSTable(byte[] data, int offset, int count, int bits)
    {
        _base = data;
        _off = offset;
        _mask = (uint)((1L << bits) - 1);
        // Размер обязан быть (mask+1)·3 — иначе файл битый, таблицу не читаем
        _empty = count < ((long)_mask + 1) * 3 || (long)offset + count > data.Length;
    }

    private static uint Step(uint h, byte b) => unchecked((h ^ b) * 0x01000193u);

    /// <summary>Значение 0…255 или −1, если ключа нет.</summary>
    public int Get(ReadOnlySpan<byte> key)
    {
        if (_empty || _base is null) return -1;
        uint a = 0x811C9DC5u;
        uint b = Step(0x811C9DC5u, 0x03);
        uint f = Step(0x811C9DC5u, 0x01);
        foreach (byte x in key)
        {
            a = Step(a, x); b = Step(b, x); f = Step(f, x);
        }
        f = Step(f, 0x02);
        uint sa = a & _mask, sb = b & _mask;
        if (sb == sa) sb = (sa + 1) & _mask;
        ushort fp = (ushort)(f >> 16);
        if (fp == 0) fp = 1;
        int ia = _off + (int)sa * 3;
        if ((ushort)(_base[ia] | (_base[ia + 1] << 8)) == fp) return _base[ia + 2];
        int ib = _off + (int)sb * 3;
        if ((ushort)(_base[ib] | (_base[ib + 1] << 8)) == fp) return _base[ib + 2];
        return -1;
    }

    public int Get(string key)
    {
        int n = Encoding.UTF8.GetByteCount(key);
        Span<byte> buf = n <= 256 ? stackalloc byte[n] : new byte[n];
        Encoding.UTF8.GetBytes(key, buf);
        return Get(buf);
    }

    internal static byte[] ReadAll(Stream s)
    {
        if (s.CanSeek)
        {
            var buf = new byte[s.Length - s.Position];
            s.ReadExactly(buf);
            return buf;
        }
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        return ms.ToArray();
    }

    internal static int U32(byte[] all, ref int off)
    {
        int v = all[off] | (all[off + 1] << 8) | (all[off + 2] << 16) | (all[off + 3] << 24);
        off += 4;
        return v;
    }
}

// Частоты слов и пар — NgramLM.cs (UniD/BiD: в double, как эталон).

/// <summary>
/// Символьная модель языка (qschar.bin, QSCL1): «как выглядит слово этого языка» —
/// символьные n-граммы с метками «^» и «$», сглаживание Уиттена–Белла в форме с откатом.
/// Оценивает любую строку: опечатки, сленг, новые словоформы. Учится nn/lm/charlm.py.
/// </summary>
public sealed class CharLM
{
    public bool Loaded { get; private set; }
    public int Order { get; private set; } = 5;
    private double _scale = 20;
    private readonly Dictionary<string, QSTable> _ng = new(), _hist = new(), _caps = new();
    /// Кодовая точка алфавита языка → её байты UTF-8; чужой символ → «#».
    private readonly Dictionary<string, Dictionary<int, byte[]>> _charBytes = new();
    private double CapCost => 255.0 / _scale;
    private static readonly byte[] Caret = { 0x5E }, Dollar = { 0x24 }, Unk = { 0x23 };

    public static CharLM Load(Func<string, Stream?> open, Action<string>? log = null)
    {
        var m = new CharLM();
        try
        {
            using var s = open("qschar.bin");
            if (s is null)
            {
                log?.Invoke("🔤 Символьная модель: qschar.bin не найден — ядро 5 без неё");
                return m;
            }
            byte[] all = QSTable.ReadAll(s);
            m.Parse(all);
            m.Loaded = true;
            log?.Invoke($"🔤 Символьная модель: qschar.bin ({all.Length / 1e6:F1} МБ, порядок {m.Order})");
        }
        catch (Exception e)
        {
            log?.Invoke($"⚠️ Символьная модель: qschar.bin не читается: {e.Message}");
        }
        return m;
    }

    private void Parse(byte[] all)
    {
        if (all.Length < 9 || Encoding.ASCII.GetString(all, 0, 5) != "QSCL1")
            throw new InvalidDataException("не QSCL1");
        int off = 5;
        int hl = QSTable.U32(all, ref off);
        using var doc = JsonDocument.Parse(new ReadOnlyMemory<byte>(all, off, hl));
        off += hl;
        var root = doc.RootElement;
        Order = root.GetProperty("order").GetInt32();
        _scale = root.GetProperty("scale").GetDouble();
        var alpha = root.GetProperty("alpha");
        var tables = root.GetProperty("tables");
        foreach (var langEl in root.GetProperty("langs").EnumerateArray())
        {
            string lang = langEl.GetString() ?? "";
            var map = new Dictionary<int, byte[]>();
            if (alpha.TryGetProperty(lang, out var a))
                foreach (Rune r in (a.GetString() ?? "").EnumerateRunes())
                    map[r.Value] = Encoding.UTF8.GetBytes(r.ToString());
            _charBytes[lang] = map;
            foreach (var name in new[] { "ng", "hist", "caps" })
            {
                int n = QSTable.U32(all, ref off);
                if ((long)off + n > all.Length) throw new InvalidDataException("файл обрезан");
                int bits = tables.TryGetProperty($"{lang}.{name}", out var tp) ? tp.GetProperty("bits").GetInt32() : 10;
                var t = new QSTable(all, off, n, bits);
                off += n;
                if (name == "ng") _ng[lang] = t;
                else if (name == "hist") _hist[lang] = t;
                else _caps[lang] = t;
            }
        }
    }

    /// <summary>−ln P(слово) по символам, с концом слова.</summary>
    public double WordCost(string word, string lang)
    {
        if (!Loaded || !_ng.TryGetValue(lang, out var ng) || !_hist.TryGetValue(lang, out var hi)
            || !_charBytes.TryGetValue(lang, out var cb)) return 60;
        var cs = new List<byte[]>(word.Length + Order);
        for (int i = 0; i < Order - 1; i++) cs.Add(Caret);
        foreach (Rune r in word.ToLowerInvariant().EnumerateRunes())
            cs.Add(cb.TryGetValue(r.Value, out var bytes) ? bytes : Unk);
        cs.Add(Dollar);
        double total = 0;
        Span<byte> key = stackalloc byte[128];
        for (int i = Order - 1; i < cs.Count; i++)
        {
            double bo = 0;
            double? got = null;
            for (int k = Order - 1; k >= 0; k--)
            {
                int len = 0;
                for (int j = i - k; j < i; j++) { cs[j].CopyTo(key[len..]); len += cs[j].Length; }
                int hlen = len;
                cs[i].CopyTo(key[len..]); len += cs[i].Length;
                int v = ng.Get(key[..len]);
                if (v >= 0) { got = bo + v / _scale; break; }
                int l = hi.Get(key[..hlen]);
                if (l >= 0) bo += l / _scale;
            }
            total += got ?? (bo + CapCost);
        }
        return total;
    }

    /// <summary>Доля вхождений слова целиком заглавными (UI, IP, РФ) или null.</summary>
    public double? CapsP(string word, string lang)
    {
        if (!_caps.TryGetValue(lang, out var t)) return null;
        int v = t.Get(word.ToLowerInvariant());
        return v < 0 ? null : v / 255.0;
    }
}

/// <summary>
/// Какой язык человек обычно набирает в этом приложении (по тому, что осталось на
/// экране; счётчики с затуханием) — ожидание для первого слова ввода. Пока данных
/// мало — по классу приложения. В файле только имя процесса и два числа.
/// </summary>
public sealed class AppLangStats
{
    private readonly string _path;
    private readonly Func<string?, double> _classPrior;
    private readonly Dictionary<string, double[]> _counts = new();
    private readonly object _lock = new();
    private int _dirty;

    public AppLangStats(string path, Func<string?, double> classPrior)
    {
        _path = path;
        _classPrior = classPrior;
        try
        {
            if (File.Exists(path))
            {
                var d = JsonSerializer.Deserialize<Dictionary<string, double[]>>(File.ReadAllText(path));
                if (d is not null)
                    foreach (var (k, v) in d)
                        if (v is { Length: 2 }) _counts[k] = v;
            }
        }
        catch { }
    }

    /// <summary>Ожидание по классу приложения (терминал 0.15, код 0.2, браузер 0.6, чат 0.8, прочее 0.7).</summary>
    public static double ClassPrior(string className) => className switch
    {
        "terminal" => 0.15,
        "code" => 0.2,
        "browser" => 0.6,
        "chat" => 0.8,
        _ => 0.7,
    };

    /// <summary>P(русский | приложение): класс как псевдосчёт 20 слов + своя статистика.</summary>
    public double PriorRu(string? app)
    {
        double d = _classPrior(app);
        lock (_lock)
        {
            var c = _counts.TryGetValue(app ?? "?", out var v) ? v : new double[2];
            return (c[0] + 20 * d) / (c[0] + c[1] + 20);
        }
    }

    public void Note(string? app, string lang, double delta = 1)
    {
        if (lang != "ru" && lang != "en") return;
        Dictionary<string, double[]>? snapshot = null;
        lock (_lock)
        {
            string key = app ?? "?";
            if (!_counts.TryGetValue(key, out var c)) { c = new double[2]; _counts[key] = c; }
            int i = lang == "ru" ? 0 : 1;
            c[i] = Math.Max(0, c[i] + delta);
            if (c[0] + c[1] > 2000) { c[0] *= 0.5; c[1] *= 0.5; }   // затухание: старое весит меньше
            if (++_dirty >= 50)
            {
                _dirty = 0;
                snapshot = _counts.ToDictionary(kv => kv.Key, kv => (double[])kv.Value.Clone());
            }
        }
        if (snapshot is not null) Save(snapshot);
    }

    public void SaveNow()
    {
        Dictionary<string, double[]> snapshot;
        lock (_lock)
        {
            _dirty = 0;
            snapshot = _counts.ToDictionary(kv => kv.Key, kv => (double[])kv.Value.Clone());
        }
        Save(snapshot);
    }

    /// <summary>Копия счётчиков (экспорт навыков).</summary>
    public Dictionary<string, double[]> Counts()
    {
        lock (_lock) return _counts.ToDictionary(kv => kv.Key, kv => (double[])kv.Value.Clone());
    }

    /// <summary>Слить счётчики из файла навыков: по каждому приложению и языку — большее
    /// (повторный импорт того же файла ничего не удваивает). Возвращает, сколько приложений
    /// изменилось.</summary>
    public int MergeMax(IReadOnlyDictionary<string, double[]> other)
    {
        int changed = 0;
        lock (_lock)
        {
            foreach (var (app, v) in other)
            {
                if (v is not { Length: 2 }) continue;
                if (!_counts.TryGetValue(app, out var c)) { c = new double[2]; _counts[app] = c; }
                bool ch = false;
                for (int i = 0; i < 2; i++) if (v[i] > c[i]) { c[i] = v[i]; ch = true; }
                if (ch) changed++;
            }
        }
        if (changed > 0) SaveNow();
        return changed;
    }

    private void Save(Dictionary<string, double[]> snapshot)
    {
        // Запись в фоне: вызывают из потока хука, диск там недопустим
        ThreadPool.QueueUserWorkItem(_ =>
        {
            try
            {
                var tmp = _path + ".tmp";
                File.WriteAllText(tmp, JsonSerializer.Serialize(snapshot));
                File.Move(tmp, _path, overwrite: true);
            }
            catch { }
        });
    }
}

/// <summary>Ядро 5: решение по слову. Экземпляр живого ввода — один; прогоны берут свой.</summary>
public sealed class Core5
{
    public sealed class Params
    {
        public double Alpha = 0.03;        // доля новых/редких слов (символьная модель)
        public double Tau = 0.02;          // доля опечаток
        public double Gamma = 0.3;         // вес личных частот (личный слой)
        public double Beta = 0.5;          // вес пары с предыдущим словом
        public double Pi = 0.04;           // смена языка между соседними словами
        public double BK = 1.0;            // «язык не совпадает с раскладкой»
        public double Theta = 2.0;         // порог свапа
        public double ThetaDefer = -1.0;   // короткое слово выше этого LO ждёт правого соседа
        public double CapsP0 = 0.03;       // P(капсом) для слова вне таблицы регистра
        public double UShort = 13.0;       // короткое другое прочтение: частота не реже e^-13
        public double UShort2 = 16.0;      // …или не реже e^-16, но при уверенном LO
        public double LoStrong = 5.0;
        public double CRel = 4.5;          // набранное — явный мусор: новое хотя бы произносимо
        public double CJunk = 6.0;
        public double CMax = 3.2;          // неизвестное длинное: символьная стоимость на букву не выше
        public int TypoMin = 4;
        public int TypoMax = 32;
        public int Short = 3;
        public double Edge = 1.5;          // цена символа-«пунктуации» на краю прочтения
        public bool DeferShort = true;
    }

    /// <summary>Слово на экране — контекст для следующего.</summary>
    public sealed class Word
    {
        public string Typed = "", Alt = "", T = "", A = "", Shown = "", Lang = "";
        public double Lo;
        public bool Pending;
        public bool Confident = true;
    }

    public sealed class Parts
    {
        public double? WordC;
        public double Char;
        public double? Typo;
        public double? Pair;
        public double? PPair;              // личная пара с предыдущим словом
        public double? Caps;
        public override string ToString()
        {
            var s = new List<string>
            {
                "слово " + (WordC.HasValue ? WordC.Value.ToString("F1", Inv) : "-"),
                "симв " + Char.ToString("F1", Inv),
            };
            if (Typo.HasValue) s.Add("опеч " + Typo.Value.ToString("F1", Inv));
            if (Pair.HasValue) s.Add("пара " + Pair.Value.ToString("F1", Inv));
            if (PPair.HasValue) s.Add("л.пара " + PPair.Value.ToString("F1", Inv));
            if (Caps.HasValue) s.Add("капс " + Caps.Value.ToString("F1", Inv));
            return "{" + string.Join(", ", s) + "}";
        }
    }

    public sealed class Decision
    {
        public bool SwitchNow;
        public string Shown = "";
        /// Исправление задним числом: предыдущее слово было на экране как RetroFrom, станет RetroPrev.
        public string? RetroPrev;
        public string? RetroFrom;
        public bool Pending;
        public double Lo;
        public string Explain = "";
    }

    private static readonly System.Globalization.CultureInfo Inv = System.Globalization.CultureInfo.InvariantCulture;

    public Params P { get; set; } = new();
    /// Живые настройки (из конфига) — применяются перед каждым решением. null — по умолчанию.
    public Func<Params>? LiveParams { get; set; }

    private readonly NgramLM _lm;
    private readonly CharLM _ch;
    private readonly object _lock = new();
    private Word? _prev;
    private double _priorRu = 0.5;

    public const string AlphaRu = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя";
    public const string AlphaEn = "abcdefghijklmnopqrstuvwxyz";
    private static readonly HashSet<char> SetRu = new(AlphaRu), SetEn = new(AlphaEn);
    private static readonly Dictionary<string, HashSet<string>> Valid1 = new()
    {
        ["ru"] = new() { "а", "в", "и", "к", "о", "с", "у", "я" },
        ["en"] = new() { "a", "i" },
    };

    public Core5(NgramLM lm, CharLM ch)
    {
        _lm = lm;
        _ch = ch;
    }

    public double PriorRu { get { lock (_lock) return _priorRu; } }
    public bool Ready => _lm.Loaded;

    /// Личный слой (PersonalLM.cs): участвует в решениях в режимах «работа + обучение» и
    /// «только работа». null или другой режим — ядро как без него.
    public PersonalLM? Personal { get; set; }
    private PersonalLM? Pers => Personal is { Uses: true } p ? p : null;

    // --- состояние ввода ---

    /// Начало ввода: клик, другое окно, навигация, пауза — левого контекста нет.
    public void Reset(double priorRu)
    {
        lock (_lock) { _prev = null; _priorRu = priorRu; }
    }

    /// Левый сосед неизвестен (стёрли назад), ожидание прежнее.
    public void ForgetPrev()
    {
        lock (_lock) _prev = null;
    }

    /// Слово решено не ядром (правило, конфиг) — всё равно контекст.
    /// confident=false — решение ничего не говорит о языке.
    public void NoteExternal(string typed, string shown, bool confident = true)
    {
        lock (_lock)
        {
            string l = LangOf(shown);
            if (!confident || l.Length == 0) { _prev = null; return; }
            string t = LangOf(typed);
            _prev = new Word
            {
                Typed = typed, Shown = shown, Lang = l, T = t, A = t == "ru" ? "en" : "ru", Confident = true,
            };
        }
    }

    /// Человек поменял последнее слово руками — его решение окончательно.
    public void NoteManual(string shown)
    {
        lock (_lock)
        {
            string l = LangOf(shown);
            if (l.Length == 0) { _prev = null; return; }
            var w = _prev ?? new Word();
            w.Shown = shown; w.Lang = l; w.Pending = false; w.Confident = true;
            _prev = w;
        }
    }

    // --- текст ---

    public static string LangOf(string w)
    {
        foreach (char ch in w.ToLowerInvariant())
        {
            if (SetRu.Contains(ch)) return "ru";
            if (SetEn.Contains(ch)) return "en";
        }
        return "";
    }

    public static int Letters(string w, string lang)
    {
        var s = lang == "ru" ? SetRu : SetEn;
        int n = 0;
        foreach (char ch in w.ToLowerInvariant()) if (s.Contains(ch)) n++;
        return n;
    }

    /// <summary>(начало, ядро, конец): по краям — символы, которые в этом языке не буквы.
    /// По кодовым точкам — как эталон на Python.</summary>
    public static (string Pre, string Core, string Post) SplitPunct(string w, string lang)
    {
        var cps = w.EnumerateRunes().ToArray();
        bool InAlpha(Rune r)
        {
            string l = r.ToString().ToLowerInvariant();
            if (l.Length != 1) return false;
            char c = l[0];
            if (lang == "ru") return SetRu.Contains(c) || c == '-';
            return SetEn.Contains(c) || c == '-' || c == '\'';
        }
        int i = 0, j = cps.Length;
        while (i < j && !InAlpha(cps[i])) i++;
        while (j > i && !InAlpha(cps[j - 1])) j--;
        static string Join(IEnumerable<Rune> rs) => string.Concat(rs.Select(r => r.ToString()));
        return (Join(cps[..i]), Join(cps[i..j]), Join(cps[j..]));
    }

    private static int CodePoints(string s) => s.EnumerateRunes().Count();

    public static bool IsCaps(string w)
    {
        int n = 0;
        foreach (Rune r in w.EnumerateRunes()) if (Rune.IsLetter(r)) n++;
        return n >= 2 && w.ToUpperInvariant() == w && w.ToLowerInvariant() != w;
    }

    /// Замена букв по таблице RU↔EN (как R2E в model.py) — только для самопроверки;
    /// в работе другое прочтение даёт LayoutPair.Swap.
    private static readonly Dictionary<char, char> R2E = BuildR2E(), E2R = R2E.ToDictionary(kv => kv.Value, kv => kv.Key);
    private static Dictionary<char, char> BuildR2E()
    {
        const string ru = "йцукенгшщзхъфывапролджэячсмитьбюё", en = "qwertyuiop[]asdfghjkl;'zxcvbnm,.\\";
        var m = new Dictionary<char, char>();
        for (int i = 0; i < ru.Length; i++) m[ru[i]] = en[i];
        return m;
    }
    public static string LetterSwap(string w)
    {
        var sb = new StringBuilder(w.Length);
        foreach (char ch in w)
        {
            char lo = char.ToLowerInvariant(ch);
            if (R2E.TryGetValue(lo, out var m) || E2R.TryGetValue(lo, out m))
                sb.Append(ch != lo ? char.ToUpperInvariant(m) : m);
            else sb.Append(ch);
        }
        return sb.ToString();
    }

    // --- модель ---

    /// −ln P_известн(слово): смесь частот корпуса и личных (γ), или null. Привычная личная
    /// опечатка — как исправленное слово, чуть дороже (PersonalLM.TypoCost).
    public double? Known(string lang, string w)
    {
        var u = _lm.UniD(lang, w);
        var pers = Pers;
        double? pc = pers?.Cost(lang, w);
        if (u is null && pc is null)
        {
            string? r = pers?.TypoOf(lang, w);
            if (r is not null && r != w.ToLowerInvariant())
            {
                var k = KnownMix(_lm.UniD(lang, r), pers!.Cost(lang, r));
                return k is null ? null : k.Value + PersonalLM.TypoCost;
            }
            return null;
        }
        return pc is null ? u : KnownMix(u, pc);
    }

    private double? KnownMix(double? u, double? pc)
    {
        if (u is null && pc is null) return null;
        double g = pc.HasValue ? P.Gamma : 0.0;
        double pu = u.HasValue ? Math.Exp(-u.Value) : 0.0;
        double pp = pc.HasValue ? Math.Exp(-pc.Value) : 0.0;
        double sum = (1 - g) * pu + g * pp;
        return sum > 0 ? -Math.Log(sum) : null;
    }

    /// Ближайшее известное слово в одной правке: −ln P(соседа) + ln(число правок).
    private double? Typo(string lang, string w)
    {
        int n = w.Length;
        if (n < P.TypoMin || n > P.TypoMax) return null;
        string a = lang == "ru" ? AlphaRu : AlphaEn;
        var cands = new HashSet<string>();
        for (int i = 0; i < n; i++)
        {
            cands.Add(w.Remove(i, 1));                                           // удаление
            if (i + 1 < n)                                                        // перестановка
            {
                var t = w.ToCharArray(); (t[i], t[i + 1]) = (t[i + 1], t[i]); cands.Add(new string(t));
            }
            foreach (char c in a)                                                 // замена
            {
                if (c == w[i]) continue;
                var s = w.ToCharArray(); s[i] = c; cands.Add(new string(s));
            }
        }
        for (int i = 0; i <= n; i++)                                              // вставка
            foreach (char c in a) cands.Add(w.Insert(i, c.ToString()));
        double? best = null;
        foreach (var c in cands)
        {
            var u = Known(lang, c);
            if (u.HasValue && (!best.HasValue || u.Value < best.Value)) best = u;
        }
        if (!best.HasValue) return null;
        return best.Value + Math.Log(cands.Count);
    }

    /// prevWord — предыдущее слово того же языка (пара корпуса), pprev — ядро предыдущего
    /// слова любого языка (личная пара: «сервер HA»).
    private (double Cost, Parts Parts) WordCost(string w, string lang, string? prevWord, string? pprev)
    {
        string lw = w.ToLowerInvariant();
        var parts = new Parts();
        double? k = Known(lang, lw);
        double c = _ch.WordCost(lw, lang);
        double? t = k is null ? Typo(lang, lw) : null;
        parts.WordC = k; parts.Char = c; parts.Typo = t;
        double pk = k.HasValue ? Math.Exp(-k.Value) : 0.0;
        double pt = t.HasValue ? Math.Exp(-t.Value) : 0.0;
        // порядок сложения — как в эталоне: (A + B) + C
        double pw = (1 - P.Alpha - P.Tau) * pk;
        pw += P.Alpha * Math.Exp(-c);
        pw += P.Tau * pt;
        if (!string.IsNullOrEmpty(prevWord))
        {
            var b = _lm.BiD(lang, prevWord.ToLowerInvariant(), lw);
            if (b.HasValue)
            {
                pw = P.Beta * Math.Exp(-b.Value) + (1 - P.Beta) * pw;
                parts.Pair = b;
            }
        }
        if (!string.IsNullOrEmpty(pprev) && Pers is { } pers)
        {
            var b = pers.Pair(lang, pprev, lw);
            if (b.HasValue)
            {
                pw = P.Beta * Math.Exp(-b.Value) + (1 - P.Beta) * pw;
                parts.PPair = b;
            }
        }
        return (-Math.Log(Math.Max(pw, 1e-300)), parts);
    }

    private (double Cost, Parts Parts, string Core) Reading(string r, string lang, string? prevWord, string? prevLang, bool caps)
    {
        var (pre, cr, post) = SplitPunct(r, lang);
        if (cr.Length == 0) return (60, new Parts(), cr);
        string? pw = prevWord is not null && prevLang == lang ? prevWord : null;
        string? pcore = prevWord is not null && !string.IsNullOrEmpty(prevLang) ? SplitPunct(prevWord, prevLang).Core : null;
        var (cost, parts) = WordCost(cr, lang, pw, pcore);
        cost += P.Edge * (CodePoints(pre) + CodePoints(post));
        if (caps)
        {
            var v = _ch.CapsP(cr, lang);
            double cp = v.HasValue ? Math.Min(0.99, Math.Max(0.01, v.Value)) : P.CapsP0;
            double cc = -Math.Log(cp);
            parts.Caps = cc;
            cost += cc;
        }
        return (cost, parts, cr);
    }

    /// Можно ли переключать В это прочтение: оно должно быть словом.
    private bool IsWord(string core, string lang, Parts parts, bool caps, double lo, double typedCpc)
    {
        int n = Letters(core, lang);
        if (n == 0) return false;
        if (n == 1) return Valid1[lang].Contains(core.ToLowerInvariant());
        double? k = parts.WordC;
        if (n <= P.Short)
        {
            if (k.HasValue && k.Value <= P.UShort) return true;
            if (k.HasValue && k.Value <= P.UShort2 && lo > P.LoStrong) return true;
            if (caps && (parts.Caps ?? 9) < 1.0 && k.HasValue) return true;
            return false;
        }
        if (k.HasValue || parts.Typo.HasValue) return true;
        double cpc = parts.Char / (n + 1);
        if (cpc <= P.CMax) return true;
        // набранное — явный мусор («bvzlt,fu»), новое хотя бы произносимо («имядебаг»)
        return typedCpc > P.CJunk && cpc <= P.CRel && lo > 10.0;
    }

    private double Prior(string lang)
    {
        double pr = lang == "ru" ? _priorRu : 1 - _priorRu;
        return -Math.Log(Math.Min(Math.Max(pr, 0.02), 0.98));
    }

    private double Trans(string lang, Word? prev)
    {
        if (prev is null || !prev.Confident) return Prior(lang);
        return lang == prev.Lang ? -Math.Log(1 - P.Pi) : -Math.Log(P.Pi);
    }

    private sealed class Scored
    {
        public double Lo, CT, CA, TT, TA;
        public string Alt = "", A = "";
        public bool Ok;
        public Parts PartsT = new(), PartsA = new();
    }

    private Scored Score(string typed, string altIn, string T, Word? prev, Func<string, string> swap)
    {
        var s = new Scored();
        string A = T == "ru" ? "en" : "ru";
        string alt = altIn;
        bool caps = IsCaps(typed);
        Word? ctx = prev is { Confident: true } ? prev : null;
        string? pw = ctx?.Shown, pl = ctx?.Lang;
        var (cT, partsT, coreT) = Reading(typed, T, pw, pl, caps);
        var (cA, partsA, coreA) = Reading(alt, A, pw, pl, caps);
        // хвост, который в набранной раскладке — пунктуация, можно оставить как набран: «ghbdtn,» → «привет,»
        var (pre, cr, post) = SplitPunct(typed, T);
        if (post.Length > 0 && pre.Length == 0 && cr.Length > 0)
        {
            string a2 = swap(cr);
            var (c2, parts2, core2) = Reading(a2, A, pw, pl, caps);
            if (c2 < cA) { cA = c2; partsA = parts2; coreA = core2; alt = a2 + post; }
        }
        double tT = Trans(T, prev), tA = Trans(A, prev);
        // личная пара через смену языка («сервер HA») уже содержит эту смену — второй раз
        // за неё не платим
        if (prev is { Confident: true })
        {
            if (partsT.PPair.HasValue && T != prev.Lang) tT = -Math.Log(1 - P.Pi);
            if (partsA.PPair.HasValue && A != prev.Lang) tA = -Math.Log(1 - P.Pi);
        }
        double lo = (cT + tT) - (cA + tA + P.BK);
        int nT = Math.Max(1, Letters(coreT, T));
        s.Ok = IsWord(coreA, A, partsA, caps, lo, partsT.Char / (nT + 1));
        s.Lo = lo; s.Alt = alt; s.A = A;
        s.CT = cT; s.CA = cA; s.TT = tT; s.TA = tA; s.PartsT = partsT; s.PartsA = partsA;
        return s;
    }

    /// <summary>
    /// Решение по слову. typed — как набрано (язык T), alt — другое прочтение тех же клавиш
    /// (по настоящей раскладке), sepIsSpace — между предыдущим словом и этим на экране ровно
    /// один пробел и ничего больше (иначе задним числом не правим).
    /// </summary>
    public Decision Decide(string typed, string alt, string T, bool sepIsSpace, Func<string, string> swap)
    {
        lock (_lock)
        {
            if (LiveParams is not null) P = LiveParams();
            var d = new Decision();
            var s = Score(typed, alt, T, _prev, swap);
            int n = Letters(typed, T);
            var w = new Word { Typed = typed, T = T, A = s.A, Alt = s.Alt, Lo = s.Lo };
            if (s.Lo > P.Theta && s.Ok) { w.Shown = s.Alt; w.Lang = s.A; }
            else
            {
                w.Shown = typed; w.Lang = T;
                if (P.DeferShort && n <= P.Short && s.Lo > P.ThetaDefer && s.Ok) { w.Pending = true; w.Confident = false; }
            }
            bool curConf = w.Shown != typed || s.Lo < -P.Theta;
            if (_prev is { Pending: true } pw && curConf)
            {
                double bonus = Math.Log((1 - P.Pi) / P.Pi);
                double add = w.Lang == pw.A ? bonus : -bonus;
                // пара справа: «другое прочтение prev → текущее» против «prev как набрано → текущее»
                if (w.Lang == pw.A)
                {
                    var bA = _lm.BiD(pw.A, pw.Alt.ToLowerInvariant(), w.Shown.ToLowerInvariant());
                    if (bA.HasValue) add += Math.Min(3.0, Math.Max(0.0, 12.0 - bA.Value) / 3);
                }
                if (w.Lang == pw.T)
                {
                    var bT = _lm.BiD(pw.T, pw.Typed.ToLowerInvariant(), w.Shown.ToLowerInvariant());
                    if (bT.HasValue) add -= Math.Min(3.0, Math.Max(0.0, 12.0 - bT.Value) / 3);
                }
                double newLo = pw.Lo + add;
                bool flipped = false;
                if (newLo > P.Theta && sepIsSpace)
                {
                    d.RetroFrom = pw.Shown;
                    pw.Shown = pw.Alt; pw.Lang = pw.A;
                    d.RetroPrev = pw.Alt;
                    flipped = true;
                }
                pw.Pending = false; pw.Confident = true; pw.Lo = newLo;
                if (flipped)
                {
                    // текущее — с исправленным соседом
                    var s2 = Score(typed, alt, T, pw, swap);
                    w.Lo = s2.Lo;
                    if (s2.Lo > P.Theta && s2.Ok) { w.Shown = s2.Alt; w.Lang = s2.A; }
                    else { w.Shown = typed; w.Lang = T; }
                }
            }
            d.SwitchNow = w.Shown != typed;
            d.Shown = w.Shown;
            d.Pending = w.Pending;
            d.Lo = w.Lo;
            var ex = new StringBuilder();
            ex.Append($"{typed}[{T}] ").Append(string.Format(Inv, "{0:F1}+{1:F1} ", s.CT, s.TT)).Append(s.PartsT);
            ex.Append($" vs {s.Alt}[{s.A}] ").Append(string.Format(Inv, "{0:F1}+{1:F1}+{2:F1} ", s.CA, s.TA, P.BK)).Append(s.PartsA);
            ex.Append(string.Format(Inv, " → LO {0:+0.0;-0.0}", s.Lo));
            if (!s.Ok) ex.Append(" (не слово)");
            if (w.Pending) ex.Append(" отложено");
            if (d.RetroPrev is not null) ex.Append($" ↺ предыдущее '{d.RetroFrom}' → '{d.RetroPrev}'");
            d.Explain = ex.ToString();
            _prev = w;
            return d;
        }
    }

    // --- самопроверка порта (nn/lm/core5-selftest.json) ---

    /// <summary>Те же входы, что эталон на Python → те же решения. (проверено, расхождений).
    /// Гоняет СВОЙ экземпляр с параметрами по умолчанию.</summary>
    public static (int Checked, int Bad) Selftest(Stream json, NgramLM lm, CharLM ch,
                                                  Action<string>? log = null, bool verbose = false)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        int checkedN = 0, bad = 0;
        if (root.TryGetProperty("chars", out var chars))
            foreach (var row in chars.EnumerateArray())
            {
                string w = row[0].GetString() ?? "", l = row[1].GetString() ?? "";
                double e = row[2].GetDouble();
                double got = ch.WordCost(w.ToLowerInvariant(), l);
                checkedN++;
                if (Math.Abs(got - e) > 0.05)
                {
                    bad++;
                    log?.Invoke($"  ✗ символьная '{w}' [{l}] {got.ToString("F4", Inv)} ≠ {e.ToString("F4", Inv)}");
                }
            }
        void RunSeqs(Core5 c, JsonElement seqs, string tag)
        {
            foreach (var seq in seqs.EnumerateArray())
            {
                double pr = seq.TryGetProperty("prior", out var p) ? p.GetDouble() : 0.5;
                c.Reset(pr);
                foreach (var row in seq.GetProperty("words").EnumerateArray())
                {
                    string typed = row[0].GetString() ?? "", shown = row[1].GetString() ?? "";
                    double lo = row[2].GetDouble();
                    bool pend = row[3].GetBoolean(), retro = row[4].GetBoolean();
                    string T = LangOf(typed);
                    if (T.Length == 0) continue;
                    var r = c.Decide(typed, LetterSwap(typed), T, true, LetterSwap);
                    checkedN++;
                    bool okShown = r.Shown == shown, okLo = Math.Abs(r.Lo - lo) <= 0.05;
                    bool okPend = r.Pending == pend, okRetro = (r.RetroPrev is not null) == retro;
                    if (!(okShown && okLo && okPend && okRetro))
                    {
                        bad++;
                        if (verbose || bad <= 20)
                        {
                            log?.Invoke($"  ✗{tag} '{typed}' → '{r.Shown}' (ждали '{shown}') LO {r.Lo.ToString("F3", Inv)} (ждали {lo.ToString("F3", Inv)})"
                                        + (okPend ? "" : $" отложено {r.Pending}") + (okRetro ? "" : $" ретро {r.RetroPrev ?? "-"}"));
                            if (verbose) log?.Invoke("     " + r.Explain);
                        }
                    }
                }
            }
        }
        if (root.TryGetProperty("seqs", out var seqs)) RunSeqs(new Core5(lm, ch), seqs, "");
        // С личным слоем эталона (выдуманные открытые фразы) — стоимости и решения те же
        if (root.TryGetProperty("personal", out var pj) && root.TryGetProperty("pseqs", out var pseqs))
        {
            var pers = PersonalLM.FromReference(pj);
            pers.ModeSource = () => PersonalMode.On;
            RunSeqs(new Core5(lm, ch) { Personal = pers }, pseqs, " (личный слой)");
        }
        return (checkedN, bad);
    }
}
