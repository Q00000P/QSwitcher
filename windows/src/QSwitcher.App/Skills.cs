using System.Text.Json;
using System.Text.Json.Nodes;
using QSwitcher.Core;

namespace QSwitcher.App;

/// <summary>
/// Навыки в файл и из файла (формат — SkillsFile.cs, общий с маком): выученные правила,
/// стоп- и форс-слова, исключённые приложения и английский ввод, ожидание языка по
/// приложениям, личный слой, журнал профиля. Импорт — слияние, ничего не стирает:
/// правила из файла важнее своих, списки объединяются, личный слой — по устройствам.
/// Приложения — только своей платформы (имена процессов на маке и винде разные).
/// </summary>
public static class Skills
{
    public const string Platform = "win";

    public static string JournalPath(string dataDir) => Path.Combine(dataDir, "profile-examples.txt");

    public static JsonObject Export(AppConfig cfg, LearnedRules learned, AppLangStats appStats,
                                    PersonalLM personal, string dataDir)
    {
        var doc = SkillsFile.NewDocument(personal.Local.Device, Environment.MachineName, Platform);
        var (stop, force) = learned.Snapshot();
        doc["learned"] = new JsonObject { ["force"] = SkillsFile.Strings(force), ["stop"] = SkillsFile.Strings(stop) };
        doc["forceWords"] = SkillsFile.Strings(cfg.ForceWords);
        doc["stopWords"] = SkillsFile.Strings(cfg.StopWords);
        var lang = new JsonObject();
        foreach (var (app, v) in appStats.Counts().OrderBy(kv => kv.Key, StringComparer.Ordinal))
            lang[app] = new JsonArray(Math.Round(v[0], 2), Math.Round(v[1], 2));
        doc["apps"] = new JsonObject
        {
            [Platform] = new JsonObject
            {
                ["excluded"] = SkillsFile.Strings(cfg.ExcludedProcesses),
                ["english"] = SkillsFile.Strings(cfg.EnglishApps),
                ["lang"] = lang,
            },
        };
        // Журнал профиля (мак): на винде профиля нет, но журнал хранится и передаётся дальше
        try
        {
            string jp = JournalPath(dataDir);
            if (File.Exists(jp)) doc["profileJournal"] = File.ReadAllText(jp);
        }
        catch { }
        doc["personal"] = JsonNode.Parse(personal.Snapshot());
        return doc;
    }

    /// <summary>Слить навыки из файла. Возвращает сводку для человека.</summary>
    public static string Import(JsonNode doc, AppConfig cfg, LearnedRules learned, AppLangStats appStats,
                                PersonalLM personal, string dataDir)
    {
        var report = new List<string>();

        // Выученные правила: из файла важнее (человек импортирует осознанно)
        var (stop0, force0) = learned.Snapshot();
        var haveForce = force0.ToHashSet(); var haveStop = stop0.ToHashSet();
        int rules = 0;
        foreach (var w in SkillsFile.ReadStrings(doc["learned"]?["force"]))
            if (!haveForce.Contains(w.ToLowerInvariant())) { learned.Add(w, force: true); rules++; }
        foreach (var w in SkillsFile.ReadStrings(doc["learned"]?["stop"]))
            if (!haveStop.Contains(w.ToLowerInvariant())) { learned.Add(w, force: false); rules++; }
        if (rules > 0) report.Add($"выученных правил: +{rules}");

        int words = 0;
        foreach (var w in SkillsFile.ReadStrings(doc["forceWords"])) if (cfg.ForceWords.Add(w.ToLowerInvariant())) words++;
        foreach (var w in SkillsFile.ReadStrings(doc["stopWords"])) if (cfg.StopWords.Add(w.ToLowerInvariant())) words++;
        if (words > 0) report.Add($"стоп- и форс-слов: +{words}");

        int apps = 0;
        var mine = doc["apps"]?[Platform];
        if (mine is not null)
        {
            foreach (var p in SkillsFile.ReadStrings(mine["excluded"]))
                if (!cfg.ExcludedProcesses.Contains(p, StringComparer.OrdinalIgnoreCase)) { cfg.ExcludedProcesses.Add(p); apps++; }
            foreach (var p in SkillsFile.ReadStrings(mine["english"]))
                if (!cfg.EnglishApps.Contains(p, StringComparer.OrdinalIgnoreCase)) { cfg.EnglishApps.Add(p); apps++; }
            if (apps > 0) report.Add($"приложений в списках: +{apps}");
            if (mine["lang"] is JsonObject lo)
            {
                var d = new Dictionary<string, double[]>();
                foreach (var (app, v) in lo)
                    if (v is JsonArray a && a.Count == 2)
                        d[app] = new[] { a[0]?.GetValue<double>() ?? 0, a[1]?.GetValue<double>() ?? 0 };
                int n = appStats.MergeMax(d);
                if (n > 0) report.Add($"ожидание языка: {n} приложений");
            }
        }
        if (words > 0 || apps > 0) cfg.Save();

        if (doc["profileJournal"]?.GetValue<string>() is { Length: > 0 } journal)
        {
            try
            {
                string jp = JournalPath(dataDir);
                string cur = File.Exists(jp) ? File.ReadAllText(jp) : "";
                var add = SkillsFile.NewJournalLines(cur, journal);
                if (add.Count > 0)
                {
                    File.AppendAllText(jp, (cur.Length > 0 && !cur.EndsWith('\n') ? "\n" : "") + string.Join("\n", add) + "\n");
                    report.Add($"журнал профиля: +{add.Count} строк (профиль — на маке)");
                }
            }
            catch (Exception e) { report.Add($"журнал профиля не записан: {e.Message}"); }
        }

        if (doc["personal"] is JsonObject pers)
        {
            using var pd = JsonDocument.Parse(pers.ToJsonString(SkillsFile.Json));
            int t = personal.Merge(pd.RootElement);
            if (t > 0) report.Add($"личный слой: таблиц других устройств +{t}");
        }

        string from = doc["from"]?["name"]?.GetValue<string>() ?? "?";
        string platform = doc["from"]?["platform"]?.GetValue<string>() ?? "?";
        return report.Count == 0
            ? $"Из «{from}» ({platform}): нового нет — всё уже есть."
            : $"Из «{from}» ({platform}):\n" + string.Join("\n", report.Select(r => "• " + r));
    }
}
