using System.Text.Json;
using QSwitcher.Core;

namespace QSwitcher.App;

/// <summary>
/// Личные исправления для дообучения сети. Пишутся при явном обучении
/// («Свап и запомнить») вместе с контекстом и классом приложения — то, чего у
/// LearnedRules нет. Файл: папка данных\nn-corrections.jsonl, по JSON на строку.
/// При дообучении к ним добавляются слова из learned.json (force → другой язык,
/// stop → свой), одинаковые (клавиши + контекст) схлопываются, последний побеждает.
/// </summary>
public sealed class Corrections
{
    private readonly string _path;
    private readonly LayoutNet _net;
    private readonly LearnedRules _learned;
    private readonly LayoutPair _pair;
    private readonly Func<string?, LayoutNet.AppClass> _appClassOf;
    private readonly Action<string> _log;
    private readonly object _lock = new();

    public Corrections(string dataDir, LayoutNet net, LearnedRules learned, LayoutPair pair,
                       Func<string?, LayoutNet.AppClass> appClassOf, Action<string> log)
    {
        _path = Path.Combine(dataDir, "nn-corrections.jsonl");
        _net = net; _learned = learned; _pair = pair; _appClassOf = appClassOf; _log = log;
    }

    /// <summary>Записать исправление: word — как набрано, intendedOther — имелся в
    /// виду «другой» язык (RU); history — предыдущие слова, ближайшее первым.</summary>
    public void Record(string word, bool intendedOther, IReadOnlyList<string> history, string? app)
    {
        string? keys = _net.KeysOf(word.ToLowerInvariant());
        if (keys is null || keys.Length < 2) return;
        var ctx = history.Take(3).Select(_net.CtxOf).ToList();
        bool layoutOther = word.Any(c => _pair.IsOtherLetter(c));
        var ex = new LayoutNet.Example(keys, ctx, _appClassOf(app), layoutOther, intendedOther);
        var j = ex.ToJson();
        j["t"] = DateTime.Now.ToString("s");
        try
        {
            lock (_lock) File.AppendAllText(_path, j.ToJsonString() + Environment.NewLine);
            _log($"[nn] исправление: '{word}' → {(intendedOther ? "ru" : "en")} (ctx='{string.Join(" ", history.Take(3))}')");
        }
        catch (Exception e) { _log($"[nn] исправление не записалось: {e.Message}"); }
    }

    /// <summary>Все личные примеры: learned.json + файл исправлений, без дубликатов.</summary>
    public List<LayoutNet.Example> Examples()
    {
        var byKey = new Dictionary<string, LayoutNet.Example>();
        var order = new List<string>();
        void Put(LayoutNet.Example e)
        {
            string k = e.DedupKey;
            if (!byKey.ContainsKey(k)) order.Add(k);
            byKey[k] = e;
        }
        var (stop, force) = _learned.Snapshot();
        foreach (var w in force)   // набрано не в той раскладке → имелся в виду другой язык
        {
            bool oth = w.Any(c => _pair.IsOtherLetter(c));
            if (_net.KeysOf(w) is { Length: >= 2 } keys)
                Put(new LayoutNet.Example(keys, Array.Empty<LayoutNet.CtxWord>(), LayoutNet.AppClass.Other, oth, !oth));
        }
        foreach (var w in stop)    // как набрано — так и надо
        {
            bool oth = w.Any(c => _pair.IsOtherLetter(c));
            if (_net.KeysOf(w) is { Length: >= 2 } keys)
                Put(new LayoutNet.Example(keys, Array.Empty<LayoutNet.CtxWord>(), LayoutNet.AppClass.Other, oth, oth));
        }
        if (File.Exists(_path))
        {
            foreach (var line in File.ReadLines(_path))
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    if (LayoutNet.Example.FromJson(doc.RootElement) is { } e) Put(e);
                }
                catch { /* битая строка — пропускаем */ }
            }
        }
        return order.Select(k => byKey[k]).ToList();
    }
}
