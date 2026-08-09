using System.Diagnostics;
using System.Runtime.InteropServices;
using QSwitcher.Core;

namespace QSwitcher.App;

/// <summary>
/// Низкоуровневый перехват клавиатуры (WH_KEYBOARD_LL) и буфер текущего слова.
///
/// Уроки macOS-версии, применённые здесь с первого дня:
/// 1. Обработчик хука — в общем конвейере ввода. НИКАКИХ долгих операций
///    внутри: ни запросов к другим процессам, ни ожиданий, ни файловых
///    операций. Иначе встаёт ввод во всей системе.
/// 2. Замена текста (стирание + печать) — строго последовательно, в одном
///    рабочем потоке. Параллельные замены перемешивают события.
/// 3. Клик мыши сбрасывает буфер: курсор уехал, накопленное слово уже не там.
/// 4. Смена раскладки сбрасывает недописанное слово — иначе склейка алфавитов.
/// </summary>
public sealed class KeyboardMonitor : IDisposable
{
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

        _processor = new Thread(ProcessLoop) { IsBackground = true, Name = "QSwitcher.Keys" };
        _processor.Start();

        KeyMap.PrimeLayout();
    }

    private void HookThreadLoop()
    {
        using var process = Process.GetCurrentProcess();
        using var module = process.MainModule!;
        var hModule = GetModuleHandle(module.ModuleName);
        _keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, _keyboardProc, hModule, 0);
        _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, hModule, 0);
        if (_keyboardHook == IntPtr.Zero)
        {
            _log($"❌ Хук не установился: {Marshal.GetLastWin32Error()}");
            return;
        }
        _log("Перехват клавиатуры активен (выделенный поток)");

        // Прокачка сообщений обязательна: низкоуровневый хук работает только
        // в потоке, который её ведёт. Ставить его откуда-то ещё бесполезно.
        while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }

    /// Разбор нажатий вне хука: тут можно и словари, и WinAPI, и лог.
    private void ProcessLoop()
    {
        foreach (var key in _pending.GetConsumingEnumerable())
        {
            try
            {
                if (key.Vk == ManualSwapMarker)
                {
                    ManualSwap(learn: false);
                    continue;
                }
                if (key.Text is not null)
                {
                    // Готовые символы довведённого шлюзом текста — сразу в буфер,
                    // на границе слова они пойдут как есть, без перевода по vk.
                    foreach (char c in key.Text)
                        _word.Add(new Keystroke(0, c.ToString()));
                    continue;
                }
                HandleKeyDown(key.Vk, key.Shift, key.Caps, key.OtherLayout);
            }
            catch (Exception ex) { _log($"[keys] ошибка: {ex.Message}"); }
        }
    }

    private IntPtr KeyboardCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);

        var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);

        // Свои синтетические события пропускаем без обработки.
        if (info.dwExtraInfo == InjectedMarker)
            return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);

        int msg = wParam.ToInt32();

        // Идёт замена — РЕАЛЬНЫЙ ввод в приложение не пропускаем: иначе он
        // вклинится между backspace и печатью замены, и backspace съест свежие
        // буквы (те самые «наслоения» при живой печати). Съедаем, откладываем,
        // довводим после завершения задания — в исходном порядке, через хук,
        // так что нажатия попадут и в буфер слова, и в приложение.
        // Раньше здесь был простой pass-through — ввод летел прямо под backspace,
        // а детектор его вдобавок не видел.
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

    private IntPtr MouseCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32();
            if (msg is WM_LBUTTONDOWN or WM_RBUTTONDOWN)
            {
                // Клик — курсор в другом месте, недописанное слово уже не рядом.
                // Через ту же очередь: буфер принадлежит рабочему потоку.
                _pending.Add(new PendingKey(ResetMarkerVk, false, false, false));
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
    public void RequestManualSwap() =>
        _pending.Add(new PendingKey(ManualSwapMarker, false, false, false));

    private const uint ManualSwapMarker = 0xFFFF_FFFE;

    private bool _shiftDown;
    private bool _capsOn;

    /// Псевдокод «сбросить буфер», приходит от мышиного хука.
    private const uint ResetMarkerVk = 0xFFFF_FFFF;

    /// Маркер «модификатор отпущен» в старших битах кода клавиши.
    private const uint ModifierUpVk = 0xFF00_0000;

    private void HandleKeyDown(uint vk, bool shift, bool caps, bool _unusedLayout)
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
            return;
        }

        if (vk == ResetMarkerVk)
        {
            if (_word.Count > 0) _word.Clear();
            InvalidateHistory("клик мышью");
            return;
        }

        // Модификаторы: следим за тапами, в буфер не идут
        if (HotkeyDetector.IsTrackableModifier(vk))
        {
            Hotkeys?.ModifierDown(vk, shift);
            if (this.Trace) _log($"[trace] нажат модификатор 0x{vk:X2} shift={shift}");
            return;
        }

        // Обычная клавиша — тап отменяется, но может быть сочетанием
        Hotkeys?.OtherKeyPressed();
        var combo = Hotkeys?.ComboPressed(vk, shift);
        if (combo is not null)
        {
            Dispatch(combo.Value);
            return;
        }

        // Навигация и редактирование сбрасывают слово
        switch (vk)
        {
            case 0x25 or 0x26 or 0x27 or 0x28: // стрелки
            case 0x21 or 0x22 or 0x23 or 0x24: // PgUp/PgDn/End/Home
            case 0x2E:                          // Delete
            case 0x1B:                          // Esc
                _word.Clear();
                InvalidateHistory("навигация");
                return;
            case 0x08: // Backspace — убираем последний символ из буфера
                if (_word.Count > 0) _word.RemoveAt(_word.Count - 1);
                return;
        }

        // Границы слова проверяем ДО перевода: пробела, Enter и Tab нет в нашей
        // таблице символов, и раньше функция выходила на пустой строке, так и
        // не завершив слово — буфер копился бесконечно, замена не срабатывала.
        switch (vk)
        {
            case 0x20: OnWordBoundary(new Keystroke(vk, " "));  return;
            case 0x0D: OnWordBoundary(new Keystroke(vk, "\r")); return;
            case 0x09: OnWordBoundary(new Keystroke(vk, "\t")); return;
        }

        // Цифры и всё, чего нет в таблице (F-клавиши, NumPad), слово прерывают
        if (vk is >= 0x30 and <= 0x39 or >= 0x60 and <= 0x69)
        {
            _word.Clear();
            return;
        }

        // Клавиша есть в нашей таблице — значит это часть слова.
        // Символ ещё не вычисляем: он зависит от раскладки, а её мы узнаем
        // один раз на границе слова.
        if (KeyMap.IsWordKey(vk))
        {
            _word.Add(new Keystroke(vk, "", shift, caps));
            return;
        }

        // Всё остальное (знаки препинания вне таблицы, F-клавиши) — граница
        string punct = KeyMap.Translate(vk, false, shift, caps);
        if (punct.Length > 0) OnWordBoundary(new Keystroke(vk, punct));
        else _word.Clear();
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
    private readonly List<(string Text, string Trigger, Lang Lang, DateTime At)> _history = new();

    /// Насколько долго слово считается «рядом с курсором».
    private static readonly TimeSpan HistoryTtl = TimeSpan.FromSeconds(8);

    private void OnWordBoundary(Keystroke trigger)
    {
        if (_word.Count == 0) return;
        if (Paused) { _word.Clear(); return; }
        if (Exclusions.IsExcluded())
        {
            _word.Clear();
            return;
        }

        // Раскладку спрашиваем ОДИН РАЗ на слово, здесь, в рабочем потоке.
        // Дёшево (одно слово вместо каждой буквы) и точно (без отставания кэша).
        bool otherLayout = KeyMap.QueryOtherLayoutActive();
        string text = string.Concat(_word.Select(k =>
            k.Chars.Length > 0 ? k.Chars
                               : KeyMap.Translate(k.VirtualKey, otherLayout, k.Shift, k.Caps)));
        var wordCopy = _word.ToList();
        _word.Clear();
        if (text.Length == 0) return;

        // Язык по содержимому — выбранной раскладке не доверяем, урок мака
        Lang current = text.Any(c => _pair.IsOtherLetter(c)) ? Lang.Other : Lang.Latin;
        var context = _lastWordLang;

        var verdict = _detector.Decide(text, current, context);
        _log($"[word] собрано '{text}' ({wordCopy.Count} клавиш)");
        _log($"[boundary] '{text}' ({current}, ctx={context?.ToString() ?? "nil"}) → {(verdict.ShouldSwap ? "SWITCH" : "keep")} [{verdict.Reason}]");
        SecureLog?.Append(verdict.ShouldSwap && verdict.Replacement is not null
            ? $"{text} → {verdict.Replacement}"
            : text);

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

            if (retro.Count > 0)
            {
                // Стираем цепочку вместе с их разделителями и печатаем заново
                int extra = retro.Sum(r => r.Text.Length + r.Trigger.Length);
                string rebuilt = string.Concat(retro.Select(r => _pair.Swap(r.Text) + r.Trigger));
                _log($"[retro] пересобираю {retro.Count} одиночных: '{rebuilt.Trim()}'");
                _replacer.Enqueue(new ReplaceJob(
                    EraseCount: extra + wordCopy.Count + trigger.Chars.Length,
                    Text: rebuilt + verdict.Replacement,
                    TriggerChar: trigger.Chars,
                    SwitchLayout: switchLayout));
            }
            else
            {
                _replacer.Enqueue(new ReplaceJob(
                    EraseCount: wordCopy.Count + trigger.Chars.Length,
                    Text: verdict.Replacement,
                    TriggerChar: trigger.Chars,
                    SwitchLayout: switchLayout));
            }

            Sounds.Play(switchLayout ? SoundKind.ConvertAndSwitch : SoundKind.ConvertOnly);
        }
        else
        {
            _lastWordLang = current;
            _lastSwitch = null;
            PushHistory(text, trigger.Chars);
            _consecutive = 0;
            _lastTarget = null;
        }
    }

    /// Выполнить действие горячей клавиши.
    private void Dispatch(HotkeyAction action)
    {
        switch (action)
        {
            case HotkeyAction.SwapWord:
                ManualSwap(learn: false);
                break;

            case HotkeyAction.SwapAndLearn:
                ManualSwap(learn: true);
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
    private void SelectionAction(SelectionOp op)
    {
        _replacer.EnqueueSelection(op, text =>
        {
            return op switch
            {
                SelectionOp.Swap => _pair.Swap(text),
                SelectionOp.Case => Transliterator.CycleCase(text),
                SelectionOp.Translit => Transliterator.ToLatin(text),
                _ => text,
            };
        });
    }

    /// Свап последнего завершённого слова. Повтор — свап обратно.
    private void ManualSwap(bool learn = false)
    {
        // Уже свапали это слово — работает ТОГГЛ: возвращаем ровно тот вариант,
        // что был, а не свапаем текущий заново.
        if (_lastSwitch is { } last && (DateTime.UtcNow - last.At).TotalSeconds < 60)
        {
            string from = last.OnScreen, to = last.Other;
            last.ShowingConverted = !last.ShowingConverted;
            _log($"[toggle] '{from}' → '{to}'");

            // Обучение ТОЛЬКО по явной команде. Тоггл сам по себе не учит:
            // человек просто смотрит варианты, и на macOS это раньше
            // переписывало правило на каждом нажатии.
            if (learn) ApplyLearn(to);

            _lastWordLang = LangOf(to);
            _replacer.Enqueue(new ReplaceJob(
                EraseCount: from.Length + last.TriggerChar.Length,
                Text: to,
                TriggerChar: last.TriggerChar,
                SwitchLayout: true));
            // Вернулись к исходному — это откат, звук другой
            Sounds.Play(last.ShowingConverted ? SoundKind.ConvertAndSwitch : SoundKind.Undo);
            return;
        }

        if (_history.Count == 0)
        {
            _log("[manual] нечего свапать");
            return;
        }

        var (text, triggerChar, _, at) = _history[^1];
        if (DateTime.UtcNow - at > HistoryTtl)
        {
            _log("[manual] последнее слово слишком старое — не трогаю");
            _history.Clear();
            return;
        }
        string swapped = _pair.Swap(text);
        _log($"[manual] '{text}' → '{swapped}'{(learn ? " + запомнить" : "")}");
        if (learn) LearnForceConsistent(text, swapped);

        _lastSwitch = new LastSwitch(text, swapped, triggerChar);
        _lastWordLang = LangOf(swapped);
        _replacer.Enqueue(new ReplaceJob(
            EraseCount: text.Length + triggerChar.Length,
            Text: swapped,
            TriggerChar: triggerChar,
            SwitchLayout: true));
        Sounds.Play(SoundKind.ConvertAndSwitch);
    }

    /// Добавить слово в историю (для ретроконверсии и ручного свапа).
    private void PushHistory(string text, string trigger)
    {
        _history.Add((text, trigger, LangOf(text), DateTime.UtcNow));
        if (_history.Count > 12) _history.RemoveAt(0);
    }

    /// Экран изменился не нами — всё, что помним про позицию, недействительно.
    private void InvalidateHistory(string why)
    {
        if (_history.Count == 0 && _lastSwitch is null) return;
        if (this.Trace) _log($"[trace] история сброшена: {why}");
        _history.Clear();
        _lastSwitch = null;
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
        if (_keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(_keyboardHook);
        if (_mouseHook != IntPtr.Zero) UnhookWindowsHookEx(_mouseHook);
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
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG lpMsg);

}
