namespace QSwitcher.Core;

/// <summary>
/// Прогон фраз через тот же детектор, что живой ввод (без хука). Порт TestRunner.swift:
/// строка: «фраза => ожидание»; цель — последнее слово или в *звёздочках*;
/// «#» — комментарий; без «=>» — просто показать решение; «@terminal ls» — место ввода.
/// Вывод построчно как на маке («--- фраза» / «    = результат ✅»), чтобы nn/sem/sweep.sh
/// считал его тем же скриптом. Итог — верно / молчал (оставил как набрано) / испортил.
/// </summary>
public static class TestRunner
{
    public sealed class Report
    {
        public List<string> Lines { get; } = new();
        public int Total, Ok, Silent, Harm;
        public string Summary => Total > 0 ? $"Итого: {Ok}/{Total} верно, молчал {Silent}, испортил {Harm}" : "";
        public string Text => string.Join("\n", Lines) + (Total > 0 ? "\n\n" + Summary : "");
    }

    /// Тег места ввода в тесте → имя процесса на винде (класс приложения для сети).
    /// Поля (address/password) на винде детектор пока не различает — оставлено под
    /// следующий шаг («список приложений»), сейчас идёт как браузер/прочее.
    public static string AppFor(string tag) => tag switch
    {
        "terminal" => "WindowsTerminal",
        "code" => "Code",
        "chat" => "Telegram",
        "browser" => "chrome",
        "address" => "chrome",
        "password" => "test",
        _ => "test",
    };

    private static bool IsOther(LayoutPair pair, string w) => w.Any(pair.IsOtherLetter);

    /// <summary>
    /// print — куда писать построчный вывод; silence(true/false) — глушить лог детектора
    /// на время «тихих» решений по словам до цели (возвращает прежнее состояние).
    /// </summary>
    public static Report Run(string text, Detector detector, LayoutPair pair,
                             Action<string> print, Func<bool, bool> silence)
    {
        var rep = new Report();
        foreach (var raw in text.Split('\n'))
        {
            string line = raw.TrimEnd('\r').Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            string? expect = null;
            int arrow = line.IndexOf("=>", StringComparison.Ordinal);
            if (arrow >= 0)
            {
                expect = line[(arrow + 2)..].Trim();
                line = line[..arrow].Trim();
            }
            var words = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
            string app = "test";
            if (words.Count > 0 && words[0].StartsWith('@'))
            {
                app = AppFor(words[0][1..].ToLowerInvariant());
                words.RemoveAt(0);
            }
            if (words.Count == 0) continue;
            int ti = words.Count - 1;
            for (int k = 0; k < words.Count; k++)
            {
                var w = words[k];
                if (w.Length > 2 && w.StartsWith('*') && w.EndsWith('*')) { words[k] = w[1..^1]; ti = k; }
            }
            string word = words[ti];

            // Как при живом наборе: слова ДО цели уже прошли через детектор и стоят
            // на экране в решённом виде. Иначе «Xnj *ns* знаешь» видит соседом
            // сырое 'Xnj', хотя живьём к моменту 'ns' на экране уже 'Что' и пара
            // «что ты» есть. Решаем предыдущие слова по очереди, тихо.
            var before = new List<string>();
            for (int k = 0; k < ti; k++)
            {
                var w = words[k];
                var recent = Recent(before);   // всё предложение до слова, как на маке
                bool saved = silence(true);
                var v = detector.Decide(w, IsOther(pair, w) ? Lang.Other : Lang.Latin, null, recent, app);
                silence(saved);
                before.Add(v.ShouldSwap && v.Replacement is not null ? v.Replacement : w);
            }
            // Контекст — большинство по буквам трёх последних слов (как KeyboardMonitor.ComputeContext)
            int oth = 0, lat = 0;
            foreach (var w in before.TakeLast(3))
                foreach (char c in w)
                {
                    if (pair.IsOtherLetter(c)) oth++;
                    else if (pair.IsLatinLetter(c)) lat++;
                }
            Lang? ctx = (oth + lat < 2) ? null : oth > lat ? Lang.Other : lat > oth ? Lang.Latin : null;
            Lang cur = IsOther(pair, word) ? Lang.Other : Lang.Latin;

            print($"--- {line}");
            // История — всё предложение до цели (ближайшее первым): нужно и для соседа,
            // и чтобы увидеть те же клавиши, уже занятые в этом предложении.
            var verdict = detector.Decide(word, cur, ctx, Recent(before), app);
            string result = verdict.ShouldSwap && verdict.Replacement is not null ? verdict.Replacement : word;
            string mark = "";
            if (expect is not null)
            {
                rep.Total++;
                bool hit = string.Equals(result, expect, StringComparison.OrdinalIgnoreCase);
                if (hit) rep.Ok++;
                else if (string.Equals(result, word, StringComparison.OrdinalIgnoreCase)) rep.Silent++;
                else rep.Harm++;
                mark = hit ? "   ✅" : $"   ❌ ждали {expect}";
            }
            print($"    = {result}{mark}");
            rep.Lines.Add($"{line}    = {result}{mark}");
        }
        return rep;
    }

    /// <summary>Место ввода в тесте → процесс и ожидание языка первого слова: как у ядра
    /// на таком месте без личной статистики (TestRunner.swift place(), nn/lm/eval_phrases.py).</summary>
    public static (string App, double PriorRu)? Place(string tag) => tag switch
    {
        "terminal" => ("WindowsTerminal", 0.15),
        "code" => ("Code", 0.2),
        "chat" => ("Telegram", 0.8),
        "browser" => ("chrome", 0.6),
        "address" => ("chrome", 0.05),
        "password" => ("test", 0.02),
        _ => null,
    };

    /// <summary>
    /// Ядро 5: все слова фразы идут по очереди через тот же Detector.Decide, что живой
    /// ввод, со своим экземпляром ядра (живой контекст не трогается) — и слова ПОСЛЕ
    /// цели тоже: короткое неуверенное слово решается задним числом по правому соседу.
    /// Порт TestRunner.runV5 (мак); эталон — nn/lm/eval_phrases.py --right.
    /// </summary>
    public static Report RunV5(string text, Detector detector, Core5 core, LayoutPair pair,
                               Action<string> print, Func<bool, bool> silence)
    {
        var rep = new Report();
        foreach (var raw in text.Split('\n'))
        {
            string line = raw.TrimEnd('\r').Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            string? expect = null;
            int arrow = line.IndexOf("=>", StringComparison.Ordinal);
            if (arrow >= 0)
            {
                expect = line[(arrow + 2)..].Trim();
                line = line[..arrow].Trim();
            }
            var words = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
            string app = "test";
            double prior = 0.5;
            if (words.Count > 0 && words[0].StartsWith('@'))
            {
                if (Place(words[0][1..].ToLowerInvariant()) is { } pl) { app = pl.App; prior = pl.PriorRu; }
                words.RemoveAt(0);
            }
            if (words.Count == 0) continue;
            int ti = words.Count - 1;
            for (int k = 0; k < words.Count; k++)
            {
                var w = words[k];
                if (w.Length > 2 && w.StartsWith('*') && w.EndsWith('*')) { words[k] = w[1..^1]; ti = k; }
            }
            print($"--- {line}");
            core.Reset(prior);
            var shown = new List<string>();
            string retroNote = "";
            for (int k = 0; k < words.Count; k++)
            {
                string w = words[k];
                bool saved = silence(k != ti);          // в выводе — только цель
                var v = detector.Decide(w, IsOther(pair, w) ? Lang.Other : Lang.Latin, null,
                                        Recent(shown), app, sepIsSpace: true, core: core);
                silence(saved);
                if (v.RetroTo is { } to && shown.Count > 0)
                {
                    if (k - 1 == ti) retroNote = $" (задним числом по '{w}': '{shown[^1]}' → '{to}')";
                    shown[^1] = to;
                }
                shown.Add(v.ShouldSwap && v.Replacement is not null ? v.Replacement : w);
            }
            string word = words[ti], result = shown[ti];
            string mark = "";
            if (expect is not null)
            {
                rep.Total++;
                bool hit = string.Equals(result, expect, StringComparison.OrdinalIgnoreCase);
                if (hit) rep.Ok++;
                else if (string.Equals(result, word, StringComparison.OrdinalIgnoreCase)) rep.Silent++;
                else rep.Harm++;
                mark = hit ? "   ✅" : $"   ❌ ждали {expect}";
            }
            print($"    = {result}{retroNote}{mark}");
            rep.Lines.Add($"{line}    = {result}{mark}{retroNote}");
        }
        return rep;
    }

    /// Ближайшее первым, всё предложение (как TestRunner.swift: history = before.reversed()).
    private static List<string> Recent(List<string> before)
    {
        var r = new List<string>(before.Count);
        for (int i = before.Count - 1; i >= 0; i--) r.Add(before[i]);
        return r;
    }
}
