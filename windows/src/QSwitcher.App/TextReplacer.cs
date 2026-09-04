using System.Runtime.InteropServices;
using System.Text;

namespace QSwitcher.App;

/// <summary>
/// Перевод виртуальной клавиши в символ ПО РАСКЛАДКЕ ОКНА С ФОКУСОМ.
///
/// Урок macOS: встроенные функции берут раскладку своего процесса, и после
/// программного переключения она отстаёт от реальной — буфер копил не те
/// символы десятки секунд. Здесь раскладка каждый раз берётся у потока
/// активного окна (GetKeyboardLayout по его thread id), поэтому расхождение
/// невозможно.
/// </summary>
internal static class KeyTranslator
{
    public static string Translate(uint vk, uint scan, byte[] state, IntPtr layout)
    {
        if (state.Length == 0) return string.Empty;
        if (layout == IntPtr.Zero) layout = GetKeyboardLayout(0);
        if (scan == 0) scan = MapVirtualKeyEx(vk, 0 /*MAPVK_VK_TO_VSC*/, layout);

        var sb = new StringBuilder(8);
        // Флаг 4 (Win10 1607+): не менять состояние клавиатуры — без него
        // ToUnicodeEx ломает dead keys в некоторых раскладках
        int rc = ToUnicodeEx(vk, scan, state, sb, sb.Capacity, 4, layout);
        return rc > 0 ? sb.ToString(0, rc) : string.Empty;
    }

    /// <summary>Текущая раскладка окна с фокусом: true если "другая" (например RU).</summary>
    public static bool ForegroundIsOtherLayout(ushort otherLangId = 0x0419)
    {
        IntPtr hwnd = GetForegroundWindow();
        uint threadId = hwnd != IntPtr.Zero ? GetWindowThreadProcessId(hwnd, out _) : 0;
        IntPtr layout = GetKeyboardLayout(threadId);
        return (ushort)((ulong)layout & 0xFFFF) == otherLangId;
    }

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint idThread);
    [DllImport("user32.dll")] private static extern uint MapVirtualKeyEx(uint uCode, uint uMapType, IntPtr dwhkl);
    [DllImport("user32.dll")]
    private static extern int ToUnicodeEx(uint wVirtKey, uint wScanCode, byte[] lpKeyState,
        StringBuilder pwszBuff, int cchBuff, uint wFlags, IntPtr dwhkl);
}

/// <summary>Задание на замену текста.</summary>
public record ReplaceJob(int EraseCount, string Text, string TriggerChar, bool SwitchLayout)
{
    /// Уже набранный после триггера хвост (цифровой префикс нового слова):
    /// стирается EraseCount'ом вместе со словом и печатается заново после
    /// триггера — иначе свап завершённого слова сносил его с экрана.
    public string TailText { get; init; } = "";

    /// Если задано — это операция над выделением, а не замена набранного.
    public (KeyboardMonitor.SelectionOp op, Func<string, string> transform)? Selection { get; init; }

    /// Для «правого Ctrl по-Punto»: выделения нет → вызвать это (свап набранного).
    /// Выделение ищется ТОЛЬКО через UIA — буфер обмена на каждый тап недопустим.
    public Action? IfNoSelection { get; init; }

    /// Вызывается с выделенным текстом до замены (обучение по выделенному слову).
    public Action<string>? OnSelected { get; init; }
}

/// <summary>
/// Отправка синтетического ввода.
///
/// ДВА ДВИЖКА:
///  • v4 (по умолчанию) — «хук как замок». Замена набранного уходит ОДНИМ
///    вызовом SendInput прямо из потока хука, пока callback ещё не вернулся:
///    всё, что нажато после, физически стоит в очереди позади батча. Ни пауз
///    перед стиранием, ни хвоста, ни гейта — вклиниться некуда.
///  • legacy — прежняя схема: очередь → рабочий поток → пауза → батч → гейт.
///    Оставлена как откат (config.json: "Engine": "legacy").
///
/// Операции над ВЫДЕЛЕНИЕМ на обоих движках идут в рабочем потоке: чтение
/// через UIA (аналог AX на маке), вывод — набором поверх выделения тем же
/// батчем; Ctrl+V и гонка с возвратом буфера обмена убраны совсем.
/// </summary>
public sealed class TextReplacer : IDisposable
{
    private readonly System.Collections.Concurrent.BlockingCollection<ReplaceJob> _queue = new();
    private readonly Thread _worker;
    private readonly Action<string> _log;
    private readonly ushort _otherLangId;

    /// Новый движок: замена набранного выполняется синхронно из хука.
    public bool V4 { get; init; } = true;

    /// ДИАГНОСТИКА: QSWITCHER_NOSWITCH=1 — раскладку после замены не трогать.
    public static readonly bool NoLayoutSwitch =
        Environment.GetEnvironmentVariable("QSWITCHER_NOSWITCH") == "1";

    /// LEGACY: пауза перед стиранием, миллисекунды.
    public int StartDelayMs { get; init; } = 25;
    private void Log(string m) => _log(m);

    public TextReplacer(Action<string> log, ushort otherLangId = 0x0419)
    {
        _log = log;
        _otherLangId = otherLangId;
        _worker = new Thread(WorkLoop) { IsBackground = true, Name = "QSwitcher.Replacer" };
        _worker.Start();
    }

    /// <summary>
    /// Отправить замену набранного. v4 — выполняется НЕМЕДЛЕННО в потоке
    /// вызывающего (хук); legacy — в очередь рабочего потока.
    /// </summary>
    public bool Submit(ReplaceJob job)
    {
        if (!V4) { _queue.Add(job); return true; }
        try { return Execute(job); }
        catch (Exception ex) { _log($"[replace] ошибка: {ex.Message}"); return false; }
    }

    /// Операция над выделенным текстом — всегда в рабочем потоке:
    /// UIA и буфер обмена в хуке недопустимы.
    public void EnqueueSelection(KeyboardMonitor.SelectionOp op, Func<string, string> transform)
        => _queue.Add(new ReplaceJob(0, "", "", false) { Selection = (op, transform) });

    /// <summary>
    /// По-Punto: если есть выделение (по UIA) — преобразовать его, иначе —
    /// выполнить fallback (свап набранного). Буфер обмена здесь не трогается:
    /// это путь тапа правого Ctrl, он срабатывает постоянно.
    /// </summary>
    public void EnqueueSelectionOrElse(Func<string, string> transform, Action fallback, Action<string>? onSelected = null)
        => _queue.Add(new ReplaceJob(0, "", "", false)
        {
            Selection = (KeyboardMonitor.SelectionOp.Swap, transform),
            IfNoSelection = fallback,
            OnSelected = onSelected,
        });

    /// <summary>
    /// LEGACY: идёт отправка синтетического ввода — хук задерживает реальный
    /// ввод. В v4 не поднимается никогда.
    /// </summary>
    public volatile bool Injecting;

    private void WorkLoop()
    {
        foreach (var job in _queue.GetConsumingEnumerable())
        {
            if (job.Selection is { } sel)
            {
                try { ExecuteSelection(sel.transform, job.IfNoSelection, job.OnSelected); }
                catch (Exception ex) { _log($"[selection] ошибка: {ex.Message}"); }
                continue;
            }

            // LEGACY-путь
            Injecting = true;
            try
            {
                _jobLayout = ForegroundLayoutHandle();
                if (StartDelayMs > 0) Thread.Sleep(StartDelayMs);
                Execute(job);
            }
            catch (Exception ex) { _log($"[replace] ошибка: {ex.Message}"); }
            finally
            {
                Thread.Sleep(30);
                Injecting = false;
                FlushDelayed();
            }
        }
    }

    /// Сколько замен уже отправлено — для диагностики в логе.
    private int _jobCounter;

    /// <summary>
    /// Батч замены: backspace'ы + текст + триггер + хвост — ОДИН SendInput.
    /// Порядок внутри гарантирует системная очередь ввода.
    /// </summary>
    private bool Execute(ReplaceJob job)
    {
        int id = ++_jobCounter;
        Log($"[replace #{id}] стираю {job.EraseCount}, печатаю '{job.Text}'"
            + $" (ctrl={(GetAsyncKeyState(0x11) & 0x8000) != 0}, shift={(GetAsyncKeyState(0x10) & 0x8000) != 0}, поток {Thread.CurrentThread.Name})");

        var batch = new List<INPUT>(job.EraseCount * 2 + (job.Text.Length + job.TailText.Length + 2) * 2);
        for (int i = 0; i < job.EraseCount; i++)
        {
            batch.Add(VkInput(0x08, false));
            batch.Add(VkInput(0x08, true));
        }
        AppendText(batch, job.Text);

        // Триггер: пробел/Enter/Tab — виртуальными клавишами (как юникод они
        // дают не то или мусор), остальное — юникодом.
        AppendTrigger(batch, job.TriggerChar);
        AppendText(batch, job.TailText);

        uint sent = SendInput((uint)batch.Count, batch.ToArray(), Marshal.SizeOf<INPUT>());
        if (sent != batch.Count)
        {
            Log($"[replace #{id}] отправлено {sent}/{batch.Count} событий (err={Marshal.GetLastWin32Error()})");
            if (sent == 0) return false;   // ничего не ушло — границу не съедать
        }

        // Раскладку переключаем ПОСЛЕ печати. Батч юникодный и от раскладки не
        // зависит; posted-сообщение приложение обработает раньше своих очередных
        // клавиш — так последующий набор человека уже пойдёт в новой раскладке.
        if (job.SwitchLayout && !NoLayoutSwitch)
            SwitchForegroundLayout(job.Text);

        Log($"[replace #{id}] готово");
        return true;
    }

    /// Текст в батч: печатные — юникодом, переводы строк и табы — клавишами.
    private static void AppendText(List<INPUT> batch, string text)
    {
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (c == '\r')
            {
                batch.Add(VkInput(0x0D, false)); batch.Add(VkInput(0x0D, true));
                if (i + 1 < text.Length && text[i + 1] == '\n') i++;
                continue;
            }
            if (c == '\n') { batch.Add(VkInput(0x0D, false)); batch.Add(VkInput(0x0D, true)); continue; }
            if (c == '\t') { batch.Add(VkInput(0x09, false)); batch.Add(VkInput(0x09, true)); continue; }
            batch.Add(CharInput(c, false));
            batch.Add(CharInput(c, true));
        }
    }

    private static void AppendTrigger(List<INPUT> batch, string trigger)
    {
        switch (trigger)
        {
            case "": return;
            case " ":  batch.Add(VkInput(0x20, false)); batch.Add(VkInput(0x20, true)); return;
            case "\r": batch.Add(VkInput(0x0D, false)); batch.Add(VkInput(0x0D, true)); return;
            case "\t": batch.Add(VkInput(0x09, false)); batch.Add(VkInput(0x09, true)); return;
            default:   AppendText(batch, trigger); return;
        }
    }

    // ==== Выделение ====

    /// Лимит на размер выделения для набора поверх: больше — отказ с логом.
    private const int SelectionCap = 20000;

    /// <summary>
    /// Прочитать выделение, преобразовать, напечатать поверх.
    /// 1) UIA TextPattern — без буфера обмена. 2) Фолбэк: Ctrl+C и проверка,
    ///    что буфер РЕАЛЬНО изменился (номер последовательности буфера, а не
    ///    сравнение содержимого), исходный буфер возвращается сразу после чтения.
    /// Вывод — набором: заменяет выделение в любом поле, Ctrl+V и гонки с
    /// возвратом буфера нет.
    /// </summary>
    private void ExecuteSelection(Func<string, string> transform, Action? ifNoSelection = null, Action<string>? onSelected = null)
    {
        string? selected = UiaText.ReadSelection();
        string source = "UIA";

        if (string.IsNullOrEmpty(selected) && ifNoSelection is not null)
        {
            // По-Punto: выделения (по UIA) нет — свап набранного
            Log("[selection] выделения нет → свап набранного");
            ifNoSelection();
            return;
        }
        if (string.IsNullOrEmpty(selected))
        {
            source = "clipboard";
            selected = ReadSelectionViaClipboard();
        }

        if (string.IsNullOrEmpty(selected))
        {
            Log("[selection] выделения нет — ничего не делаю");
            return;
        }
        if (selected.Length > SelectionCap)
        {
            Log($"[selection] выделение {selected.Length} символов — слишком большое, не трогаю");
            return;
        }

        onSelected?.Invoke(selected);
        string result = transform(selected);
        if (result == selected) { Log($"[selection/{source}] без изменений"); return; }

        // Сочетание (RCtrl+T и т.п.) — человек ещё держит модификатор, а набор
        // под Ctrl превращается в шорткаты. Ждём физического отпускания:
        // это ожидание действия человека, а не гонка по времени.
        WaitModifiersReleased();

        var batch = new List<INPUT>(result.Length * 2 + 4);
        AppendText(batch, result);
        uint sent = SendInput((uint)batch.Count, batch.ToArray(), Marshal.SizeOf<INPUT>());
        if (sent != batch.Count)
            Log($"[selection] отправлено {sent}/{batch.Count} (err={Marshal.GetLastWin32Error()})");
        Log($"[selection/{source}] '{Trim(selected)}' → '{Trim(result)}'");
    }

    /// <summary>
    /// Фолбэк без UIA: Ctrl+C, ждём смены номера последовательности буфера.
    /// Ожидание ограничено сверху как ПРЕДОХРАНИТЕЛЬ ОТКАЗА (не успело —
    /// «выделения нет»), а не как настройка: неправильный результат по
    /// таймингу здесь невозможен, только отсутствие действия.
    /// </summary>
    private string? ReadSelectionViaClipboard()
    {
        string? saved = ClipboardText();
        uint before = GetClipboardSequenceNumber();

        SendCombo(0x11 /*Ctrl*/, 0x43 /*C*/);

        bool changed = false;
        for (int i = 0; i < 160; i++)          // до ~800 мс
        {
            Thread.Sleep(5);
            if (GetClipboardSequenceNumber() != before) { changed = true; break; }
        }
        if (!changed) return null;

        string? selected = ClipboardText();

        // Буфер человека возвращаем СРАЗУ: вставки дальше не будет, гонки нет.
        if (saved is not null) SetClipboardText(saved);
        return selected;
    }

    private static string Trim(string s) => s.Length <= 30 ? s : s[..30] + "…";

    /// Дождаться, пока Ctrl/Alt/Win/Shift физически отпущены (предохранитель 3 с).
    private static void WaitModifiersReleased()
    {
        for (int i = 0; i < 600; i++)
        {
            bool held = false;
            foreach (int vk in new[] { 0x11, 0x12, 0x10, 0x5B, 0x5C })
                if ((GetAsyncKeyState(vk) & 0x8000) != 0) { held = true; break; }
            if (!held) return;
            Thread.Sleep(5);
        }
    }

    private static string? ClipboardText()
    {
        string? result = null;
        var t = new Thread(() =>
        {
            try { if (Clipboard.ContainsText()) result = Clipboard.GetText(); }
            catch { }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.Start(); t.Join(1000);
        return result;
    }

    private bool SetClipboardText(string text)
    {
        bool ok = false;
        var t = new Thread(() =>
        {
            try { Clipboard.SetText(text); ok = true; } catch { }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.Start(); t.Join(1000);
        if (!ok) Log("[selection] не удалось вернуть буфер обмена (занят другим процессом)");
        return ok;
    }

    private void SendCombo(uint modifier, uint key)
    {
        var inputs = new INPUT[4];
        inputs[0] = VkInput(modifier, false);
        inputs[1] = VkInput(key, false);
        inputs[2] = VkInput(key, true);
        inputs[3] = VkInput(modifier, true);
        SendInput(4, inputs, Marshal.SizeOf<INPUT>());
    }

    // === LEGACY input-gate: реальный ввод, съеденный хуком во время замены ===

    private readonly System.Collections.Concurrent.ConcurrentQueue<(uint Vk, ushort Scan, bool Up, bool Ext, bool Shift, bool Caps)> _delayed = new();
    private const int DelayedCap = 128;

    /// LEGACY: раскладка окна на момент старта текущего задания.
    private IntPtr _jobLayout;

    /// LEGACY: довведённый юникодом текст — монитор кладёт его в буфер слова.
    public Action<string>? OnReplayedText;

    /// LEGACY: отложить реальное нажатие (из потока хука).
    public void DelayRealKey(uint vk, ushort scan, bool up, bool extended, bool shift, bool caps)
    {
        if (_delayed.Count < DelayedCap)
            _delayed.Enqueue((vk, scan, up, extended, shift, caps));
    }

    /// LEGACY: доввод задержанного — печатные юникодом по раскладке на момент
    /// нажатия, контрольные сканкодами без маркера.
    private void FlushDelayed()
    {
        if (_delayed.IsEmpty) return;
        var list = new List<INPUT>();
        var replayedText = new StringBuilder();
        var unicodeDowns = new HashSet<uint>();

        while (_delayed.TryDequeue(out var k))
        {
            if (k.Up)
            {
                if (unicodeDowns.Remove(k.Vk)) continue;
                list.Add(RealKeyInput(k.Vk, k.Scan, true, k.Ext));
                continue;
            }

            string s = "";
            if (k.Vk != 0x20)
            {
                var state = new byte[256];
                if (k.Shift) state[0x10] = 0x80;
                if (k.Caps) state[0x14] = 0x01;
                s = KeyTranslator.Translate(k.Vk, k.Scan, state, _jobLayout);
            }

            if (s.Length > 0 && !char.IsControl(s[0]) && s[0] != ' ')
            {
                foreach (char c in s)
                {
                    list.Add(CharInput(c, false));
                    list.Add(CharInput(c, true));
                }
                replayedText.Append(s);
                unicodeDowns.Add(k.Vk);
            }
            else
            {
                list.Add(RealKeyInput(k.Vk, k.Scan, false, k.Ext));
            }
        }

        if (list.Count == 0) return;
        Log($"[gate] доввод {list.Count} событий" +
            (replayedText.Length > 0 ? $", юникодом: '{replayedText}'" : ""));
        uint sent = SendInput((uint)list.Count, list.ToArray(), Marshal.SizeOf<INPUT>());
        if (sent != list.Count)
            Log($"[gate] отправлено {sent}/{list.Count} (err={Marshal.GetLastWin32Error()})");
        if (replayedText.Length > 0)
            OnReplayedText?.Invoke(replayedText.ToString());
    }

    /// Раскладка потока окна с фокусом.
    private static IntPtr ForegroundLayoutHandle()
    {
        IntPtr hwnd = GetForegroundWindow();
        uint threadId = hwnd != IntPtr.Zero ? GetWindowThreadProcessId(hwnd, out _) : 0;
        return GetKeyboardLayout(threadId);
    }

    /// Клавиша доввода (legacy): со скан-кодом как у оригинала, dwExtraInfo = 0.
    private static INPUT RealKeyInput(uint vk, ushort scan, bool up, bool extended) => new()
    {
        type = 1,
        u = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = (ushort)vk,
                wScan = scan,
                dwFlags = (up ? 0x0002u : 0u) | (extended ? 0x0001u : 0u),
                dwExtraInfo = 0,
            }
        }
    };

    /// <summary>
    /// Переключение раскладки активного окна. ActivateKeyboardLayout меняет
    /// раскладку только СВОЕГО потока — для чужого окна нужен
    /// WM_INPUTLANGCHANGEREQUEST.
    /// </summary>
    private void SwitchForegroundLayout(string upcomingText)
    {
        bool wantOther = upcomingText.Any(c =>
            (c >= 'а' && c <= 'я') || (c >= 'А' && c <= 'Я') || c == 'ё' || c == 'Ё');
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return;

        var list = new IntPtr[16];
        int n = GetKeyboardLayoutList(list.Length, list);
        for (int i = 0; i < n; i++)
        {
            ushort lang = (ushort)((ulong)list[i] & 0xFFFF);
            bool isOther = lang == _otherLangId;
            if (isOther == wantOther)
            {
                PostMessage(hwnd, 0x0050 /*WM_INPUTLANGCHANGEREQUEST*/, IntPtr.Zero, list[i]);
                return;
            }
        }
    }

    private static INPUT CharInput(char c, bool up) => new()
    {
        type = 1, // INPUT_KEYBOARD
        u = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = 0,
                wScan = c,
                dwFlags = (uint)(0x0004 /*UNICODE*/ | (up ? 0x0002 /*KEYUP*/ : 0)),
                dwExtraInfo = KeyboardMonitor.InjectedMarker,
            }
        }
    };

    /// Виртуальная клавиша ВМЕСТЕ со скан-кодом.
    ///
    /// Без скан-кода часть приложений (игры, Electron, некоторые поля ввода)
    /// синтетические нажатия игнорирует. Именно так терялись backspace'ы.
    private static INPUT VkInput(uint vk, bool up)
    {
        ushort scan = (ushort)MapVirtualKey(vk, 0 /*MAPVK_VK_TO_VSC*/);
        return new INPUT
        {
            type = 1,
            u = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = (ushort)vk,
                    wScan = scan,
                    dwFlags = up ? 0x0002u : 0u,
                    dwExtraInfo = KeyboardMonitor.InjectedMarker,
                }
            }
        };
    }

    [DllImport("user32.dll")] private static extern uint MapVirtualKey(uint uCode, uint uMapType);

    public void Dispose() => _queue.CompleteAdding();

    // ==== P/Invoke ====

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public InputUnion u; }

    // Объединение ОБЯЗАНО включать MOUSEINPUT: он самый большой (32 байта),
    // и именно по нему Windows считает размер INPUT (40 на x64). С одним
    // KEYBDINPUT размер выходит 32, SendInput видит неверный cbSize и молча
    // отбрасывает весь пакет.
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint idThread);
    [DllImport("user32.dll")] private static extern int GetKeyboardLayoutList(int nBuff, [Out] IntPtr[] lpList);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vKey);
}
