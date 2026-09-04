using System.Diagnostics;
using System.Runtime.InteropServices;

namespace QSwitcher.App;

/// <summary>
/// Слежение за окном/полем с фокусом — ПО СОБЫТИЯМ, а не запросами.
///
/// Ядро 4.0 принимает решение и шлёт замену прямо из хука. Из хука нельзя
/// ходить в чужой процесс (имя процесса — открытие хендла, поле пароля —
/// UIA-запрос на десятки миллисекунд): хук обязан вернуться за микросекунды,
/// иначе Windows снимет его. Поэтому всё это узнаётся заранее: система сама
/// сообщает о смене фокуса (WinEvent), фоновый поток дорешивает детали и
/// публикует результат, а хук читает готовые поля.
///
/// Каждая смена фокуса получает номер поколения. Записи защищённого лога
/// помечаются поколением на момент набора и решаются («поле пароля или нет»)
/// уже при сбросе на диск — без ожиданий в горячем пути.
/// </summary>
public sealed class ForegroundTracker : IDisposable
{
    private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    private const uint EVENT_OBJECT_FOCUS = 0x8005;
    private const uint WINEVENT_OUTOFCONTEXT = 0x0000;

    private delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint idEventThread, uint dwmsEventTime);

    private readonly WinEventDelegate _proc;
    private readonly Action<string> _log;
    private IntPtr _hookFg, _hookFocus;

    private int _generation;
    private volatile string _process = "";

    /// Поколение → поле пароля. Хранится последние несколько десятков.
    private readonly System.Collections.Concurrent.ConcurrentDictionary<int, bool> _password = new();
    private readonly System.Collections.Concurrent.BlockingCollection<(int gen, IntPtr hwnd)> _work = new();
    private readonly Thread _worker;

    /// Кэш pid → имя процесса: открывать процесс на каждую смену фокуса незачем.
    private readonly Dictionary<uint, string> _names = new();

    public ForegroundTracker(Action<string> log)
    {
        _log = log;
        _proc = OnEvent;
        _worker = new Thread(WorkLoop) { IsBackground = true, Name = "QSwitcher.Foreground" };
        _worker.Start();
    }

    /// Номер текущего поколения фокуса.
    public int Generation => Volatile.Read(ref _generation);

    /// Имя процесса окна с фокусом (без .exe). Пусто, пока не известно.
    public string ProcessName => _process;

    /// Поле пароля для данного поколения: true/false, либо null — ещё не решено.
    public bool? PasswordAt(int gen) => _password.TryGetValue(gen, out var b) ? b : null;

    /// <summary>
    /// Установить WinEvent-хуки. Вызывать ИЗ ПОТОКА С ЦИКЛОМ СООБЩЕНИЙ
    /// (поток хука клавиатуры): OUTOFCONTEXT-события доставляются через него.
    /// </summary>
    public void Install()
    {
        _hookFg = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _proc, 0, 0, WINEVENT_OUTOFCONTEXT);
        _hookFocus = SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS, IntPtr.Zero, _proc, 0, 0, WINEVENT_OUTOFCONTEXT);
        if (_hookFg == IntPtr.Zero || _hookFocus == IntPtr.Zero)
            _log($"[fg] WinEvent-хук не установился (err={Marshal.GetLastWin32Error()})");
        // Стартовое состояние — окно, которое уже в фокусе
        Push(GetForegroundWindow());
    }

    private void OnEvent(IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint idEventThread, uint dwmsEventTime)
    {
        // Только фиксируем факт — никакой работы в потоке цикла сообщений
        if (idObject != 0 /*OBJID_WINDOW*/ && eventType == EVENT_SYSTEM_FOREGROUND) return;
        Push(hwnd);
    }

    private void Push(IntPtr hwnd)
    {
        int gen = Interlocked.Increment(ref _generation);
        _work.Add((gen, hwnd));
    }

    private void WorkLoop()
    {
        foreach (var first in _work.GetConsumingEnumerable())
        {
            // Фокус мог смениться несколько раз, пока мы решали — берём последнее,
            // но пароль решаем для КАЖДОГО поколения: лог помечен именно им.
            var items = new List<(int gen, IntPtr hwnd)> { first };
            while (_work.TryTake(out var more)) items.Add(more);

            var last = items[^1];
            try { _process = ProcessNameOf(last.hwnd); }
            catch { _process = ""; }

            bool pwd = IsPasswordFieldFocused();
            foreach (var it in items) _password[it.gen] = pwd;

            // Держим ограниченную историю поколений
            int cutoff = last.gen - 64;
            foreach (var k in _password.Keys)
                if (k < cutoff) _password.TryRemove(k, out _);
        }
    }

    private string ProcessNameOf(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return "";
        GetWindowThreadProcessId(hwnd, out uint pid);
        if (pid == 0) return "";
        lock (_names)
        {
            if (_names.TryGetValue(pid, out var cached)) return cached;
        }
        string name = "";
        try { using var p = Process.GetProcessById((int)pid); name = p.ProcessName; }
        catch { }
        lock (_names)
        {
            if (_names.Count > 256) _names.Clear();
            _names[pid] = name;
        }
        return name;
    }

    private static bool IsPasswordFieldFocused()
    {
        try
        {
            var el = System.Windows.Automation.AutomationElement.FocusedElement;
            return el is not null && (bool)el.GetCurrentPropertyValue(
                System.Windows.Automation.AutomationElement.IsPasswordProperty);
        }
        catch { return false; }
    }

    public void Dispose()
    {
        _work.CompleteAdding();
        if (_hookFg != IntPtr.Zero) UnhookWinEvent(_hookFg);
        if (_hookFocus != IntPtr.Zero) UnhookWinEvent(_hookFocus);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hWinEventHook);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}

/// <summary>
/// Чтение выделенного текста через UI Automation — без буфера обмена.
/// Аналог AX-пути на маке. Работает в Win32 Edit/RichEdit, WPF, UWP, Office,
/// Chromium/Electron с включённой accessibility; где TextPattern нет —
/// возвращает null, и вызывающий уходит в clipboard-фолбэк.
/// </summary>
internal static class UiaText
{
    public static string? ReadSelection()
    {
        try
        {
            var el = System.Windows.Automation.AutomationElement.FocusedElement;
            if (el is null) return null;
            if (!el.TryGetCurrentPattern(System.Windows.Automation.TextPattern.Pattern, out var p)) return null;
            var tp = (System.Windows.Automation.TextPattern)p;
            var ranges = tp.GetSelection();
            if (ranges is null || ranges.Length == 0) return null;
            var sb = new System.Text.StringBuilder();
            foreach (var r in ranges) sb.Append(r.GetText(-1));
            return sb.Length > 0 ? sb.ToString() : null;
        }
        catch { return null; }
    }
}

/// <summary>
/// Кольцевой журнал ввода для «починить выделенное по журналу»: последние
/// нажатия и слова как есть, ничем не сбрасывается. Пишет только поток,
/// который разбирает клавиши; читают снаружи через снимок.
/// </summary>
public sealed class KeyJournal
{
    public enum Kind : byte { Key, Backspace, Boundary, Reset, Word, Replaced }

    public readonly record struct Entry(long Tick, Kind Kind, uint Vk, bool Shift, bool Caps, string? Text);

    private const int Cap = 512;
    private readonly Entry[] _ring = new Entry[Cap];
    private int _next;
    private int _count;
    private readonly object _lock = new();

    public void Add(Kind kind, uint vk = 0, bool shift = false, bool caps = false, string? text = null)
    {
        lock (_lock)
        {
            _ring[_next] = new Entry(Environment.TickCount64, kind, vk, shift, caps, text);
            _next = (_next + 1) % Cap;
            if (_count < Cap) _count++;
        }
    }

    public List<Entry> Snapshot()
    {
        lock (_lock)
        {
            var list = new List<Entry>(_count);
            int start = (_next - _count + Cap) % Cap;
            for (int i = 0; i < _count; i++) list.Add(_ring[(start + i) % Cap]);
            return list;
        }
    }
}
