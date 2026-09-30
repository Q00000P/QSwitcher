using System.Text.Json;
using System.Text.Json.Nodes;

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
    /// <summary>Загружены пользовательские (дообученные) веса, а не встроенные.</summary>
    public bool IsUser { get; private set; }
    /// <summary>Заголовок файла как есть — переносится в пользовательские веса.</summary>
    private JsonNode? _header;
    private Func<string, Stream?>? _open;
    /// <summary>Путь пользовательских весов (в папке данных) — задаётся при Load.</summary>
    public string? UserWeightsPath { get; private set; }

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

    /// <summary>open — как у WordDictionary.Load: снаружи, потом встроенное.
    /// userWeightsPath — куда пишет «Дообучить» (папка данных); если файл там есть,
    /// он важнее встроенного.</summary>
    public static LayoutNet Load(LayoutPair pair, Func<string, Stream?> open, Action<string>? log = null,
                                 string? userWeightsPath = null)
    {
        var net = new LayoutNet(pair, log) { _open = open, UserWeightsPath = userWeightsPath };
        net.Reload();
        return net;
    }

    /// <summary>Перечитать веса (после дообучения или сброса).</summary>
    public void Reload()
    {
        Loaded = false;
        IsUser = false;
        try
        {
            byte[]? bytes = null;
            if (UserWeightsPath is not null && File.Exists(UserWeightsPath))
            {
                bytes = File.ReadAllBytes(UserWeightsPath);
                IsUser = true;
                Source = UserWeightsPath;
            }
            else if (_open is not null)
            {
                using var s = _open("qsnet.bin");
                if (s is not null)
                {
                    using var ms = new MemoryStream();
                    s.CopyTo(ms);
                    bytes = ms.ToArray();
                    Source = "qsnet.bin";
                }
            }
            if (bytes is null)
            {
                _log?.Invoke("🧠 Сеть: qsnet.bin не найден — работаем на словарях");
                return;
            }
            Parse(bytes);
            Loaded = true;
            string ft = _header?["finetuned"]?.GetValue<string>() is { } f
                ? $", дообучена {f}, v{_header?["finetune_version"]?.GetValue<int>() ?? 0}" : "";
            _log?.Invoke($"🧠 Сеть: {Source} (buckets={_buckets}, dim={_dim}, hidden={_hidden}, обучена {Trained}{ft})");
            // Селфтест — только для встроенных весов: эталон считан именно по ним.
            if (!IsUser && _open is not null)
            {
                using var st = _open("qsnet-selftest.json");
                if (!SelfTest(st))
                {
                    Loaded = false;
                    _log?.Invoke("⚠️ Сеть ВЫКЛЮЧЕНА: порт не совпал с эталоном (см. выше)");
                }
            }
        }
        catch (Exception e)
        {
            Loaded = false;
            _log?.Invoke($"⚠️ Сеть: qsnet.bin не читается: {e.Message}");
        }
    }

    private void Parse(byte[] data)
    {
        if (data.Length < 8 || data[0] != (byte)'Q' || data[1] != (byte)'S' || data[2] != (byte)'N' || data[3] != (byte)'1')
            throw new InvalidDataException("не QSN1");
        int hlen = BitConverter.ToInt32(data, 4);
        _header = JsonNode.Parse(new ReadOnlyMemory<byte>(data, 8, hlen).Span);
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

    // ------------------------------------------------------------ дообучение

    /// <summary>Личный или общий пример: клавиши, контекст, класс приложения, раскладка, метка.</summary>
    public sealed record Example(string Keys, IReadOnlyList<CtxWord> Ctx, AppClass App, bool LayoutRu, bool LabelRu)
    {
        /// <summary>Из JSON {"keys","ctx":[[k,f]…],"app","layout","label"}; null — битая запись.</summary>
        public static Example? FromJson(JsonElement c)
        {
            if (!c.TryGetProperty("keys", out var kp) || kp.GetString() is not { Length: > 0 } keys) return null;
            if (!c.TryGetProperty("label", out var lp)) return null;
            var ctx = new List<CtxWord>();
            if (c.TryGetProperty("ctx", out var cp))
                foreach (var pair in cp.EnumerateArray())
                {
                    if (ctx.Count >= CtxWords) break;
                    string? k = pair.GetArrayLength() > 0 && pair[0].ValueKind == JsonValueKind.String ? pair[0].GetString() : null;
                    string f = pair.GetArrayLength() > 1 ? pair[1].GetString() ?? "none" : "none";
                    ctx.Add(new CtxWord(k, f == "ru" ? CtxFlag.Ru : f == "en" ? CtxFlag.En : CtxFlag.None));
                }
            string appName = c.TryGetProperty("app", out var ap) ? ap.GetString() ?? "other" : "other";
            int ai = Array.IndexOf(AppNames, appName);
            string layout = c.TryGetProperty("layout", out var lay) ? lay.GetString() ?? "en" : "en";
            return new Example(keys, ctx, ai < 0 ? AppClass.Other : (AppClass)ai, layout == "ru", lp.GetString() == "ru");
        }

        public JsonObject ToJson()
        {
            var ctx = new JsonArray();
            foreach (var c in Ctx)
                ctx.Add(new JsonArray(c.Keys is null ? null : JsonValue.Create(c.Keys),
                                      JsonValue.Create(new[] { "ru", "en", "none" }[(int)c.Flag])));
            return new JsonObject
            {
                ["keys"] = Keys, ["ctx"] = ctx, ["app"] = AppNames[(int)App],
                ["layout"] = LayoutRu ? "ru" : "en", ["label"] = LabelRu ? "ru" : "en",
            };
        }

        /// <summary>Ключ для схлопывания дубликатов: клавиши + контекст.</summary>
        public string DedupKey => Keys + "|" + string.Join(",", Ctx.Select(c => (c.Keys ?? "") + ":" + (int)c.Flag));
    }

    public sealed record FinetuneReport(int Personal, int PersonalBefore, int PersonalAfter,
                                        int Generic, int GenericBefore, int GenericAfter, double Seconds)
    {
        public override string ToString() =>
            $"личных примеров {Personal}: верно {PersonalBefore} → {PersonalAfter}; " +
            $"общих {Generic}: {GenericBefore} → {GenericAfter}; {Seconds:F1} с";
    }

    // Гиперпараметры — ровно как в nn/finetune.py
    private const int FtEpochs = 300;
    private const float FtLR = 0.05f, FtLambda = 0.05f, FtSmooth = 0.02f, FtPersonalWeight = 20f;

    /// <summary>Общие примеры для replay (qsnet-replay.json) — чтобы личные слова
    /// добавились, а не вытеснили базу.</summary>
    public List<Example> LoadReplay()
    {
        var outp = new List<Example>();
        if (_open is null) return outp;
        using var st = _open("qsnet-replay.json");
        if (st is null) return outp;
        using var doc = JsonDocument.Parse(st);
        foreach (var c in doc.RootElement.EnumerateArray())
            if (Example.FromJson(c) is { } e) outp.Add(e);
        return outp;
    }

    /// <summary>Аугментация личного примера: обе раскладки и копия без контекста — как expand() в finetune.py.</summary>
    private static IEnumerable<Example> Expand(Example e)
    {
        foreach (bool lay in new[] { e.LayoutRu, !e.LayoutRu })
        {
            yield return e with { LayoutRu = lay };
            if (e.Ctx.Count > 0) yield return e with { LayoutRu = lay, Ctx = Array.Empty<CtxWord>() };
        }
    }

    /// <summary>Дообучить текущие веса на личных примерах (+ replay) и записать
    /// пользовательский qsnet.bin. Долго (секунды) — звать из фона. После — Reload().</summary>
    public FinetuneReport Finetune(IReadOnlyList<Example> personal, IReadOnlyList<Example> replay)
    {
        if (!Loaded) throw new InvalidOperationException("сеть не загружена");
        if (UserWeightsPath is null) throw new InvalidOperationException("не задан путь пользовательских весов");
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var pers = personal.SelectMany(Expand).ToList();
        var samples = pers.Concat(replay).ToList();
        int nP = pers.Count, N = samples.Count;
        if (N == 0) throw new InvalidOperationException("нет примеров");
        int D = _dim, H = _hidden, I = _inputDim;

        var slots = new List<(int off, int[] bk)>[N];
        var dense = new float[N][];
        var y = new float[N];
        var w = new float[N];
        for (int i = 0; i < N; i++)
        {
            var e = samples[i];
            var sl = new List<(int, int[])> { (0, BucketsOf(e.Keys).ToArray()) };
            int off = D;
            for (int c = 0; c < CtxWords; c++)
            {
                if (c < e.Ctx.Count && e.Ctx[c].Keys is { Length: > 0 } k) sl.Add((off, BucketsOf(k).ToArray()));
                off += D + NFlags;
            }
            slots[i] = sl;
            var x = new float[I];
            off = D;
            for (int c = 0; c < CtxWords; c++)
            {
                var flag = c < e.Ctx.Count ? e.Ctx[c].Flag : CtxFlag.None;
                x[off + D + (int)flag] = 1;
                off += D + NFlags;
            }
            x[off + (int)e.App] = 1; off += NApps;
            x[off + (e.LayoutRu ? 0 : 1)] = 1;
            dense[i] = x;
            y[i] = e.LabelRu ? 1 : 0;
            w[i] = i < nP ? FtPersonalWeight : 1;
        }
        float wMean = w.Sum() / N;
        for (int i = 0; i < N; i++) w[i] /= wMean;
        var yt = y.Select(v => v * (1 - 2 * FtSmooth) + FtSmooth).ToArray();

        var emb = (float[])_emb.Clone();
        var w1 = (float[])_w1.Clone(); var b1 = (float[])_b1.Clone();
        var w2 = (float[])_w2.Clone(); float b2 = _b2;
        var w1_0 = _w1; var b1_0 = _b1; var w2_0 = _w2; float b2_0 = _b2;
        var X = new float[N * I];
        var hp = new float[N * H];
        var p = new float[N];

        void Assemble()
        {
            for (int i = 0; i < N; i++)
            {
                int bas = i * I;
                Array.Copy(dense[i], 0, X, bas, I);
                foreach (var (off, bk) in slots[i])
                {
                    foreach (int r in bk)
                    {
                        int rb = r * D;
                        for (int j = 0; j < D; j++) X[bas + off + j] += emb[rb + j];
                    }
                    float inv = 1f / bk.Length;
                    for (int j = 0; j < D; j++) X[bas + off + j] *= inv;
                }
            }
        }
        void Forward()
        {
            for (int i = 0; i < N; i++)
            {
                int xb = i * I;
                float z = b2;
                for (int j = 0; j < H; j++)
                {
                    float h = b1[j];
                    for (int k = 0; k < I; k++) { float xk = X[xb + k]; if (xk != 0) h += xk * w1[k * H + j]; }
                    hp[i * H + j] = h;
                    if (h > 0) z += h * w2[j];
                }
                p[i] = 1f / (1f + MathF.Exp(-z));
            }
        }
        (int, int) Correct()
        {
            int a = 0, b = 0;
            for (int i = 0; i < N; i++)
                if ((p[i] >= 0.5f) == (y[i] >= 0.5f)) { if (i < nP) a++; else b++; }
            return (a, b);
        }

        Assemble(); Forward();
        var before = Correct();
        var gw1 = new float[I * H]; var gb1 = new float[H]; var gw2 = new float[H]; var dh = new float[H];
        for (int ep = 0; ep < FtEpochs; ep++)
        {
            Assemble(); Forward();
            for (int j = 0; j < I * H; j++) gw1[j] = FtLambda * (w1[j] - w1_0[j]);
            for (int j = 0; j < H; j++) { gb1[j] = FtLambda * (b1[j] - b1_0[j]); gw2[j] = FtLambda * (w2[j] - w2_0[j]); }
            float gb2 = FtLambda * (b2 - b2_0);
            for (int i = 0; i < N; i++)
            {
                float dz = (p[i] - yt[i]) * w[i] / N;
                gb2 += dz;
                int xb = i * I;
                for (int j = 0; j < H; j++)
                {
                    float h = hp[i * H + j];
                    if (h > 0) { gw2[j] += h * dz; dh[j] = dz * w2[j]; } else dh[j] = 0;
                }
                for (int j = 0; j < H; j++)
                {
                    if (dh[j] == 0) continue;
                    gb1[j] += dh[j];
                    for (int k = 0; k < I; k++) { float xk = X[xb + k]; if (xk != 0) gw1[k * H + j] += xk * dh[j]; }
                }
                foreach (var (off, bk) in slots[i])
                {
                    float inv = 1f / bk.Length;
                    for (int d = 0; d < D; d++)
                    {
                        float g = 0;
                        int row = (off + d) * H;
                        for (int j = 0; j < H; j++) if (dh[j] != 0) g += dh[j] * w1[row + j];
                        g *= inv * FtLR;
                        if (g != 0) foreach (int r in bk) emb[r * D + d] -= g;
                    }
                }
            }
            for (int j = 0; j < I * H; j++) w1[j] -= FtLR * gw1[j];
            for (int j = 0; j < H; j++) { b1[j] -= FtLR * gb1[j]; w2[j] -= FtLR * gw2[j]; }
            b2 -= FtLR * gb2;
        }
        var keep = (_emb, _w1, _b1, _w2, _b2);
        _emb = emb; _w1 = w1; _b1 = b1; _w2 = w2; _b2 = b2;
        Assemble(); Forward();
        var after = Correct();
        try { SaveUser(personal.Count); }
        catch { (_emb, _w1, _b1, _w2, _b2) = keep; throw; }
        return new FinetuneReport(nP, before.Item1, after.Item1, N - nP, before.Item2, after.Item2, sw.Elapsed.TotalSeconds);
    }

    private void SaveUser(int personalCount)
    {
        var h = _header?.DeepClone() as JsonObject ?? new JsonObject();
        h["finetuned"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm");
        h["finetune_version"] = (h["finetune_version"]?.GetValue<int>() ?? 0) + 1;
        h["personal_examples"] = personalCount;
        h["base_trained"] ??= Trained;
        var hbytes = System.Text.Encoding.UTF8.GetBytes(h.ToJsonString());
        using var ms = new MemoryStream();
        ms.Write(new[] { (byte)'Q', (byte)'S', (byte)'N', (byte)'1' });
        ms.Write(BitConverter.GetBytes(hbytes.Length));
        ms.Write(hbytes);
        foreach (var t in h["tensors"]!.AsArray())
        {
            float[] arr = t![0]!.GetValue<string>() switch
            {
                "emb" => _emb, "w1" => _w1, "b1" => _b1, "w2" => _w2, "b2" => new[] { _b2 }, _ => Array.Empty<float>(),
            };
            var bytes = new byte[arr.Length * 4];
            Buffer.BlockCopy(arr, 0, bytes, 0, bytes.Length);
            ms.Write(bytes);
        }
        Directory.CreateDirectory(Path.GetDirectoryName(UserWeightsPath!)!);
        File.WriteAllBytes(UserWeightsPath! + ".tmp", ms.ToArray());
        File.Move(UserWeightsPath! + ".tmp", UserWeightsPath!, overwrite: true);
        _header = h;
    }

    /// <summary>Сброс к встроенным весам: удалить пользовательский файл и перечитать.</summary>
    public void ResetToBase()
    {
        if (UserWeightsPath is not null && File.Exists(UserWeightsPath)) File.Delete(UserWeightsPath);
        Reload();
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
