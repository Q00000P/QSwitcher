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
}

/// <summary>
/// Отправка синтетического ввода. ОДИН поток, задания строго по очереди —
/// урок macOS, где параллельные замены съедали текст и роняли процесс.
/// </summary>
public sealed class TextReplacer : IDisposable
{
    private readonly System.Collections.Concurrent.BlockingCollection<ReplaceJob> _queue = new();
    private readonly Thread _worker;
    private readonly Action<string> _log;
    private readonly ushort _otherLangId;

    /// Пауза перед стиранием, миллисекунды. Слишком мало — гонка с доставкой
    /// клавиши-границы, слишком много — человек успевает набрать дальше.
    public int StartDelayMs { get; init; } = 25;
    private void Log(string m) => _log(m);

    public TextReplacer(Action<string> log, ushort otherLangId = 0x0419)
    {
        _log = log;
        _otherLangId = otherLangId;
        _worker = new Thread(WorkLoop) { IsBackground = true, Name = "QSwitcher.Replacer" };
        _worker.Start();
    }

    public void Enqueue(ReplaceJob job) => _queue.Add(job);

    /// Операция над выделенным текстом: копируем, преобразуем, вставляем.
    /// На Windows нет аналога macOS Accessibility API для чтения выделения,
    /// так что буфер обмена — единственный надёжный путь. Содержимое буфера
    /// сохраняем и возвращаем.
    public void EnqueueSelection(KeyboardMonitor.SelectionOp op, Func<string, string> transform)
        => _queue.Add(new ReplaceJob(0, "", "", false) { Selection = (op, transform) });

    /// <summary>
    /// Идёт отправка синтетического ввода.
    ///
    /// Пока true, перехватчик обязан игнорировать ВСЁ. Одной метки
    /// dwExtraInfo оказалось мало: наша же замена возвращалась в обработку,
    /// детектор конвертировал её обратно, и получался бесконечный круг
    /// ('q' → 'й' → 'q' …), засыпающий текст мусором.
    /// </summary>
    public volatile bool Injecting;

    private void WorkLoop()
    {
        foreach (var job in _queue.GetConsumingEnumerable())
        {
            Injecting = true;
            try { Execute(job); }
            catch (Exception ex) { _log($"[replace] ошибка: {ex.Message}"); }
            finally
            {
                // Небольшой хвост: события доходят до приложений с задержкой,
                // и последние из них могут прилететь в хук уже после Execute.
                Thread.Sleep(30);
                Injecting = false;
                // Доввод реального ввода, съеденного хуком во время замены.
                FlushDelayed();
            }
        }
    }

    /// Сколько замен уже отправлено — для диагностики в логе.
    private int _jobCounter;

    private void Execute(ReplaceJob job)
    {
        if (job.Selection is { } sel)
        {
            ExecuteSelection(sel.transform);
            return;
        }

        int id = ++_jobCounter;
        Log($"[replace #{id}] стираю {job.EraseCount}, печатаю '{job.Text}'");

        // Раскладка окна ДО любых наших действий: по ней будут переведены
        // задержанные шлюзом нажатия. После замены раскладка может смениться,
        // а человек жал клавиши ещё при старой — довводить надо её символы.
        _jobLayout = ForegroundLayoutHandle();

        // Пауза перед стиранием. Хук пропускает клавишу-границу дальше и сразу
        // ставит слово в очередь — но приложение может ещё не успеть её
        // обработать. Тогда backspace'ы стирают на символ больше, чем реально
        // напечатано, и текст уезжает назад. Пауза нужна маленькая: она должна
        // покрыть доставку одного события, а не ожидание человека.
        if (StartDelayMs > 0) Thread.Sleep(StartDelayMs);

        // ОДИН вызов SendInput со всем пакетом: backspace'ы + замена + триггер
        // встают в системную очередь атомарно — между ними физически не может
        // вклиниться другой ввод. Паузы между событиями убраны: порядок
        // гарантирует сама очередь, пейсинг лишь растягивал окно гонки.
        var batch = new List<INPUT>(job.EraseCount * 2 + (job.Text.Length + 2) * 2);
        for (int i = 0; i < job.EraseCount; i++)
        {
            batch.Add(VkInput(0x08, false));
            batch.Add(VkInput(0x08, true));
        }
        foreach (char c in job.Text)
        {
            batch.Add(CharInput(c, false));
            batch.Add(CharInput(c, true));
        }

        // Триггер: печатные символы юникодом (код клавиши прогнался бы через
        // текущую раскладку и дал не тот символ), а Enter и Tab — виртуальными
        // клавишами: как юникод они вставляют не перевод строки, а мусор.
        if (job.TriggerChar == "\r") { batch.Add(VkInput(0x0D, false)); batch.Add(VkInput(0x0D, true)); }
        else if (job.TriggerChar == "\t") { batch.Add(VkInput(0x09, false)); batch.Add(VkInput(0x09, true)); }
        else foreach (char c in job.TriggerChar)
        {
            batch.Add(CharInput(c, false));
            batch.Add(CharInput(c, true));
        }

        foreach (char c in job.TailText)
        {
            batch.Add(CharInput(c, false));
            batch.Add(CharInput(c, true));
        }

        uint sent = SendInput((uint)batch.Count, batch.ToArray(), Marshal.SizeOf<INPUT>());
        if (sent != batch.Count)
            Log($"[replace #{id}] отправлено {sent}/{batch.Count} событий (err={Marshal.GetLastWin32Error()})");

        // Раскладку переключаем ПОСЛЕ печати. PostMessage асинхронный, и если
        // делать это раньше, часть символов уходит в старой раскладке, часть
        // в новой — отсюда каша тем сильнее, чем больше набрано.
        if (job.SwitchLayout)
            SwitchForegroundLayout(job.Text);

        Log($"[replace #{id}] готово");
    }

    /// Читаем выделение через Ctrl+C, преобразуем, вставляем через Ctrl+V.
    private void ExecuteSelection(Func<string, string> transform)
    {
        string? saved = null;
        try
        {
            // Сохраняем текущий буфер, чтобы вернуть его человеку
            saved = ClipboardText();

            // ВАЖНО: перед копированием кладём в буфер метку.
            // Если выделения нет, Ctrl+C ничего не меняет, и старое содержимое
            // буфера принимается за «выделенный текст». Именно так в документ
            // однажды влетели команды из терминала, свапнутые в кириллицу.
            const string sentinel = "\u0001QSWITCHER_NO_SELECTION\u0001";
            SetClipboardText(sentinel);
            Thread.Sleep(30);

            SendCombo(0x11 /*Ctrl*/, 0x43 /*C*/);

            // Ждём пока буфер реально изменится, но не дольше 400 мс
            string selected = "";
            for (int i = 0; i < 20; i++)
            {
                Thread.Sleep(20);
                var now = ClipboardText() ?? "";
                if (now != sentinel && now.Length > 0) { selected = now; break; }
            }

            if (selected.Length == 0)
            {
                Log("[selection] выделения нет — ничего не делаю");
                return;
            }

            string result = transform(selected);
            if (result == selected) { Log("[selection] без изменений"); return; }

            SetClipboardText(result);
            Thread.Sleep(40);
            SendCombo(0x11, 0x56 /*V*/);
            Thread.Sleep(120);
            Log($"[selection] '{Trim(selected)}' → '{Trim(result)}'");
        }
        catch (Exception ex) { Log($"[selection] ошибка: {ex.Message}"); }
        finally
        {
            if (saved is not null) { Thread.Sleep(60); SetClipboardText(saved); }
        }
    }

    private static string Trim(string s) => s.Length <= 30 ? s : s[..30] + "…";

    private static string? ClipboardText()
    {
        string? result = null;
        var t = new Thread(() =>
        {
            try { if (Clipboard.ContainsText()) result = Clipboard.GetText(); }
            catch { }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.Start(); t.Join(500);
        return result;
    }

    private static void SetClipboardText(string text)
    {
        var t = new Thread(() =>
        {
            try { Clipboard.SetText(text); } catch { }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.Start(); t.Join(500);
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

    // === Input-gate: реальный ввод, съеденный хуком во время замены ===

    private readonly System.Collections.Concurrent.ConcurrentQueue<(uint Vk, ushort Scan, bool Up, bool Ext, bool Shift, bool Caps)> _delayed = new();
    private const int DelayedCap = 128;

    /// Раскладка окна на момент старта текущего задания (см. Execute).
    private IntPtr _jobLayout;

    /// Довведённый юникодом текст сюда: монитор кладёт его в буфер слова
    /// готовыми символами (сам он эти события не видит — они с маркером).
    public Action<string>? OnReplayedText;

    /// Отложить реальное нажатие. Зовётся из потока LL-хука — только быстрая
    /// постановка в очередь, никакого WinAPI и логов.
    public void DelayRealKey(uint vk, ushort scan, bool up, bool extended, bool shift, bool caps)
    {
        if (_delayed.Count < DelayedCap)
            _delayed.Enqueue((vk, scan, up, extended, shift, caps));
    }

    /// Доввод задержанного. ПЕЧАТНЫЕ клавиши переводим в символы по раскладке
    /// НА МОМЕНТ НАЖАТИЯ (_jobLayout) и шлём юникодом с маркером: замена могла
    /// переключить раскладку, и сканкоды легли бы на экран не теми буквами —
    /// именно так после свапа 'ТД'→'NL' кириллица превращалась в 'z ndjq'.
    /// КОНТРОЛЬНЫЕ (пробел, Enter, backspace, стрелки) от раскладки не зависят —
    /// идут сканкодами БЕЗ маркера, чтобы штатно пройти хук как границы/сбросы.
    /// Вызывать строго ПОСЛЕ Injecting = false.
    private void FlushDelayed()
    {
        if (_delayed.IsEmpty) return;
        var list = new List<INPUT>();
        var replayedText = new System.Text.StringBuilder();
        var unicodeDowns = new HashSet<uint>();

        while (_delayed.TryDequeue(out var k))
        {
            if (k.Up)
            {
                // Пара down этой клавиши ушла юникодом — up уже отправлен с ней
                if (unicodeDowns.Remove(k.Vk)) continue;
                list.Add(RealKeyInput(k.Vk, k.Scan, true, k.Ext));
                continue;
            }

            string s = "";
            if (k.Vk != 0x20) // пробел — всегда сканкодом: это граница слова
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

    /// Клавиша доввода: со скан-кодом и extended-флагом как у оригинала,
    /// dwExtraInfo = 0 — хук обработает её как реальный ввод.
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

        // Раскладки: язык нужного семейства ищем среди установленных
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
    /// синтетические нажатия игнорирует. Именно так терялись backspace'ы:
    /// стирание не происходило, а замена дописывалась следом — 'й' + 'q'
    /// вместо 'q'.
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
    // отбрасывает весь пакет — replacement не печатался именно из-за этого.
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
}
