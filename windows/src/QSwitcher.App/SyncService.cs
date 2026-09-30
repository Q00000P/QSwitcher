using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using QSwitcher.Core;

namespace QSwitcher.App;

/// <summary>Настройки синхронизации без секретов: %APPDATA%\QSwitcher\sync.json.</summary>
public sealed class SyncSettings
{
    /// "gdrive", "webdav" или "" (не настроена).
    public string Backend { get; set; } = "";
    /// Сама: раз в минуту и по событиям (блокировка, сон, пробуждение).
    public bool Auto { get; set; } = true;
    public string WebDavUrl { get; set; } = WebDavTransport.DefaultUrl;
    public string WebDavUser { get; set; } = "";

    public static SyncSettings Load(string path)
    {
        try
        {
            if (File.Exists(path)) return JsonSerializer.Deserialize<SyncSettings>(File.ReadAllText(path)) ?? new();
        }
        catch { }
        return new();
    }

    public void Save(string path) =>
        File.WriteAllText(path, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
}

/// <summary>Секреты синхронизации: пароль, вход в Google, пароль WebDAV. На диске —
/// sync-secrets.bin = "QSS1" + DPAPI (текущий пользователь). Открытым текстом нигде.</summary>
internal sealed class SyncSecrets
{
    public string Password { get; set; } = "";
    public string GDriveRefresh { get; set; } = "";
    public string WebDavPassword { get; set; } = "";

    private const string Magic = "QSS1";
    private static readonly byte[] Entropy = Encoding.ASCII.GetBytes("QSwitcher.sync.v1");

    public static SyncSecrets Load(string path, Action<string> log)
    {
        try
        {
            if (!File.Exists(path)) return new();
            byte[] data = File.ReadAllBytes(path);
            if (data.Length < 4 || Encoding.ASCII.GetString(data, 0, 4) != Magic) throw new InvalidDataException("не QSS1");
            byte[] plain = ProtectedData.Unprotect(data[4..], Entropy, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<SyncSecrets>(plain) ?? new();
        }
        catch (Exception e)
        {
            log($"[sync] секреты не прочитались ({e.Message}) — подключение и пароль нужно задать заново");
            return new();
        }
    }

    public void Save(string path)
    {
        byte[] enc = ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(this), Entropy, DataProtectionScope.CurrentUser);
        string tmp = path + ".tmp";
        using (var f = File.Create(tmp))
        {
            f.Write(Encoding.ASCII.GetBytes(Magic));
            f.Write(enc);
        }
        File.Move(tmp, path, overwrite: true);
    }
}

/// <summary>
/// Синхронизация навыков с другими устройствами (мак, другие компьютеры): личный слой,
/// выученные правила, стоп- и форс-слова, исключённые приложения и английский ввод (свои для
/// винды), ожидание языка по приложениям, журнал профиля. Круг — SyncEngine (Core).
///
/// Когда: через 15 с после запуска; раз в минуту (чужие файлы — если изменились, свои правила и
/// списки — если изменились; личный слой — не чаще раза в 5 минут); блокировка, сон, выход из
/// системы, выход из программы — отправить сразу; разблокировка, пробуждение — забрать сразу;
/// «Синхронизировать сейчас» — вручную.
/// </summary>
public sealed class SyncService : IDisposable, ISyncHost
{
    public const string PlatformName = "win";

    private readonly string _dir;
    private readonly AppConfig _cfg;
    private readonly LearnedRules _learned;
    private readonly AppLangStats _appStats;
    private readonly Action<string> _log;
    private readonly Action _savePersonal;
    private readonly SynchronizationContext? _ui;
    private readonly SyncEngine _engine;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly CancellationTokenSource _cts = new();
    private readonly CancellationTokenSource _uiCts = new();
    private readonly object _reqLock = new();
    private SyncSettings _settings;
    private SyncSecrets _secrets;
    private ISyncTransport? _transport;
    private System.Threading.Timer? _timer;
    private bool _running, _again, _wantForce, _stopping;
    private volatile bool _inline;
    private string _lastError = "", _loggedError = "";

    public PersonalLM Personal { get; }

    public SyncService(string dataDir, AppConfig cfg, LearnedRules learned, AppLangStats appStats,
                       PersonalLM personal, Action savePersonal, Action<string> log)
    {
        _dir = dataDir;
        _cfg = cfg;
        _learned = learned;
        _appStats = appStats;
        Personal = personal;
        _savePersonal = savePersonal;
        _log = log;
        _ui = SynchronizationContext.Current;     // создаётся на потоке интерфейса, после меню трея
        _settings = SyncSettings.Load(SettingsPath);
        _secrets = SyncSecrets.Load(SecretsPath, log);
        _engine = new SyncEngine(this, Path.Combine(dataDir, "sync-state.json"), log);
        _lastError = _engine.State.LastError;
    }

    private string SettingsPath => Path.Combine(_dir, "sync.json");
    private string SecretsPath => Path.Combine(_dir, "sync-secrets.bin");

    // ------------------------------------------------------------ запуск и события

    /// <summary>Таймер и системные события. Первый круг — через 15 с после запуска.</summary>
    public void Start()
    {
        _timer = new System.Threading.Timer(_ => Request(false, "таймер"), null, 15_000, 60_000);
        try
        {
            SystemEvents.SessionSwitch += OnSessionSwitch;
            SystemEvents.PowerModeChanged += OnPowerModeChanged;
            SystemEvents.SessionEnding += OnSessionEnding;
        }
        catch (Exception e) { _log($"[sync] системные события недоступны: {e.Message}"); }
        if (Configured) _log($"[sync] {Where}: авто {(_settings.Auto ? "вкл" : "выкл")}, устройство {Device}");
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        switch (e.Reason)
        {
            case SessionSwitchReason.SessionLock:
            case SessionSwitchReason.ConsoleDisconnect:
            case SessionSwitchReason.RemoteDisconnect:
                Request(true, "блокировка");
                break;
            case SessionSwitchReason.SessionUnlock:
            case SessionSwitchReason.ConsoleConnect:
            case SessionSwitchReason.RemoteConnect:
                Request(false, "разблокировка", delayMs: 3_000);
                break;
        }
    }

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) Request(true, "сон");
        else if (e.Mode == PowerModes.Resume) Request(false, "пробуждение", delayMs: 10_000);   // сеть поднимается не сразу
    }

    private void OnSessionEnding(object? sender, SessionEndingEventArgs e) => PushBlocking(3_000, "выход из системы");

    /// <summary>Выход из программы: отправить своё (не дольше нескольких секунд).</summary>
    public void Shutdown()
    {
        if (_stopping) return;
        _stopping = true;
        _timer?.Dispose();
        try
        {
            SystemEvents.SessionSwitch -= OnSessionSwitch;
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            SystemEvents.SessionEnding -= OnSessionEnding;
        }
        catch { }
        PushBlocking(6_000, "выход");
    }

    /// Отправить своё, дождавшись не дольше timeoutMs. Цикл сообщений может уже не крутиться:
    /// чтение своего — прямо здесь, ожидающие задачи интерфейса снимаются.
    private void PushBlocking(int timeoutMs, string reason)
    {
        if (!Configured) return;
        _inline = true;
        _uiCts.Cancel();
        try
        {
            Task.Run(async () =>
            {
                if (!await _gate.WaitAsync(timeoutMs / 2).ConfigureAwait(false)) return;
                try
                {
                    var t = Transport(out _);
                    if (t is null) return;
                    using var cts = new CancellationTokenSource(timeoutMs);
                    var rep = await _engine.RunAsync(t, _secrets.Password, forcePush: true, pull: false, cts.Token).ConfigureAwait(false);
                    if (rep.Pushed) _log($"[sync] {reason}: своё отправлено");
                }
                catch (Exception e) { _log($"[sync] {reason}: не отправилось ({e.Message})"); }
                finally { _gate.Release(); }
            }).Wait(timeoutMs + 500);
        }
        catch { }
    }

    /// <summary>Попросить круг. forcePush — своё отправить сразу (личный слой тоже).</summary>
    public void Request(bool forcePush, string reason, int delayMs = 0)
    {
        if (_stopping || !Configured || !_settings.Auto) return;
        if (delayMs > 0)
        {
            _ = Task.Delay(delayMs).ContinueWith(_ => Request(forcePush, reason), TaskScheduler.Default);
            return;
        }
        lock (_reqLock)
        {
            _wantForce |= forcePush;
            if (_running) { _again = true; return; }
            _running = true;
        }
        _ = Task.Run(async () =>
        {
            while (true)
            {
                bool force;
                lock (_reqLock) { force = _wantForce; _wantForce = false; _again = false; }
                await RunAsync(force, reason, manual: false).ConfigureAwait(false);
                lock (_reqLock)
                {
                    if (!_again || _stopping) { _running = false; return; }
                }
            }
        });
    }

    /// <summary>«Синхронизировать сейчас»: круг с отправкой своего; итог для человека.</summary>
    public async Task<(bool Ok, string Text)> SyncNowAsync()
    {
        if (!Configured) return (false, "Синхронизация не настроена: подключите Google Drive или WebDAV.");
        var rep = await RunAsync(true, "вручную", manual: true).ConfigureAwait(false);
        if (rep is null) return (false, _lastError.Length > 0 ? _lastError : "Не удалось.");
        return (rep.Problems.Count == 0, rep.Summary());
    }

    private async Task<SyncReport?> RunAsync(bool forcePush, string reason, bool manual)
    {
        try { await _gate.WaitAsync(_cts.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return null; }
        try
        {
            var t = Transport(out string why);
            if (t is null) { SetError(why); return null; }
            var rep = await _engine.RunAsync(t, _secrets.Password, forcePush, pull: true, _cts.Token).ConfigureAwait(false);
            if (_lastError.Length > 0) _log($"[sync] снова работает ({Where})");
            _lastError = _loggedError = "";
            if (manual || rep.Files > 0 || rep.AppliedTotal > 0 || rep.PersonalTables > 0 || rep.Pushed)
                _log($"[sync] {reason}: {rep.Summary().Replace('\n', ';')}");
            return rep;
        }
        catch (SyncException e)
        {
            if (e.Auth) _transport = null;
            SetError(e.Message);
        }
        catch (HttpRequestException e) { SetError($"нет связи ({e.Message})"); }
        catch (TaskCanceledException) when (!_cts.IsCancellationRequested) { SetError("сервер не ответил вовремя"); }
        catch (OperationCanceledException) { }
        catch (Exception e) { SetError($"{e.GetType().Name}: {e.Message}"); }
        finally { _gate.Release(); }
        return null;
    }

    private void SetError(string text)
    {
        _lastError = text;
        _engine.State.LastError = text;
        if (_loggedError != text) { _log($"[sync] ⚠️ {text}"); _loggedError = text; }
    }

    // ------------------------------------------------------------ хранилище

    public bool Configured => _settings.Backend is "gdrive" or "webdav";
    public bool Auto => _settings.Auto;
    public string Backend => _settings.Backend;
    public bool HasPassword => _secrets.Password.Length > 0;
    public string WebDavUrl => _settings.WebDavUrl;
    public string WebDavUser => _settings.WebDavUser;

    public string Where => _settings.Backend switch
    {
        "gdrive" => "Google Drive",
        "webdav" => $"WebDAV ({HostOf(_settings.WebDavUrl)})",
        _ => "не настроена",
    };

    private static string HostOf(string url) => Uri.TryCreate(url, UriKind.Absolute, out var u) ? u.Host : url;

    /// <summary>Client ID и secret Desktop-клиента Google: из переменных окружения
    /// QS_GOOGLE_CLIENT_ID / QS_GOOGLE_CLIENT_SECRET (при запуске или при сборке — csproj
    /// кладёт их в метаданные сборки). В исходниках их нет.</summary>
    public static (string Id, string Secret) GoogleClient()
    {
        string id = Environment.GetEnvironmentVariable("QS_GOOGLE_CLIENT_ID") ?? "";
        string secret = Environment.GetEnvironmentVariable("QS_GOOGLE_CLIENT_SECRET") ?? "";
        if (id.Trim().Length > 0 && secret.Trim().Length > 0) return (id.Trim(), secret.Trim());
        id = secret = "";
        foreach (var a in typeof(SyncService).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>())
        {
            if (a.Key == "QSGoogleClientId") id = a.Value ?? "";
            else if (a.Key == "QSGoogleClientSecret") secret = a.Value ?? "";
        }
        return (id.Trim(), secret.Trim());
    }

    public static bool GoogleAvailable => GoogleClient() is { Id.Length: > 0, Secret.Length: > 0 };

    private ISyncTransport? Transport(out string why)
    {
        why = "";
        if (_secrets.Password.Length == 0) { why = "нет пароля синхронизации"; return null; }
        if (_transport is not null) return _transport;
        switch (_settings.Backend)
        {
            case "gdrive":
                var (id, secret) = GoogleClient();
                if (id.Length == 0 || secret.Length == 0) { why = "в этой сборке нет ключа Google (QS_GOOGLE_CLIENT_ID)"; return null; }
                if (_secrets.GDriveRefresh.Length == 0) { why = "нет входа в Google — «Подключить Google Drive…»"; return null; }
                _transport = new GoogleDriveTransport(SyncHttp.Client, id, secret, _secrets.GDriveRefresh, Device);
                break;
            case "webdav":
                if (_settings.WebDavUser.Length == 0 || _secrets.WebDavPassword.Length == 0) { why = "нет логина WebDAV"; return null; }
                _transport = new WebDavTransport(SyncHttp.Client, _settings.WebDavUrl, _settings.WebDavUser, _secrets.WebDavPassword);
                break;
            default:
                why = "не настроена";
                return null;
        }
        return _transport;
    }

    private void SaveAll()
    {
        _settings.Save(SettingsPath);
        _secrets.Save(SecretsPath);
    }

    /// <summary>Пароль синхронизации (одинаковый на всех устройствах). Чужие файлы перечитываются,
    /// свой — перешифровывается.</summary>
    public void SetPassword(string password)
    {
        _secrets.Password = password;
        SaveAll();
        _engine.Reset();
        _log("[sync] пароль синхронизации задан");
    }

    public async Task<(bool Ok, string Text)> ConnectGoogleAsync(Action<string> openBrowser)
    {
        var (id, secret) = GoogleClient();
        if (id.Length == 0 || secret.Length == 0)
            return (false, "Эта сборка без ключа Google. Задайте переменные окружения QS_GOOGLE_CLIENT_ID и " +
                           "QS_GOOGLE_CLIENT_SECRET и перезапустите QSwitcher (или пересоберите). WebDAV работает и так.");
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            cts.CancelAfter(TimeSpan.FromMinutes(5));
            string refresh = await GoogleOAuth.SignInAsync(SyncHttp.Client, id, secret, openBrowser, cts.Token).ConfigureAwait(false);
            _secrets.GDriveRefresh = refresh;
            if (_settings.Backend != "gdrive") { _settings.Backend = "gdrive"; _engine.Reset(); }
            _transport = null;
            _lastError = "";
            SaveAll();
            _log("[sync] Google Drive подключён");
        }
        catch (OperationCanceledException) { return (false, "Вход в Google не завершён за 5 минут."); }
        catch (Exception e) { return (false, e.Message); }
        _savePersonal();           // закрепить id устройства: по нему назван свой файл
        return await SyncNowAsync().ConfigureAwait(false);
    }

    public async Task<(bool Ok, string Text)> ConnectWebDavAsync(string url, string user, string password)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            cts.CancelAfter(TimeSpan.FromSeconds(30));
            await new WebDavTransport(SyncHttp.Client, url, user, password).TestAsync(cts.Token).ConfigureAwait(false);
        }
        catch (Exception e) { return (false, e is TaskCanceledException ? "сервер не ответил" : e.Message); }
        bool changed = _settings.Backend != "webdav" || _settings.WebDavUrl != url || _settings.WebDavUser != user;
        _settings.Backend = "webdav";
        _settings.WebDavUrl = url;
        _settings.WebDavUser = user;
        _secrets.WebDavPassword = password;
        if (changed) _engine.Reset();
        _transport = null;
        _lastError = "";
        SaveAll();
        _log($"[sync] WebDAV подключён: {HostOf(url)}");
        _savePersonal();
        return await SyncNowAsync().ConfigureAwait(false);
    }

    public void SetAuto(bool on)
    {
        _settings.Auto = on;
        SaveAll();
        if (on) Request(false, "включено");
    }

    /// <summary>Отключить: забыть вход в хранилище. Навыки и файлы в облаке остаются.</summary>
    public void Disconnect()
    {
        _settings.Backend = "";
        _secrets.GDriveRefresh = "";
        _secrets.WebDavPassword = "";
        _transport = null;
        _lastError = "";
        _engine.Reset();
        SaveAll();
        _log("[sync] отключена");
    }

    // ------------------------------------------------------------ состояние для меню

    public string StatusLine()
    {
        if (!Configured) return "Не настроена";
        if (_lastError.Length > 0) return $"{Where}: ⚠️ {_lastError}";
        long ok = _engine.State.LastOk;
        return ok == 0 ? $"{Where}: ещё не было" : $"{Where}: {Ago(ok)}";
    }

    public List<string> DeviceLines()
    {
        var lines = new List<string> { $"{Environment.MachineName} (эта винда)" };
        foreach (var r in _engine.State.Remote.Values.OrderBy(r => r.DeviceName, StringComparer.CurrentCulture))
        {
            string name = r.DeviceName.Length > 0 ? r.DeviceName : r.Name;
            string plat = r.Platform switch { "mac" => "мак", "win" => "винда", "" => "?", var p => p };
            lines.Add(r.Error.Length > 0 ? $"{name}: {r.Error}" : $"{name} ({plat}), файл {Ago(r.Updated)}");
        }
        return lines;
    }

    public static string Ago(long ms)
    {
        if (ms <= 0) return "—";
        var t = DateTimeOffset.FromUnixTimeMilliseconds(ms).ToLocalTime();
        var d = DateTimeOffset.Now - t;
        if (d.TotalSeconds < 60) return "только что";
        if (d.TotalMinutes < 60) return $"{(int)d.TotalMinutes} мин назад";
        if (t.Date == DateTime.Today) return $"сегодня в {t:HH:mm}";
        return $"{t:dd.MM HH:mm}";
    }

    // ------------------------------------------------------------ ISyncHost: навыки винды

    public string Device => Personal.Local.Device;
    public string DeviceName => Environment.MachineName;
    public string Platform => PlatformName;
    public string AppTitle => $"QSwitcher {AppVersion.Version} {AppVersion.Build}";

    private string JournalPath => Skills.JournalPath(_dir);

    public Dictionary<string, Dictionary<string, string>> ReadLocal()
    {
        var d = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        var (stop, force) = _learned.Snapshot();
        var learned = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var w in stop) learned[w] = "s";
        foreach (var w in force) learned[w] = "f";
        d[SyncCollections.Learned] = learned;
        d[SyncCollections.StopWords] = Set(_cfg.StopWords);
        d[SyncCollections.ForceWords] = Set(_cfg.ForceWords);
        d[SyncCollections.Excluded(PlatformName)] = Set(_cfg.ExcludedProcesses);
        d[SyncCollections.English(PlatformName)] = Set(_cfg.EnglishApps);
        string journal = "";
        try { if (File.Exists(JournalPath)) journal = File.ReadAllText(JournalPath); } catch { }
        d[SyncCollections.Journal] = SyncJournal.Counts(journal);
        return d;
    }

    private static Dictionary<string, string> Set(IEnumerable<string> xs)
    {
        var m = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var x in xs)
            if (!string.IsNullOrWhiteSpace(x)) m[x] = "1";
        return m;
    }

    public void Apply(IReadOnlyList<SyncOp> ops)
    {
        bool cfgChanged = false;
        var learned = new List<(string, string?)>();
        var journal = new List<SyncOp>();
        string excl = SyncCollections.Excluded(PlatformName), eng = SyncCollections.English(PlatformName);
        foreach (var op in ops)
        {
            bool on = op.Value is not null;
            if (op.Collection == SyncCollections.Learned) learned.Add((op.Key, op.Value));
            else if (op.Collection == SyncCollections.StopWords) cfgChanged |= on ? _cfg.StopWords.Add(op.Key) : _cfg.StopWords.Remove(op.Key);
            else if (op.Collection == SyncCollections.ForceWords) cfgChanged |= on ? _cfg.ForceWords.Add(op.Key) : _cfg.ForceWords.Remove(op.Key);
            else if (op.Collection == excl) cfgChanged |= Member(_cfg.ExcludedProcesses, op.Key, on);
            else if (op.Collection == eng) cfgChanged |= Member(_cfg.EnglishApps, op.Key, on);
            else if (op.Collection == SyncCollections.Journal) journal.Add(op);
        }
        if (learned.Count > 0) _learned.ApplySync(learned);
        if (cfgChanged)
        {
            try { _cfg.Save(); } catch (Exception e) { _log($"[sync] конфиг не записался: {e.Message}"); }
        }
        if (journal.Count > 0)
        {
            try
            {
                string cur = File.Exists(JournalPath) ? File.ReadAllText(JournalPath) : "";
                File.WriteAllText(JournalPath, SyncJournal.Apply(cur, journal));
            }
            catch (Exception e) { _log($"[sync] журнал профиля не записался: {e.Message}"); }
        }
    }

    private static bool Member(List<string> list, string item, bool on)
    {
        if (on)
        {
            if (list.Contains(item, StringComparer.Ordinal)) return false;
            list.Add(item);
            return true;
        }
        return list.RemoveAll(x => string.Equals(x, item, StringComparison.Ordinal)) > 0;
    }

    public Dictionary<string, double[]> AppLang() => _appStats.Counts();

    public void MergeAppLang(Dictionary<string, double[]> other) => _appStats.MergeMax(other);

    public void SavePersonal() => _savePersonal();

    /// <summary>На потоке интерфейса (списки и меню живут там). Если цикл сообщений уже не
    /// крутится (выход), задача снимается, круг прерывается.</summary>
    public void OnUi(Action action)
    {
        var ui = _ui;
        if (ui is null || _inline || SynchronizationContext.Current == ui) { action(); return; }
        var job = new UiJob(action);
        ui.Post(_ => job.Run(), null);
        job.Wait(_uiCts.Token);
    }

    private sealed class UiJob
    {
        private readonly Action _action;
        private readonly ManualResetEventSlim _done = new(false);
        private int _state;        // 0 ждёт, 1 выполняется, 2 готово, 3 снято
        private Exception? _error;

        public UiJob(Action action) => _action = action;

        public void Run()
        {
            if (Interlocked.CompareExchange(ref _state, 1, 0) != 0) return;
            try { _action(); }
            catch (Exception e) { _error = e; }
            finally { Volatile.Write(ref _state, 2); _done.Set(); }
        }

        public void Wait(CancellationToken ct)
        {
            var deadline = DateTime.UtcNow.AddSeconds(60);
            while (!_done.Wait(200))
            {
                if ((ct.IsCancellationRequested || DateTime.UtcNow > deadline)
                    && Interlocked.CompareExchange(ref _state, 3, 0) == 0)
                    throw new OperationCanceledException("поток интерфейса не ответил");
            }
            if (_error is not null) ExceptionDispatchInfo.Capture(_error).Throw();
        }
    }

    public void Dispose()
    {
        Shutdown();
        _cts.Cancel();
    }
}

/// <summary>Подменю «Синхронизация» в трее (пункты — как на маке).</summary>
internal static class SyncMenu
{
    public static ToolStripMenuItem Build(SyncService sync, Action<string, string, bool> balloon)
    {
        var root = new ToolStripMenuItem("Синхронизация");
        root.DropDownItems.Add(new ToolStripMenuItem("…") { Enabled = false });
        root.DropDownOpening += (_, _) =>
        {
            root.DropDownItems.Clear();
            root.DropDownItems.Add(new ToolStripMenuItem(sync.StatusLine()) { Enabled = false });
            if (sync.Configured)
            {
                root.DropDownItems.Add(new ToolStripMenuItem("Устройства:") { Enabled = false });
                foreach (var line in sync.DeviceLines())
                    root.DropDownItems.Add(new ToolStripMenuItem("    " + line) { Enabled = false });
            }
            root.DropDownItems.Add(new ToolStripSeparator());

            var now = new ToolStripMenuItem("Синхронизировать сейчас") { Enabled = sync.Configured };
            now.Click += async (_, _) =>
            {
                balloon("Синхронизация", "Синхронизирую…", false);
                var (ok, text) = await sync.SyncNowAsync();
                Report(ok, "Синхронизация", text, balloon);
            };
            root.DropDownItems.Add(now);
            var auto = new ToolStripMenuItem("Автоматически (раз в минуту и по событиям)") { Checked = sync.Auto };
            auto.Click += (_, _) => sync.SetAuto(!sync.Auto);
            root.DropDownItems.Add(auto);
            root.DropDownItems.Add(new ToolStripSeparator());

            var google = new ToolStripMenuItem("Подключить Google Drive…") { Checked = sync.Backend == "gdrive" };
            google.Click += async (_, _) =>
            {
                if (!SyncService.GoogleAvailable)
                {
                    MessageBox.Show("В этой сборке нет ключа Google.\n\nЗадайте переменные окружения QS_GOOGLE_CLIENT_ID и " +
                                    "QS_GOOGLE_CLIENT_SECRET (Desktop-клиент Google) и перезапустите QSwitcher — или " +
                                    "подключите WebDAV (Яндекс Диск).", "Google Drive", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                if (!EnsurePassword(sync)) return;
                balloon("Google Drive", "Открываю браузер: войдите в Google и разрешите QSwitcher доступ к его папке на Диске.", false);
                var (ok, text) = await sync.ConnectGoogleAsync(OpenUrl);
                Report(ok, "Google Drive", text, balloon);
            };
            root.DropDownItems.Add(google);

            var webdav = new ToolStripMenuItem("Подключить WebDAV (Яндекс Диск)…") { Checked = sync.Backend == "webdav" };
            webdav.Click += async (_, _) =>
            {
                var r = SyncDialogs.WebDav(sync.WebDavUrl, sync.WebDavUser);
                if (r is null) return;
                if (!EnsurePassword(sync)) return;
                var (ok, text) = await sync.ConnectWebDavAsync(r.Value.Url, r.Value.User, r.Value.Password);
                Report(ok, "WebDAV", text, balloon);
            };
            root.DropDownItems.Add(webdav);

            var pw = new ToolStripMenuItem("Пароль синхронизации…");
            pw.Click += (_, _) =>
            {
                string? p = SyncDialogs.Password("Пароль синхронизации",
                    "Одинаковый на всех устройствах: им шифруются файлы в облаке.\nСменили здесь — смените и на остальных.", confirm: true);
                if (p is null) return;
                sync.SetPassword(p);
                sync.Request(true, "новый пароль");
                balloon("Синхронизация", "Пароль сохранён. На других устройствах нужен такой же.", false);
            };
            root.DropDownItems.Add(pw);

            var off = new ToolStripMenuItem("Отключить") { Enabled = sync.Configured };
            off.Click += (_, _) =>
            {
                if (MessageBox.Show("Забыть вход в хранилище? Навыки остаются здесь, файлы в облаке — там.",
                                    "Отключить синхронизацию", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
                    return;
                sync.Disconnect();
            };
            root.DropDownItems.Add(off);
        };
        return root;
    }

    private static bool EnsurePassword(SyncService sync)
    {
        if (sync.HasPassword) return true;
        string? p = SyncDialogs.Password("Пароль синхронизации",
            "Придумайте пароль — одинаковый на всех устройствах (мак, винда).\nИм шифруются файлы в облаке.", confirm: true);
        if (p is null) return false;
        sync.SetPassword(p);
        return true;
    }

    private static void Report(bool ok, string title, string text, Action<string, string, bool> balloon)
    {
        if (ok) balloon(title, text.Length > 240 ? text[..240] + "…" : text, false);
        else MessageBox.Show(text, title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }

    private static void OpenUrl(string url)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception e) { MessageBox.Show($"Браузер не открылся: {e.Message}\n\n{url}", "Google Drive"); }
    }
}

/// <summary>Окна ввода синхронизации.</summary>
internal static class SyncDialogs
{
    /// Пароль (скрытый ввод). confirm — второй раз для проверки. null — отмена, пусто или не совпало.
    public static string? Password(string title, string text, bool confirm)
    {
        using var form = new Form
        {
            Text = title, ClientSize = new Size(380, confirm ? 170 : 126),
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MinimizeBox = false, MaximizeBox = false, TopMost = true,
        };
        var lbl = new Label { Text = text, Left = 10, Top = 10, Width = 360, Height = 40 };
        var box = new TextBox { Left = 10, Top = 56, Width = 360, UseSystemPasswordChar = true };
        var lbl2 = new Label { Text = "Ещё раз:", Left = 10, Top = 84, AutoSize = true, Visible = confirm };
        var box2 = new TextBox { Left = 10, Top = 104, Width = 360, UseSystemPasswordChar = true, Visible = confirm };
        int by = confirm ? 136 : 92;
        var ok = new Button { Text = "OK", Left = 214, Top = by, Width = 75, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Отмена", Left = 295, Top = by, Width = 75, DialogResult = DialogResult.Cancel };
        form.Controls.AddRange(new Control[] { lbl, box, lbl2, box2, ok, cancel });
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        if (form.ShowDialog() != DialogResult.OK) return null;
        if (box.Text.Length == 0) { MessageBox.Show("Пустой пароль не подходит.", title); return null; }
        if (confirm && box.Text != box2.Text)
        {
            MessageBox.Show("Пароли не совпали.", title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return null;
        }
        return box.Text;
    }

    /// Адрес, логин и пароль WebDAV. Для Яндекс Диска — пароль приложения.
    public static (string Url, string User, string Password)? WebDav(string url, string user)
    {
        using var form = new Form
        {
            Text = "WebDAV (Яндекс Диск)", ClientSize = new Size(420, 262),
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MinimizeBox = false, MaximizeBox = false, TopMost = true,
        };
        var hint = new Label
        {
            Text = "Яндекс Диск: адрес https://webdav.yandex.ru, логин Яндекса, пароль — «пароль приложения» " +
                   "(id.yandex.ru → Безопасность → Пароли приложений → Файлы). Файлы лягут в папку QSwitcher.",
            Left = 10, Top = 10, Width = 400, Height = 48,
        };
        var l1 = new Label { Text = "Адрес:", Left = 10, Top = 66, AutoSize = true };
        var urlBox = new TextBox { Left = 10, Top = 86, Width = 400, Text = url.Length > 0 ? url : WebDavTransport.DefaultUrl };
        var l2 = new Label { Text = "Логин:", Left = 10, Top = 114, AutoSize = true };
        var userBox = new TextBox { Left = 10, Top = 134, Width = 400, Text = user };
        var l3 = new Label { Text = "Пароль приложения:", Left = 10, Top = 162, AutoSize = true };
        var pwBox = new TextBox { Left = 10, Top = 182, Width = 400, UseSystemPasswordChar = true };
        var ok = new Button { Text = "Подключить", Left = 234, Top = 222, Width = 95, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Отмена", Left = 335, Top = 222, Width = 75, DialogResult = DialogResult.Cancel };
        form.Controls.AddRange(new Control[] { hint, l1, urlBox, l2, userBox, l3, pwBox, ok, cancel });
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        if (form.ShowDialog() != DialogResult.OK) return null;
        string u = urlBox.Text.Trim(), n = userBox.Text.Trim(), p = pwBox.Text;
        if (!Uri.TryCreate(u, UriKind.Absolute, out var parsed) || (parsed.Scheme != "https" && parsed.Scheme != "http"))
        {
            MessageBox.Show("Адрес должен начинаться с https://", "WebDAV");
            return null;
        }
        if (n.Length == 0 || p.Length == 0) { MessageBox.Show("Нужны логин и пароль.", "WebDAV"); return null; }
        return (u, n, p);
    }
}
