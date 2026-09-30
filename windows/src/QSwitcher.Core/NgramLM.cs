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
/// </summary>
public sealed class NgramLM
{
    public bool Loaded { get; private set; }

    private int _uniBits, _biBits;
    private float _scale = 0.1f;
    private readonly Dictionary<string, (byte[] Uni, byte[] Bi)> _tables = new();
    private readonly Action<string>? _log;

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

    public NgramLM(Action<string>? log = null) => _log = log;

    /// Числа в логе всегда с точкой (как на маке и в score.py), независимо от локали.
    private static string Inv(FormattableString f) => f.ToString(CultureInfo.InvariantCulture);

    // ------------------------------------------------------------ загрузка

    /// <summary>open — как у LayoutNet.Load: сначала снаружи (папка данных), потом встроенное.</summary>
    public static NgramLM Load(Func<string, Stream?> open, Action<string>? log = null)
    {
        var lm = new NgramLM(log);
        try
        {
            using var s = open("qsngram.bin");
            if (s is null)
            {
                log?.Invoke("🔡 N-граммы: qsngram.bin не найден — сигнал выключен");
                return lm;
            }
            using var ms = new MemoryStream();
            s.CopyTo(ms);
            var data = ms.ToArray();
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
        if (d.Length < 9 || d[0] != (byte)'Q' || d[1] != (byte)'S' || d[2] != (byte)'N' || d[3] != (byte)'G' || d[4] != (byte)'2')
            throw new InvalidDataException("не QSNG2");
        int off = 5;
        int U32() { int v = BitConverter.ToInt32(d, off); off += 4; return v; }
        int hl = U32();
        using var doc = JsonDocument.Parse(new ReadOnlyMemory<byte>(d, off, hl));
        off += hl;
        var h = doc.RootElement;
        _uniBits = h.GetProperty("uni_bits").GetInt32();
        _biBits = h.GetProperty("bi_bits").GetInt32();
        _scale = (float)h.GetProperty("scale").GetDouble();
        _tables.Clear();
        foreach (var lang in h.GetProperty("langs").EnumerateArray())
        {
            int ul = U32(), bl = U32();
            var u = new byte[ul]; Buffer.BlockCopy(d, off, u, 0, ul); off += ul;
            var b = new byte[bl]; Buffer.BlockCopy(d, off, b, 0, bl); off += bl;
            _tables[lang.GetString()!] = (u, b);
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

    private float? Get(byte[] table, int bits, string key)
    {
        uint mask = (uint)((1 << bits) - 1);
        ushort fp = Fp16(key);
        var (a, b) = Slots(key, mask);
        foreach (int slot in new[] { a, b })
        {
            int i = slot * 3;
            ushort cur = (ushort)(table[i] | (table[i + 1] << 8));
            if (cur == fp) return table[i + 2] * _scale;
        }
        return null;
    }

    public float? Uni(string lang, string w) =>
        _tables.TryGetValue(lang, out var t) ? Get(t.Uni, _uniBits, w) : null;

    public float? Bi(string lang, string p, string w) =>
        _tables.TryGetValue(lang, out var t) ? Get(t.Bi, _biBits, p + "\u001f" + w) : null;

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
