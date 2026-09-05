using System.Text.Json;

namespace QSwitcher.Core;

/// <summary>
/// Инференс QSNet — контекстного детектора раскладки. Один в один повторяет
/// эталон nn/qsnet.py (word_vec / build_input / forward): слово → клавиши в
/// EN-обозначениях → хэшированные n-граммы (FNV-1a) → среднее строк таблицы
/// эмбеддингов; плюс 3 предыдущих слова с флагами языка, класс приложения и
/// текущая раскладка → скрытый слой ReLU → sigmoid = P(имелся в виду RU).
///
/// Веса — файл QSN1 (nn/README.md). Открывается через Res.Open: файл снаружи
/// (рядом с exe / в папке данных — задел под синк и своё дообучение) важнее
/// встроенного. Без файла сеть выключена, работают словари.
///
/// Паритет с эталоном проверяется при загрузке по qsnet-selftest.json;
/// расхождение больше 1e-3 — сеть выключается с записью в лог.
/// </summary>
public sealed class LayoutNet
{
    public enum AppClass { Other = 0, Terminal, Code, Browser, Chat }
    public static readonly string[] AppNames = { "other", "terminal", "code", "browser", "chat" };

    public enum CtxFlag { Ru = 0, En, None }

    /// <summary>Контекстное слово: клавиши (null — не кодируется) и флаг языка.</summary>
    public readonly record struct CtxWord(string? Keys, CtxFlag Flag);

    public bool Loaded { get; private set; }
    public string Trained { get; private set; } = "";
    public string Source { get; private set; } = "";

    private int _buckets, _dim, _hidden, _inputDim;
    private float[] _emb = Array.Empty<float>();
    private float[] _w1 = Array.Empty<float>();
    private float[] _b1 = Array.Empty<float>();
    private float[] _w2 = Array.Empty<float>();
    private float _b2;

    private const int CtxWords = 3, NFlags = 3, NApps = 5, NLangs = 2, MaxWordLen = 24;
    private static readonly HashSet<char> KeyChars = new("abcdefghijklmnopqrstuvwxyz[];',.`");

    private readonly LayoutPair _pair;
    private readonly Action<string>? _log;

    public LayoutNet(LayoutPair pair, Action<string>? log = null)
    {
        _pair = pair;
        _log = log;
    }

    // ------------------------------------------------------------ загрузка

    /// <summary>open — как у WordDictionary.Load: снаружи, потом встроенное.</summary>
    public static LayoutNet Load(LayoutPair pair, Func<string, Stream?> open, Action<string>? log = null)
    {
        var net = new LayoutNet(pair, log);
        try
        {
            using var s = open("qsnet.bin");
            if (s is null)
            {
                log?.Invoke("🧠 Сеть: qsnet.bin не найден — работаем на словарях");
                return net;
            }
            using var ms = new MemoryStream();
            s.CopyTo(ms);
            net.Parse(ms.ToArray());
            net.Loaded = true;
            log?.Invoke($"🧠 Сеть: qsnet.bin (buckets={net._buckets}, dim={net._dim}, hidden={net._hidden}, обучена {net.Trained})");
            using var st = open("qsnet-selftest.json");
            if (!net.SelfTest(st))
            {
                net.Loaded = false;
                log?.Invoke("⚠️ Сеть ВЫКЛЮЧЕНА: порт не совпал с эталоном (см. выше)");
            }
        }
        catch (Exception e)
        {
            net.Loaded = false;
            log?.Invoke($"⚠️ Сеть: qsnet.bin не читается: {e.Message}");
        }
        return net;
    }

    private void Parse(byte[] data)
    {
        if (data.Length < 8 || data[0] != (byte)'Q' || data[1] != (byte)'S' || data[2] != (byte)'N' || data[3] != (byte)'1')
            throw new InvalidDataException("не QSN1");
        int hlen = BitConverter.ToInt32(data, 4);
        using var doc = JsonDocument.Parse(new ReadOnlyMemory<byte>(data, 8, hlen));
        var h = doc.RootElement;
        _buckets = h.GetProperty("buckets").GetInt32();
        _dim = h.GetProperty("dim").GetInt32();
        _hidden = h.GetProperty("hidden").GetInt32();
        _inputDim = _dim + CtxWords * (_dim + NFlags) + NApps + NLangs;
        if (h.TryGetProperty("input_dim", out var idp) && idp.GetInt32() != _inputDim)
            throw new InvalidDataException($"input_dim {idp.GetInt32()} ≠ {_inputDim}");
        Trained = h.TryGetProperty("trained", out var tr) ? tr.GetString() ?? "?" : "?";

        int offset = 8 + hlen;
        foreach (var t in h.GetProperty("tensors").EnumerateArray())
        {
            string name = t[0].GetString() ?? "";
            int count = 1;
            foreach (var d in t[1].EnumerateArray()) count *= d.GetInt32();
            if (data.Length < offset + count * 4) throw new InvalidDataException("обрезан тензор " + name);
            var arr = new float[count];
            Buffer.BlockCopy(data, offset, arr, 0, count * 4);   // little-endian, как и x86/ARM
            offset += count * 4;
            switch (name)
            {
                case "emb": _emb = arr; break;
                case "w1": _w1 = arr; break;
                case "b1": _b1 = arr; break;
                case "w2": _w2 = arr; break;
                case "b2": _b2 = arr.Length > 0 ? arr[0] : 0; break;
            }
        }
        if (_emb.Length != _buckets * _dim || _w1.Length != _inputDim * _hidden || _b1.Length != _hidden || _w2.Length != _hidden)
            throw new InvalidDataException("размеры тензоров не сходятся");
    }

    // ------------------------------------------------------------ нормализация

    /// <summary>
    /// Слово в любой раскладке → клавиши в EN-обозначениях («привет» → "ghbdtn").
    /// null — если что-то не с буквенной клавиши (цифра, дефис).
    /// </summary>
    public string? KeysOf(string word)
    {
        var sb = new System.Text.StringBuilder(word.Length);
        foreach (char raw in word.ToLowerInvariant())
        {
            char k = raw;
            if (_pair.IsOtherLetter(raw))
            {
                if (!_pair.OtherToLatin.TryGetValue(raw, out k)) return null;
            }
            if (k == '\\' || k == '|') k = '`';   // ё: ` на ПК, \ на маке — одна клавиша-токен
            if (!KeyChars.Contains(k)) return null;
            sb.Append(k);
        }
        if (sb.Length == 0 || sb.Length > MaxWordLen) return null;
        return sb.ToString();
    }

    /// <summary>Контекстное слово как оно на экране → клавиши + флаг по алфавиту.</summary>
    public CtxWord CtxOf(string word)
    {
        string lower = word.ToLowerInvariant();
        bool oth = lower.Any(c => _pair.IsOtherLetter(c));
        bool lat = lower.Any(c => _pair.IsLatinLetter(c));
        var flag = oth && !lat ? CtxFlag.Ru : lat && !oth ? CtxFlag.En : CtxFlag.None;
        return new CtxWord(flag == CtxFlag.None ? null : KeysOf(lower), flag);
    }

    // ------------------------------------------------------------ признаки

    /// <summary>FNV-1a 32 бит по ASCII-байтам.</summary>
    private static uint Fnv1a(ReadOnlySpan<byte> s)
    {
        uint h = 0x811C9DC5;
        foreach (byte b in s)
        {
            h ^= b;
            h *= 0x01000193;
        }
        return h;
    }

    /// <summary>Подстроки 1..4 строки "&lt;keys&gt;" плюс "=keys" → номера строк.</summary>
    private List<int> BucketsOf(string keys)
    {
        var s = System.Text.Encoding.ASCII.GetBytes("<" + keys + ">");
        var outp = new List<int>(s.Length * 4 + 1);
        int n = s.Length;
        for (int L = 1; L <= 4 && L <= n; L++)
            for (int i = 0; i + L <= n; i++)
                outp.Add((int)(Fnv1a(new ReadOnlySpan<byte>(s, i, L)) % (uint)_buckets));
        outp.Add((int)(Fnv1a(System.Text.Encoding.ASCII.GetBytes("=" + keys)) % (uint)_buckets));
        return outp;
    }

    private void WordVec(string? keys, float[] x, int offset)
    {
        if (string.IsNullOrEmpty(keys)) return;
        var rows = BucketsOf(keys);
        foreach (int r in rows)
        {
            int b = r * _dim;
            for (int j = 0; j < _dim; j++) x[offset + j] += _emb[b + j];
        }
        float inv = 1f / rows.Count;
        for (int j = 0; j < _dim; j++) x[offset + j] *= inv;
    }

    // ------------------------------------------------------------ прямой проход

    /// <summary>P(имелся в виду RU). ctx — предыдущие слова, БЛИЖАЙШЕЕ ПЕРВЫМ, до трёх.</summary>
    public float ProbabilityRu(string keys, IReadOnlyList<CtxWord> ctx, AppClass app, bool layoutRu)
    {
        var x = new float[_inputDim];
        int off = 0;
        WordVec(keys, x, off); off += _dim;
        for (int i = 0; i < CtxWords; i++)
        {
            var c = i < ctx.Count ? ctx[i] : new CtxWord(null, CtxFlag.None);
            WordVec(c.Keys, x, off); off += _dim;
            x[off + (int)c.Flag] = 1; off += NFlags;
        }
        x[off + (int)app] = 1; off += NApps;
        x[off + (layoutRu ? 0 : 1)] = 1;

        float z = _b2;
        for (int j = 0; j < _hidden; j++)
        {
            float h = _b1[j];
            for (int i = 0; i < _inputDim; i++)
            {
                float xi = x[i];
                if (xi != 0) h += xi * _w1[i * _hidden + j];
            }
            if (h > 0) z += h * _w2[j];
        }
        return 1f / (1f + MathF.Exp(-z));
    }

    // ------------------------------------------------------------ самопроверка

    private bool SelfTest(Stream? st)
    {
        if (st is null)
        {
            _log?.Invoke("🧠 selftest: qsnet-selftest.json нет — паритет не проверен");
            return true;
        }
        using var doc = JsonDocument.Parse(st);
        float maxDiff = 0;
        string worst = "";
        int n = 0;
        foreach (var c in doc.RootElement.EnumerateArray())
        {
            n++;
            string keys = c.GetProperty("keys").GetString() ?? "";
            string appName = c.GetProperty("app").GetString() ?? "other";
            string layout = c.GetProperty("layout").GetString() ?? "en";
            float want = (float)c.GetProperty("p").GetDouble();
            var ctx = new List<CtxWord>();
            foreach (var pair in c.GetProperty("ctx").EnumerateArray())
            {
                string? k = pair[0].ValueKind == JsonValueKind.Null ? null : pair[0].GetString();
                string f = pair[1].GetString() ?? "none";
                ctx.Add(new CtxWord(k, f == "ru" ? CtxFlag.Ru : f == "en" ? CtxFlag.En : CtxFlag.None));
            }
            int ai = Array.IndexOf(AppNames, appName);
            var app = ai < 0 ? AppClass.Other : (AppClass)ai;
            float p = ProbabilityRu(keys, ctx, app, layout == "ru");
            float diff = MathF.Abs(p - want);
            if (diff > maxDiff) { maxDiff = diff; worst = $"{keys} ctx={ctx.Count} {appName}/{layout}: порт {p} эталон {want}"; }
        }
        bool ok = maxDiff <= 1e-3f;
        _log?.Invoke($"🧠 selftest: {n} случаев, макс. расхождение {maxDiff}{(ok ? "" : " ✗ " + worst)}");
        return ok;
    }
}
