using System.Diagnostics;
using System.Runtime.InteropServices;
using QSwitcher.Core;

namespace QSwitcher.App;

/// <summary>
/// Низкоуровневый перехват клавиатуры (WH_KEYBOARD_LL) и буфер текущего слова.
///
/// ДВИЖОК 4.0 — «хук как замок». Пока callback хука не вернулся, система не
/// отдаёт никому следующие события ввода — они стоят в очереди за ним. Этим
/// и пользуемся: решение о свапе принимается прямо в хуке (словари в памяти,
/// микросекунды), клавиша-граница СЪЕДАЕТСЯ, а батч «backspace'ы + текст +
/// граница» уходит одним SendInput до возврата из callback'а. Всё, что нажато
/// после, физически стоит позади батча — вклиниться некуда. Ни пауз, ни
/// гейта, ни флага «идёт замена»: гонка с собственным вводом устранена
/// порядком очереди, а не таймингами.
///
/// Цена: из хука уходит всё, что ходит в чужой процесс или на диск. Имя
/// процесса и поле пароля — из ForegroundTracker (по событиям), звук/лог/
/// защищённый лог — через очереди, правила — отложенная запись.
/// Сторож: если поток хука замирал (GC, стоп-мир), хук переустанавливается —
/// Windows снимает медленные хуки молча и навсегда.
///
/// Прежний движок (очередь → рабочий поток → пауза → батч → гейт) оставлен
/// целиком как откат: config.json "Engine": "legacy".
/// </summary>
public sealed class KeyboardMonitor : IDisposable
{
    /// Новый движок (замена из хука). false — legacy.
    public bool EngineV4 { get; init; } = true;

    /// Слежение за фокусом по событиям; ставится в потоке хука.
    public ForegroundTracker? Foreground { get; init; }

    /// Кольцевой журнал ввода (для починки по журналу).
    public KeyJournal Journal { get; } = new();

    /// Отпускание этой клавиши съесть: её нажатие ушло в батче (граница).
    private uint _eatUpVk;

    /// Поток хука — сюда шлём внешние команды (свап из трея).
    private uint _hookThreadId;
    private const uint WM_QS_MANUAL_SWAP = 0x8000 + 1;   // WM_APP+1
    private const uint WM_QS_ACTION = 0x8000 + 2;        // WM_APP+2, wParam = HotkeyAction
    private const uint WM_TIMER = 0x0113;
    private nuint _watchdogTimerId;
    private long _lastTimerTick;
    private long _slowestCallbackMs;
    private const int WH_KEYBOARD_LL = 13;
    private const int WH_MOUSE_LL = 14;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYUP = 0x0105;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_RBUTTONDOWN = 0x0204;

    private readonly LowLevelProc _keyboardProc;
    private readonly LowLevelProc _mouseProc;
    private IntPtr _keyboardHook = IntPtr.Zero;
    private IntPtr _mouseHook = IntPtr.Zero;

    private readonly List<Keystroke> _word = new();
    private readonly Detector _detector;
    private readonly LearnedRules _learned;

    /// Звуки и проверка исключений.
    public required SoundPlayerService Sounds { get; init; }
    public required AppExclusions Exclusions { get; init; }

    /// Защищённый лог истории набора.
    public SecureLog? SecureLog { get; init; }
    private readonly LayoutPair _pair;
    private readonly Action<string> _log;

    /// <summary>Отправка замен — отдельный поток, строго последовательный.</summary>
    private readonly TextReplacer _replacer;

    /// <summary>Свои синтетические события помечены, чтобы не обрабатывать их же.</summary>
    internal const nuint InjectedMarker = 0x51535749; // "QSWI"

    /// Пассивный режим: хук стоит, но события не разбираются.
    /// Для изоляции — ломает ли чужие хоткеи установка хука или наша работа.
    public bool Passive { get; init; }

    public record Keystroke(uint VirtualKey, string Chars, bool Shift = false, bool Caps = false);

    /// Сырое нажатие, каким его увидел хук. Разбирается уже в рабочем потоке.
    private record PendingKey(uint Vk, bool Shift, bool Caps, bool OtherLayout, string? Text = null);

    private readonly System.Collections.Concurrent.BlockingCollection<PendingKey> _pending = new();
    private Thread? _processor;

    public KeyboardMonitor(Detector detector, LayoutPair pair, TextReplacer replacer,
                           LearnedRules learned, Action<string> log)
    {
        _detector = detector;
        _learned = learned;
        _pair = pair;
        _replacer = replacer;
        // Довведённые шлюзом юникод-символы идут с маркером и мимо хука —
        // реплейсер отдаёт их сюда, чтобы буфер слова их не терял.
        _replacer.OnReplayedText = s =>
            _pending.Add(new PendingKey(0, false, false, false, s));
        _log = log;
        _keyboardProc = KeyboardCallback;
        _mouseProc = MouseCallback;
    }

    private Thread? _hookThread;

    public void Start()
    {
        // Хук живёт в СВОЁМ потоке со своей прокачкой сообщений.
        // Если ставить его в главный WinForms-поток, любая задержка UI
        // (открытый flyout трея, меню) подвешивает прокачку — а вместе с ней
        // ввод во всей системе: хоткеи чужих программ переставали работать,
        // пока открыт трей.
        _hookThread = new Thread(HookThreadLoop) { IsBackground = true, Name = "QSwitcher.Hook" };
        _hookThread.SetApartmentState(ApartmentState.STA);
        _hookThread.Start();

        if (!EngineV4)
        {
            _processor = new Thread(ProcessLoop) { IsBackground = true, Name = "QSwitcher.Keys" };
            _processor.Start();
        }

        KeyMap.PrimeLayout();
    }

    private IntPtr _hModule;

    private bool InstallHooks()
    {
        _keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, _keyboardProc, _hModule, 0);
        _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, _hModule, 0);
        if (_keyboardHook == IntPtr.Zero)
        {
            _log($"❌ Хук не установился: {Marshal.GetLastWin32Error()}");
            return false;
        }
        return true;
    }

    private void RemoveHooks()
    {
        if (_keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(_keyboardHook);
        if (_mouseHook != IntPtr.Zero) UnhookWindowsHookEx(_mouseHook);
        _keyboardHook = IntPtr.Zero;
        _mouseHook = IntPtr.Zero;
    }

    /// <summary>
    /// Переустановить хук. Windows снимает LL-хук молча, если поток не
    /// ответил за LowLevelHooksTimeout (300 мс); проверить «жив ли хук» API
    /// не даёт. Поэтому при любом признаке замирания потока — переставляем:
    /// снятие несуществующего хука безвредно, а живой просто перевешивается.
    /// </summary>
    private void Rehook(string why)
    {
        RemoveHooks();
        bool ok = InstallHooks();
        _log($"[hook] переустановлен ({why}){(ok ? "" : " — НЕУДАЧНО")}");
    }

    private void HookThreadLoop()
    {
        using (var process = Process.GetCurrentProcess())
        using (var module = process.MainModule!)
            _hModule = GetModuleHandle(module.ModuleName);
        _hookThreadId = GetCurrentThreadId();

        if (!InstallHooks()) return;
        _log($"Перехват клавиатуры активен (выделенный поток, движок {(EngineV4 ? "v4" : "legacy")})");

        // Слежение за фокусом живёт здесь же: OUTOFCONTEXT-события WinEvent
        // приходят через цикл сообщений установившего потока.
        try { Foreground?.Install(); }
        catch (Exception ex) { _log($"[fg] трекер не поднялся: {ex.Message}"); }

        // Сторож: секундный таймер. Если между двумя тиками прошло заметно
        // больше секунды — поток замирал, хук мог быть снят системой.
        // Таймер без окна: идентификатор выдаёт система (nIDEvent игнорируется)
        _watchdogTimerId = SetTimer(IntPtr.Zero, 0, 1000, IntPtr.Zero);
        _lastTimerTick = Environment.TickCount64;

        // Прокачка сообщений обязательна: низкоуровневый хук работает только
        // в потоке, который её ведёт. Ставить его откуда-то ещё бесполезно.
        while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            if (msg.message == WM_QS_MANUAL_SWAP)
            {
                try { ManualSwap(learn: msg.wParam != 0); }
                catch (Exception ex) { _log($"[keys] ошибка: {ex.Message}"); }
                continue;
            }
            if (msg.message == WM_QS_ACTION)
            {
                if (Trace) _log($"[trace] действие {(HotkeyAction)(uint)msg.wParam} (из очереди потока хука)");
                try { DispatchNow((HotkeyAction)(uint)msg.wParam); }
                catch (Exception ex) { _log($"[keys] ошибка: {ex.Message}"); }
                continue;
            }
            if (msg.message == WM_TIMER && msg.hwnd == IntPtr.Zero && msg.wParam == _watchdogTimerId)
            {
                long now = Environment.TickCount64;
                long gap = now - _lastTimerTick;
                _lastTimerTick = now;
                if (gap > 1350) Rehook($"поток замирал {gap - 1000} мс");
                continue;
            }
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }

    /// <summary>
    /// Разбор одного события из хука. В v4 — синхронно, прямо в callback'е;
    /// в legacy — через очередь рабочего потока. Возвращает true, если
    /// нажатие надо СЪЕСТЬ (его роль выполнил батч).
    /// </summary>
    private bool Submit(PendingKey key)
    {
        if (EngineV4) return ProcessKey(key);
        _pending.Add(key);
        return false;
    }

    private bool ProcessKey(PendingKey key)
    {
        try
        {
            if (key.Vk is ManualSwapMarker or ManualLearnMarker)
            {
                ManualSwap(learn: key.Vk == ManualLearnMarker);
                return false;
            }
            if (key.Text is not null)
            {
                // LEGACY: готовые символы довведённого шлюзом текста — сразу в буфер
                foreach (char c in key.Text)
                    _word.Add(new Keystroke(0, c.ToString()));
                return false;
            }
            return HandleKeyDown(key.Vk, key.Shift, key.Caps, key.OtherLayout);
        }
        catch (Exception ex) { _log($"[keys] ошибка: {ex.Message}"); return false; }
    }

    /// Разбор нажатий вне хука: тут можно и словари, и WinAPI, и лог.
    /// LEGACY: разбор нажатий в отдельном потоке.
    private void ProcessLoop()
    {
        foreach (var key in _pending.GetConsumingEnumerable())
            ProcessKey(key);
    }

    private IntPtr KeyboardCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);

        var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);

        int msg = wParam.ToInt32();

        // Свои синтетические события пропускаем без обработки.
        if (info.dwExtraInfo == InjectedMarker)
        {
            if (Trace) _log($"[trace] inj {(msg is WM_KEYUP or WM_SYSKEYUP ? "up  " : "down")} vk=0x{info.vkCode:X2} scan=0x{info.scanCode:X2} flags=0x{info.flags:X2}");
            return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
        }
        if (Trace && (info.flags & 0x10) != 0)
            _log($"[trace] чужой инжект {(msg is WM_KEYUP or WM_SYSKEYUP ? "up  " : "down")} vk=0x{info.vkCode:X2} extra=0x{(ulong)info.dwExtraInfo:X}");

        // v4: весь разбор здесь, синхронно. Меряем длительность — сторожу
        // и для диагностики: медленный callback = риск снятия хука.
        if (EngineV4)
        {
            long t0 = Stopwatch.GetTimestamp();
            bool eat = HandleHookEventV4(msg, in info);
            long ms = (Stopwatch.GetTimestamp() - t0) * 1000 / Stopwatch.Frequency;
            if (ms > _slowestCallbackMs)
            {
                _slowestCallbackMs = ms;
                if (ms >= 20) _log($"[hook] медленный callback: {ms} мс (vk=0x{info.vkCode:X2})");
            }
            if (ms >= 250) Rehook($"callback {ms} мс");
            return eat ? (IntPtr)1 : CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
        }

        // ===== LEGACY ниже =====

        // Идёт замена — РЕАЛЬНЫЙ ввод в приложение не пропускаем: иначе он
        // вклинится между backspace и печатью замены, и backspace съест свежие
        // буквы (те самые «наслоения» при живой печати). Съедаем, откладываем,
        // довводим после завершения задания — в исходном порядке, через хук,
        // так что нажатия попадут и в буфер слова, и в приложение.
        if (_replacer.Injecting)
        {
            // Инжектированные события (LLKHF_INJECTED ставит сама система для
            // любого SendInput) пропускаем: это наши с потерявшейся меткой —
            // раньше из-за них замена уходила в детектор по второму кругу.
            // Задерживаем только ввод с реальной клавиатуры.
            bool injected = (info.flags & 0x10) != 0;
            if (!injected && msg is WM_KEYDOWN or WM_SYSKEYDOWN or WM_KEYUP or WM_SYSKEYUP)
            {
                // Shift трекаем и здесь (идемпотентно), иначе задержанная буква
                // уйдёт без признака регистра. Caps не трогаем: его toggle
                // сработает при довводе самого события.
                bool isUp = msg is WM_KEYUP or WM_SYSKEYUP;
                if (info.vkCode is 0x10 or 0xA0 or 0xA1) _shiftDown = !isUp;
                _replacer.DelayRealKey(info.vkCode, (ushort)info.scanCode,
                    up: isUp,
                    extended: (info.flags & 0x01) != 0,
                    shift: _shiftDown, caps: _capsOn);
                return (IntPtr)1;
            }
            return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
        }

        if (msg is WM_KEYUP or WM_SYSKEYUP)
        {
            if (HotkeyDetector.IsTrackableModifier(info.vkCode))
                _pending.Add(new PendingKey(ModifierUpVk | info.vkCode, _shiftDown, _capsOn, false));
            // Флаг сбрасываем ПОСЛЕ постановки в очередь: иначе отпускание
            // Ctrl, пришедшее сразу за отпусканием Shift, теряет признак.
            if (info.vkCode is 0x10 or 0xA0 or 0xA1) _shiftDown = false;
            return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
        }
        if (msg is WM_KEYDOWN or WM_SYSKEYDOWN)
        {
            if (Passive) return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);

            uint vk = info.vkCode;
            // Shift и Caps считаем САМИ по событиям: GetKeyboardState из потока
            // хука возвращает состояние своей очереди, а не реальное.
            if (vk is 0x10 or 0xA0 or 0xA1) { _shiftDown = true; }
            if (vk == 0x14) { _capsOn = !_capsOn; }

            // Ctrl и Alt пропускаем дальше: на них висят тапы.
            bool isTrackable = HotkeyDetector.IsTrackableModifier(vk);
            bool isNoise = !isTrackable &&
                (vk is 0x10 or 0xA0 or 0xA1 or 0x11 or 0x12 or 0x14 or 0x5B or 0x5C);
            if (!isNoise)
            {
                // Раскладку здесь НЕ спрашиваем: обращения к чужому процессу
                // на каждое нажатие убивают хук. Она выясняется один раз
                // на слово, в рабочем потоке.
                _pending.Add(new PendingKey(vk, _shiftDown, _capsOn, false));
            }
        }
        return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
    }

    /// <summary>
    /// v4: разбор события хука прямо в callback'е. Возвращает true — съесть.
    /// Съедается только граница слова, чьё нажатие ушло в батче замены,
    /// и её же отпускание.
    /// </summary>
    private bool HandleHookEventV4(int msg, in KBDLLHOOKSTRUCT info)
    {
        uint vk = info.vkCode;

        if (msg is WM_KEYUP or WM_SYSKEYUP)
        {
            if (_eatUpVk != 0 && vk == _eatUpVk)
            {
                _eatUpVk = 0;
                return true;
            }
            if (HotkeyDetector.IsTrackableModifier(vk))
                Submit(new PendingKey(ModifierUpVk | vk, _shiftDown, _capsOn, false));
            // Флаг сбрасываем ПОСЛЕ разбора: иначе отпускание Ctrl сразу за
            // отпусканием Shift теряет признак.
            if (vk is 0x10 or 0xA0 or 0xA1) _shiftDown = false;
            return false;
        }

        if (msg is WM_KEYDOWN or WM_SYSKEYDOWN)
        {
            if (Passive) return false;

            // Shift и Caps считаем САМИ по событиям: GetKeyboardState из потока
            // хука возвращает состояние своей очереди, а не реальное.
            if (vk is 0x10 or 0xA0 or 0xA1) { _shiftDown = true; }
            if (vk == 0x14) { _capsOn = !_capsOn; }

            bool isTrackable = HotkeyDetector.IsTrackableModifier(vk);
            bool isNoise = !isTrackable &&
                (vk is 0x10 or 0xA0 or 0xA1 or 0x11 or 0x12 or 0x14 or 0x5B or 0x5C);
            if (isNoise) return false;

            bool eat = Submit(new PendingKey(vk, _shiftDown, _capsOn, false));
            if (eat) _eatUpVk = vk;
            return eat;
        }
        return false;
    }

    private IntPtr MouseCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32();
            if (msg is WM_LBUTTONDOWN or WM_RBUTTONDOWN)
            {
                // Клик — курсор в другом месте, недописанное слово уже не рядом.
                // v4: мышиный хук в том же потоке, разбираем сразу; legacy — очередь.
                Submit(new PendingKey(ResetMarkerVk, false, false, false));
            }
        }
        return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    /// Подробный лог каждой клавиши. Включается QSWITCHER_TRACE=1.
    public bool Trace { get; init; }

    /// Распознаватель тапов и сочетаний.
    public HotkeyDetector? Hotkeys { get; init; }

    /// Свитчер на паузе — автозамена не работает, хоткеи работают.
    public bool Paused { get; private set; }

    /// Пауза из меню трея (раньше пункт «Пауза» был TODO и ничего не делал).
    public void TogglePause()
    {
        Paused = !Paused;
        _log(Paused ? "⏸ Свитчер на паузе (меню)" : "▶ Свитчер активен (меню)");
    }

    /// Свап последнего слова из меню трея. Через очередь — ManualSwap
    /// работает с состоянием processing-потока, из UI его звать нельзя.
    public void RequestManualSwap() => RequestManual(learn: false);

    private void RequestManualLearnSwap() => RequestManual(learn: true);

    private void RequestManual(bool learn)
    {
        if (EngineV4 && _hookThreadId != 0)
            PostThreadMessage(_hookThreadId, WM_QS_MANUAL_SWAP, (UIntPtr)(learn ? 1u : 0u), IntPtr.Zero);
        else
            _pending.Add(new PendingKey(learn ? ManualLearnMarker : ManualSwapMarker, false, false, false));
    }

    private const uint ManualSwapMarker = 0xFFFF_FFFE;
    private const uint ManualLearnMarker = 0xFFFF_FFFD;

    /// Цифровой префикс, набранный вплотную перед текущим словом ('10' перед
    /// 'ю0ю0ю1' в IP). Ручной свап конвертирует его вместе со словом — как
    /// Punto: '10ю0ю0ю1' → '10.0.0.1'. Живёт строго вместе с _word.
    private string _droppedPrefix = "";
    /// Префикс последнего завершённого слова (для ручного свапа задним числом).
    private string _lastCompletedPrefix = "";
    private const int PrefixCap = 32;

    private bool _shiftDown;
    private bool _capsOn;

    /// Псевдокод «сбросить буфер», приходит от мышиного хука.
    private const uint ResetMarkerVk = 0xFFFF_FFFF;

    /// Маркер «модификатор отпущен» в старших битах кода клавиши.
    private const uint ModifierUpVk = 0xFF00_0000;

    /// Разбор нажатия. Возвращает true, если нажатие надо съесть (v4: граница
    /// слова ушла в батче замены).
    private bool HandleKeyDown(uint vk, bool shift, bool caps, bool _unusedLayout)
    {
        if (this.Trace)
        {
            _log($"[trace] vk=0x{vk:X2} shift={shift} (буфер {_word.Count})");
        }

        // Отпускание модификатора: может оказаться тапом
        if ((vk & ModifierUpVk) == ModifierUpVk && vk != ResetMarkerVk)
        {
            uint real = vk & 0xFF;
            var tap = Hotkeys?.ModifierUp(real, shift);
            if (this.Trace) _log($"[trace] отпущен модификатор 0x{real:X2} shift={shift} → тап: {tap?.ToString() ?? "нет"}");
            if (tap is not null) Dispatch(tap.Value);
            return false;
        }

        if (vk == ResetMarkerVk)
        {
            if (_word.Count > 0) _word.Clear();
            _droppedPrefix = "";
            InvalidateHistory("клик мышью");
            Journal.Add(KeyJournal.Kind.Reset);
            return false;
        }

        // Модификаторы: следим за тапами, в буфер не идут
        if (HotkeyDetector.IsTrackableModifier(vk))
        {
            Hotkeys?.ModifierDown(vk, shift);
            if (this.Trace) _log($"[trace] нажат модификатор 0x{vk:X2} shift={shift}");
            return false;
        }

        // Обычная клавиша — тап отменяется, но может быть сочетанием
        Hotkeys?.OtherKeyPressed();
        var combo = Hotkeys?.ComboPressed(vk, shift);
        if (combo is not null)
        {
            Dispatch(combo.Value);
            return false;
        }

        // Навигация и редактирование сбрасывают слово
        switch (vk)
        {
            case 0x25 or 0x26 or 0x27 or 0x28: // стрелки
            case 0x21 or 0x22 or 0x23 or 0x24: // PgUp/PgDn/End/Home
            case 0x2E:                          // Delete
            case 0x1B:                          // Esc
                _word.Clear();
                _droppedPrefix = "";
                InvalidateHistory("навигация");
                Journal.Add(KeyJournal.Kind.Reset, vk);
                return false;
            case 0x08: // Backspace — убираем последний символ из буфера
                if (_word.Count > 0) _word.RemoveAt(_word.Count - 1);
                else if (_droppedPrefix.Length > 0)
                    _droppedPrefix = _droppedPrefix[..^1];
                Journal.Add(KeyJournal.Kind.Backspace, vk);
                return false;
        }

        // Границы слова проверяем ДО перевода: пробела, Enter и Tab нет в нашей
        // таблице символов, и раньше функция выходила на пустой строке, так и
        // не завершив слово — буфер копился бесконечно, замена не срабатывала.
        switch (vk)
        {
            case 0x20: return OnWordBoundary(new Keystroke(vk, " "));
            case 0x0D: return OnWordBoundary(new Keystroke(vk, "\r"));
            case 0x09: return OnWordBoundary(new Keystroke(vk, "\t"));
        }

        // Цифры: внутри слова ('ю0ю0ю1' в IP-адресе) — часть слова, кладём
        // готовым символом (цифры от раскладки не зависят). Перед словом —
        // копим как префикс, чтобы ручной свап конвертировал его вместе со
        // словом ('10ю0ю0ю1' → '10.0.0.1', как Punto). Раньше любая цифра
        // просто стирала буфер и IP-кейс был мёртв.
        // Shift+цифра верхнего ряда — знак, зависящий от раскладки: как раньше, граница.
        if (vk is >= 0x30 and <= 0x39 && !shift || vk is >= 0x60 and <= 0x69)
        {
            char digit = (char)('0' + (int)(vk <= 0x39 ? vk - 0x30 : vk - 0x60));
            bool bufferHasLetters = _word.Count > 0 && _word.Any(k =>
                k.Chars.Length == 0 || k.Chars.Any(char.IsLetter));
            if (bufferHasLetters)
                _word.Add(new Keystroke(vk, digit.ToString(), shift, caps));
            else if (_droppedPrefix.Length < PrefixCap)
                _droppedPrefix += digit;
            Journal.Add(KeyJournal.Kind.Key, vk, shift, caps);
            return false;
        }
        if (vk is >= 0x30 and <= 0x39)
        {
            // Shift+цифра — знак, зависящий от раскладки: '3$' в RU дало '3;'.
            // Если слово с буквами уже набирается — как раньше, сброс.
            // Иначе знак — часть набора: кладём кейкодом, ручной свап переведёт
            // его через противоположную раскладку (';' → '$').
            bool lettersInWord = _word.Any(k => k.Chars.Length == 0 || k.Chars.Any(char.IsLetter));
            if (lettersInWord) { _word.Clear(); _droppedPrefix = ""; }
            else _word.Add(new Keystroke(vk, "", shift, caps));
            Journal.Add(KeyJournal.Kind.Key, vk, shift, caps);
            return false;
        }

        // Клавиша есть в нашей таблице — значит это часть слова.
        // Символ ещё не вычисляем: он зависит от раскладки, а её мы узнаем
        // один раз на границе слова.
        if (KeyMap.IsWordKey(vk))
        {
            _word.Add(new Keystroke(vk, "", shift, caps));
            Journal.Add(KeyJournal.Kind.Key, vk, shift, caps);
            return false;
        }

        // Всё остальное (знаки препинания вне таблицы, F-клавиши) — граница
        string punct = KeyMap.Translate(vk, false, shift, caps);
        if (punct.Length > 0) return OnWordBoundary(new Keystroke(vk, punct));
        _word.Clear(); _droppedPrefix = "";
        Journal.Add(KeyJournal.Kind.Reset, vk);
        return false;
    }

    private Lang? _lastWordLang;

    /// Сколько слов подряд сконвертировано в одну сторону.
    /// Раскладку переключаем только при подтверждённой смене языка: разовая
    /// вставка ('NL' посреди русского текста) текст исправит, но раскладку
    /// не тронет — как на macOS.
    private int _consecutive;
    private Lang? _lastTarget;

    /// 0 — не переключать никогда, 1 — сразу, 2 — после двух подряд.
    public int SwitchLayoutAfter { get; init; } = 2;

    /// Последнее завершённое слово, как оно сейчас выглядит на экране,
    /// и клавиша-граница после него. Для ручного свапа по Pause.
    /// Состояние последнего свапа для тоггла.
    ///
    /// Хранит ОБА варианта и то, какой сейчас на экране. Раньше хранился только
    /// текущий текст, и повторный тап свапал его заново — для несимметричных
    /// случаев результат отличался от исходного.
    private sealed record LastSwitch(string Original, string Converted, string TriggerChar)
    {
        public bool ShowingConverted { get; set; } = true;
        public string OnScreen => ShowingConverted ? Converted : Original;
        public string Other => ShowingConverted ? Original : Converted;
        public DateTime At { get; } = DateTime.UtcNow;
    }

    private LastSwitch? _lastSwitch;

    /// Недавно завершённые слова — для ретроконверсии цепочки одиночных букв.
    ///
    /// КРИТИЧНО: история отражает то, что СЕЙЧАС стоит на экране слева от
    /// курсора. Любое событие, после которого это перестаёт быть правдой —
    /// клик мышью, стрелки, Esc, ручной свап, пауза между словами — историю
    /// обнуляет. Без этого ретроконверсия пересобирала слова из прошлых
    /// сеансов поверх текущего текста: одно набранное 'й' превращалось
    /// в 'q q q', съедая соседние символы.
    private readonly List<(string Text, string Trigger, Lang Lang, DateTime At, IReadOnlyList<Keystroke>? Keys)> _history = new();

    /// Насколько долго слово считается «рядом с курсором».
    private static readonly TimeSpan HistoryTtl = TimeSpan.FromSeconds(8);

    /// Граница слова. Возвращает true, если клавишу-границу надо съесть:
    /// в v4 она уходит в батче замены вместе с текстом.
    private bool OnWordBoundary(Keystroke trigger)
    {
        if (_word.Count == 0) { Journal.Add(KeyJournal.Kind.Boundary, trigger.VirtualKey, text: trigger.Chars); return false; }
        if (Paused) { _word.Clear(); _droppedPrefix = ""; return false; }
        if (Exclusions.IsExcluded())
        {
            _word.Clear();
            _droppedPrefix = "";
            return false;
        }

        // Раскладку спрашиваем ОДИН РАЗ на слово. Это системный вызов
        // (окно → поток → раскладка), не обращение к процессу окна.
        bool otherLayout = KeyMap.QueryOtherLayoutActive();
        string text = string.Concat(_word.Select(k =>
            k.Chars.Length > 0 ? k.Chars
                               : KeyMap.Translate(k.VirtualKey, otherLayout, k.Shift, k.Caps)));
        var wordCopy = _word.ToList();
        _word.Clear();
        // Слово завершено — его префикс переезжает к завершённому слову,
        // чтобы ручной свап задним числом конвертировал их вместе.
        _lastCompletedPrefix = _droppedPrefix;
        _droppedPrefix = "";
        if (text.Length == 0) return false;

        Journal.Add(KeyJournal.Kind.Word, trigger.VirtualKey, text: text);
        Journal.Add(KeyJournal.Kind.Boundary, trigger.VirtualKey, text: trigger.Chars);

        // Язык по содержимому — выбранной раскладке не доверяем, урок мака
        Lang current = text.Any(c => _pair.IsOtherLetter(c)) ? Lang.Other : Lang.Latin;
        // Контекст — большинство по буквам трёх последних слов, как на маке.
        // По одному последнему слову 'US' в русской фразе давал ctx=Latin, и щит
        // коротких слов молча съедал 'rfr' (как).
        var context = ComputeContext() ?? _lastWordLang;

        // Сети — три последних слова как они на экране (ближайшее первым) и
        // процесс, где идёт ввод. Историю ветка перевода строки уже сбросила,
        // так что контекст не перетекает из прошлого сообщения.
        var recent = new List<string>(3);
        for (int i = _history.Count - 1; i >= 0 && recent.Count < 3; i--) recent.Add(_history[i].Text);
        var verdict = _detector.Decide(text, current, context, recent, Foreground?.ProcessName);
        _log($"[word] собрано '{text}' ({wordCopy.Count} клавиш)");
        _log($"[boundary] '{text}' ({current}, ctx={context?.ToString() ?? "nil"}) → {(verdict.ShouldSwap ? "SWITCH" : "keep")} [{verdict.Reason}]");
        SecureLog?.Append(verdict.ShouldSwap && verdict.Replacement is not null
            ? $"{text} → {verdict.Replacement}"
            : text);

        // Enter/Tab — конец строки/поля: то, что было слева, уже не «рядом
        // с курсором» (в чате сообщение ушло). Ретро и ручной свап через
        // перевод строки склеивали текст в мусор ('м↵…').
        bool lineBreak = trigger.Chars is "\r" or "\t";

        if (verdict.ShouldSwap && verdict.Replacement is not null)
        {
            _lastWordLang = verdict.Replacement.Any(c => _pair.IsOtherLetter(c)) ? Lang.Other : Lang.Latin;
            _lastSwitch = new LastSwitch(text, verdict.Replacement, trigger.Chars);

            // Ретроконверсия: одиночные буквы перед словом почти наверняка
            // набраны в той же неверной раскладке ('z ,skf' → 'я была').
            // Сами по себе они неоднозначны, но раз следующее слово уверенно
            // свапнулось — сомнений больше нет.
            var retro = RetroChain(_lastWordLang!.Value);

            PushHistory(verdict.Replacement, trigger.Chars);
            var target = _lastWordLang!.Value;
            if (_lastTarget == target) _consecutive++;
            else { _lastTarget = target; _consecutive = 1; }

            bool switchLayout = SwitchLayoutAfter > 0 && _consecutive >= SwitchLayoutAfter;
            if (!switchLayout)
                _log($"[layout] раскладку не трогаем ({_consecutive}/{SwitchLayoutAfter} подряд)");

            // v4: граница ещё НЕ дошла до приложения (мы её съедаем), стирать
            // её не надо — батч напечатает её сам. legacy: граница уже
            // прошла, стираем вместе со словом.
            int triggerErase = EngineV4 ? 0 : trigger.Chars.Length;

            ReplaceJob job;
            if (retro.Count > 0)
            {
                // Стираем цепочку вместе с их разделителями и печатаем заново
                int extra = retro.Sum(r => r.Text.Length + r.Trigger.Length);
                string rebuilt = string.Concat(retro.Select(r => _pair.Swap(r.Text) + r.Trigger));
                _log($"[retro] пересобираю {retro.Count} одиночных: '{rebuilt.Trim()}'");
                job = new ReplaceJob(
                    EraseCount: extra + wordCopy.Count + triggerErase,
                    Text: rebuilt + verdict.Replacement,
                    TriggerChar: trigger.Chars,
                    SwitchLayout: switchLayout);
            }
            else
            {
                job = new ReplaceJob(
                    EraseCount: wordCopy.Count + triggerErase,
                    Text: verdict.Replacement,
                    TriggerChar: trigger.Chars,
                    SwitchLayout: switchLayout);
            }
            Journal.Add(KeyJournal.Kind.Replaced, text: job.Text);
            bool sentOk = _replacer.Submit(job);

            Sounds.Play(switchLayout ? SoundKind.ConvertAndSwitch : SoundKind.ConvertOnly);
            if (lineBreak) InvalidateHistory("перевод строки");
            // v4: батч ушёл — граница уже напечатана им, физическую съедаем
            return EngineV4 && sentOk;
        }
        else
        {
            _lastWordLang = current;
            _lastSwitch = null;
            PushHistory(text, trigger.Chars, wordCopy);
            _consecutive = 0;
            _lastTarget = null;
            if (lineBreak) InvalidateHistory("перевод строки");
            return false;
        }
    }

    /// <summary>
    /// Выполнить действие горячей клавиши.
    ///
    /// v4: НЕ из callback'а. Тап срабатывает на отпускании модификатора, и
    /// батч, отправленный прямо из callback'а этого отпускания, приходит в
    /// приложение раньше, чем оно узнало, что Ctrl отпущен: Electron видел
    /// Ctrl+Backspace (стирал слово целиком) и Ctrl+буквы (тоггл панели).
    /// Поэтому действие откладывается сообщением в поток хука — оно
    /// выполнится сразу ПОСЛЕ того, как отпускание ушло дальше по цепочке.
    /// Автосвап это не касается: он идёт с пробела, модификаторов там нет.
    /// </summary>
    private void Dispatch(HotkeyAction action)
    {
        if (EngineV4 && _hookThreadId != 0)
        {
            PostThreadMessage(_hookThreadId, WM_QS_ACTION, (UIntPtr)(uint)action, IntPtr.Zero);
            return;
        }
        DispatchNow(action);
    }

    private void DispatchNow(HotkeyAction action)
    {
        switch (action)
        {
            // По-Punto: есть выделение — свапается оно, нет — набранное/последнее.
            // Проверка выделения (UIA) идёт в рабочем потоке реплейсера, а свап
            // набранного возвращается сюда сообщением — хук не ждёт чужой процесс.
            case HotkeyAction.SwapWord:
                _replacer.EnqueueSelectionOrElse(SelectionSwapText, RequestManualSwap);
                break;

            case HotkeyAction.SwapAndLearn:
                _replacer.EnqueueSelectionOrElse(SelectionSwapText, RequestManualLearnSwap, selected =>
                {
                    // Выделено одно слово — учим его (как Shift+тап по набранному)
                    string w = selected.Trim();
                    if (w.Length > 0 && !w.Any(char.IsWhiteSpace) && w.Any(char.IsLetter))
                    {
                        LearnForceConsistent(w, _pair.Swap(w));
                        _log($"[learn] по выделению: '{w}' → переключать");
                    }
                });
                break;

            case HotkeyAction.SwapSelection:
                SelectionAction(SelectionOp.Swap);
                break;

            case HotkeyAction.ChangeCase:
                SelectionAction(SelectionOp.Case);
                break;

            case HotkeyAction.Translit:
                SelectionAction(SelectionOp.Translit);
                break;

            case HotkeyAction.TogglePause:
                Paused = !Paused;
                _log(Paused ? "⏸ Свитчер на паузе" : "▶ Свитчер активен");
                break;

            case HotkeyAction.UndoLast:
                if (_lastSwitch is not null) ManualSwap(learn: false);
                break;
        }
    }

    public enum SelectionOp { Swap, Case, Translit }

    /// Операции над выделенным текстом — через буфер обмена.
    /// На Windows нет аналога Accessibility API для чтения выделения,
    /// поэтому единственный надёжный путь: Ctrl+C, обработать, Ctrl+V.
    /// <summary>Последний свап выделения — для обратимости. Из одного знака не
    /// узнать, EN-клавиша это '.' или RU-клавиша '/': '/' → '.' верно, но '.' → 'ю'
    /// уже не назад. Выделено ровно то, что мы выдали — возвращаем исходник.</summary>
    private (string From, string To)? _lastSelSwap;

    private string SelectionSwapText(string text)
    {
        // Сравниваем по обрезанному: через Ctrl+C текст приходит с хвостом
        // ('\r\n', пробел) в некоторых редакторах — хвост сохраняем, ядро меняем.
        string core = text.Trim();
        if (_lastSelSwap is { } last && core.Length > 0 && last.To.Trim() == core)
        {
            string back = text.Replace(core, last.From.Trim());
            _lastSelSwap = (text, back);
            _log($"[selection] обратно к исходнику: '{Vis(text)}' → '{Vis(back)}'");
            return back;
        }
        string result = _pair.SwapSelection(text, KeyMap.QueryOtherLayoutActive());
        _lastSelSwap = (text, result);
        _log($"[selection] '{Vis(text)}' → '{Vis(result)}'");
        return result;
    }

    private static string Vis(string s) => s.Replace("\r", "\\r").Replace("\n", "\\n").Replace("\t", "\\t");

    /// <summary>Язык контекста по трём последним словам: считаем буквы, нужно
    /// хотя бы две; равенство — неизвестно (паритет с computeContext() мака).</summary>
    private Lang? ComputeContext()
    {
        int oth = 0, lat = 0;
        for (int i = _history.Count - 1, n = 0; i >= 0 && n < 3; i--, n++)
            foreach (char c in _history[i].Text)
            {
                if (_pair.IsOtherLetter(c)) oth++;
                else if (_pair.IsLatinLetter(c)) lat++;
            }
        if (oth + lat < 2) return null;
        if (oth > lat) return Lang.Other;
        if (lat > oth) return Lang.Latin;
        return null;
    }

    private void SelectionAction(SelectionOp op)
    {
        _replacer.EnqueueSelection(op, text =>
        {
            return op switch
            {
                SelectionOp.Swap => SelectionSwapText(text),
                SelectionOp.Case => Transliterator.CycleCase(text),
                SelectionOp.Translit => Transliterator.ToLatin(text),
                _ => text,
            };
        });
    }

    /// Свап последнего завершённого слова. Повтор — свап обратно.
    private void ManualSwap(bool learn = false)
    {
        // Текущий незавершённый набор. Критерий — меняет ли его КЕЙКОДНЫЙ
        // свап: '3,3' (numpad-точка в RU) → '3.3' меняет — свапаем БУФЕР;
        // чистое '3' свап не меняет — это ХВОСТ: при свапе завершённого слова
        // его нужно стереть вместе со словом и вернуть на место, иначе
        // стирание сносило его («гит 3» превращалось в «гubn»).
        string tail = "";
        string bufFull = "", bufSwapped = "";
        if (_word.Count > 0 || _droppedPrefix.Length > 0)
        {
            bool otherT = KeyMap.QueryOtherLayoutActive();
            string bufT = string.Concat(_word.Select(k =>
                k.Chars.Length > 0 ? k.Chars
                                   : KeyMap.Translate(k.VirtualKey, otherT, k.Shift, k.Caps)));
            bufFull = _droppedPrefix + bufT;
            // Свап ПО КЕЙКОДАМ через противоположную раскладку, а не по
            // символьной карте: знак по символу неоднозначен (';' — 'ж' в EN
            // против Shift+4 в RU), по кейкоду — однозначен ('3;' → '3$').
            // Готовые символы (цифры, доввод) свапаются посимвольно.
            bufSwapped = _droppedPrefix + string.Concat(_word.Select(k =>
                k.Chars.Length > 0 ? _pair.Swap(k.Chars)
                                   : KeyMap.SwapKey(k.VirtualKey, otherT, k.Shift, k.Caps)));
            if (bufSwapped == bufFull) tail = bufFull;
        }

        // Набор со ЗНАКАМИ, который свап не меняет — не трогаем ничего:
        // каскад к предыдущему слову портил соседний текст. Каскад разрешён
        // только чисто цифровому хвосту («гит 3» — намерение однозначно).
        if (tail.Length > 0 && !tail.All(char.IsDigit))
        {
            _log($"[manual] набор '{tail}' свап не меняет — ничего не делаю");
            return;
        }

        // 1. Буфер есть и его свап что-то меняет — свапаем буфер
        // (вместе с цифровым префиксом: '10ю0ю0ю1' → '10.0.0.1', как Punto).
        if (bufFull.Length > 0 && tail.Length == 0)
        {
            string full = bufFull;
            string swappedFull = bufSwapped;
            string bufText = _droppedPrefix.Length > 0 ? full[_droppedPrefix.Length..] : full;
            _word.Clear();
            _droppedPrefix = "";
            _log($"[manual-buf] '{full}' → '{swappedFull}'{(learn ? " + запомнить" : "")}");
            if (learn && bufText.Any(char.IsLetter))
                LearnForceConsistent(bufText, _pair.Swap(bufText)); // учим слово (с буквами), не префикс
            _lastSwitch = new LastSwitch(full, swappedFull, "");
            _lastWordLang = LangOf(swappedFull);
            _replacer.Submit(new ReplaceJob(
                EraseCount: full.Length,
                Text: swappedFull,
                TriggerChar: "",
                SwitchLayout: true));
            Sounds.Play(SoundKind.ConvertAndSwitch);
            return;
        }

        // 2. Уже свапали это слово — работает ТОГГЛ: возвращаем ровно тот вариант,
        // что был, а не свапаем текущий заново.
        if (_lastSwitch is { } last && (DateTime.UtcNow - last.At).TotalSeconds < 60)
        {
            string from = last.OnScreen, to = last.Other;
            last.ShowingConverted = !last.ShowingConverted;
            _log($"[toggle] '{from}' → '{to}'" + (tail.Length > 0 ? $" (хвост '{tail}')" : ""));

            // Обучение ТОЛЬКО по явной команде. Тоггл сам по себе не учит:
            // человек просто смотрит варианты, и на macOS это раньше
            // переписывало правило на каждом нажатии.
            if (learn) ApplyLearn(to);

            _lastWordLang = LangOf(to);
            _replacer.Submit(new ReplaceJob(
                EraseCount: from.Length + last.TriggerChar.Length + tail.Length,
                Text: to,
                TriggerChar: last.TriggerChar,
                SwitchLayout: true) { TailText = tail });
            // Вернулись к исходному — это откат, звук другой
            Sounds.Play(last.ShowingConverted ? SoundKind.ConvertAndSwitch : SoundKind.Undo);
            return;
        }

        if (_history.Count == 0)
        {
            _log("[manual] нечего свапать");
            return;
        }

        var (text, triggerChar, _, at, histKeys) = _history[^1];
        if (DateTime.UtcNow - at > HistoryTtl)
        {
            _log("[manual] последнее слово слишком старое — не трогаю");
            _history.Clear();
            return;
        }
        string fullText = _lastCompletedPrefix + text;
        string swapped;
        if (histKeys is not null)
        {
            // По кейкодам: точный перевод знаков (см. буферную ветку выше).
            // Направление — от текущей раскладки: между набором и свапом её
            // обычно не меняли.
            bool otherNow = KeyMap.QueryOtherLayoutActive();
            swapped = _lastCompletedPrefix + string.Concat(histKeys.Select(k =>
                k.Chars.Length > 0 ? _pair.Swap(k.Chars)
                                   : KeyMap.SwapKey(k.VirtualKey, otherNow, k.Shift, k.Caps)));
        }
        else swapped = _pair.Swap(fullText);
        _log($"[manual] '{fullText}' → '{swapped}'{(learn ? " + запомнить" : "")}"
            + (tail.Length > 0 ? $" (хвост '{tail}')" : ""));
        if (learn) LearnForceConsistent(text, _pair.Swap(text)); // учим слово, не префикс

        _lastSwitch = new LastSwitch(fullText, swapped, triggerChar);
        _lastWordLang = LangOf(swapped);
        _replacer.Submit(new ReplaceJob(
            EraseCount: fullText.Length + triggerChar.Length + tail.Length,
            Text: swapped,
            TriggerChar: triggerChar,
            SwitchLayout: true) { TailText = tail });
        Sounds.Play(SoundKind.ConvertAndSwitch);
    }

    /// Добавить слово в историю (для ретроконверсии и ручного свапа).
    private void PushHistory(string text, string trigger, IReadOnlyList<Keystroke>? keys = null)
    {
        _history.Add((text, trigger, LangOf(text), DateTime.UtcNow, keys));
        if (_history.Count > 12) _history.RemoveAt(0);
    }

    /// Экран изменился не нами — всё, что помним про позицию, недействительно.
    private void InvalidateHistory(string why)
    {
        if (_history.Count == 0 && _lastSwitch is null) return;
        if (this.Trace) _log($"[trace] история сброшена: {why}");
        _history.Clear();
        _lastSwitch = null;
        _lastCompletedPrefix = "";
    }

    /// Цепочка одиночных букв непосредственно перед текущим словом,
    /// набранных НЕ в целевом языке. Возвращается в порядке набора.
    /// Насколько далеко назад тянуть ретроконверсию.
    /// 0 — выключено, иначе максимум букв в цепочке. По умолчанию без ограничений
    /// по смыслу: подхватываются любые одиночные буквы «не того» языка.
    public int RetroMaxChain { get; init; } = 4;

    /// Требовать, чтобы свап давал осмысленный предлог. По умолчанию НЕТ:
    /// ограничение убирает полезные случаи чаще, чем спасает от лишних.
    public bool RetroPrepositionsOnly { get; init; }

    private static readonly HashSet<string> RetroPrepositions = new()
    { "а", "и", "в", "к", "с", "о", "у", "я", "б", "ж" };

    /// Одиночные буквы, являющиеся словами своего языка, — ретро их не трогает.
    private static readonly HashSet<string> ValidSingles = new()
    { "а", "и", "в", "к", "с", "о", "у", "я", "a", "i" };

    /// Цепочка одиночных букв перед текущим словом, набранных не в целевом
    /// языке. Раз следующее слово уверенно свапнулось — почти наверняка они
    /// набраны там же по ошибке.
    private List<(string Text, string Trigger, Lang Lang)> RetroChain(Lang target)
    {
        if (RetroMaxChain <= 0) return new();

        var chain = new List<(string, string, Lang)>();
        var now = DateTime.UtcNow;
        for (int i = _history.Count - 1; i >= 0; i--)
        {
            var h = _history[i];
            // Слишком давно — курсор мог уехать куда угодно
            if (now - h.At > HistoryTtl) break;
            if (h.Text.Length != 1 || !char.IsLetter(h.Text[0])) break;
            if (h.Lang == target) break;
            // Через перевод строки/таб не тянем: текст за ним уже не рядом
            if (h.Trigger is "\r" or "\t") break;
            // Одиночная буква, которая сама по себе валидное слово своего языка
            // («и», «я», «в», английские a/i), набранная в СВОЕЙ раскладке —
            // не ошибка раскладки, а слово. По логу: «х и ву» → «[ b du»,
            // «я днс» → «z lyc» — ретро тащило за ложным свапом честные слова.
            if (ValidSingles.Contains(h.Text.ToLowerInvariant())) break;

            if (RetroPrepositionsOnly)
            {
                string sw = _pair.Swap(h.Text).ToLowerInvariant();
                if (!RetroPrepositions.Contains(sw)) break;
            }

            chain.Insert(0, (h.Text, h.Trigger, h.Lang));
            if (chain.Count >= RetroMaxChain) break;
        }
        if (chain.Count > 0) _history.RemoveRange(_history.Count - chain.Count, chain.Count);
        return chain;
    }

    /// Запомнить решение по тому, что сейчас на экране.
    private void ApplyLearn(string onScreen)
    {
        if (_lastSwitch is not { } l) return;
        // Показан конвертированный — значит свапать надо; показан исходный —
        // значит не надо. Правило пишем на ИСХОДНОЕ слово.
        if (onScreen == l.Converted) LearnForceConsistent(l.Original, l.Converted);
        else _learned.LearnStop(l.Original);
    }

    /// <summary>
    /// Создать правило «переключать», убрав встречное.
    ///
    /// Правила 'й → q' и 'q → й' одновременно дают качели: что ни набери,
    /// оно перевернётся, а ретроконверсия растащит это на соседние слова.
    /// Раз человек сказал «й должно становиться q», то обратное правило
    /// заведомо неверно и снимается.
    /// </summary>
    private void LearnForceConsistent(string word, string swapped)
    {
        _learned.LearnForce(word);
        if (!string.Equals(swapped, word, StringComparison.OrdinalIgnoreCase))
        {
            _learned.Remove(swapped);
            _log($"[learn] встречное правило для '{swapped}' снято");
        }
    }

    private Lang LangOf(string s) =>
        s.Any(c => _pair.IsOtherLetter(c)) ? Lang.Other : Lang.Latin;

    public void Dispose()
    {
        _pending.CompleteAdding();
        RemoveHooks();
    }

    // ==== P/Invoke ====

    private delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd; public uint message; public nuint wParam; public nint lParam;
        public uint time; public int ptX; public int ptY;
    }

    [DllImport("user32.dll")] private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint idThread, uint msg, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern nuint SetTimer(IntPtr hWnd, nuint nIDEvent, uint uElapse, IntPtr lpTimerFunc);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG lpMsg);

}
