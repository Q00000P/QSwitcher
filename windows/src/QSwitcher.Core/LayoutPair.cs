namespace QSwitcher.Core;

/// <summary>
/// Пара раскладок, между которыми происходит переключение.
///
/// Архитектура сразу под несколько языков: RU↔EN — первая пара, немецкая и
/// испанская добавятся новым экземпляром LayoutPair с своей таблицей
/// соответствий и словарями, без изменения логики детектора.
/// </summary>
public sealed class LayoutPair
{
    /// <summary>Код "первого" языка пары (латинский), например "en".</summary>
    public required string LatinCode { get; init; }

    /// <summary>Код "второго" языка пары, например "ru".</summary>
    public required string OtherCode { get; init; }

    /// <summary>Латинская буква → буква другой раскладки на той же клавише.</summary>
    public required IReadOnlyDictionary<char, char> LatinToOther { get; init; }

    /// <summary>Обратная таблица.</summary>
    public required IReadOnlyDictionary<char, char> OtherToLatin { get; init; }

    /// <summary>
    /// Символы, которые в латинской раскладке — пунктуация, а в другой — буквы.
    /// Для RU: ; [ ] ' ` \ , . дают ж х ъ э ё ё б ю
    /// Такие символы считаются частью слова при детекте.
    /// </summary>
    public required IReadOnlySet<char> LayoutPunct { get; init; }

    /// <summary>Буква принадлежит "другому" алфавиту пары (для RU — кириллица).</summary>
    public required Func<char, bool> IsOtherLetter { get; init; }

    public bool IsLatinLetter(char c) => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z';

    /// <summary>Перевести строку в противоположную раскладку, регистр сохраняется.</summary>
    public string Swap(string text)
    {
        var result = new char[text.Length];
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            char lower = char.ToLowerInvariant(c);
            char mapped;
            if (LatinToOther.TryGetValue(lower, out var toOther))
                mapped = toOther;
            else if (OtherToLatin.TryGetValue(lower, out var toLatin))
                mapped = toLatin;
            else
            {
                result[i] = c;
                continue;
            }
            result[i] = char.IsUpper(c) ? char.ToUpperInvariant(mapped) : mapped;
        }
        return new string(result);
    }

    /// <summary>Стандартная пара RU↔EN (ЙЦУКЕН ↔ QWERTY).</summary>
    public static LayoutPair RuEn()
    {
        // Таблица идентична macOS-версии — раскладки ЙЦУКЕН/QWERTY совпадают
        // на обеих платформах, поэтому словари и списки переносятся как есть.
        var pairs = new (char lat, char other)[]
        {
            ('q','й'),('w','ц'),('e','у'),('r','к'),('t','е'),('y','н'),('u','г'),
            ('i','ш'),('o','щ'),('p','з'),('[','х'),(']','ъ'),
            ('a','ф'),('s','ы'),('d','в'),('f','а'),('g','п'),('h','р'),('j','о'),
            ('k','л'),('l','д'),(';','ж'),('\'','э'),
            ('z','я'),('x','ч'),('c','с'),('v','м'),('b','и'),('n','т'),('m','ь'),
            (',','б'),('.','ю'),('`','ё'),('\\','ё'),
        };
        var latinToOther = new Dictionary<char, char>();
        var otherToLatin = new Dictionary<char, char>();
        foreach (var (lat, other) in pairs)
        {
            latinToOther[lat] = other;
            // ё встречается дважды (` и \) — обратной берём первую
            if (!otherToLatin.ContainsKey(other)) otherToLatin[other] = lat;
        }
        return new LayoutPair
        {
            LatinCode = "en",
            OtherCode = "ru",
            LatinToOther = latinToOther,
            OtherToLatin = otherToLatin,
            LayoutPunct = new HashSet<char> { ';', '[', ']', '\'', '`', '\\', ',', '.' },
            IsOtherLetter = c => (c >= 'а' && c <= 'я') || (c >= 'А' && c <= 'Я') || c == 'ё' || c == 'Ё',
        };
    }
}
