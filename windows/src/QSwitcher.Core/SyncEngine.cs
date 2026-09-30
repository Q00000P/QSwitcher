using System.Text;
using System.Text.Json;

namespace QSwitcher.Core;

/// <summary>Приложение со стороны синхронизации: где лежат навыки и как их менять.</summary>
public interface ISyncHost
{
    /// Устройство (id своей таблицы личного слоя), имя для людей, "mac"/"win", версия приложения.
    string Device { get; }
    string DeviceName { get; }
    string Platform { get; }
    string AppTitle { get; }
    /// Своё состояние по коллекциям этой платформы: ключ → значение (вызывается через OnUi).
    Dictionary<string, Dictionary<string, string>> ReadLocal();
    /// Применить изменения (через OnUi).
    void Apply(IReadOnlyList<SyncOp> ops);
    /// Своё ожидание языка по приложениям и слияние чужого (той же платформы) по большему.
    Dictionary<string, double[]> AppLang();
    void MergeAppLang(Dictionary<string, double[]> other);
    PersonalLM Personal { get; }
    void SavePersonal();
    /// Выполнить на потоке интерфейса и дождаться (там живут списки и правила).
    void OnUi(Action action);
}

/// <summary>Итог одного круга: что пришло, что ушло, что не так.</summary>
public sealed class SyncReport
{
    /// Сколько чужих файлов прочитано (изменившихся).
    public int Files;
    /// Изменения у себя по коллекциям.
    public readonly SortedDictionary<string, int> Applied = new(StringComparer.Ordinal);
    /// Сколько таблиц личного слоя других устройств принято.
    public int PersonalTables;
    public bool Pushed;
    public readonly List<string> Problems = new();

    public int AppliedTotal => Applied.Values.Sum();

    /// Для человека.
    public string Summary()
    {
        var parts = new List<string>();
        if (Files > 0) parts.Add($"прочитано файлов других устройств: {Files}");
        foreach (var (c, n) in Applied) parts.Add($"{SyncEngine.Title(c)}: {n}");
        if (PersonalTables > 0) parts.Add($"личный слой: таблиц других устройств {PersonalTables}");
        parts.Add(Pushed ? "свой файл отправлен" : "своё без изменений");
        parts.AddRange(Problems.Select(p => "⚠️ " + p));
        return string.Join("\n", parts);
    }
}

/// <summary>Круг синхронизации: чужие файлы → слияние → применение у себя → свой файл.
/// Сеть — ISyncTransport, приложение — ISyncHost. Один круг за раз (вызывающий следит).</summary>
public sealed class SyncEngine
{
    /// «Мягкое» (личный слой, ожидание языка — меняются с каждым словом) — не чаще раза в 5 минут,
    /// если не просили отправить сразу (блокировка, сон, выход, «Синхронизировать сейчас»).
    public const long SoftIntervalMs = 5 * 60 * 1000;

    private readonly ISyncHost _host;
    private readonly string _statePath;
    private readonly Action<string> _log;
    private long _pushedPersonalVersion = -1;

    public SyncState State { get; private set; }

    public SyncEngine(ISyncHost host, string statePath, Action<string> log)
    {
        _host = host;
        _statePath = statePath;
        _log = log;
        State = new SyncState();
        try
        {
            if (File.Exists(statePath)) State = SyncState.FromJson(File.ReadAllText(statePath));
        }
        catch (Exception e)
        {
            // Битое состояние: реестры соберутся заново (своё — как давнее), чужое перечитается
            _log($"[sync] состояние не прочиталось ({e.Message}) — начинаю заново");
            try { File.Move(statePath, statePath + ".broken", overwrite: true); } catch { }
        }
    }

    public string OwnFileName => new string(_host.Device.Where(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_').ToArray()) + ".qssync";

    public void SaveState()
    {
        try
        {
            string tmp = _statePath + ".tmp";
            File.WriteAllText(tmp, State.ToJson());
            File.Move(tmp, _statePath, overwrite: true);
        }
        catch (Exception e) { _log($"[sync] состояние не записалось: {e.Message}"); }
    }

    /// <summary>Сменили хранилище или пароль: всё чужое перечитать, своё отправить заново.</summary>
    public void Reset()
    {
        State.ForgetRemote();
        _pushedPersonalVersion = -1;
        SaveState();
    }

    public static string Title(string collection) => collection switch
    {
        SyncCollections.Learned => "выученные правила",
        SyncCollections.StopWords => "стоп-слова",
        SyncCollections.ForceWords => "форс-слова",
        SyncCollections.Journal => "журнал профиля",
        _ when collection.EndsWith(".excluded", StringComparison.Ordinal) => "исключённые приложения",
        _ when collection.EndsWith(".english", StringComparison.Ordinal) => "приложения с английским вводом",
        _ => collection,
    };

    private static long Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    /// <summary>Один круг. pull — читать чужие файлы (на выходе из приложения — только отправка);
    /// forcePush — отправить своё сразу, даже если с прошлой отправки прошло мало времени.</summary>
    public async Task<SyncReport> RunAsync(ISyncTransport transport, string password, bool forcePush, bool pull,
                                           CancellationToken ct)
    {
        var rep = new SyncReport();
        long now = Now();
        var fresh = new List<SyncPayload>();
        var infos = new Dictionary<string, SyncRemoteInfo>(StringComparer.Ordinal);
        var present = new HashSet<string>(StringComparer.Ordinal);
        bool ownMissing = false;
        string own = OwnFileName;

        if (pull)
        {
            var files = await transport.ListAsync(ct).ConfigureAwait(false);
            ownMissing = !files.Any(f => f.Name == own);
            foreach (var f in files)
            {
                if (f.Name == own) continue;
                present.Add(f.Id);
                if (State.Remote.TryGetValue(f.Id, out var known) && known.Version == f.Version) continue;
                var info = new SyncRemoteInfo { Name = f.Name, Version = f.Version };
                byte[] data;
                try { data = await transport.GetAsync(f, ct).ConfigureAwait(false); }
                catch (SyncException e) when (!e.Auth)
                {
                    // Один файл не скачался — остальные не ждут; этот повторится на следующем круге
                    rep.Problems.Add($"{f.Name}: {e.Message}");
                    continue;
                }
                try
                {
                    var p = SyncPayload.Parse(SkillsFile.Open(data, password));
                    info.Device = p.Device;
                    info.DeviceName = p.Name;
                    info.Platform = p.Platform;
                    info.Updated = p.Updated;
                    if (p.Device != _host.Device) fresh.Add(p);
                }
                catch (SkillsFile.WrongPasswordException)
                {
                    info.Error = "другой пароль синхронизации";
                }
                catch (Exception e) when (e is InvalidDataException or JsonException or InvalidOperationException
                                              or FormatException or KeyNotFoundException)
                {
                    info.Error = "файл не читается";
                }
                infos[f.Id] = info;
            }
        }

        // Своё и чужое — одним куском на потоке интерфейса: между чтением своего и применением
        // человек ничего не успеет поменять
        var applied = new List<SyncOp>();
        _host.OnUi(() =>
        {
            var local = _host.ReadLocal();
            SyncMerge.NoteLocal(State, local, now);
            foreach (var p in fresh) SyncMerge.MergeRemote(State, p.Ledgers);
            if (pull)
            {
                var ops = SyncMerge.Plan(State, local);
                if (ops.Count > 0)
                {
                    _host.Apply(ops);
                    applied.AddRange(ops);
                    local = _host.ReadLocal();
                }
            }
            SyncMerge.Remember(State, local);
        });
        foreach (var op in applied)
            rep.Applied[op.Collection] = (rep.Applied.TryGetValue(op.Collection, out var n) ? n : 0) + 1;

        // Ожидание языка — только от устройств той же платформы (имена приложений свои)
        foreach (var p in fresh)
            if (p.Platform == _host.Platform && p.AppLang.Count > 0)
                _host.MergeAppLang(new Dictionary<string, double[]>(p.AppLang));
        // Личный слой других устройств: их таблицы целиком, если свежее
        long clearedBefore = _host.Personal.ClearedAt;
        foreach (var p in fresh)
            if (p.Personal is { } pe) rep.PersonalTables += _host.Personal.Merge(pe);
        if (rep.PersonalTables > 0 || _host.Personal.ClearedAt != clearedBefore) _host.SavePersonal();
        rep.Files = fresh.Count;

        if (pull)
        {
            foreach (var (id, info) in infos) State.Remote[id] = info;
            foreach (var id in State.Remote.Keys.Where(k => !present.Contains(k)).ToList()) State.Remote.Remove(id);
            foreach (var info in State.Remote.Values)
                if (info.Error.Length > 0) rep.Problems.Add($"{(info.DeviceName.Length > 0 ? info.DeviceName : info.Name)}: {info.Error}");
        }
        SyncMerge.Prune(State, now);

        // Своё: реестры (и очистка личного слоя) — сразу; личный слой и ожидание языка — не чаще
        // раза в SoftIntervalMs, если не просили сразу
        string hard = SyncMerge.LedgerHash(State) + "|" + _host.Personal.ClearedAt;
        var appLang = _host.AppLang();
        string soft = SyncPayload.SoftHash(appLang);
        long pv = _host.Personal.LocalVersion;
        bool hardChanged = hard != State.PushedLedgerHash || ownMissing;
        bool softChanged = soft != State.PushedSoftHash || pv != _pushedPersonalVersion;
        bool due = forcePush || now - State.PushedSoftAt >= SoftIntervalMs;
        if (hardChanged || (softChanged && due))
        {
            var personal = _host.Personal.SnapshotLocal();
            var doc = SyncPayload.Build(State, _host.Device, _host.DeviceName, _host.Platform, _host.AppTitle,
                                        appLang, personal, now);
            byte[] blob = SkillsFile.Seal(Encoding.UTF8.GetBytes(doc.ToJsonString(SkillsFile.Json)), password, stableSalt: true);
            await transport.PutAsync(own, blob, State.Cache, ct).ConfigureAwait(false);
            State.PushedLedgerHash = hard;
            State.PushedSoftHash = soft;
            State.PushedAt = now;
            State.PushedSoftAt = now;
            _pushedPersonalVersion = pv;
            rep.Pushed = true;
        }
        State.LastOk = now;
        State.LastError = "";
        SaveState();
        return rep;
    }
}
