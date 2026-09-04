using System.IO.Compression;
using System.Security.Cryptography;

namespace QSwitcher.App;

/// <summary>
/// Автообновление: скачать архив → сверить sha256 из манифеста → распаковать →
/// подменить exe → перезапуститься.
///
/// Запущенный exe в Windows перезаписать нельзя, но ПЕРЕИМЕНОВАТЬ можно —
/// классический трюк: QSwitcher.exe → QSwitcher.exe.old, новый на его место,
/// перезапуск; старый файл удаляется при следующем старте (CleanupOldBinary).
/// Helper-процесс не нужен.
/// </summary>
internal static class UpdateInstaller
{
    /// <summary>
    /// Качает и ставит обновление. null — успех, вызывающий должен завершить
    /// приложение (новый exe уже запущен). Строка — текст ошибки для показа;
    /// текущая версия при этом продолжает работать.
    /// </summary>
    public static async Task<string?> InstallAsync(UpdateChecker.Result r, Action<string> log)
    {
        if (string.IsNullOrEmpty(r.Sha256))
            return "автообновление без sha256 запрещено";

        string current = Environment.ProcessPath
            ?? throw new InvalidOperationException("не знаю путь своего exe");

        var work = Path.Combine(Path.GetTempPath(), $"qswitcher-update-{DateTime.Now:yyyyMMdd-HHmmss}");
        Directory.CreateDirectory(work);

        try
        {
            // 1. Скачиваем
            log($"[update] качаю {r.Url}");
            string zipPath = Path.Combine(work, "update.zip");
            using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) })
            {
                using var resp = await http.GetAsync(r.Url, HttpCompletionOption.ResponseHeadersRead);
                if (!resp.IsSuccessStatusCode) return $"загрузка: HTTP {(int)resp.StatusCode}";
                await using var src = await resp.Content.ReadAsStreamAsync();
                await using var dst = File.Create(zipPath);
                await src.CopyToAsync(dst);
            }

            // 2. sha256 ДО любых действий со скачанным
            log("[update] проверяю sha256");
            string hash;
            using (var sha = SHA256.Create())
            await using (var f = File.OpenRead(zipPath))
                hash = Convert.ToHexString(await sha.ComputeHashAsync(f)).ToLowerInvariant();
            if (!hash.Equals(r.Sha256, StringComparison.OrdinalIgnoreCase))
                return $"sha256 не совпал: архив повреждён или подменён.\nОжидал {r.Sha256}\nПолучил {hash}";

            // 3. Распаковка
            log("[update] распаковываю");
            string unpack = Path.Combine(work, "unpacked");
            ZipFile.ExtractToDirectory(zipPath, unpack);
            string? newExe = Directory
                .GetFiles(unpack, "QSwitcher.exe", SearchOption.AllDirectories)
                .FirstOrDefault();
            if (newExe is null) return "в архиве нет QSwitcher.exe";

            // 4. Rename-трюк
            string oldPath = current + ".old";
            if (File.Exists(oldPath)) File.Delete(oldPath);
            File.Move(current, oldPath);
            try
            {
                File.Copy(newExe, current);
                // Сопутствующие файлы архива (если появятся) — рядом,
                // конфиг пользователя не трогаем
                string targetDir = Path.GetDirectoryName(current)!;
                string newDir = Path.GetDirectoryName(newExe)!;
                foreach (var f in Directory.GetFiles(newDir))
                {
                    string name = Path.GetFileName(f);
                    if (name.Equals("QSwitcher.exe", StringComparison.OrdinalIgnoreCase)) continue;
                    if (name.Equals("config.json", StringComparison.OrdinalIgnoreCase)) continue;
                    File.Copy(f, Path.Combine(targetDir, name), overwrite: true);
                }
            }
            catch
            {
                // Копирование сорвалось — возвращаем старый exe на место
                if (!File.Exists(current)) File.Move(oldPath, current);
                throw;
            }

            log($"[update] перезапускаюсь ({r.Latest})");
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(current)
            {
                UseShellExecute = true,
                WorkingDirectory = Path.GetDirectoryName(current)!,
            });
            return null; // вызывающий делает Application.Exit()
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
        finally
        {
            // Архив и распаковку чистим в любом случае
            try { Directory.Delete(work, recursive: true); } catch { }
        }
    }

    /// <summary>Убрать exe прошлой версии, оставшийся после rename-трюка.
    /// Зовётся при старте; сразу после обновления файл может быть ещё занят
    /// умирающим процессом — тогда удалится при следующем запуске.</summary>
    public static void CleanupOldBinary(Action<string> log)
    {
        try
        {
            string? p = Environment.ProcessPath;
            if (p is null) return;
            string oldPath = p + ".old";
            if (File.Exists(oldPath))
            {
                File.Delete(oldPath);
                log("[update] прошлая версия подчищена");
            }
        }
        catch { /* занят — уберём в следующий раз */ }
    }
}
