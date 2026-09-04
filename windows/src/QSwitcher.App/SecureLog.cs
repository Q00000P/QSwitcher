using System.Security.Cryptography;
using System.Text;

namespace QSwitcher.App;

/// <summary>
/// Защищённый лог набора.
///
/// Обычный лог пишется открытым текстом — там границы слов и решения детектора,
/// этого достаточно для отладки. Но история набора по своей природе
/// чувствительна: в неё попадает всё, что человек печатает. Поэтому она идёт
/// в отдельный зашифрованный файл.
///
/// Схема повторяет macOS-версию, только вместо Keychain и Touch ID —
/// DPAPI и Windows Hello:
///   • случайный ключ AES-256 генерируется один раз;
///   • сам ключ лежит на диске зашифрованным через DPAPI, привязанным
///     к учётной записи Windows — на другой машине или под другим
///     пользователем файл не расшифруется;
///   • каждая запись шифруется AES-GCM со своим nonce, так что повреждение
///     одной записи не рушит весь файл;
///   • на чтение спрашивается Windows Hello.
/// </summary>
public sealed class SecureLog : IDisposable
{
    private readonly string _dataDir;
    private readonly string _logPath;
    private readonly string _keyPath;
    private readonly Action<string> _log;
    private byte[]? _key;

    /// Строка + поколение фокуса на момент набора (см. ForegroundTracker).
    private readonly System.Collections.Concurrent.ConcurrentQueue<(string line, int gen, int tries)> _queue = new();

    /// Поколение фокуса сейчас (по событиям). Не задано — старый синхронный детект.
    public Func<int>? FocusGeneration { get; set; }

    /// Поле пароля для поколения: true/false, null — ещё не решено.
    public Func<int, bool?>? PasswordAt { get; set; }
    private readonly System.Threading.Timer _flushTimer;

    public bool Enabled { get; set; } = true;

    /// Писать ли набор в полях паролей. Детект — системный флаг UIA
    /// IsPassword у фокусного элемента: покрывает Win32 Edit (ES_PASSWORD),
    /// браузеры, большинство приложений. Аналог маковского
    /// «Логировать пароли (Secure Input)» — на Windows нет Secure Input,
    /// но есть честная пометка поля пароля.
    public bool LogPasswords { get; set; } = true;

    private static bool IsPasswordFieldFocused()
    {
        try
        {
            var el = System.Windows.Automation.AutomationElement.FocusedElement;
            return el is not null && (bool)el.GetCurrentPropertyValue(
                System.Windows.Automation.AutomationElement.IsPasswordProperty);
        }
        catch { return false; }
    }

    /// Максимальный размер файла. При превышении старые записи отбрасываются.
    public int MaxSizeMb { get; set; } = 50;

    public SecureLog(string dataDir, Action<string> log)
    {
        _dataDir = dataDir;
        _log = log;
        Directory.CreateDirectory(dataDir);
        _logPath = Path.Combine(dataDir, "securelog.bin");
        _keyPath = Path.Combine(dataDir, "securelog.key");
        _flushTimer = new System.Threading.Timer(_ => Flush(), null, 3000, 3000);
    }

    /// Выгрузить буфер на диск немедленно (пункт меню).
    public void FlushNow() => Flush();

    /// Периодичность сброса буфера на диск.
    public void SetFlushInterval(int seconds)
    {
        int ms = Math.Max(1, seconds) * 1000;
        _flushTimer.Change(ms, ms);
    }

    /// <summary>Добавить запись. Пишется в фоне, ввод не задерживает.</summary>
    public void Append(string text)
    {
        if (!Enabled || text.Length == 0) return;
        int gen = -1;
        if (!LogPasswords)
        {
            if (FocusGeneration is { } fg) gen = fg();
            else if (IsPasswordFieldFocused()) return;   // без трекера — как раньше
        }
        _queue.Enqueue(($"{DateTime.Now:yyyy-MM-dd HH:mm:ss}\t{text}", gen, 0));
    }

    /// Решить, писать ли запись: поле пароля определяется трекером по
    /// событиям, в момент набора ответ мог быть ещё не готов — тогда запись
    /// откладывается до следующего сброса (не более нескольких раз).
    private bool ShouldWrite((string line, int gen, int tries) rec, out bool retry)
    {
        retry = false;
        if (LogPasswords || rec.gen < 0 || PasswordAt is null) return true;
        var pwd = PasswordAt(rec.gen);
        if (pwd is bool b) return !b;
        if (rec.tries < 3) { retry = true; return false; }
        return true;   // так и не решилось — как раньше при сбое детекта: пишем
    }

    private void Flush()
    {
        if (_queue.IsEmpty) return;
        try
        {
            var key = GetOrCreateKey();
            using var fs = new FileStream(_logPath, FileMode.Append, FileAccess.Write, FileShare.Read);
            var deferred = new List<(string line, int gen, int tries)>();
            while (_queue.TryDequeue(out var rec))
            {
                if (!ShouldWrite(rec, out bool retry))
                {
                    if (retry) deferred.Add((rec.line, rec.gen, rec.tries + 1));
                    continue;
                }
                var record = EncryptRecord(key, rec.line);
                // Длина записи впереди — чтобы читать файл последовательно
                fs.Write(BitConverter.GetBytes(record.Length));
                fs.Write(record);
            }
            fs.Flush();
            foreach (var d in deferred) _queue.Enqueue(d);
            TrimIfNeeded();
        }
        catch (Exception ex) { _log($"[securelog] запись не удалась: {ex.Message}"); }
    }

    private static byte[] EncryptRecord(byte[] key, string plain)
    {
        var data = Encoding.UTF8.GetBytes(plain);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[data.Length];
        var tag = new byte[16];
        using var gcm = new AesGcm(key, 16);
        gcm.Encrypt(nonce, data, cipher, tag);

        var result = new byte[12 + 16 + cipher.Length];
        nonce.CopyTo(result, 0);
        tag.CopyTo(result, 12);
        cipher.CopyTo(result, 28);
        return result;
    }

    private static string DecryptRecord(byte[] key, byte[] record)
    {
        var nonce = record[..12];
        var tag = record[12..28];
        var cipher = record[28..];
        var plain = new byte[cipher.Length];
        using var gcm = new AesGcm(key, 16);
        gcm.Decrypt(nonce, cipher, tag, plain);
        return Encoding.UTF8.GetString(plain);
    }

    /// <summary>
    /// Ключ шифрования. Хранится на диске, сам защищён DPAPI под текущего
    /// пользователя — прочитать его на другой машине нельзя.
    /// </summary>
    private byte[] GetOrCreateKey()
    {
        if (_key is not null) return _key;

        if (File.Exists(_keyPath))
        {
            var prot = File.ReadAllBytes(_keyPath);
            _key = System.Security.Cryptography.ProtectedData.Unprotect(
                prot, null, DataProtectionScope.CurrentUser);
            return _key;
        }

        _key = RandomNumberGenerator.GetBytes(32);
        var wrapped = System.Security.Cryptography.ProtectedData.Protect(
            _key, null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(_keyPath, wrapped);
        _log("🔐 Создан ключ защищённого лога (DPAPI, текущий пользователь)");
        return _key;
    }

    /// <summary>Прочитать последние N записей. Требует подтверждения личности.</summary>
    public async Task<string> ReadAsync(IntPtr anchorWindow, int lastRecords = 500)
    {
        if (!await ConfirmIdentityAsync(anchorWindow))
            return "Доступ не подтверждён.";

        if (!File.Exists(_logPath)) return "Лог пуст.";

        try
        {
            var key = GetOrCreateKey();
            var lines = new List<string>();
            using var fs = new FileStream(_logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var lenBuf = new byte[4];
            while (fs.Read(lenBuf) == 4)
            {
                int len = BitConverter.ToInt32(lenBuf);
                if (len <= 28 || len > 1_000_000) break;
                var rec = new byte[len];
                if (fs.Read(rec) != len) break;
                try { lines.Add(DecryptRecord(key, rec)); }
                catch { lines.Add("[повреждённая запись]"); }
            }
            if (lines.Count == 0) return "Лог пуст.";
            return string.Join(Environment.NewLine, lines.TakeLast(lastRecords));
        }
        catch (Exception ex) { return $"Не удалось прочитать: {ex.Message}"; }
    }

    /// <summary>
    /// Подтверждение личности через Windows Hello. Если оно недоступно
    /// (нет камеры, отпечатка или ПИН-кода), спрашиваем обычным диалогом —
    /// защиту файла это не ослабляет, ключ всё равно привязан к учётке.
    /// </summary>
    private async Task<bool> ConfirmIdentityAsync(IntPtr anchorWindow)
    {
        try
        {
            var availability = await Windows.Security.Credentials.UI.UserConsentVerifier
                .CheckAvailabilityAsync();
            _log($"[hello] доступность: {availability}");
            if (availability == Windows.Security.Credentials.UI.UserConsentVerifierAvailability.Available)
            {
                var result = await RequestVerificationForWindowAsync(
                    anchorWindow, "Показать историю набора QSwitcher");
                if (result is not null)
                    return result == Windows.Security.Credentials.UI.UserConsentVerificationResult.Verified;
            }
        }
        catch { /* WinRT недоступен — падаем на обычный диалог */ }

        return MessageBox.Show(
            "Показать историю набора?\n\nWindows Hello недоступен, поэтому подтверждение обычное.",
            "QSwitcher", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
    }

    /// <summary>
    /// Запрос Windows Hello с привязкой к окну.
    ///
    /// Обычный UserConsentVerifier.RequestVerificationAsync рассчитан на UWP.
    /// В десктопном приложении ему не к чему прицепить биометрический запрос,
    /// поэтому предлагается только ПИН, а отпечаток не срабатывает. Для таких
    /// приложений нужен интероп-интерфейс с дескриптором окна.
    /// </summary>
    private static async Task<Windows.Security.Credentials.UI.UserConsentVerificationResult?>
        RequestVerificationForWindowAsync(IntPtr hwnd, string message)
    {
        // Якорем служит НАСТОЯЩЕЕ окно приложения, которое человек только что
        // открыл из меню. Фиктивное невидимое окно не годилось: системный
        // запрос наследовал его неактивность и не принимал ни отпечаток,
        // ни ПИН, пока в него не ткнёшь мышью.
        try
        {
            var interop = GetInterop();
            var iid = typeof(Windows.Foundation.IAsyncOperation<
                Windows.Security.Credentials.UI.UserConsentVerificationResult>).GUID;
            var op = interop.RequestVerificationForWindowAsync(hwnd, message, ref iid);
            var r = await op;
            System.Diagnostics.Debug.WriteLine($"[hello] интероп вернул {r}");
            return r;
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[hello] интероп не сработал: {ex.Message}");
            try
            {
                Windows.Security.Credentials.UI.UserConsentVerificationResult fallback =
                    await Windows.Security.Credentials.UI.UserConsentVerifier
                        .RequestVerificationAsync(message);
                return fallback;
            }
            catch { return null; }
        }
    }

    /// <summary>
    /// Сделать окно активным по-настоящему.
    ///
    /// Windows запрещает менять активное окно процессу, который сам не в
    /// фокусе, — простой SetForegroundWindow из фонового приложения молча
    /// игнорируется. Запрос Windows Hello наследовал эту неактивность:
    /// он был виден, но сенсор отпечатка не слушал, пока в окно не ткнёшь
    /// мышью. Штатный обход — временно привязаться к потоку активного окна,
    /// тогда система считает нас «своими» и разрешает переключение.
    /// </summary>
    private static void ForceForeground(IntPtr hwnd)
    {
        try
        {
            IntPtr fg = GetForegroundWindow();
            uint fgThread = GetWindowThreadProcessId(fg, out _);
            uint ourThread = GetCurrentThreadId();

            if (fgThread != ourThread)
                AttachThreadInput(ourThread, fgThread, true);
            try
            {
                ShowWindow(hwnd, 5 /*SW_SHOW*/);
                BringWindowToTop(hwnd);
                SetForegroundWindow(hwnd);
                SetActiveWindow(hwnd);
                SetFocus(hwnd);
            }
            finally
            {
                if (fgThread != ourThread)
                    AttachThreadInput(ourThread, fgThread, false);
            }
        }
        catch { }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr SetFocus(IntPtr hWnd);

    /// <summary>
    /// Фабрика интероп-интерфейса.
    ///
    /// Берём системным вызовом RoGetActivationFactory, а не через обёртку
    /// CsWinRT: её API меняется от версии к версии, а системный не меняется.
    /// </summary>
    private static IUserConsentVerifierInterop GetInterop()
    {
        const string cls = "Windows.Security.Credentials.UI.UserConsentVerifier";
        int hr = WindowsCreateString(cls, cls.Length, out IntPtr hstr);
        if (hr != 0) throw new InvalidOperationException($"WindowsCreateString: 0x{hr:X}");
        try
        {
            var iid = typeof(IUserConsentVerifierInterop).GUID;
            hr = RoGetActivationFactory(hstr, ref iid, out IntPtr factoryPtr);
            if (hr != 0) throw new InvalidOperationException($"RoGetActivationFactory: 0x{hr:X}");
            try
            {
                return (IUserConsentVerifierInterop)
                    System.Runtime.InteropServices.Marshal.GetObjectForIUnknown(factoryPtr);
            }
            finally { System.Runtime.InteropServices.Marshal.Release(factoryPtr); }
        }
        finally { WindowsDeleteString(hstr); }
    }

    [System.Runtime.InteropServices.DllImport("combase.dll", CharSet =
        System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int WindowsCreateString(string sourceString, int length, out IntPtr hstring);

    [System.Runtime.InteropServices.DllImport("combase.dll")]
    private static extern int WindowsDeleteString(IntPtr hstring);

    [System.Runtime.InteropServices.DllImport("combase.dll")]
    private static extern int RoGetActivationFactory(IntPtr activatableClassId,
        ref Guid iid, out IntPtr factory);

    [System.Runtime.InteropServices.ComImport]
    [System.Runtime.InteropServices.Guid("39E050C3-4E74-441A-8DC0-B81104DF949C")]
    [System.Runtime.InteropServices.InterfaceType(
        System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIInspectable)]
    private interface IUserConsentVerifierInterop
    {
        Windows.Foundation.IAsyncOperation<
            Windows.Security.Credentials.UI.UserConsentVerificationResult>
            RequestVerificationForWindowAsync(
                IntPtr appWindow,
                [System.Runtime.InteropServices.MarshalAs(
                    System.Runtime.InteropServices.UnmanagedType.HString)] string message,
                ref Guid riid);
    }

    /// <summary>Стереть историю целиком вместе с ключом.</summary>
    public void Wipe()
    {
        try
        {
            _queue.Clear();
            if (File.Exists(_logPath)) File.Delete(_logPath);
            if (File.Exists(_keyPath)) File.Delete(_keyPath);
            _key = null;
            _log("🔐 Защищённый лог стёрт");
        }
        catch (Exception ex) { _log($"[securelog] стереть не удалось: {ex.Message}"); }
    }

    public long SizeBytes => File.Exists(_logPath) ? new FileInfo(_logPath).Length : 0;

    /// Файл растёт бесконечно, поэтому при превышении лимита начинаем заново.
    /// Резать середину нельзя — записи переменной длины, а индекса нет.
    private void TrimIfNeeded()
    {
        if (SizeBytes < MaxSizeMb * 1024L * 1024L) return;
        try
        {
            File.Delete(_logPath);
            _log($"[securelog] превышен лимит {MaxSizeMb} МБ — файл начат заново");
        }
        catch { }
    }

    public void Dispose()
    {
        _flushTimer.Dispose();
        Flush();
    }
}
