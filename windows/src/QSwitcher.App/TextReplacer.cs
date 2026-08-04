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

        // Пауза перед стиранием. Хук пропускает клавишу-границу дальше и сразу
        // ставит слово в очередь — но приложение может ещё не успеть её
        // обработать. Тогда backspace'ы стирают на символ больше, чем реально
        // напечатано, и текст уезжает назад. Пауза нужна маленькая: она должна
        // покрыть доставку одного события, а не ожидание человека.
        if (StartDelayMs > 0) Thread.Sleep(StartDelayMs);

        SendBackspaces(job.EraseCount);

        // Печатаем замену юникодом — от раскладки не зависит
        SendText(job.Text);

        // Триггер: печатные символы юникодом (код клавиши прогнался бы через
        // текущую раскладку и дал не тот символ), а Enter и Tab — виртуальными
        // клавишами: как юникод они вставляют не перевод строки, а мусор.
        if (job.TriggerChar == "\r") SendVirtualKey(0x0D);
        else if (job.TriggerChar == "\t") SendVirtualKey(0x09);
        else if (job.TriggerChar.Length > 0) SendText(job.TriggerChar);

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

    private void SendBackspaces(int n)
    {
        int failed = 0;
        for (int i = 0; i < n; i++)
        {
            if (!SendVirtualKey(0x08)) failed++;
            Thread.Sleep(3);
        }
        if (failed > 0) Log($"[replace] {failed} из {n} backspace не ушли (err={Marshal.GetLastWin32Error()})");
        // Дать приложению переварить удаление до печати
        Thread.Sleep(5);
    }

    private void SendText(string text)
    {
        foreach (char c in text)
        {
            var inputs = new INPUT[2];
            inputs[0] = CharInput(c, false);
            inputs[1] = CharInput(c, true);
            SendInput(2, inputs, Marshal.SizeOf<INPUT>());
            Thread.Sleep(2);
        }
    }

    private bool SendVirtualKey(uint vk)
    {
        var inputs = new INPUT[2];
        inputs[0] = VkInput(vk, false);
        inputs[1] = VkInput(vk, true);
        return SendInput(2, inputs, Marshal.SizeOf<INPUT>()) == 2;
    }

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
    [DllImport("user32.dll")] private static extern int GetKeyboardLayoutList(int nBuff, [Out] IntPtr[] lpList);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
