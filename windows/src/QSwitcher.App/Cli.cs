using System.Runtime.InteropServices;
using System.Text;
using QSwitcher.Core;

namespace QSwitcher.App;

/// <summary>
/// Режимы командной строки — как на маке (main.swift):
///   QSwitcher.exe --test nn\sem\test-phrases.txt [--verbose]
///   QSwitcher.exe --selftest-core [nn\lm\core5-selftest.json]   (и самопроверка синхронизации)
///   QSwitcher.exe --selftest-sync
/// Идут рядом с запущенным свитчером: его не завершают, хук не ставят, лог не трогают.
/// Прогон — тем же детектором и с тем же config.json и выученными правилами, что живой
/// ввод; отчёт — в %APPDATA%\QSwitcher\test-report.txt (его читает nn\sem\sweep.ps1).
/// exe оконный, поэтому PowerShell его не ждёт: для вывода в консоль —
///   .\QSwitcher.exe --test <репозиторий>\nn\sem\test-phrases.txt | Out-Host
/// </summary>
internal static class Cli
{
    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(int dwProcessId);

    public static bool Handles(string[] args) =>
        args.Length > 0 && args[0] is "--test" or "--selftest-core" or "--selftest-sync";

    public static string ReportPath => Path.Combine(Program.DataDir, "test-report.txt");

    public static int Run(string[] args)
    {
        // Консоль, из которой запустили; нет её — вывод только в файл отчёта
        if (OperatingSystem.IsWindows()) try { AttachConsole(-1); } catch { }
        // Кодировку консоли не трогаем: вывод идёт в её кодовой странице (кириллица есть
        // и в 866), а PowerShell при «| Out-Host» так же её и читает. Отчёт — в UTF-8.
        Directory.CreateDirectory(Program.DataDir);
        try
        {
            return args[0] switch
            {
                "--test" => Test(args),
                "--selftest-sync" => SyncSelftest(),
                _ => Selftest(args),
            };
        }
        catch (Exception e)
        {
            Say($"⚠️ {e.Message}");
            return 2;
        }
    }

    private static void Say(string s)
    {
        try { Console.WriteLine(s); } catch { }
    }

    private static string? Arg(string[] args, int i) =>
        i < args.Length && !args[i].StartsWith("--", StringComparison.Ordinal) ? args[i] : null;

    /// Самопроверка порта ядра 5: те же входы, что эталон на Python, — те же решения.
    private static int Selftest(string[] args)
    {
        var ngram = NgramLM.Load(Res.Open, Say);
        var charLm = CharLM.Load(Res.Open, Say);
        string? file = Arg(args, 1);
        using var st = file is not null ? File.OpenRead(file) : Res.Open("core5-selftest.json");
        if (st is null) { Say("нет core5-selftest.json — укажи путь: --selftest-core nn\\lm\\core5-selftest.json"); return 2; }
        if (!ngram.Loaded) { Say("нет qsngram.bin — ядру 5 не на чем решать"); return 2; }
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var (n, bad) = Core5.Selftest(st, ngram, charLm, Say, verbose: args.Contains("--verbose"));
        Say($"Ядро 5 / самопроверка: {n - bad}/{n} совпало с эталоном ({sw.ElapsedMilliseconds} мс)");
        int rs = SyncSelftest();
        return bad == 0 && n > 0 && rs == 0 ? 0 : 1;
    }

    /// Самопроверка синхронизации: слияние реестров и файл устройства — те же сценарии и тот же
    /// образец файла, что на маке (SyncModel.swift).
    private static int SyncSelftest()
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var (n, bad) = SyncMerge.Selftest(Say);
        Say($"Синхронизация / самопроверка: {n - bad}/{n} ({sw.ElapsedMilliseconds} мс)");
        return bad == 0 ? 0 : 1;
    }

    /// Прогон фраз: строка «[@место] слова … *цель* … => ожидание» (формат nn/sem/*.txt).
    private static int Test(string[] args)
    {
        string? path = Arg(args, 1);
        if (path is null || !File.Exists(path)) { Say($"не читается: {path ?? "(нет файла)"}"); return 2; }
        string text = File.ReadAllText(path);
        bool verbose = args.Contains("--verbose");

        // Служебное (загрузка словарей, сети) — только с --verbose
        void Quiet(string s) { if (verbose) Say(s); }
        var cfg = AppConfig.Load(Program.DataDir, Quiet);
        var pair = LayoutPair.RuEn();
        var dict = WordDictionary.Load(Res.Open, Quiet);
        dict.MergeUser(Path.Combine(Program.DataDir, "dicts", "en.txt"), latin: true);
        dict.MergeUser(Path.Combine(Program.DataDir, "dicts", "ru.txt"), latin: false);
        var learned = new LearnedRules(Program.DataDir);
        var net = LayoutNet.Load(pair, Res.Open, Quiet, userWeightsPath: Path.Combine(Program.DataDir, "qsnet.bin"));
        var ngram = NgramLM.Load(Res.Open, Quiet);
        var charLm = CharLM.Load(Res.Open, Quiet);

        // Личный слой — как в живом вводе (в своём режиме), но прогон его не пополняет
        var personal = PersonalStore.Load(Program.DataDir, Quiet, readOnly: true);
        personal.ModeSource = () => cfg.PersonalModeValue == PersonalMode.Learn || cfg.PersonalModeValue == PersonalMode.Off
            ? PersonalMode.Off : PersonalMode.Frozen;
        Core5 MakeCore() { var c = Program.MakeCore(cfg, ngram, charLm); c.Personal = personal; return c; }

        // Рассуждения детектора — по целевому слову; слова вокруг решаются молча
        bool muted = false;
        var detector = Program.MakeDetector(cfg, pair, dict, learned, net, MakeCore(),
                                            s => { if (!muted) Say(s); });
        bool Silence(bool on) { bool was = muted; muted = on; return was; }

        var (stop, force) = learned.Snapshot();
        var ps = personal.Stats();
        Say($"⚙️ Ядро: {(detector.CoreV5 ? "v5 (одна формула)" : "legacy (каскад)")}; выученных правил: {stop.Count + force.Count}; " +
            $"личный слой: {(personal.Uses ? $"слов {ps.WordsRu + ps.WordsEn}, пар {ps.Pairs}" : "не участвует")}");
        var rep = detector.CoreV5
            // Свой экземпляр ядра: контекст прогона не смешивается с живым
            ? TestRunner.RunV5(text, detector, MakeCore(), pair, Say, Silence)
            : TestRunner.Run(text, detector, pair, Say, Silence);
        File.WriteAllText(ReportPath, rep.Text, new UTF8Encoding(true));
        if (rep.Total > 0) Say("\n" + rep.Summary);
        Say($"Отчёт: {ReportPath}");
        return 0;
    }
}
