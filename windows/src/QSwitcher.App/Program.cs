using System.Runtime.InteropServices;
using QSwitcher.Core;

namespace QSwitcher.App;

/// <summary>
/// QSwitcher для Windows — автопереключатель раскладки RU↔EN.
/// Порт macOS-версии: детектор общий, платформенный слой свой.
///
/// Трей-иконка, назначаемые хоткеи (по умолчанию Pause как у Punto Switcher),
/// самообучение по явной команде.
/// </summary>
internal static class Program
{
    public static readonly string DataDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QSwitcher");

    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Directory.CreateDirectory(DataDir);

        // Лог буферизованный: запись в файл на каждой строке тормозит разбор
        // нажатий, а он и так в горячем пути.
        var logger = new BufferedLogger(Path.Combine(DataDir, "qswitcher.log"));
        void Log(string msg) => logger.Write(msg);

        Log($"===== QSwitcher {AppVersion.Version} запущен =====");

        var cfg = AppConfig.Load(DataDir, Log);
        var pair = LayoutPair.RuEn();

        var dict = WordDictionary.Load(Res.Open, Log);
        dict.MergeUser(Path.Combine(DataDir, "dicts", "en.txt"), latin: true);
        dict.MergeUser(Path.Combine(DataDir, "dicts", "ru.txt"), latin: false);

        // Без словарей детектор принимает решения вслепую — лучше сказать сразу,
        // чем ловить странные свапы. Так уже было: exe раздулся до 178 МБ,
        // потому что PublishSingleFile упаковал словари внутрь, и они не нашлись.
        if (dict.Latin.Count == 0 || dict.Other.Count == 0)
        {
            MessageBox.Show(
                "Словари не загружены — переключение работать не будет.\n\n" +
                $"en.txt: {dict.Latin.Count}, ru.txt: {dict.Other.Count}\n" +
                $"Встроено: {string.Join(", ", Res.Embedded())}\n\n" +
                "Похоже, сборка сделана без словарей: положи ru.txt и en.txt\n" +
                "в src\\QSwitcher.App\\Resources и пересобери.",
                "QSwitcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        else
        {
            Log($"Словари: en={dict.Latin.Count}, ru={dict.Other.Count}, " +
                $"короткие en={dict.ShortLatin.Count}, ru={dict.ShortOther.Count}");
        }

        // Защищённый лог: история набора шифруется, ключ под DPAPI
        var secureLog = new SecureLog(DataDir, Log) { Enabled = cfg.SecureLogEnabled };

        var learned = new LearnedRules(DataDir);

        // Снимаем взаимоисключающие пары, накопленные раньше: если записаны
        // и 'й → переключать', и 'q → переключать', слово переворачивается
        // бесконечно. Оставляем то, что человек задал последним, — но так как
        // порядок неизвестен, безопаснее убрать оба и дать задать заново.
        {
            var (stop, force) = learned.Snapshot();
            int removed = 0;
            foreach (var w in force.ToList())
            {
                var sw = pair.Swap(w);
                if (!string.Equals(sw, w, StringComparison.OrdinalIgnoreCase) && force.Contains(sw))
                {
                    learned.Remove(w);
                    learned.Remove(sw);
                    removed += 2;
                }
            }
            if (removed > 0)
                Log($"🧹 Снято {removed} взаимоисключающих правил (слово и его свап оба «переключать»)");
        }
        var detector = new Detector(pair, dict,
            learned,
            new DetectorConfig
            {
                ForceWords = cfg.ForceWords,
                StopWords = cfg.StopWords,
                MinWordLength = cfg.MinWordLength,
            }, Log);

        // Режим изоляции: QSWITCHER_PASSIVE=1 — хук ставится, но НИЧЕГО не делает.
        // Нужен чтобы понять, ломает ли чужие хоткеи сам факт установки хука
        // или наша обработка. Запуск:  $env:QSWITCHER_PASSIVE=1; .\QSwitcher.exe
        bool passive = Environment.GetEnvironmentVariable("QSWITCHER_PASSIVE") == "1";
        if (passive) Log("⚠️ ПАССИВНЫЙ РЕЖИМ: хук установлен, обработка отключена");

        using var replacer = new TextReplacer(Log) { StartDelayMs = cfg.ReplaceStartDelayMs };
        bool trace = Environment.GetEnvironmentVariable("QSWITCHER_TRACE") == "1";
        if (trace) Log("🔎 ТРАССИРОВКА включена");
        var hotkeys = new HotkeyDetector(cfg.Hotkeys);
        var sounds = new SoundPlayerService(
            () => cfg.SoundEnabled,
            () => cfg.SoundConvertOnly,
            () => cfg.SoundConvertAndSwitch,
            () => cfg.SoundUndo);
        var exclusions = new AppExclusions(() => cfg.ExcludedProcesses);

        using var monitor = new KeyboardMonitor(detector, pair, replacer, learned, Log)
        {
            Passive = passive,
            Trace = trace,
            Hotkeys = hotkeys,
            Sounds = sounds,
            Exclusions = exclusions,
            SecureLog = secureLog,
            RetroMaxChain = cfg.RetroMaxChain,
            RetroPrepositionsOnly = cfg.RetroPrepositionsOnly,
            SwitchLayoutAfter = cfg.SwitchLayoutAfter,
        };
        using var tray = new TrayUi(cfg, learned, secureLog, pair, Log);
        tray.IsPaused = () => monitor.Paused;
        tray.TogglePause = monitor.TogglePause;
        tray.SwapLastWord = monitor.RequestManualSwap;
        secureLog.Enabled = cfg.SecureLogEnabled;
        secureLog.LogPasswords = cfg.SecureLogPasswords;
        secureLog.MaxSizeMb = cfg.SecureLogMaxMb;
        secureLog.SetFlushInterval(cfg.SecureLogFlushSec);

        monitor.Start();
        Application.Run();
    }
}

/// <summary>
/// Лог с буферизацией: строки копятся в памяти и сбрасываются на диск раз в
/// секунду отдельным потоком.
/// </summary>
public sealed class BufferedLogger : IDisposable
{
    private readonly string _path;
    private readonly System.Collections.Concurrent.ConcurrentQueue<string> _queue = new();
    private readonly System.Threading.Timer _timer;

    public BufferedLogger(string path)
    {
        _path = path;
        _timer = new System.Threading.Timer(_ => Flush(), null, 1000, 1000);
    }

    public void Write(string msg)
    {
        _queue.Enqueue($"[{DateTime.Now:HH:mm:ss}] {msg}");
        System.Diagnostics.Debug.WriteLine(msg);
    }

    private void Flush()
    {
        if (_queue.IsEmpty) return;
        var sb = new System.Text.StringBuilder();
        while (_queue.TryDequeue(out var line)) sb.AppendLine(line);
        try { File.AppendAllText(_path, sb.ToString()); } catch { }
    }

    public void Dispose() { _timer.Dispose(); Flush(); }
}

/// <summary>Версия приложения.</summary>
public static class AppVersion
{
    public const string Version = "3.2";
}

/// <summary>
/// Конфиг приложения: %APPDATA%\QSwitcher\config.json
/// Хоткеи назначаемые — хранятся здесь же, меняются через меню трея.
/// </summary>
public sealed class AppConfig
{
    public HashSet<string> ForceWords { get; set; } = new();
    public HashSet<string> StopWords { get; set; } = new()
    {
        "api","cli","css","dns","git","gui","html","ide","json","npm",
        "sql","ssh","ssl","tcp","udp","url","vpn","xml","yaml"
    };
    public int MinWordLength { get; set; } = 2;

    /// <summary>Горячие клавиши. Переназначаются через меню трея.</summary>
    public HotkeyMap Hotkeys { get; set; } = new();

    /// Процессы, где свитчер не работает. Сравнение по вхождению, без .exe.
    /// Терминалы — потому что свап портит команды, менеджеры паролей —
    /// потому что в поле пароля вмешиваться нельзя вовсе.
    public List<string> ExcludedProcesses { get; set; } = new()
    {
        "1Password", "KeePass", "Bitwarden", "LastPass",
        "WindowsTerminal", "cmd", "powershell", "pwsh", "conhost",
        "putty", "mintty", "wt",
    };

    /// Пауза перед стиранием при замене, миллисекунды.
    /// Если текст иногда уезжает назад — увеличь до 40-60.
    public int ReplaceStartDelayMs { get; set; } = 25;

    /// После скольких конвертаций подряд менять раскладку. 0 — никогда, 1 — сразу.
    public int SwitchLayoutAfter { get; set; } = 2;

    /// Сколько одиночных букв перед словом подхватывать при свапе.
    /// 0 — выключить ретроконверсию.
    public int RetroMaxChain { get; set; } = 4;

    /// Подхватывать только те буквы, чей свап даёт русский предлог.
    /// По умолчанию выключено — работает без ограничений.
    public bool RetroPrepositionsOnly { get; set; }

    /// Писать историю набора в зашифрованный файл.
    public bool SecureLogEnabled { get; set; } = true;

    /// Писать ли в защищённый лог набор в полях паролей (детект через UIA IsPassword).
    public bool SecureLogPasswords { get; set; } = true;

    /// Интервал сброса буфера защищённого лога на диск, сек.
    public int SecureLogFlushSec { get; set; } = 3;

    /// Лимит размера базы защищённого лога, МБ.
    public int SecureLogMaxMb { get; set; } = 50;

    public bool SoundEnabled { get; set; } = true;

    /// Звук когда текст исправлен, но раскладка НЕ менялась.
    /// Имя файла в папке Resources, полный путь к .wav, none,
    /// либо системный: beep | asterisk | exclamation | hand | question
    public string SoundConvertOnly { get; set; } = "replace.wav";

    /// Звук когда исправлен текст И переключена раскладка.
    public string SoundConvertAndSwitch { get; set; } = "switch.wav";

    /// Звук отката (тоггл вернул исходный вариант).
    public string SoundUndo { get; set; } = "undo.wav";

    private string _path = "";

    public static AppConfig Load(string dir, Action<string> log)
    {
        var path = Path.Combine(dir, "config.json");
        AppConfig cfg;
        try
        {
            cfg = File.Exists(path)
                ? System.Text.Json.JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(path)) ?? new()
                : new();
        }
        catch (Exception ex)
        {
            log($"⚠️ Конфиг не прочитался ({ex.Message}) — использую значения по умолчанию");
            cfg = new();
        }
        cfg._path = path;
        // Миграция: convert.wav заменён на replace.wav (звук без переключения раскладки)
        if (cfg.SoundConvertOnly == "convert.wav") { cfg.SoundConvertOnly = "replace.wav"; cfg.Save(); }
        if (!File.Exists(path)) cfg.Save();
        return cfg;
    }

    public string PathOnDisk => _path;

    /// Перечитать config.json В ТОТ ЖЕ объект: на cfg и его коллекции держат
    /// ссылки детектор и замыкания меню, поэтому подменять объект нельзя —
    /// мутируем содержимое. Хоткеи применятся после перезапуска.
    public void ReloadInPlace(Action<string> log)
    {
        AppConfig fresh;
        try
        {
            fresh = System.Text.Json.JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(_path)) ?? new();
        }
        catch (Exception ex)
        {
            log($"⚠️ Конфиг не перечитался: {ex.Message}");
            return;
        }
        MinWordLength = fresh.MinWordLength;
        ReplaceStartDelayMs = fresh.ReplaceStartDelayMs;
        SwitchLayoutAfter = fresh.SwitchLayoutAfter;
        RetroMaxChain = fresh.RetroMaxChain;
        RetroPrepositionsOnly = fresh.RetroPrepositionsOnly;
        SecureLogEnabled = fresh.SecureLogEnabled;
        SecureLogPasswords = fresh.SecureLogPasswords;
        SecureLogFlushSec = fresh.SecureLogFlushSec;
        SecureLogMaxMb = fresh.SecureLogMaxMb;
        SoundEnabled = fresh.SoundEnabled;
        SoundConvertOnly = fresh.SoundConvertOnly;
        SoundConvertAndSwitch = fresh.SoundConvertAndSwitch;
        SoundUndo = fresh.SoundUndo;
        ForceWords.Clear(); ForceWords.UnionWith(fresh.ForceWords);
        StopWords.Clear(); StopWords.UnionWith(fresh.StopWords);
        ExcludedProcesses.Clear(); ExcludedProcesses.AddRange(fresh.ExcludedProcesses);
        log("🔄 Конфиг перечитан (горячие клавиши — после перезапуска)");
    }

    public void Save()
    {
        File.WriteAllText(_path, System.Text.Json.JsonSerializer.Serialize(this,
            new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
    }
}

/// <summary>
/// Иконка в трее с меню: пауза, выученные правила, настройка хоткея, выход.
/// </summary>
public sealed class TrayUi : IDisposable
{
    private readonly NotifyIcon _icon;

    public TrayUi(AppConfig cfg, LearnedRules learned, SecureLog secureLog,
                  LayoutPair pairForRules, Action<string> log)
    {
        var menu = new ContextMenuStrip();

        // === Заголовок-статус (обновляется UpdateIndicator) ===
        _headerItem = new ToolStripMenuItem("QSwitcher активен") { Enabled = false };
        menu.Items.Add(_headerItem);
        menu.Items.Add(new ToolStripSeparator());

        // === Пауза / свап последнего слова / звук ===
        _pauseItem = new ToolStripMenuItem("Поставить на паузу");
        _pauseItem.Click += (_, _) => { TogglePause?.Invoke(); UpdateIndicator(); };
        menu.Items.Add(_pauseItem);

        var swapLastItem = new ToolStripMenuItem("Переключить последнее слово");
        swapLastItem.Click += (_, _) => SwapLastWord?.Invoke();
        menu.Items.Add(swapLastItem);

        var soundItem = new ToolStripMenuItem("Звук переключения")
            { Checked = cfg.SoundEnabled, CheckOnClick = true };
        soundItem.Click += (_, _) => { cfg.SoundEnabled = soundItem.Checked; cfg.Save(); };
        menu.Items.Add(soundItem);

        menu.Items.Add(new ToolStripSeparator());

        // === Исключения ===
        var excludeCurrentItem = new ToolStripMenuItem("Исключить: …");
        excludeCurrentItem.Click += (_, _) =>
        {
            var p = _lastForeignProcess;
            if (string.IsNullOrEmpty(p)) return;
            if (!cfg.ExcludedProcesses.Contains(p, StringComparer.OrdinalIgnoreCase))
            {
                cfg.ExcludedProcesses.Add(p);
                cfg.Save();
                log($"[excl] добавлен {p}");
            }
        };
        menu.Items.Add(excludeCurrentItem);

        var excludedListItem = new ToolStripMenuItem("Исключённые приложения");
        excludedListItem.DropDownOpening += (_, _) =>
        {
            excludedListItem.DropDownItems.Clear();
            foreach (var p in cfg.ExcludedProcesses.OrderBy(x => x))
            {
                var it = new ToolStripMenuItem(p) { ToolTipText = "Клик — убрать из исключений" };
                it.Click += (_, _) => { cfg.ExcludedProcesses.Remove(p); cfg.Save(); };
                excludedListItem.DropDownItems.Add(it);
            }
            if (excludedListItem.DropDownItems.Count == 0)
                excludedListItem.DropDownItems.Add(new ToolStripMenuItem("(пусто)") { Enabled = false });
        };
        // Пустышка, чтобы стрелка подменю была видна до первого открытия
        excludedListItem.DropDownItems.Add(new ToolStripMenuItem("…") { Enabled = false });
        menu.Items.Add(excludedListItem);

        menu.Items.Add(new ToolStripSeparator());

        // === Стоп/форс-слова ===
        var stopItem = new ToolStripMenuItem("Стоп-слова (никогда не переключать)");
        BuildWordListSubmenu(stopItem, cfg.StopWords, cfg, log);
        menu.Items.Add(stopItem);

        var forceItem = new ToolStripMenuItem("Форс-слова (всегда переключать)");
        BuildWordListSubmenu(forceItem, cfg.ForceWords, cfg, log);
        menu.Items.Add(forceItem);

        menu.Items.Add(new ToolStripSeparator());

        // === Конфиг ===
        var openCfgItem = new ToolStripMenuItem("Открыть конфиг…");
        openCfgItem.Click += (_, _) =>
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(cfg.PathOnDisk) { UseShellExecute = true }); }
            catch (Exception ex) { MessageBox.Show($"Не открылся: {ex.Message}", "QSwitcher"); }
        };
        menu.Items.Add(openCfgItem);

        var reloadCfgItem = new ToolStripMenuItem("Перезагрузить конфиг");
        reloadCfgItem.Click += (_, _) => cfg.ReloadInPlace(log);
        menu.Items.Add(reloadCfgItem);

        // === Защищённый лог (подменю как на маке) ===
        _secureLogItem = new ToolStripMenuItem("Защищённый лог");

        var slEnabledItem = new ToolStripMenuItem("Логирование")
            { Checked = cfg.SecureLogEnabled, CheckOnClick = true };
        slEnabledItem.Click += (_, _) =>
        {
            cfg.SecureLogEnabled = slEnabledItem.Checked;
            secureLog.Enabled = slEnabledItem.Checked;
            cfg.Save();
        };
        _secureLogItem.DropDownItems.Add(slEnabledItem);

        var slPasswordsItem = new ToolStripMenuItem("Логировать пароли (поля паролей)")
            { Checked = cfg.SecureLogPasswords, CheckOnClick = true };
        slPasswordsItem.Click += (_, _) =>
        {
            cfg.SecureLogPasswords = slPasswordsItem.Checked;
            secureLog.LogPasswords = slPasswordsItem.Checked;
            cfg.Save();
        };
        _secureLogItem.DropDownItems.Add(slPasswordsItem);

        var slShowItem = new ToolStripMenuItem("Показать историю…");
        slShowItem.Click += (_, _) => ShowSecureLogWindow(secureLog);
        _secureLogItem.DropDownItems.Add(slShowItem);

        var slFlushItem = new ToolStripMenuItem("Выгрузить в базу сейчас");
        slFlushItem.Click += (_, _) => { secureLog.FlushNow(); log("[secure] буфер выгружен"); };
        _secureLogItem.DropDownItems.Add(slFlushItem);

        var slExportItem = new ToolStripMenuItem("Экспортировать (расшифровать)…");
        slExportItem.Click += (_, _) => ExportSecureLog(secureLog);
        _secureLogItem.DropDownItems.Add(slExportItem);

        var slIntervalItem = new ToolStripMenuItem("Интервал сброса буфера");
        foreach (int sec in new[] { 1, 3, 10, 30 })
        {
            var it = new ToolStripMenuItem($"{sec} с") { Checked = cfg.SecureLogFlushSec == sec };
            it.Click += (_, _) =>
            {
                cfg.SecureLogFlushSec = sec;
                secureLog.SetFlushInterval(sec);
                cfg.Save();
                foreach (ToolStripMenuItem sib in slIntervalItem.DropDownItems) sib.Checked = sib == it;
            };
            slIntervalItem.DropDownItems.Add(it);
        }
        _secureLogItem.DropDownItems.Add(slIntervalItem);

        var slLimitItem = new ToolStripMenuItem("Лимит размера базы");
        foreach (int mb in new[] { 10, 50, 100, 500 })
        {
            var it = new ToolStripMenuItem($"{mb} МБ") { Checked = cfg.SecureLogMaxMb == mb };
            it.Click += (_, _) =>
            {
                cfg.SecureLogMaxMb = mb;
                secureLog.MaxSizeMb = mb;
                cfg.Save();
                foreach (ToolStripMenuItem sib in slLimitItem.DropDownItems) sib.Checked = sib == it;
            };
            slLimitItem.DropDownItems.Add(it);
        }
        _secureLogItem.DropDownItems.Add(slLimitItem);

        var slWipeItem = new ToolStripMenuItem("Очистить базу…");
        slWipeItem.Click += (_, _) =>
        {
            if (MessageBox.Show("Стереть историю набора без возможности восстановления?",
                    "QSwitcher", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
            {
                secureLog.Wipe();
                log("[secure] база стёрта");
            }
        };
        _secureLogItem.DropDownItems.Add(slWipeItem);

        var slStatsItem = new ToolStripMenuItem("Статистика…");
        slStatsItem.Click += (_, _) => MessageBox.Show(
            $"Размер базы: {secureLog.SizeBytes / 1024} КБ (лимит {cfg.SecureLogMaxMb} МБ)" + Environment.NewLine +
            $"Сброс буфера: каждые {cfg.SecureLogFlushSec} с" + Environment.NewLine +
            $"Логирование: {(cfg.SecureLogEnabled ? "включено" : "выключено")}" + Environment.NewLine +
            "Шифрование: AES-256-GCM, ключ в DPAPI, чтение через Windows Hello",
            "QSwitcher — защищённый лог");
        _secureLogItem.DropDownItems.Add(slStatsItem);

        menu.Items.Add(_secureLogItem);

        // === Справка / правила / о программе ===
        var helpItem = new ToolStripMenuItem("Справка / Горячие клавиши…");
        helpItem.Click += (_, _) =>
        {
            var lines = cfg.Hotkeys.All()
                .Select(x => $"{x.title,-28} {x.binding.Display}");
            MessageBox.Show(
                string.Join(Environment.NewLine, lines) + Environment.NewLine + Environment.NewLine +
                "Тап — нажать и отпустить модификатор, ничего больше не задев." + Environment.NewLine +
                "Правила создаются только через «Свап и запомнить»." + Environment.NewLine +
                "Обычный свап и тоггл ничего не запоминают.",
                "QSwitcher — горячие клавиши");
        };
        menu.Items.Add(helpItem);

        var hotkeyItem = new ToolStripMenuItem("Настроить горячие клавиши…");
        hotkeyItem.Click += (_, _) =>
        {
            using var form = new HotkeySettingsForm(cfg.Hotkeys, () => cfg.Save());
            form.ShowDialog();
        };
        menu.Items.Add(hotkeyItem);

        var learnedItem = new ToolStripMenuItem("Выученные правила…");
        learnedItem.Click += (_, _) =>
        {
            using var form = new LearnedRulesForm(learned, pairForRules.Swap);
            form.ShowDialog();
        };
        menu.Items.Add(learnedItem);

        var resetLearnedItem = new ToolStripMenuItem("Сбросить выученное…");
        resetLearnedItem.Click += (_, _) =>
        {
            if (MessageBox.Show("Удалить все выученные правила?", "QSwitcher",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
            {
                learned.Reset();
                log("[learned] правила сброшены");
            }
        };
        menu.Items.Add(resetLearnedItem);

        var aboutItem = new ToolStripMenuItem("О программе…");
        aboutItem.Click += (_, _) => MessageBox.Show(
            $"QSwitcher для Windows {AppVersion.Version}" + Environment.NewLine + Environment.NewLine +
            $"Конфиг: {cfg.PathOnDisk}" + Environment.NewLine +
            "Автопереключение раскладки RU↔EN, самообучение, защищённый лог.",
            "QSwitcher");
        menu.Items.Add(aboutItem);

        var autostartItem2 = new ToolStripMenuItem("Запускать при входе") { Checked = Autostart.IsEnabled(), CheckOnClick = true };
        autostartItem2.Click += (_, _) =>
        {
            if (autostartItem2.Checked)
            {
                if (!Autostart.Enable())
                {
                    autostartItem2.Checked = false;
                    MessageBox.Show("Не удалось записать автозапуск в реестр.", "QSwitcher");
                }
            }
            else Autostart.Disable();
        };
        menu.Items.Add(autostartItem2);

        // === Счётчики (обновляются при открытии меню) ===
        _countersItem = new ToolStripMenuItem("") { Enabled = false };
        menu.Items.Add(_countersItem);
        menu.Items.Add(new ToolStripSeparator());

        var exitItem = new ToolStripMenuItem("Выход");
        exitItem.Click += (_, _) => Application.Exit();
        menu.Items.Add(exitItem);

        // Живые надписи при каждом открытии меню
        menu.Opening += (_, _) =>
        {
            bool paused = IsPaused?.Invoke() ?? false;
            string label = KeyMap.QueryOtherLayoutActive() ? "RU" : "EN";
            _headerItem.Text = paused ? $"QSwitcher на паузе ({label})" : $"QSwitcher активен ({label})";
            _pauseItem.Text = paused ? "Снять с паузы" : "Поставить на паузу";
            excludeCurrentItem.Text = string.IsNullOrEmpty(_lastForeignProcess)
                ? "Исключить: (нет окна)" : $"Исключить: {_lastForeignProcess}";
            excludeCurrentItem.Enabled = !string.IsNullOrEmpty(_lastForeignProcess);
            excludedListItem.Text = $"Исключённые приложения ({cfg.ExcludedProcesses.Count})";
            stopItem.Text = $"Стоп-слова (никогда не переключать) ({cfg.StopWords.Count})";
            forceItem.Text = $"Форс-слова (всегда переключать) ({cfg.ForceWords.Count})";
            _secureLogItem.Text = $"Защищённый лог ({(cfg.SecureLogEnabled ? "вкл" : "выкл")})";
            _countersItem.Text = $"Исключений: {cfg.ExcludedProcesses.Count} · стоп: {cfg.StopWords.Count} · форс: {cfg.ForceWords.Count}";
        };

        _icon = new NotifyIcon
        {
            Text = $"QSwitcher {AppVersion.Version}",
            Icon = TrayIconFactory.ForLayout("EN", paused: false),
            ContextMenuStrip = menu,
            Visible = true,
        };

        // Левый клик по иконке открывает то же меню, что и правый.
        // NotifyIcon по умолчанию показывает меню только правой кнопкой.
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            try
            {
                var m = typeof(NotifyIcon).GetMethod("ShowContextMenu",
                    System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
                if (m is not null) { m.Invoke(_icon, null); return; }
            }
            catch { }
            menu.Show(Control.MousePosition);
        };

        // Обновляем индикатор раскладки. Опрос в фоне: раскладка меняется
        // и снаружи (Alt+Shift, языковая панель), уведомления об этом
        // ненадёжны для чужих окон.
        _layoutTimer = new System.Threading.Timer(_ => UpdateIndicator(), null, 500, 700);
    }

    private readonly System.Threading.Timer? _layoutTimer;
    private string _lastLabel = "";
    private bool _lastPaused;

    /// Приложение сообщает сюда, стоит ли оно на паузе.
    public Func<bool>? IsPaused { get; set; }

    private readonly ToolStripMenuItem _headerItem = null!;
    private readonly ToolStripMenuItem _pauseItem = null!;
    private readonly ToolStripMenuItem _secureLogItem = null!;
    private readonly ToolStripMenuItem _countersItem = null!;

    public Action? TogglePause { get; set; }
    public Action? SwapLastWord { get; set; }

    /// Имя процесса последнего чужого окна с фокусом — цель пункта «Исключить: X».
    /// Трекается таймером: в момент клика по трею фокус уже у меню.
    private string _lastForeignProcess = "";

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    private void TrackForegroundProcess()
    {
        try
        {
            IntPtr hwnd = GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return;
            GetWindowThreadProcessId(hwnd, out uint pid);
            if (pid == 0 || pid == Environment.ProcessId) return;
            string name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName;
            if (!string.IsNullOrEmpty(name) && name != "explorer")
                _lastForeignProcess = name;
        }
        catch { }
    }

    /// Подменю списка слов: клик по слову — удалить, «Добавить…» — ввод.
    private static void BuildWordListSubmenu(ToolStripMenuItem parent, HashSet<string> words,
        AppConfig cfg, Action<string> log)
    {
        parent.DropDownItems.Add(new ToolStripMenuItem("…") { Enabled = false });
        parent.DropDownOpening += (_, _) =>
        {
            parent.DropDownItems.Clear();
            var addItem = new ToolStripMenuItem("Добавить…");
            addItem.Click += (_, _) =>
            {
                string? w = Prompt("Слово:", parent.Text);
                w = w?.Trim().ToLowerInvariant();
                if (!string.IsNullOrEmpty(w)) { words.Add(w); cfg.Save(); log($"[words] + {w}"); }
            };
            parent.DropDownItems.Add(addItem);
            if (words.Count > 0) parent.DropDownItems.Add(new ToolStripSeparator());
            foreach (var w in words.OrderBy(x => x))
            {
                var it = new ToolStripMenuItem(w) { ToolTipText = "Клик — удалить" };
                it.Click += (_, _) => { words.Remove(w); cfg.Save(); log($"[words] - {w}"); };
                parent.DropDownItems.Add(it);
            }
        };
    }

    /// Простейший ввод строки (в WinForms нет InputBox).
    private static string? Prompt(string label, string title)
    {
        using var form = new Form
        {
            Text = title, ClientSize = new Size(340, 96),
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MinimizeBox = false, MaximizeBox = false,
        };
        var lbl = new Label { Text = label, Left = 10, Top = 10, AutoSize = true };
        var box = new TextBox { Left = 10, Top = 30, Width = 320 };
        var ok = new Button { Text = "OK", Left = 174, Top = 62, Width = 75, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Отмена", Left = 255, Top = 62, Width = 75, DialogResult = DialogResult.Cancel };
        form.Controls.AddRange(new Control[] { lbl, box, ok, cancel });
        form.AcceptButton = ok; form.CancelButton = cancel;
        return form.ShowDialog() == DialogResult.OK ? box.Text : null;
    }

    /// Окно просмотра истории (Windows Hello как гейт — см. комментарий внутри).
    private static void ShowSecureLogWindow(SecureLog secureLog)
    {
        // Окно открываем СРАЗУ, ещё до проверки личности: системный запрос
        // Windows Hello привязывается к нему как к настоящему активному
        // окну. С фиктивным невидимым якорем запрос появлялся неактивным
        // и не принимал ни отпечаток, ни ПИН без клика мышью.
        var form = new Form
        {
            Text = "QSwitcher — история набора",
            ClientSize = new Size(700, 520),
            StartPosition = FormStartPosition.CenterScreen,
            ShowInTaskbar = true,
        };
        var box = new TextBox
        {
            Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both,
            WordWrap = false, Dock = DockStyle.Fill,
            Text = "Подтвердите личность…",
            Font = new Font("Consolas", 9f),
        };
        form.Controls.Add(box);

        var panel = new Panel { Dock = DockStyle.Bottom, Height = 40 };
        var wipe = new Button { Text = "Стереть историю", Left = 8, Top = 6, Width = 140, Enabled = false };
        wipe.Click += (_, _) =>
        {
            if (MessageBox.Show("Стереть историю набора без возможности восстановления?",
                    "QSwitcher", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
            {
                secureLog.Wipe();
                box.Text = "Лог пуст.";
            }
        };
        panel.Controls.Add(wipe);
        form.Controls.Add(panel);

        form.Shown += async (_, _) =>
        {
            // Просто активируем и даём окну устояться. Принудительный вывод
            // на передний план делал хуже: наше окно оказывалось ВЫШЕ
            // системного запроса, и тот прятался под ним.
            form.Activate();
            await Task.Delay(150);
            string text = await secureLog.ReadAsync(form.Handle);
            box.Text = text;
            form.Text = $"QSwitcher — история набора ({secureLog.SizeBytes / 1024} КБ)";
            wipe.Enabled = true;
        };

        form.ShowDialog();
        form.Dispose();
    }

    /// Экспорт расшифрованной истории в файл (тот же Hello-гейт).
    private static void ExportSecureLog(SecureLog secureLog)
    {
        var form = new Form
        {
            Text = "QSwitcher — экспорт истории",
            ClientSize = new Size(380, 70),
            StartPosition = FormStartPosition.CenterScreen,
            FormBorderStyle = FormBorderStyle.FixedDialog,
        };
        var lbl = new Label { Text = "Подтвердите личность…", Left = 12, Top = 22, AutoSize = true };
        form.Controls.Add(lbl);
        form.Shown += async (_, _) =>
        {
            form.Activate();
            await Task.Delay(150);
            string text = await secureLog.ReadAsync(form.Handle, int.MaxValue);
            form.Hide();
            using var dlg = new SaveFileDialog
            {
                FileName = $"qswitcher-history-{DateTime.Now:yyyyMMdd-HHmm}.txt",
                Filter = "Текст (*.txt)|*.txt",
            };
            if (dlg.ShowDialog() == DialogResult.OK)
                File.WriteAllText(dlg.FileName, text);
            form.Close();
        };
        form.ShowDialog();
        form.Dispose();
    }

    private void UpdateIndicator()
    {
        try
        {
            bool other = KeyMap.QueryOtherLayoutActive();
            string label = other ? "RU" : "EN";
            bool paused = IsPaused?.Invoke() ?? false;
            TrackForegroundProcess();
            if (label == _lastLabel && paused == _lastPaused) return;

            _lastLabel = label;
            _lastPaused = paused;
            var icon = TrayIconFactory.ForLayout(label, paused);
            _icon.Icon = icon;
            _icon.Text = paused ? $"QSwitcher {AppVersion.Version} — пауза ({label})" : $"QSwitcher {AppVersion.Version} — {label}";
        }
        catch { }
    }

    private static System.Drawing.Icon LoadIcon()
    {
        try
        {
            using var s = Res.Open("qswitcher.ico");
            if (s is not null) return new System.Drawing.Icon(s);
        }
        catch { }
        return System.Drawing.SystemIcons.Application;
    }

    public void Dispose() { _layoutTimer?.Dispose(); _icon.Visible = false; _icon.Dispose(); }
}

/// <summary>Мелкие системные вызовы для окон.</summary>
internal static class NativeMethods
{
    /// <summary>
    /// Вывести окно на передний план по-настоящему.
    ///
    /// Windows не даёт менять активное окно процессу, который сам не в фокусе.
    /// Фоновое приложение из трея как раз такой, поэтому обычного вызова мало —
    /// временно привязываемся к потоку активного окна.
    /// </summary>
    public static void BringToFront(IntPtr hwnd)
    {
        try
        {
            IntPtr fg = GetForegroundWindow();
            uint fgThread = GetWindowThreadProcessId(fg, out _);
            uint ourThread = GetCurrentThreadId();
            bool attached = fgThread != ourThread && AttachThreadInput(ourThread, fgThread, true);
            try
            {
                ShowWindow(hwnd, 5 /*SW_SHOW*/);
                BringWindowToTop(hwnd);
                SetForegroundWindow(hwnd);
            }
            finally
            {
                if (attached) AttachThreadInput(ourThread, fgThread, false);
            }
        }
        catch { }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int cmd);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr h);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
}
