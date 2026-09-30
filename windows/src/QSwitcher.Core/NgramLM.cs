using System.Globalization;
using System.Text;
using System.Text.Json;

namespace QSwitcher.Core;

/// <summary>
/// Языковая модель на словных n-граммах (nn/ngram/build.py → qsngram.bin, QSNG2).
/// Две таблицы (ru, en): униграммы и биграммы, по хэшу FNV-1a, запись 3 байта =
/// 16-битный отпечаток + −logP в шагах 0.1 ната, две корзины на ключ.
/// Эталон расчёта — nn/ngram/score.py и NgramLM.swift; здесь то же самое, только
/// левый сосед (правого при вводе ещё нет). Лукап — два хэша и сравнение, микросекунды.
///
/// Один экземпляр на приложение: им пользуются и ядро 5 (UniD/BiD — в double, как
/// эталон nn/lm/model.py, иначе самопроверка разойдётся в последних знаках), и
/// n-граммный слой прежнего каскада (Uni/Bi/Cost/Decide — во float, как NgramLM.swift).
/// Таблицы — окна в одном массиве файла (QSTable), без копий: 57 МБ, а не 114.
/// </summary>
public sealed class NgramLM
{
    public bool Loaded { get; private set; }

    private int _uniBits, _biBits;
    private float _scale = 0.1f;
    private double _scaleD = 0.1;
    private readonly Dictionary<string, (QSTable Uni, QSTable Bi)> _tables = new();

    // Те же константы, что в score.py / NgramLM.swift
    /// Пары нет — униграмма с надбавкой.
    public const float Backoff = 1.2f;
    /// Слова нет в корпусе — хуже ЛЮБОГО настоящего слова (шкала до 25.5). С потолком 12
    /// «kubectl» (19) проигрывал несуществующему «лгиусед» — и так свапалось всё редкое.
    public const float Unseen = 30.0f;
    /// Сосед другого алфавита. ДОЛЖЕН быть меньше порога решения: иначе штраф
    /// один, без единого свидетельства из корпуса, решает исход («сосед русский —
    /// значит и слово русское»), и на симметричном наборе это ровно половина
    /// ошибок. Он только склоняет чашу, когда всё остальное поровну.
    public const float SwitchCost = 0.35f;

    /// Пустая модель (не загружена): ядро 5 молчит, n-граммный слой тоже.
    public NgramLM() { }

    /// Числа в логе всегда с точкой (как на маке и в score.py), независимо от локали.
    private static string Inv(FormattableString f) => f.ToString(CultureInfo.InvariantCulture);

    // ------------------------------------------------------------ загрузка

    /// <summary>open — как у LayoutNet.Load: сначала снаружи (папка данных), потом встроенное.</summary>
    public static NgramLM Load(Func<string, Stream?> open, Action<string>? log = null)
    {
        var lm = new NgramLM();
        try
        {
            using var s = open("qsngram.bin");
            if (s is null)
            {
                log?.Invoke("🔡 N-граммы: qsngram.bin не найден — ядро 5 и n-граммы выключены");
                return lm;
            }
            byte[] data = QSTable.ReadAll(s);
            lm.Parse(data);
            lm.Loaded = true;
            log?.Invoke(Inv($"🔡 N-граммы: qsngram.bin ({data.Length / 1e6:F1} МБ, слов 2^{lm._uniBits}, пар 2^{lm._biBits} на язык)"));
        }
        catch (Exception e)
        {
            lm.Loaded = false;
            log?.Invoke($"⚠️ N-граммы: qsngram.bin не читается: {e.Message}");
        }
        return lm;
    }

    private void Parse(byte[] d)
    {
        if (d.Length < 9 || Encoding.ASCII.GetString(d, 0, 5) != "QSNG2")
            throw new InvalidDataException("не QSNG2");
        int off = 5;
        int hl = QSTable.U32(d, ref off);
        using var doc = JsonDocument.Parse(new ReadOnlyMemory<byte>(d, off, hl));
        off += hl;
        var h = doc.RootElement;
        _uniBits = h.GetProperty("uni_bits").GetInt32();
        _biBits = h.GetProperty("bi_bits").GetInt32();
        _scaleD = h.GetProperty("scale").GetDouble();
        _scale = (float)_scaleD;
        _tables.Clear();
        foreach (var lang in h.GetProperty("langs").EnumerateArray())
        {
            int ul = QSTable.U32(d, ref off), bl = QSTable.U32(d, ref off);
            var u = new QSTable(d, off, ul, _uniBits); off += ul;
            var b = new QSTable(d, off, bl, _biBits); off += bl;
            _tables[lang.GetString() ?? ""] = (u, b);
        }
    }

    // ------------------------------------------------------------ хэши (как в build.py)

    public static uint Fnv1a(string s)
    {
        uint h = 0x811C9DC5;
        foreach (byte b in Encoding.UTF8.GetBytes(s)) { h ^= b; h *= 0x01000193; }
        return h;
    }

    public static ushort Fp16(string s)
    {
        ushort v = (ushort)(Fnv1a("\u0001" + s + "\u0002") >> 16);
        return v == 0 ? (ushort)1 : v;
    }

    public static (int A, int B) Slots(string key, uint mask)
    {
        uint a = Fnv1a(key) & mask;
        uint b = Fnv1a("\u0003" + key) & mask;
        return ((int)a, (int)(b != a ? b : (a + 1) & mask));
    }

    // ------------------------------------------------------------ лукап

    private int RawUni(string lang, string w) =>
        _tables.TryGetValue(lang, out var t) ? t.Uni.Get(w) : -1;

    private int RawBi(string lang, string p, string w) =>
        _tables.TryGetValue(lang, out var t) ? t.Bi.Get(p + "\u001f" + w) : -1;

    /// <summary>−ln P(слово) или null — слова нет в корпусе (float, n-граммный слой).</summary>
    public float? Uni(string lang, string w) { int v = RawUni(lang, w); return v < 0 ? null : v * _scale; }

    /// <summary>−ln P(слово | предыдущее) или null — пары нет (float, n-граммный слой).</summary>
    public float? Bi(string lang, string p, string w) { int v = RawBi(lang, p, w); return v < 0 ? null : v * _scale; }

    /// <summary>То же для ядра 5 — в double, как эталон на Python.</summary>
    public double? UniD(string lang, string w) { int v = RawUni(lang, w); return v < 0 ? null : v * _scaleD; }

    /// <summary>То же для ядра 5 — в double, как эталон на Python.</summary>
    public double? BiD(string lang, string p, string w) { int v = RawBi(lang, p, w); return v < 0 ? null : v * _scaleD; }

    // ------------------------------------------------------------ балл чтения

    public static string LangOf(string s)
    {
        foreach (char c in s)
        {
            if (c >= 0x0400 && c <= 0x04FF) return "ru";
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) return "en";
        }
        return "";
    }

    /// Свидетельство: нашлась ли пара «сосед → слово» в корпусе (после последнего Cost).
    public bool LastHadBigram { get; private set; }

    /// <summary>
    /// −logP чтения с учётом левого соседа: пара, иначе униграмма + откат,
    /// плюс смена языка, если сосед другого алфавита. Меньше — лучше.
    /// </summary>
    public (float Cost, string Why) Cost(string word, string? left)
    {
        LastHadBigram = false;
        string lang = LangOf(word);
        if (lang.Length == 0) return (Unseen, "нет алфавита");
        float? uq = Uni(lang, word);
        if (uq is null) return (Unseen, $"{lang}: слова нет");
        float u = uq.Value;
        string? l = left?.ToLowerInvariant();
        if (string.IsNullOrEmpty(l)) return (u, Inv($"слово {u:F1}"));
        string ll = LangOf(l);
        if (ll.Length > 0 && ll != lang)
            return (u + Backoff + SwitchCost, Inv($"откат {u + Backoff:F1}, смена языка +{SwitchCost:F1}"));
        float? b = Bi(lang, l, word);
        if (b is not null)
        {
            LastHadBigram = true;
            return (b.Value, Inv($"пара {b.Value:F1}"));
        }
        return (u + Backoff, Inv($"откат {u + Backoff:F1}"));
    }

    /// <summary>Слово есть в корпусе своего языка?</summary>
    public bool Known(string word)
    {
        string lang = LangOf(word);
        return lang.Length > 0 && Uni(lang, word) is not null;
    }

    /// <summary>
    /// null — молчим; иначе победившее чтение и объяснение.
    /// Свапаем ТОЛЬКО в слово, которое есть в корпусе: опечатка, сленг, редкий
    /// термин («сломали», «kubectl») не должны превращаться в мусор только потому,
    /// что модель их не видела. «Не видели оба» — молчим.
    /// noContextFactor — множитель порога, когда ни у одного чтения нет пары.
    /// </summary>
    public (string Win, string Explain)? Decide(string typed, string swapped, string? left,
                                                float margin, float noContextFactor)
    {
        var (a, wa) = Cost(typed, left); bool ea = LastHadBigram;
        var (b, wb) = Cost(swapped, left); bool eb = LastHadBigram;
        // Ни у одного чтения пары в корпусе нет — свидетельств о КОНТЕКСТЕ нет,
        // сравниваются голые частоты слов. Тогда побеждает просто более частое,
        // и на симметричном наборе половина строк обречена. В таком случае
        // требуем куда больший разрыв: «часто» само по себе не довод.
        float m = (ea || eb) ? margin : margin * noContextFactor;
        string note = (ea || eb) ? "" : ", без пары";
        string explain = Inv($"'{typed}' {a:F2} ({wa}) vs '{swapped}' {b:F2} ({wb}){note}");
        bool ka = Known(typed), kb = Known(swapped);
        if (kb && b + m < a) return (swapped, explain);
        if (ka && a + m < b) return (typed, explain);
        return null;
    }
}
