namespace QSwitcher.Core;

/// <summary>
/// Язык слова в терминах пары раскладок.
/// </summary>
public enum Lang { Latin, Other }

/// <summary>
/// Результат решения детектора. Ядро 5 может ещё исправить ПРЕДЫДУЩЕЕ слово
/// задним числом: на экране было RetroFrom, должно стать RetroTo.
/// </summary>
public readonly record struct Verdict(bool ShouldSwap, string? Replacement, string Reason)
{
    public string? RetroFrom { get; init; }
    public string? RetroTo { get; init; }
}

/// <summary>
/// Детектор ошибочной раскладки. Перенесён с macOS-версии (Swift) правило в
/// правило — та логика выстрадана на десятках реальных багов, и повторять
/// этот путь на второй платформе нет смысла.
///
/// Решение по приоритету:
///   0. forceWords / stopWords из конфига, затем выученные правила
///   ядро 5 (по умолчанию): смешанные алфавиты → нормализация, остальное —
///      одна формула (Core5.cs): частоты слов, символьная модель, опечатки,
///      сосед, ожидание приложения; короткое неуверенное — задним числом
///   прежний каскад (Core = "legacy"):
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
    private readonly Core5? _core;

    public Detector(LayoutPair pair, WordDictionary dict, LearnedRules learned,
                    DetectorConfig cfg, Action<string>? log = null, LayoutNet? net = null,
                    Core5? core = null)
    {
        _pair = pair;
        _dict = dict;
        _learned = learned;
        _cfg = cfg;
        _log = log;
        _net = net;
        _core = core;
    }

    /// Ядро живого ввода (контекст для него ведёт KeyboardMonitor).
    public Core5? Core => _core;

    /// Решает ядро 5 (есть модель и не выбран прежний каскад)?
    public bool CoreV5 => _core is { Ready: true } && (_cfg.CoreV5?.Invoke() ?? true);

    /// <summary>
    /// Главная точка входа: вызывается на границе слова.
    /// history — предыдущие слова как они на экране, БЛИЖАЙШЕЕ ПЕРВЫМ (до трёх);
    /// app — имя процесса, где идёт ввод (для класса приложения сети).
    /// </summary>
    /// sepIsSpace — между предыдущим словом и этим на экране ровно один пробел
    /// (ядро 5 может исправить предыдущее задним числом); core — свой экземпляр ядра
    /// для прогонов, по умолчанию ядро живого ввода; field — "password" в поле пароля.
    public Verdict Decide(string raw, Lang currentLang, Lang? context,
                          IReadOnlyList<string>? history = null, string? app = null,
                          bool sepIsSpace = false, Core5? core = null, string? field = null)
    {
        string lower = raw.ToLowerInvariant();
        int effectiveLen = raw.Count(c => char.IsLetter(c) || _pair.LayoutPunct.Contains(c));
        var c5 = CoreV5 ? core ?? _core : null;
        // Решение не ядра — всё равно контекст для следующего слова
        Verdict Ext(bool swap, string reason)
        {
            string shown = swap ? _pair.Swap(raw) : raw;
            c5?.NoteExternal(raw, shown);
            return new(swap, swap ? shown : null, reason);
        }

        // 0. Ручные списки важнее всего. Как на маке: строчное слово в списке совпадает без
        // учёта регистра, слово с заглавными — только точно («РФ» ≠ «рф»)
        if (_cfg.ForceWords.Contains(lower) || _cfg.ForceWords.Contains(raw))
            return Ext(true, "forceWords");
        if (_cfg.StopWords.Contains(lower) || _cfg.StopWords.Contains(raw))
            return Ext(false, "stopWords");

        // Выученное на исправлениях: человек уже показал, чего хочет
        if (_learned.ShouldForce(lower))
        {
            Log($"'{lower}' — выучено: переключаем");
            return Ext(true, "learned-force");
        }
        if (_learned.ShouldStop(lower))
        {
            Log($"'{lower}' — выучено: не трогаем");
            return Ext(false, "learned-stop");
        }

        // Место ввода. Поле пароля — не трогаем ничего: пароль бывает и кириллицей, а
        // исправленный «на английский» пароль не подойдёт (на маке такие поля хук не видит
        // вовсе). Приложения из списка «английский ввод» (поиск Windows, лаунчеры): кириллица
        // свапается сразу, латиница не трогается — как expectEnglishBundles на маке.
        if (field == "password")
        {
            c5?.NoteExternal(raw, raw, confident: false);
            return new(false, null, "password");
        }
        if (app is { Length: > 0 } && _cfg.EnglishApps?.Invoke() is { Count: > 0 } eng
            && eng.Any(a => a.Length > 0 && app.Contains(a, StringComparison.OrdinalIgnoreCase)))
        {
            bool cyr = lower.Any(c => _pair.IsOtherLetter(c));
            Log(cyr ? $"'{raw}' — английский ввод ({app}) → SWITCH" : $"'{raw}' — английский ввод ({app}) → keep");
            return Ext(cyr, "place");
        }

        if (c5 is not null) return DecideV5(raw, lower, sepIsSpace, c5);

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
    /// Ядро 5: смешанные алфавиты (кириллица + латиница в одном слове) — нормализация
    /// как раньше, всё остальное — одна формула.
    /// </summary>
    private Verdict DecideV5(string raw, string lower, bool sepIsSpace, Core5 core)
    {
        bool hasLat = lower.Any(_pair.IsLatinLetter);
        bool hasOth = lower.Any(c => _pair.IsOtherLetter(c));
        if (hasLat && hasOth)
        {
            var norm = NormalizeMixed(raw, lower);
            core.NoteExternal(raw, norm ?? raw, confident: norm is not null);
            Log(norm is null ? $"'{raw}' смешанные алфавиты — нормализовать нечем → keep"
                             : $"'{raw}' смешанные алфавиты → '{norm}'");
            return norm is null ? new(false, null, "mixed") : new(true, norm, "mixed");
        }
        // Адрес сайта, набранный в русской раскладке: «пщщпдуюсщь» → «google.com».
        // Модель языка адрес не оценит (точка — не буква); зона из списка и то, что
        // набранное — не русское слово, отсекают «клюем» → «rk.tv» и подобное.
        if (hasOth && !hasLat)
        {
            string sw = _pair.Swap(raw);
            if (LooksLikeDomain(sw) && core.Known("ru", lower) is null)
            {
                core.NoteExternal(raw, sw);
                Log($"'{raw}' — адрес '{sw}' в русской раскладке → SWITCH");
                return new(true, sw, "domain");
            }
        }
        string T = Core5.LangOf(raw);
        if (T.Length == 0) return new(false, null, "no-letters");   // ни одной буквы — не слово
        int n = Core5.Letters(raw, T);
        if (_cfg.MinWordLength > 2 && n > 1 && n < _cfg.MinWordLength)
        {
            core.NoteExternal(raw, raw, confident: false);
            return new(false, null, "too-short");
        }
        var d = core.Decide(raw, _pair.Swap(raw), T, sepIsSpace, _pair.Swap);
        Log($"ядро5: {d.Explain}");
        return new(d.SwitchNow, d.SwitchNow ? d.Shown : null, "core5")
        {
            RetroFrom = d.RetroFrom,
            RetroTo = d.RetroPrev,
        };
    }

    /// Зоны, по которым строка считается адресом сайта. Без tv/cn/cs/cm и подобных:
    /// «клюем» по раскладке — «rk.tv», «каюсь» — «rf.cm», «Андрюше» — «fylh.it».
    private static readonly HashSet<string> DomainZones = new()
    {
        "com", "ru", "org", "net", "io", "dev", "app", "info", "me", "co", "ai", "gg", "xyz",
        "site", "online", "tech", "pro", "biz", "edu", "gov", "eu", "us", "uk", "de", "fi", "su",
        "by", "ua", "fr", "es", "nl", "se", "no", "pl", "jp", "ca", "au", "ch", "be",
        "cloud", "store", "blog", "ly", "sh", "gl", "so", "to", "am", "in",
    };

    /// «google.com», «www.youtube.com», «mail.yandex.ru» — метки из латиницы/цифр/дефиса
    /// через точку, первая не короче двух символов, последняя — известная зона.
    public static bool LooksLikeDomain(string s)
    {
        string l = s.ToLowerInvariant();
        if (l.Length < 5) return false;
        var labels = l.Split('.');
        if (labels.Length < 2 || labels[0].Length < 2 || !DomainZones.Contains(labels[^1])) return false;
        foreach (var lab in labels)
            if (lab.Length == 0 || !lab.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-')) return false;
        return true;
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

        // (1а) Сеть — основной режим: решает до щита и словарей, если уверена.
        // Для коротких слов (≤3) порог строже (ThresholdShort). Не уверена — молчит.
        var nn = _cfg.Nn?.Invoke();
        if (nn is { Mode: not "arbiter" })
        {
            var v = NetVerdict(word, lower, isLatin, history, app, nn.Value);
            if (v.HasValue) return (v.Value.Result, v.Value.Reason);
        }

        // (1б) Щит коротких слов: короткое слово, НАБРАННОЕ В ЯЗЫКЕ КОНТЕКСТА,
        // против контекста не свапаем. Почти любая пара букв — чьё-то короткое
        // слово в другом языке ('ру' при ctx=ru свапалось в 'he', 'рф' → 'ha').
        // Стоит после сети: она, если уверена (строгий порог), знает про
        // контекст больше, чем язык соседей; не уверена — щит страхует.
        if (lower.Length <= 3 && context is not null
            && context == (isLatin ? Lang.Latin : Lang.Other))
        {
            Log($"'{lower}' короткое, набрано в языке контекста ({context}) → keep");
            return (null, "short-in-context");
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
        double threshold = lower.Length <= 3 ? nn.ThresholdShort : nn.Threshold;
        if (conf < threshold)
        {
            Log($"сеть {tag} не уверена (порог {threshold}, ctx='{ctxStr}', {appName}) → словари");
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
public readonly record struct NnSettings(bool Enabled, double Threshold, string Mode, int MinLen, double ThresholdShort = 0.95);

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
    /// <summary>Решает ядро 5 (true) или прежний каскад (false). Читается на лету.</summary>
    public Func<bool>? CoreV5 { get; init; }
    /// Процессы с английским вводом (меню «Английский ввод»): подстрока имени процесса.
    public Func<IReadOnlyCollection<string>>? EnglishApps { get; init; }
}
