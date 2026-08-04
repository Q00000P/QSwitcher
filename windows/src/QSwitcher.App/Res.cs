using System.Reflection;

namespace QSwitcher.App;

/// <summary>
/// Доступ к ресурсам приложения.
///
/// Приложение — один файл, поэтому словари, звуки и прочее лежат ВНУТРИ
/// сборки. Но сначала проверяется файл снаружи: рядом с exe или в папке
/// данных пользователя. Так можно подменить словарь или звук, ничего
/// не пересобирая, и при этом раздавать одну самодостаточную программу.
/// </summary>
public static class Res
{
    private static readonly Assembly Asm = Assembly.GetExecutingAssembly();

    /// Все встроенные ресурсы. Имя формируется из КОРНЕВОГО ПРОСТРАНСТВА ИМЁН
    /// проекта, а не из имени сборки — угадывать префикс нельзя, поэтому
    /// сопоставляем по окончанию имени.
    private static readonly string[] Names = Asm.GetManifestResourceNames();

    private static string? Resolve(string name)
    {
        foreach (var n in Names)
        {
            if (n.EndsWith("." + name, StringComparison.OrdinalIgnoreCase) ||
                n.Equals(name, StringComparison.OrdinalIgnoreCase))
                return n;
        }
        return null;
    }

    /// <summary>Папки, где ищем внешнюю замену ресурсу.</summary>
    private static IEnumerable<string> ExternalDirs()
    {
        yield return Path.Combine(AppContext.BaseDirectory, "Resources");
        yield return AppContext.BaseDirectory;
        yield return Path.Combine(Program.DataDir, "Resources");
        yield return Program.DataDir;
    }

    /// <summary>Открыть ресурс по имени файла. null — если нигде нет.</summary>
    public static Stream? Open(string name)
    {
        foreach (var dir in ExternalDirs())
        {
            try
            {
                var p = Path.Combine(dir, name);
                if (File.Exists(p))
                    return new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.Read);
            }
            catch { }
        }
        var full = Resolve(name);
        return full is null ? null : Asm.GetManifestResourceStream(full);
    }

    /// <summary>Путь к внешнему файлу, если он есть (для случаев, где нужен именно путь).</summary>
    public static string? ExternalPath(string name)
    {
        foreach (var dir in ExternalDirs())
        {
            var p = Path.Combine(dir, name);
            if (File.Exists(p)) return p;
        }
        return null;
    }

    public static bool Exists(string name) =>
        ExternalPath(name) is not null || Resolve(name) is not null;

    /// <summary>Что вообще встроено — для диагностики.</summary>
    public static IEnumerable<string> Embedded() =>
        Names.Select(n => n.Contains(".Resources.")
            ? n[(n.IndexOf(".Resources.", StringComparison.Ordinal) + 11)..]
            : n);
}
