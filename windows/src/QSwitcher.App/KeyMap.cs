using System.Runtime.InteropServices;

namespace QSwitcher.App;

/// <summary>
/// Свой перевод виртуальной клавиши в символ — БЕЗ ToUnicodeEx и GetKeyboardState.
///
/// Зачем: системный перевод из потока хука врёт. GetKeyboardState возвращает
/// состояние очереди СВОЕГО потока, а не реальное, и GetKeyboardLayout не всегда
/// отдаёт раскладку целевого окна. В логах это выглядело так: человек набирает
/// 'и' в русской раскладке, а буфер получает 'B' — латиницу, да ещё заглавную.
/// Ровно та же болезнь была на macOS с keyboardGetUnicodeString.
///
/// Здесь таблица VK → (латинский символ, символ другой раскладки) задана явно,
/// а состояние Shift и Caps отслеживается по событиям хука. Результат
/// детерминированный и от системы не зависит.
/// </summary>
internal static class KeyMap
{
    /// <summary>VK → (латиница, кириллица) для основного блока клавиатуры.</summary>
    private static readonly Dictionary<uint, (char lat, char oth)> Table = new()
    {
        // Буквенный ряд
        [0x51] = ('q','й'), [0x57] = ('w','ц'), [0x45] = ('e','у'), [0x52] = ('r','к'),
        [0x54] = ('t','е'), [0x59] = ('y','н'), [0x55] = ('u','г'), [0x49] = ('i','ш'),
        [0x4F] = ('o','щ'), [0x50] = ('p','з'),
        [0x41] = ('a','ф'), [0x53] = ('s','ы'), [0x44] = ('d','в'), [0x46] = ('f','а'),
        [0x47] = ('g','п'), [0x48] = ('h','р'), [0x4A] = ('j','о'), [0x4B] = ('k','л'),
        [0x4C] = ('l','д'),
        [0x5A] = ('z','я'), [0x58] = ('x','ч'), [0x43] = ('c','с'), [0x56] = ('v','м'),
        [0x42] = ('b','и'), [0x4E] = ('n','т'), [0x4D] = ('m','ь'),

        // OEM-клавиши: в латинской раскладке пунктуация, в русской буквы
        [0xDB] = ('[','х'),   // OEM_4
        [0xDD] = (']','ъ'),   // OEM_6
        [0xBA] = (';','ж'),   // OEM_1
        [0xDE] = ('\'','э'),  // OEM_7
        [0xBC] = (',','б'),   // OEM_COMMA
        [0xBE] = ('.','ю'),   // OEM_PERIOD
        [0xC0] = ('`','ё'),   // OEM_3
    };

    /// <summary>Символы, которые меняются при Shift в ЛАТИНСКОЙ раскладке.</summary>
    private static readonly Dictionary<char, char> LatinShift = new()
    {
        ['['] = '{', [']'] = '}', [';'] = ':', ['\''] = '"',
        [','] = '<', ['.'] = '>', ['`'] = '~',
    };

    /// <summary>
    /// Перевести клавишу. otherLayout — активна ли «другая» раскладка (RU).
    /// Возвращает пустую строку для клавиш вне таблицы.
    /// </summary>
    public static string Translate(uint vk, bool otherLayout, bool shift, bool caps)
    {
        if (!Table.TryGetValue(vk, out var pair)) return string.Empty;

        char c = otherLayout ? pair.oth : pair.lat;
        bool upper = shift ^ caps;

        if (char.IsLetter(c))
            return upper ? char.ToUpperInvariant(c).ToString() : c.ToString();

        // Пунктуация: Caps не влияет, только Shift
        if (shift && !otherLayout && LatinShift.TryGetValue(c, out var shifted))
            return shifted.ToString();
        if (shift && otherLayout && char.IsLetter(c))
            return char.ToUpperInvariant(c).ToString();
        return c.ToString();
    }

    /// <summary>
    /// Активна ли «другая» раскладка в окне с фокусом.
    ///
    /// КРИТИЧНО: отдаёт КЭШ и никогда не ходит в WinAPI синхронно.
    /// Раньше здесь на каждое нажатие шли три обращения к чужому процессу
    /// (окно → его поток → его раскладка), прямо внутри хука. При быстром
    /// наборе хук переставал успевать, и Windows молча снимал его —
    /// одиночные нажатия проходили, а поток букв пропадал целиком.
    /// </summary>
    public static bool IsOtherLayoutActive()
    {
        var now = Environment.TickCount64;
        if (now - _layoutCheckedAt > 300 && !_layoutRefreshing)
        {
            _layoutRefreshing = true;
            ThreadPool.QueueUserWorkItem(_ => RefreshLayout());
        }
        return _otherLayoutActive;
    }

    private const ushort OtherLangId = 0x0419;   // русская
    private static volatile bool _otherLayoutActive;
    private static volatile bool _layoutRefreshing;
    private static long _layoutCheckedAt;

    private static void RefreshLayout()
    {
        try
        {
            IntPtr hwnd = GetForegroundWindow();
            if (hwnd != IntPtr.Zero)
            {
                uint tid = GetWindowThreadProcessId(hwnd, out _);
                IntPtr hkl = GetKeyboardLayout(tid);
                _otherLayoutActive = (ushort)((ulong)hkl & 0xFFFF) == OtherLangId;
            }
        }
        catch { }
        finally
        {
            _layoutCheckedAt = Environment.TickCount64;
            _layoutRefreshing = false;
        }
    }

    /// Обновить раскладку немедленно (при старте).
    public static void PrimeLayout() => RefreshLayout();

    /// <summary>
    /// Синхронный запрос раскладки. Вызывать ТОЛЬКО из рабочего потока —
    /// в хуке это убивает перехват. Раз на слово стоит копейки.
    /// </summary>
    public static bool QueryOtherLayoutActive()
    {
        try
        {
            IntPtr hwnd = GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return _otherLayoutActive;
            uint tid = GetWindowThreadProcessId(hwnd, out _);
            IntPtr hkl = GetKeyboardLayout(tid);
            bool result = (ushort)((ulong)hkl & 0xFFFF) == OtherLangId;
            _otherLayoutActive = result;
            return result;
        }
        catch { return _otherLayoutActive; }
    }

    /// <summary>Клавиша даёт букву (в любой из двух раскладок).</summary>
    public static bool IsWordKey(uint vk) => Table.ContainsKey(vk);

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint idThread);
}
