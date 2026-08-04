using System.Diagnostics;
using System.Media;
using System.Runtime.InteropServices;

namespace QSwitcher.App;

/// <summary>Что произошло — от этого зависит звук.</summary>
public enum SoundKind
{
    /// Текст исправлен, раскладка осталась прежней.
    ConvertOnly,
    /// Текст исправлен И раскладка переключена.
    ConvertAndSwitch,
    /// Откат: тоггл вернул исходный вариант.
    Undo,
}

/// <summary>
/// Звуковая обратная связь. Два РАЗНЫХ сигнала — иначе на слух не отличить
/// «просто исправил слово» от «исправил и сменил раскладку», а знать это важно:
/// от этого зависит, в какой раскладке продолжать печатать.
///
/// Звуки играются в фоне и никогда не блокируют разбор нажатий.
/// </summary>
public sealed class SoundPlayerService
{
    private readonly Func<bool> _enabled;
    private readonly Func<string> _convertOnly;
    private readonly Func<string> _convertAndSwitch;
    private readonly Func<string> _undo;

    public SoundPlayerService(Func<bool> enabled, Func<string> convertOnly,
                              Func<string> convertAndSwitch, Func<string> undo)
    {
        _enabled = enabled;
        _convertOnly = convertOnly;
        _convertAndSwitch = convertAndSwitch;
        _undo = undo;
    }

    /// Проигрыватели кэшируются: SoundPlayer читает файл при каждом Play,
    /// а звук срабатывает на каждое слово.
    private readonly Dictionary<string, SoundPlayer> _players = new();

    private void PlayFile(string name)
    {
        SoundPlayer? player;
        lock (_players)
        {
            if (!_players.TryGetValue(name, out player))
            {
                // Полный путь — берём как есть, иначе ищем среди ресурсов
                // (сначала снаружи, потом встроенные)
                Stream? stream = Path.IsPathRooted(name) && File.Exists(name)
                    ? new FileStream(name, FileMode.Open, FileAccess.Read, FileShare.Read)
                    : Res.Open(name);
                if (stream is null) { SystemSounds.Beep.Play(); return; }

                // SoundPlayer держит поток, поэтому копируем в память:
                // звук проигрывается часто, файл трогать каждый раз незачем.
                var ms = new MemoryStream();
                stream.CopyTo(ms);
                stream.Dispose();
                ms.Position = 0;
                player = new SoundPlayer(ms);
                player.Load();
                _players[name] = player;
            }
        }
        player.Play();
    }

    public void Play(SoundKind kind)
    {
        if (!_enabled()) return;
        string name = kind switch
        {
            SoundKind.ConvertOnly => _convertOnly(),
            SoundKind.Undo => _undo(),
            _ => _convertAndSwitch(),
        };
        if (string.Equals(name, "none", StringComparison.OrdinalIgnoreCase)) return;

        ThreadPool.QueueUserWorkItem(_ =>
        {
            try
            {
                switch (name.ToLowerInvariant())
                {
                    case "beep": SystemSounds.Beep.Play(); break;
                    case "asterisk": SystemSounds.Asterisk.Play(); break;
                    case "exclamation": SystemSounds.Exclamation.Play(); break;
                    case "hand": SystemSounds.Hand.Play(); break;
                    case "question": SystemSounds.Question.Play(); break;
                    default:
                        PlayFile(name);
                        break;
                }
            }
            catch { }
        });
    }
}

/// <summary>
/// Проверка, надо ли работать в текущем приложении.
///
/// Терминалы и менеджеры паролей трогать нельзя: в первых свап портит команды,
/// во вторых мы вообще не должны вмешиваться в поле пароля.
///
/// Имя процесса кэшируется на короткое время: запрос идёт на каждой границе
/// слова, а обращение к чужому процессу не бесплатно. Кэш обновляется в фоне
/// и НИКОГДА не блокирует разбор нажатий — на macOS такой запрос, поставленный
/// прямо в путь ввода, подвешивал всю систему.
/// </summary>
public sealed class AppExclusions
{
    private readonly Func<IReadOnlyCollection<string>> _excluded;
    private readonly object _lock = new();
    private string _cachedProcess = "";
    private DateTime _refreshedAt = DateTime.MinValue;
    private bool _refreshing;

    public AppExclusions(Func<IReadOnlyCollection<string>> excluded) => _excluded = excluded;

    /// Текущее приложение в списке исключений?
    public bool IsExcluded()
    {
        string name = CachedProcessName();
        if (name.Length == 0) return false;
        foreach (var e in _excluded())
            if (name.Contains(e, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    public string CurrentProcess() => CachedProcessName();

    private string CachedProcessName()
    {
        lock (_lock)
        {
            bool stale = (DateTime.UtcNow - _refreshedAt).TotalMilliseconds > 400;
            if (stale && !_refreshing)
            {
                _refreshing = true;
                ThreadPool.QueueUserWorkItem(_ => Refresh());
            }
            return _cachedProcess;
        }
    }

    private void Refresh()
    {
        string result = "";
        try
        {
            IntPtr hwnd = GetForegroundWindow();
            if (hwnd != IntPtr.Zero)
            {
                GetWindowThreadProcessId(hwnd, out uint pid);
                if (pid != 0)
                {
                    using var p = Process.GetProcessById((int)pid);
                    result = p.ProcessName;
                }
            }
        }
        catch { }
        lock (_lock)
        {
            _cachedProcess = result;
            _refreshedAt = DateTime.UtcNow;
            _refreshing = false;
        }
    }

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
