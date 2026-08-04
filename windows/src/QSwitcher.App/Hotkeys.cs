using System.Text.Json.Serialization;

namespace QSwitcher.App;

/// <summary>Что делает горячая клавиша.</summary>
public enum HotkeyAction
{
    SwapWord,        // свап последнего слова, повтор — обратно
    SwapAndLearn,    // свап + создать правило (единственный способ обучения)
    SwapSelection,   // свап выделенного мышью текста
    ChangeCase,      // циклическая смена регистра выделенного
    Translit,        // транслит выделенного
    TogglePause,     // приостановить/возобновить свитчер
    UndoLast,        // отменить последнее автопереключение
}

/// <summary>
/// Привязка клавиши к действию.
///
/// Два вида:
///  • Tap — нажать и отпустить модификатор, не задев других клавиш. Приём взят
///    с macOS-версии: рука не покидает основную позицию, в отличие от Pause,
///    до которого надо тянуться через всю клавиатуру.
///  • Combo — обычное сочетание модификатор + клавиша.
/// </summary>
public sealed record HotkeyBinding
{
    /// Код клавиши. Для Tap — код самого модификатора (например 0xA3 = правый Ctrl).
    public uint Key { get; init; }

    /// Нужен ли Shift дополнительно.
    public bool Shift { get; init; }

    /// Tap по модификатору вместо обычного сочетания.
    public bool IsTap { get; init; }

    /// Модификатор-держатель для Combo (0 — не нужен).
    public uint Modifier { get; init; }

    [JsonIgnore]
    public string Display
    {
        get
        {
            if (Key == 0) return "—";
            string k = KeyName(Key);
            if (IsTap) return Shift ? $"Shift + тап {k}" : $"тап {k}";
            string m = Modifier != 0 ? KeyName(Modifier) + " + " : "";
            string sh = Shift ? "Shift + " : "";
            return $"{sh}{m}{k}";
        }
    }

    public static string KeyName(uint vk) => vk switch
    {
        0xA0 => "левый Shift",
        0xA1 => "правый Shift",
        0xA2 => "левый Ctrl",
        0xA3 => "правый Ctrl",
        0xA4 => "левый Alt",
        0xA5 => "правый Alt",
        0x13 => "Pause",
        0x1B => "Esc",
        0x14 => "CapsLock",
        0x91 => "ScrollLock",
        >= 0x70 and <= 0x7B => $"F{vk - 0x6F}",
        >= 0x41 and <= 0x5A => ((char)vk).ToString(),
        _ => $"0x{vk:X2}",
    };
}

/// <summary>
/// Набор привязок. Значения по умолчанию подобраны так, чтобы руки не покидали
/// основную позицию: правый Ctrl под мизинцем и почти никем не занят.
///
/// Правый Alt намеренно НЕ используется — это AltGr, он понадобится когда
/// добавим немецкую и испанскую раскладки.
/// </summary>
public sealed class HotkeyMap
{
    public HotkeyBinding SwapWord { get; set; } =
        new() { Key = 0xA3, IsTap = true };                       // тап правый Ctrl

    public HotkeyBinding SwapAndLearn { get; set; } =
        new() { Key = 0xA3, IsTap = true, Shift = true };         // Shift + тап правый Ctrl

    public HotkeyBinding SwapSelection { get; set; } =
        new() { Key = 0xA2, IsTap = true };                       // тап левый Ctrl

    public HotkeyBinding ChangeCase { get; set; } =
        new() { Key = 0x55, Modifier = 0xA3 };                    // правый Ctrl + U

    public HotkeyBinding Translit { get; set; } =
        new() { Key = 0x54, Modifier = 0xA3 };                    // правый Ctrl + T

    public HotkeyBinding TogglePause { get; set; } =
        new() { Key = 0x50, Modifier = 0xA3 };                    // правый Ctrl + P

    public HotkeyBinding UndoLast { get; set; } =
        new() { Key = 0x1B };                                     // Esc

    /// Синоним для мышечной памяти от Punto Switcher.
    public HotkeyBinding SwapWordAlt { get; set; } =
        new() { Key = 0x13 };                                     // Pause

    public IEnumerable<(HotkeyAction action, HotkeyBinding binding, string title)> All()
    {
        yield return (HotkeyAction.SwapWord, SwapWord, "Свап слова / тоггл");
        yield return (HotkeyAction.SwapAndLearn, SwapAndLearn, "Свап и запомнить");
        yield return (HotkeyAction.SwapSelection, SwapSelection, "Свап выделенного");
        yield return (HotkeyAction.ChangeCase, ChangeCase, "Регистр выделенного");
        yield return (HotkeyAction.Translit, Translit, "Транслит выделенного");
        yield return (HotkeyAction.TogglePause, TogglePause, "Пауза свитчера");
        yield return (HotkeyAction.UndoLast, UndoLast, "Отменить переключение");
        yield return (HotkeyAction.SwapWord, SwapWordAlt, "Свап слова (запасная)");
    }

    public void Set(HotkeyAction action, HotkeyBinding b)
    {
        switch (action)
        {
            case HotkeyAction.SwapWord: SwapWord = b; break;
            case HotkeyAction.SwapAndLearn: SwapAndLearn = b; break;
            case HotkeyAction.SwapSelection: SwapSelection = b; break;
            case HotkeyAction.ChangeCase: ChangeCase = b; break;
            case HotkeyAction.Translit: Translit = b; break;
            case HotkeyAction.TogglePause: TogglePause = b; break;
            case HotkeyAction.UndoLast: UndoLast = b; break;
        }
    }
}

/// <summary>
/// Распознаватель тапов по модификатору и обычных сочетаний.
///
/// Тап засчитывается если: модификатор нажали, отпустили быстрее порога, и
/// между нажатием и отпусканием не было ни одной другой клавиши. Логика
/// перенесена с macOS, где она отработала на тысячах нажатий.
/// </summary>
public sealed class HotkeyDetector
{
    private const int TapMaxMs = 300;

    private uint _heldModifier;
    private DateTime _heldSince;
    private bool _contaminated;
    private bool _shiftDuringHold;

    private readonly HotkeyMap _map;
    public HotkeyDetector(HotkeyMap map) => _map = map;

    /// Нажатие модификатора — начинаем следить.
    public void ModifierDown(uint vk, bool shiftNow)
    {
        if (IsShift(vk))
        {
            // Shift — часть жеста «свап и запомнить», а не помеха.
            // На macOS он раньше считался загрязнением, и жест не срабатывал
            // если Shift отпускали раньше Option.
            if (_heldModifier != 0) _shiftDuringHold = true;
            return;
        }
        _heldModifier = vk;
        _heldSince = DateTime.UtcNow;
        _contaminated = false;
        _shiftDuringHold = shiftNow;
    }

    /// Любая обычная клавиша во время удержания — тап отменяется.
    public void OtherKeyPressed()
    {
        if (_heldModifier != 0) _contaminated = true;
    }

    /// Отпускание модификатора. Возвращает действие, если это был тап.
    ///
    /// shiftNow — состояние Shift в момент отпускания. Учитываем И его, и то,
    /// что было при нажатии: иначе Shift засчитывался только если его зажали
    /// ДО тапа, а обратный порядок молча давал обычный свап вместо свапа
    /// с запоминанием.
    public HotkeyAction? ModifierUp(uint vk, bool shiftNow = false)
    {
        if (IsShift(vk)) return null;
        if (_heldModifier != vk) { Reset(); return null; }

        var held = (DateTime.UtcNow - _heldSince).TotalMilliseconds;
        bool wasTap = !_contaminated && held <= TapMaxMs;
        bool shift = _shiftDuringHold || shiftNow;
        Reset();
        if (!wasTap) return null;

        foreach (var (action, b, _) in _map.All())
            if (b.IsTap && b.Key == vk && b.Shift == shift)
                return action;
        return null;
    }

    /// Обычное сочетание: клавиша нажата при удерживаемом модификаторе.
    public HotkeyAction? ComboPressed(uint vk, bool shift)
    {
        foreach (var (action, b, _) in _map.All())
        {
            if (b.IsTap || b.Key != vk) continue;
            if (b.Shift != shift) continue;
            if (b.Modifier != 0 && b.Modifier != _heldModifier) continue;
            if (b.Modifier == 0 && _heldModifier != 0) continue;
            return action;
        }
        return null;
    }

    private void Reset()
    {
        _heldModifier = 0;
        _contaminated = false;
        _shiftDuringHold = false;
    }

    private static bool IsShift(uint vk) => vk is 0x10 or 0xA0 or 0xA1;
    public static bool IsTrackableModifier(uint vk) => vk is 0xA2 or 0xA3 or 0xA4 or 0xA5;
}
