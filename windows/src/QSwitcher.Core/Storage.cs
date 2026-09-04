using System.Text.Json;

namespace QSwitcher.Core;

/// <summary>
/// Словари пары языков. Latin/Other — полные, ShortLatin/ShortOther — частотные
/// списки для слов 2–3 букв (на них полный словарь бесполезен из-за архаизмов).
/// BadLatin/BadOther — n-граммы-триггеры.
/// </summary>
public sealed class WordDictionary
{
    public HashSet<string> Latin { get; private set; } = new();
    public HashSet<string> Other { get; private set; } = new();
    public HashSet<string> ShortLatin { get; private set; } = new();
    public HashSet<string> ShortOther { get; private set; } = new();
    public HashSet<string> BadLatin { get; private set; } = new();
    public HashSet<string> BadOther { get; private set; } = new();

    /// <summary>
    /// Загрузка словарей. open — открывает ресурс по имени файла: сначала
    /// ищется файл рядом с приложением (чтобы можно было подменить), иначе
    /// берётся встроенный в сборку.
    /// </summary>
    public static WordDictionary Load(Func<string, Stream?> open, Action<string>? log = null)
    {
        var d = new WordDictionary();
        d.Latin = LoadWords(open, "en.txt", log);
        d.Other = LoadWords(open, "ru.txt", log);
        d.ShortLatin = LoadWords(open, "short_en.txt", log);
        d.ShortOther = LoadWords(open, "short_ru.txt", log);

        using var ng = open("bad_ngrams.json");
        if (ng is not null)
        {
            using var doc = JsonDocument.Parse(ng);
            if (doc.RootElement.TryGetProperty("latin", out var lat))
                d.BadLatin = lat.EnumerateArray().Select(e => e.GetString()!).ToHashSet();
            if (doc.RootElement.TryGetProperty("cyrillic", out var cyr))
                d.BadOther = cyr.EnumerateArray().Select(e => e.GetString()!).ToHashSet();
            log?.Invoke($"Плохие n-граммы: {d.BadLatin.Count} лат, {d.BadOther.Count} кир");
        }
        return d;
    }

    /// <summary>Подмешать пользовательский словарь (дополнения человека).</summary>
    public void MergeUser(string path, bool latin)
    {
        if (!File.Exists(path)) return;
        var target = latin ? Latin : Other;
        foreach (var w in File.ReadLines(path))
        {
            var t = w.Trim().ToLowerInvariant();
            if (t.Length > 0) target.Add(t);
        }
    }

    private static HashSet<string> LoadWords(Func<string, Stream?> open, string name, Action<string>? log)
    {
        using var stream = open(name);
        if (stream is null)
        {
            log?.Invoke($"⚠️ Не найден {name}");
            return new();
        }
        var set = new HashSet<string>(StringComparer.Ordinal);
        using var reader = new StreamReader(stream, System.Text.Encoding.UTF8);
        string? line;
        while ((line = reader.ReadLine()) is not null)
        {
            var t = line.Trim().ToLowerInvariant();
            if (t.Length > 0) set.Add(t);
        }
        log?.Invoke($"Словарь {name}: {set.Count}");
        return set;
    }
}

/// <summary>
/// Самообучение на исправлениях пользователя. Перенесено с macOS:
/// правило создаётся ТОЛЬКО по явной команде (на маке Shift+Option),
/// обычный свап и тоггл ничего не запоминают — они разовые.
/// Хранится в learned.json рядом с конфигом.
/// </summary>
public sealed class LearnedRules
{
    private readonly string _path;
    private readonly object _lock = new();
    private HashSet<string> _stop = new();
    private HashSet<string> _force = new();

    public LearnedRules(string dataDir)
    {
        Directory.CreateDirectory(dataDir);
        _path = Path.Combine(dataDir, "learned.json");
        Load();
    }

    public bool ShouldStop(string word) { lock (_lock) return _stop.Contains(word.ToLowerInvariant()); }
    public bool ShouldForce(string word) { lock (_lock) return _force.Contains(word.ToLowerInvariant()); }

    public void LearnStop(string word)
    {
        var w = word.ToLowerInvariant();
        if (w.Length == 0) return;
        lock (_lock) { _force.Remove(w); _stop.Add(w); Save(); }
    }

    public void LearnForce(string word)
    {
        var w = word.ToLowerInvariant();
        if (w.Length == 0) return;
        lock (_lock) { _stop.Remove(w); _force.Add(w); Save(); }
    }

    public void Reset() { lock (_lock) { _stop.Clear(); _force.Clear(); Save(); } }

    /// Удалить конкретное правило.
    public void Remove(string word)
    {
        var w = word.ToLowerInvariant();
        lock (_lock) { _stop.Remove(w); _force.Remove(w); Save(); }
    }

    /// Переключить правило на противоположное.
    public void Flip(string word)
    {
        var w = word.ToLowerInvariant();
        lock (_lock)
        {
            if (_force.Remove(w)) _stop.Add(w);
            else if (_stop.Remove(w)) _force.Add(w);
            Save();
        }
    }

    /// Добавить правило вручную.
    public void Add(string word, bool force)
    {
        var w = word.Trim().ToLowerInvariant();
        if (w.Length == 0) return;
        lock (_lock)
        {
            _stop.Remove(w); _force.Remove(w);
            (force ? _force : _stop).Add(w);
            Save();
        }
    }

    public (IReadOnlyList<string> stop, IReadOnlyList<string> force) Snapshot()
    {
        lock (_lock) return (_stop.OrderBy(x => x).ToList(), _force.OrderBy(x => x).ToList());
    }

    private record Stored(List<string> Stop, List<string> Force);

    private void Load()
    {
        try
        {
            if (!File.Exists(_path)) return;
            var s = JsonSerializer.Deserialize<Stored>(File.ReadAllText(_path));
            if (s is null) return;
            _stop = s.Stop.ToHashSet();
            _force = s.Force.ToHashSet();
        }
        catch { /* повреждённый файл — начинаем с чистого */ }
    }

    private int _savePending;
    private readonly ManualResetEventSlim _saved = new(true);

    /// Запись на диск — отложенно, в фоне: правила учатся из потока хука
    /// (Shift+тап), а файловая операция в хуке недопустима. Несколько правок
    /// подряд схлопываются в одну запись.
    private void Save()
    {
        _saved.Reset();
        if (Interlocked.Exchange(ref _savePending, 1) == 1) return;
        ThreadPool.QueueUserWorkItem(_ =>
        {
            Interlocked.Exchange(ref _savePending, 0);
            try { WriteNow(); }
            catch { }
            finally { if (Volatile.Read(ref _savePending) == 0) _saved.Set(); }
        });
    }

    private void WriteNow()
    {
        string json;
        lock (_lock)
        {
            var s = new Stored(_stop.OrderBy(x => x).ToList(), _force.OrderBy(x => x).ToList());
            json = JsonSerializer.Serialize(s, new JsonSerializerOptions { WriteIndented = true });
        }
        File.WriteAllText(_path, json);
    }

    /// Дождаться отложенной записи (перед выходом).
    public void Flush()
    {
        if (!_saved.Wait(2000))
        {
            try { WriteNow(); } catch { }
        }
    }
}
