using System.Text;

namespace QSwitcher.App;

/// <summary>
/// Преобразования выделенного текста: регистр и транслит.
/// Перенесено с macOS-версии.
/// </summary>
public static class Transliterator
{
    /// <summary>
    /// Циклическая смена регистра: привет → Привет → ПРИВЕТ → привет.
    /// Работает по всему выделению целиком, а не по каждому слову.
    /// </summary>
    public static string CycleCase(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;

        bool hasLetters = text.Any(char.IsLetter);
        if (!hasLetters) return text;

        bool allLower = text.Where(char.IsLetter).All(char.IsLower);
        bool allUpper = text.Where(char.IsLetter).All(char.IsUpper);

        if (allLower) return CapitalizeFirst(text);
        if (allUpper) return text.ToLowerInvariant();
        return text.ToUpperInvariant();
    }

    private static string CapitalizeFirst(string text)
    {
        var sb = new StringBuilder(text);
        for (int i = 0; i < sb.Length; i++)
        {
            if (char.IsLetter(sb[i]))
            {
                sb[i] = char.ToUpperInvariant(sb[i]);
                break;
            }
        }
        return sb.ToString();
    }

    /// <summary>
    /// Транслитерация кириллицы латиницей по ГОСТ 7.79-2000 (система Б).
    /// привет → privet
    /// </summary>
    public static string ToLatin(string text)
    {
        var sb = new StringBuilder(text.Length * 2);
        foreach (char c in text)
        {
            char lower = char.ToLowerInvariant(c);
            if (Map.TryGetValue(lower, out var repl))
            {
                if (char.IsUpper(c) && repl.Length > 0)
                    sb.Append(char.ToUpperInvariant(repl[0])).Append(repl[1..]);
                else
                    sb.Append(repl);
            }
            else sb.Append(c);
        }
        return sb.ToString();
    }

    private static readonly Dictionary<char, string> Map = new()
    {
        ['а']="a", ['б']="b", ['в']="v", ['г']="g", ['д']="d", ['е']="e", ['ё']="yo",
        ['ж']="zh", ['з']="z", ['и']="i", ['й']="j", ['к']="k", ['л']="l", ['м']="m",
        ['н']="n", ['о']="o", ['п']="p", ['р']="r", ['с']="s", ['т']="t", ['у']="u",
        ['ф']="f", ['х']="h", ['ц']="cz", ['ч']="ch", ['ш']="sh", ['щ']="shh",
        ['ъ']="``", ['ы']="y", ['ь']="`", ['э']="e`", ['ю']="yu", ['я']="ya",
    };
}
