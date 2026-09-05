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
    private readonly LayoutNet? _net;

    public Detector(LayoutPair pair, WordDictionary dict, LearnedRules learned,
                    DetectorConfig cfg, Action<string>? log = null, LayoutNet? net = null)
    {
        _pair = pair;
        _dict = dict;
        _learned = learned;
        _cfg = cfg;
        _log = log;
        _net = net;
    }

    /// <summary>
    /// Главная точка входа: вызывается на границе слова.
    /// history — предыдущие слова как они на экране, БЛИЖАЙШЕЕ ПЕРВЫМ (до трёх);
    /// app — имя процесса, где идёт ввод (для класса приложения сети).
    /// </summary>
    public Verdict Decide(string raw, Lang currentLang, Lang? context,
                          IReadOnlyList<string>? history = null, string? app = null)
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

        var (converted, reason) = AutoConvert(raw, context, history ?? Array.Empty<string>(), app);
        return converted is null
            ? new(false, null, reason)
            : new(true, converted, reason);
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

    private (string? Result, string Reason) AutoConvert(string word, Lang? context,
                                                       IReadOnlyList<string> history, string? app)
    {
        string lower = word.ToLowerInvariant();
        if (lower.Length < 2) return (null, "too-short");

        bool isLatin = lower.All(c => _pair.IsLatinLetter(c));
        bool isOther = lower.All(c => _pair.IsOtherLetter(c));

        // (1) Смешанные алфавиты → нормализация
        if (!isLatin && !isOther)
            return (NormalizeMixed(word, lower), "mixed");

        // (1а) Щит коротких слов: короткое слово, НАБРАННОЕ В ЯЗЫКЕ КОНТЕКСТА,
        // против контекста не свапаем. Почти любая пара букв — чьё-то короткое
        // слово в другом языке ('ру' при ctx=ru свапалось в 'he', 'рф' → 'ha').
        // Стоит ВЫШЕ сети намеренно: 'he' в корпусах частое, «ру» — нет, и
        // сеть уверенно ошибётся ровно там, где мы уже обжигались.
        // Направление 'yt'→'не' при ctx=ru не задето: цель свапа = контекст.
        if (lower.Length <= 3 && context is not null
            && context == (isLatin ? Lang.Latin : Lang.Other))
        {
            Log($"'{lower}' короткое, набрано в языке контекста ({context}) → keep");
            return (null, "short-in-context");
        }

        // (1б) Сеть — основной режим: решает до словарей, если уверена.
        // Не уверена — молчит, дальше словарные правила как раньше.
        var nn = _cfg.Nn?.Invoke();
        if (nn is { Mode: not "arbiter" })
        {
            var v = NetVerdict(word, lower, isLatin, history, app, nn.Value);
            if (v.HasValue) return (v.Value.Result, v.Value.Reason);
        }

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
            if (valid) { Log($"'{lower}' валидное {_pair.LatinCode.ToUpper()}-слово → keep"); return (null, "valid"); }
        }
        if (isOther)
        {
            bool valid = shortWord && _dict.ShortOther.Count > 0
                ? _dict.ShortOther.Contains(lower)
                : _dict.Other.Contains(lower);
            if (valid) { Log($"'{lower}' валидное {_pair.OtherCode.ToUpper()}-слово → keep"); return (null, "valid"); }
        }

        string candidate = _pair.Swap(word);
        string candidateLower = candidate.ToLowerInvariant();

        // (3) Целиком в плохих триггерах (n-граммы, натренированные на корпусе)
        var triggers = isLatin ? _dict.BadLatin : _dict.BadOther;
        if (triggers.Contains(lower))
        {
            Log($"'{lower}' в триггерах → SWAP к '{candidate}'");
            return (candidate, "trigger");
        }

        // (4а) щит коротких слов переехал выше сети — см. (1а)

        // (4) Свап — валидное слово другого языка.
        // Для 2 букв разрешаем свободно: коротких латинских слов мало и они в словаре;
        // если двухбуквенное не в словаре, а свап в словаре другого языка —
        // почти наверняка промах раскладки. Для 3 букв на маке проверили:
        // реальные аббревиатуры (dmg, jpg, sql) свапаются в бессмыслицу и
        // отсекаются словарём, коллизий единицы. 4+ свободно.
        if (isLatin && _dict.Other.Contains(candidateLower))
        {
            Log($"свап '{candidate}' есть в {_pair.OtherCode.ToUpper()} (len={lower.Length}) → SWAP");
            return (candidate, "swap-in-dict");
        }
        if (isOther && _dict.Latin.Contains(candidateLower))
        {
            Log($"свап '{candidate}' есть в {_pair.LatinCode.ToUpper()} (len={lower.Length}) → SWAP");
            return (candidate, "swap-in-dict");
        }

        // (5) Взвешенного score нет намеренно: на маке он делал ложные свапы
        // валидных слов, которых нет в словаре. Либо правило 4, либо ничего.

        // (6) Режим «арбитр»: сеть спрашиваем только когда словари промолчали.
        if (nn is { Mode: "arbiter" })
        {
            var v = NetVerdict(word, lower, isLatin, history, app, nn.Value);
            if (v.HasValue) return (v.Value.Result, v.Value.Reason);
        }

        Log($"'{lower}' (свап='{candidate}') не подошло ни одно правило → keep");
        return (null, "no-rule");
    }

    /// <summary>
    /// Вердикт сети: (свап, "nn-swap"), (null, "nn-keep") или null — не уверена /
    /// выключена / слово не кодируется, тогда решают словари. В логе всегда P(ru),
    /// контекст и класс приложения — решения остаются объяснимыми.
    /// </summary>
    private (string? Result, string Reason)? NetVerdict(string word, string lower, bool isLatin,
                                                        IReadOnlyList<string> history, string? app,
                                                        NnSettings nn)
    {
        if (_net is null || !_net.Loaded || !nn.Enabled) return null;
        if (lower.Length < nn.MinLen) return null;
        string? keys = _net.KeysOf(lower);
        if (keys is null) return null;
        var ctx = history.Take(3).Select(_net.CtxOf).ToList();
        var appClass = _cfg.AppClassOf?.Invoke(app) ?? LayoutNet.AppClass.Other;
        float p = _net.ProbabilityRu(keys, ctx, appClass, layoutRu: !isLatin);
        bool intendedOther = p >= 0.5f;
        float conf = MathF.Max(p, 1 - p);
        string ctxStr = string.Join(" ", history.Take(3));
        string appName = LayoutNet.AppNames[(int)appClass];
        string tag = $"P(ru)={p:F3}";
        if (conf < nn.Threshold)
        {
            Log($"сеть {tag} не уверена (порог {nn.Threshold}, ctx='{ctxStr}', {appName}) → словари");
            return null;
        }
        if (intendedOther == !isLatin)
        {
            Log($"сеть {tag} (ctx='{ctxStr}', {appName}) → keep");
            return (null, "nn-keep");
        }
        string candidate = _pair.Swap(word);
        Log($"сеть {tag} (ctx='{ctxStr}', {appName}) → SWAP к '{candidate}'");
        return (candidate, "nn-swap");
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

/// <summary>Настройки сети на момент решения (читаются из конфига на лету).</summary>
public readonly record struct NnSettings(bool Enabled, double Threshold, string Mode, int MinLen);

/// <summary>Настройки детектора, читаются из конфига приложения.</summary>
public sealed class DetectorConfig
{
    public HashSet<string> ForceWords { get; init; } = new();
    public HashSet<string> StopWords { get; init; } = new();
    public int MinWordLength { get; init; } = 2;
    /// <summary>Живые настройки сети (null — сеть не используется).</summary>
    public Func<NnSettings>? Nn { get; init; }
    /// <summary>Имя процесса → класс приложения для сети.</summary>
    public Func<string?, LayoutNet.AppClass>? AppClassOf { get; init; }
}
