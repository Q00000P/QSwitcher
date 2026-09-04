using System.Net.Http;
using System.Text.Json;

namespace QSwitcher.App;

/// <summary>
/// Проверка новой версии.
///
/// Два источника по порядку:
///   1. Манифест на своём VPS (домен + нестандартный порт из конфига) —
///      основной: не зависит от доступности GitHub и переживает переезд
///      сервера, потому что адресуется доменом, а не IP.
///   2. GitHub Releases API — фолбэк, если VPS недоступен.
///
/// Ничего не скачивает и не устанавливает: только сравнивает версии.
/// </summary>
internal static class UpdateChecker
{
    /// Sha256 пустой — автообновление недоступно (GitHub-фолбэк хеша не
    /// даёт), только открыть страницу: непроверенный бинарь не ставим.
    public record Result(string Latest, string Current, string Url, bool IsNewer, string Source, string Sha256);

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(8) };

    /// <summary>Сравнение семверов: 3.10 новее 3.9, «win-3.3» == «3.3».</summary>
    public static bool IsNewer(string candidate, string current)
    {
        static int[] Parts(string s)
        {
            s = s.Trim().TrimStart('v');
            if (s.StartsWith("win-", StringComparison.OrdinalIgnoreCase)) s = s[4..];
            return s.Split('.')
                    .Select(p => int.TryParse(new string(p.TakeWhile(char.IsDigit).ToArray()), out int n) ? n : 0)
                    .ToArray();
        }
        var a = Parts(candidate);
        var b = Parts(current);
        for (int i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            int x = i < a.Length ? a[i] : 0;
            int y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    /// <summary>Проверить обновления. null — оба источника недоступны.</summary>
    public static async Task<Result?> CheckAsync(AppConfig cfg, Action<string> log)
    {
        string current = AppVersion.Version;

        var manifest = await FetchManifestAsync(cfg, log);
        if (manifest is not null)
            return Finish(manifest.Value.version, manifest.Value.url, manifest.Value.sha256, "сервер обновлений", current, log);

        log("[update] манифест недоступен — пробую GitHub API");
        var gh = await FetchGitHubAsync(cfg, log);
        if (gh is not null)
            return Finish(gh.Value.version, gh.Value.url, "", "GitHub", current, log);

        return null;
    }

    private static Result Finish(string latest, string url, string sha256, string source, string current, Action<string> log)
    {
        bool newer = IsNewer(latest, current);
        log($"[update] {source}: {latest}, у нас {current} → {(newer ? "есть обновление" : "актуальна")}");
        return new Result(latest, current, url, newer, source, sha256);
    }

    private static async Task<(string version, string url, string sha256)?> FetchManifestAsync(AppConfig cfg, Action<string> log)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, cfg.UpdateManifestUrl);
            req.Headers.UserAgent.ParseAdd($"QSwitcher/{AppVersion.Version}");
            using var resp = await Http.SendAsync(req);
            if (!resp.IsSuccessStatusCode) { log($"[update] манифест: HTTP {(int)resp.StatusCode}"); return null; }

            using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
            if (!doc.RootElement.TryGetProperty("version", out var v)) return null;
            string url = doc.RootElement.TryGetProperty("url", out var u)
                ? u.GetString() ?? cfg.UpdateReleasesPage
                : cfg.UpdateReleasesPage;
            string sha = doc.RootElement.TryGetProperty("sha256", out var h)
                ? h.GetString() ?? "" : "";
            return (v.GetString() ?? "", url, sha);
        }
        catch (Exception ex) { log($"[update] манифест: {ex.Message}"); return null; }
    }

    private static async Task<(string version, string url)?> FetchGitHubAsync(AppConfig cfg, Action<string> log)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get,
                $"https://api.github.com/repos/{cfg.UpdateRepo}/releases");
            req.Headers.UserAgent.ParseAdd($"QSwitcher/{AppVersion.Version}");
            using var resp = await Http.SendAsync(req);
            if (!resp.IsSuccessStatusCode) { log($"[update] GitHub: HTTP {(int)resp.StatusCode}"); return null; }

            using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
            // Теги винды — win-3.3, мака — v3.3. Берём только свои, самый свежий.
            foreach (var rel in doc.RootElement.EnumerateArray())
            {
                if (rel.TryGetProperty("draft", out var d) && d.GetBoolean()) continue;
                if (!rel.TryGetProperty("tag_name", out var t)) continue;
                string tag = t.GetString() ?? "";
                if (!tag.StartsWith("win-", StringComparison.OrdinalIgnoreCase)) continue;
                string page = rel.TryGetProperty("html_url", out var h)
                    ? h.GetString() ?? cfg.UpdateReleasesPage
                    : cfg.UpdateReleasesPage;
                return (tag[4..], page);
            }
            return null;
        }
        catch (Exception ex) { log($"[update] GitHub: {ex.Message}"); return null; }
    }
}
