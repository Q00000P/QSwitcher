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
    public const string Version = "0.1";
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

    public bool SoundEnabled { get; set; } = true;

    /// Звук когда текст исправлен, но раскладка НЕ менялась.
    /// Имя файла в папке Resources, полный путь к .wav, none,
    /// либо системный: beep | asterisk | exclamation | hand | question
    public string SoundConvertOnly { get; set; } = "convert.wav";

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
        if (!File.Exists(path)) cfg.Save();
        return cfg;
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

        var pauseItem = new ToolStripMenuItem("Пауза");
        pauseItem.Click += (_, _) =>
        {
            pauseItem.Checked = !pauseItem.Checked;
            // TODO: связать с монитором
        };
        menu.Items.Add(pauseItem);

        menu.Items.Add(new ToolStripSeparator());

        var secureItem = new ToolStripMenuItem("История набора…");
        secureItem.Click += (_, _) =>
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
        };
        menu.Items.Add(secureItem);

        var learnedItem = new ToolStripMenuItem("Выученные правила…");
        learnedItem.Click += (_, _) =>
        {
            using var form = new LearnedRulesForm(learned, pairForRules.Swap);
            form.ShowDialog();
        };
        menu.Items.Add(learnedItem);

        var autostartItem = new ToolStripMenuItem("Запускать при входе")
        {
            Checked = Autostart.IsEnabled(),
            CheckOnClick = true,
        };
        autostartItem.Click += (_, _) =>
        {
            if (autostartItem.Checked)
            {
                if (!Autostart.Enable())
                {
                    autostartItem.Checked = false;
                    MessageBox.Show("Не удалось записать автозапуск в реестр.", "QSwitcher");
                }
            }
            else Autostart.Disable();
        };
        menu.Items.Add(autostartItem);

        var soundItem = new ToolStripMenuItem("Звук") { Checked = cfg.SoundEnabled, CheckOnClick = true };
        soundItem.Click += (_, _) => { cfg.SoundEnabled = soundItem.Checked; cfg.Save(); };
        menu.Items.Add(soundItem);

        var excludedItem = new ToolStripMenuItem("Исключения…");
        excludedItem.Click += (_, _) =>
        {
            MessageBox.Show(
                "Свитчер не работает в этих процессах:" + Environment.NewLine + Environment.NewLine +
                string.Join(", ", cfg.ExcludedProcesses) + Environment.NewLine + Environment.NewLine +
                "Список правится в config.json (ExcludedProcesses)." + Environment.NewLine +
                "Сравнение по вхождению, .exe писать не нужно.",
                "QSwitcher — исключения");
        };
        menu.Items.Add(excludedItem);

        menu.Items.Add(new ToolStripSeparator());

        var hotkeyItem = new ToolStripMenuItem("Горячие клавиши…");
        hotkeyItem.Click += (_, _) =>
        {
            using var form = new HotkeySettingsForm(cfg.Hotkeys, () => cfg.Save());
            form.ShowDialog();
        };
        menu.Items.Add(hotkeyItem);

        var helpItem = new ToolStripMenuItem("Справка…");
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

        menu.Items.Add(new ToolStripSeparator());

        var exitItem = new ToolStripMenuItem("Выход");
        exitItem.Click += (_, _) => Application.Exit();
        menu.Items.Add(exitItem);

        _icon = new NotifyIcon
        {
            Text = "QSwitcher",
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

    private void UpdateIndicator()
    {
        try
        {
            bool other = KeyMap.QueryOtherLayoutActive();
            string label = other ? "RU" : "EN";
            bool paused = IsPaused?.Invoke() ?? false;
            if (label == _lastLabel && paused == _lastPaused) return;

            _lastLabel = label;
            _lastPaused = paused;
            var icon = TrayIconFactory.ForLayout(label, paused);
            _icon.Icon = icon;
            _icon.Text = paused ? $"QSwitcher — пауза ({label})" : $"QSwitcher — {label}";
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
