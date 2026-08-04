namespace QSwitcher.Core;

/// <summary>
/// Язык слова в терминах пары раскладок.
/// </summary>
public enum Lang { Latin, Other }

/// <summary>
/// Результат решения детектора.
/// </summary>
public readonly record struct Verdict(bool ShouldSwap, string? Replacement, string Reason);

/// <summary>
/// Детектор ошибочной раскладки. Перенесён с macOS-версии (Swift) правило в
/// правило — та логика выстрадана на десятках реальных багов, и повторять
/// этот путь на второй платформе нет смысла.
///
/// Решение по приоритету:
///   0. forceWords / stopWords из конфига, затем выученные правила
///   1. Слово смешанных алфавитов → нормализация
///   2. Слово валидно в текущем языке → не трогаем
///      (для 2–3 букв — по частотным спискам, полный словарь там бесполезен)
///   3. Свап целиком в плохих триггерах → SWAP
///   4. Свап — валидное слово другого языка → SWAP
///   5. Ничего не подошло → не трогаем
/// </summary>
public sealed class Detector
{
    private readonly LayoutPair _pair;
    private readonly WordDictionary _dict;
    private readonly LearnedRules _learned;
    private readonly DetectorConfig _cfg;
    private readonly Action<string>? _log;

    public Detector(LayoutPair pair, WordDictionary dict, LearnedRules learned,
                    DetectorConfig cfg, Action<string>? log = null)
    {
        _pair = pair;
        _dict = dict;
        _learned = learned;
        _cfg = cfg;
        _log = log;
    }

    /// <summary>Главная точка входа: вызывается на границе слова.</summary>
    public Verdict Decide(string raw, Lang currentLang, Lang? context)
    {
        string lower = raw.ToLowerInvariant();
        int effectiveLen = raw.Count(c => char.IsLetter(c) || _pair.LayoutPunct.Contains(c));

        // 0. Ручные списки важнее всего
        if (_cfg.ForceWords.Contains(lower))
            return new(true, _pair.Swap(raw), "forceWords");
        if (_cfg.StopWords.Contains(lower))
            return new(false, null, "stopWords");

        // Выученное на исправлениях: человек уже показал, чего хочет
        if (_learned.ShouldForce(lower))
        {
            Log($"'{lower}' — выучено: переключаем");
            return new(true, _pair.Swap(raw), "learned-force");
        }
        if (_learned.ShouldStop(lower))
        {
            Log($"'{lower}' — выучено: не трогаем");
            return new(false, null, "learned-stop");
        }

        // Одиночная буква — только по контексту (предлоги)
        if (effectiveLen == 1)
        {
            var single = SingleCharSwap(raw, context);
            return single is null
                ? new(false, null, "single-no-context")
                : new(true, single, "single-preposition");
        }

        if (effectiveLen < _cfg.MinWordLength)
            return new(false, null, "too-short");

        var converted = AutoConvert(raw, context);
        return converted is null
            ? new(false, null, "no-rule")
            : new(true, converted, "auto");
    }

    /// <summary>
    /// Свап одиночной буквы-предлога по контексту: `f` после русских слов → `а`.
    /// Без контекста не трогаем — может быть честное EN `a` или `i`.
    /// </summary>
    private string? SingleCharSwap(string word, Lang? context)
    {
        if (context is null) return null;
        string lower = word.ToLowerInvariant();

        // Для RU↔EN; при добавлении новых пар предлоги переедут в конфиг пары
        var singleOther = new HashSet<string> { "а", "и", "в", "к", "с", "о", "у", "я" };
        var singleLatin = new HashSet<string> { "a", "i" };

        if (singleOther.Contains(lower) || singleLatin.Contains(lower)) return null;

        string swapped = _pair.Swap(word);
        string swappedLow = swapped.ToLowerInvariant();

        if (singleOther.Contains(swappedLow) && context == Lang.Other) return swapped;
        if (singleLatin.Contains(swappedLow) && context == Lang.Latin) return swapped;
        return null;
    }

    private string? AutoConvert(string word, Lang? context)
    {
        string lower = word.ToLowerInvariant();
        if (lower.Length < 2) return null;

        bool isLatin = lower.All(c => _pair.IsLatinLetter(c));
        bool isOther = lower.All(c => _pair.IsOtherLetter(c));

        // (1) Смешанные алфавиты → нормализация
        if (!isLatin && !isOther)
            return NormalizeMixed(word, lower);

        // (2) Валидное слово текущего языка — не трогаем.
        // Для 2–3 букв полный словарь бесполезен: в нём архаизмы и фамилии,
        // почти любая пара букв формально «слово» ('ут' — старое название ноты).
        // Короткие сверяются с частотными списками реально употребимых.
        bool shortWord = lower.Length <= 3;
        if (isLatin)
        {
            bool valid = shortWord && _dict.ShortLatin.Count > 0
                ? _dict.ShortLatin.Contains(lower)
                : _dict.Latin.Contains(lower);
            if (valid) { Log($"'{lower}' валидное {_pair.LatinCode.ToUpper()}-слово → keep"); return null; }
        }
        if (isOther)
        {
            bool valid = shortWord && _dict.ShortOther.Count > 0
                ? _dict.ShortOther.Contains(lower)
                : _dict.Other.Contains(lower);
            if (valid) { Log($"'{lower}' валидное {_pair.OtherCode.ToUpper()}-слово → keep"); return null; }
        }

        string candidate = _pair.Swap(word);
        string candidateLower = candidate.ToLowerInvariant();

        // (3) Целиком в плохих триггерах (n-граммы, натренированные на корпусе)
        var triggers = isLatin ? _dict.BadLatin : _dict.BadOther;
        if (triggers.Contains(lower))
        {
            Log($"'{lower}' в триггерах → SWAP к '{candidate}'");
            return candidate;
        }

        // (4) Свап — валидное слово другого языка.
        // Для 2 букв разрешаем свободно: коротких латинских слов мало и они в словаре;
        // если двухбуквенное не в словаре, а свап в словаре другого языка —
        // почти наверняка промах раскладки. Для 3 букв на маке проверили:
        // реальные аббревиатуры (dmg, jpg, sql) свапаются в бессмыслицу и
        // отсекаются словарём, коллизий единицы. 4+ свободно.
        if (isLatin && _dict.Other.Contains(candidateLower))
        {
            Log($"свап '{candidate}' есть в {_pair.OtherCode.ToUpper()} (len={lower.Length}) → SWAP");
            return candidate;
        }
        if (isOther && _dict.Latin.Contains(candidateLower))
        {
            Log($"свап '{candidate}' есть в {_pair.LatinCode.ToUpper()} (len={lower.Length}) → SWAP");
            return candidate;
        }

        // (5) Взвешенного score нет намеренно: на маке он делал ложные свапы
        // валидных слов, которых нет в словаре. Либо правило 4, либо ничего.
        Log($"'{lower}' (свап='{candidate}') не подошло ни одно правило → keep");
        return null;
    }

    /// <summary>
    /// Смешанное слово: латиница + кириллица, либо layout-пунктуация с буквами.
    /// Нормализуем если результат — чистый алфавит.
    /// </summary>
    private string? NormalizeMixed(string word, string lower)
    {
        string lettersLat = new(lower.Where(c => _pair.IsLatinLetter(c)).ToArray());
        string lettersOth = new(lower.Where(c => _pair.IsOtherLetter(c)).ToArray());
        bool hasLat = lettersLat.Length > 0;
        bool hasOth = lettersOth.Length > 0;
        bool hasLayoutPunct = lower.Any(c => _pair.LayoutPunct.Contains(c));

        bool isCandidate = (hasLat && hasOth) || (hasLayoutPunct && (hasLat || hasOth));
        if (!isCandidate) return null;

        // Пунктуация только в конце ('Hello,') — настоящая. Не трогаем, если
        // буквенная часть словарная.
        bool firstIsLayoutPunct = lower.Length > 0 && _pair.LayoutPunct.Contains(lower[0]);
        if (!firstIsLayoutPunct)
        {
            if (!hasOth && hasLat && _dict.Latin.Contains(lettersLat)) return null;
            if (!hasLat && hasOth && _dict.Other.Contains(lettersOth)) return null;
        }

        string normalized = _pair.Swap(word);
        string normLow = normalized.ToLowerInvariant();
        if (normLow == lower) return null;

        bool normIsLat = normLow.All(c => _pair.IsLatinLetter(c) || !char.IsLetter(c));
        bool normIsOth = normLow.All(c => _pair.IsOtherLetter(c) || !char.IsLetter(c));
        bool hasLetters = normLow.Any(char.IsLetter);
        if (hasLetters && (normIsLat || normIsOth)) return normalized;
        return null;
    }

    private void Log(string msg) => _log?.Invoke($"  [det] {msg}");
}

/// <summary>Настройки детектора, читаются из конфига приложения.</summary>
public sealed class DetectorConfig
{
    public HashSet<string> ForceWords { get; init; } = new();
    public HashSet<string> StopWords { get; init; } = new();
    public int MinWordLength { get; init; } = 2;
}
