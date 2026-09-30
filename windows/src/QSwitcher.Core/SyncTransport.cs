using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Xml.Linq;

namespace QSwitcher.Core;

// Хранилища синхронизации: Google Drive (доступ drive.file — приложение видит только свои
// файлы) и WebDAV (Яндекс Диск и любой другой). Протокол одинаковый: список файлов
// *.qssync с версиями, скачать чужой, записать свой. Зеркало на маке — SyncTransport.swift.

/// <summary>Файл в хранилище: id (для скачивания), имя, версия (не менялась — не качаем).</summary>
public sealed record RemoteFile(string Id, string Name, string Version);

public interface ISyncTransport
{
    /// Для человека: «Google Drive», «WebDAV (webdav.yandex.ru)».
    string Title { get; }
    /// Все файлы синхронизации в общей папке (свой тоже).
    Task<List<RemoteFile>> ListAsync(CancellationToken ct);
    Task<byte[]> GetAsync(RemoteFile file, CancellationToken ct);
    /// Записать свой файл. cache — между вызовами (id файла на Drive).
    Task PutAsync(string name, byte[] data, IDictionary<string, string> cache, CancellationToken ct);
}

/// <summary>Ошибка хранилища. Auth — вход больше не действует (подключить заново).</summary>
public sealed class SyncException : Exception
{
    public bool Auth { get; }
    public SyncException(string message, bool auth = false) : base(message) => Auth = auth;
}

public static class SyncHttp
{
    /// Один клиент на приложение; запрос — не дольше двух минут (личный слой — мегабайты).
    public static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        AutomaticDecompression = DecompressionMethods.All,
    })
    { Timeout = TimeSpan.FromMinutes(2) };

    internal static string Detail(byte[] body)
    {
        try
        {
            var j = JsonNode.Parse(body);
            string? m = j?["error"]?["message"]?.GetValue<string>() ?? j?["error_description"]?.GetValue<string>();
            if (!string.IsNullOrEmpty(m)) return ": " + (m.Length > 160 ? m[..160] + "…" : m);
        }
        catch { }
        return "";
    }
}

/// <summary>Google Drive: папка QSwitcher, файлы помечены appProperties qswitcher=sync.</summary>
public sealed class GoogleDriveTransport : ISyncTransport
{
    public const string Scope = "https://www.googleapis.com/auth/drive.file";
    public const string FolderName = "QSwitcher";
    public const string TokenUrl = "https://oauth2.googleapis.com/token";
    private const string Mine = "appProperties has { key='qswitcher' and value='sync' } and trashed = false";

    private readonly HttpClient _http;
    private readonly string _clientId, _clientSecret, _refresh, _device, _api, _uploadApi, _tokenUrl;
    private string? _token;
    private DateTime _tokenUntil;

    /// apiRoot и tokenUrl — для проверки на подставном сервере.
    public GoogleDriveTransport(HttpClient http, string clientId, string clientSecret, string refreshToken, string device,
                                string apiRoot = "https://www.googleapis.com", string tokenUrl = TokenUrl)
    {
        _http = http;
        _clientId = clientId;
        _clientSecret = clientSecret;
        _refresh = refreshToken;
        _device = device;
        _api = apiRoot.TrimEnd('/') + "/drive/v3/files";
        _uploadApi = apiRoot.TrimEnd('/') + "/upload/drive/v3/files";
        _tokenUrl = tokenUrl;
    }

    public string Title => "Google Drive";

    private async Task<string> TokenAsync(CancellationToken ct)
    {
        if (_token is not null && DateTime.UtcNow < _tokenUntil) return _token;
        using var req = new HttpRequestMessage(HttpMethod.Post, _tokenUrl)
        {
            Content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["client_id"] = _clientId,
                ["client_secret"] = _clientSecret,
                ["refresh_token"] = _refresh,
                ["grant_type"] = "refresh_token",
            }),
        };
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        byte[] body = await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        JsonNode? j = null;
        try { j = JsonNode.Parse(body); } catch { }
        string? token = j?["access_token"]?.GetValue<string>();
        if (!resp.IsSuccessStatusCode || string.IsNullOrEmpty(token))
        {
            string err = j?["error"]?.GetValue<string>() ?? $"HTTP {(int)resp.StatusCode}";
            bool auth = err is "invalid_grant" or "unauthorized_client" or "invalid_client";
            throw new SyncException(auth
                ? $"Google: вход больше не действует ({err}) — «Подключить Google Drive…» заново"
                : $"Google: токен не обновился ({err})", auth);
        }
        int exp = 3600;
        try { exp = j?["expires_in"]?.GetValue<int>() ?? 3600; } catch { }
        _token = token;
        _tokenUntil = DateTime.UtcNow.AddSeconds(Math.Max(60, exp - 120));
        return token;
    }

    private async Task<(HttpStatusCode Code, byte[] Body)> SendAsync(Func<HttpRequestMessage> make, string ctx,
                                                                     CancellationToken ct, bool allow404 = false)
    {
        for (int attempt = 0; ; attempt++)
        {
            string token = await TokenAsync(ct).ConfigureAwait(false);
            using var req = make();
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
            byte[] body = await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            if (resp.StatusCode == HttpStatusCode.Unauthorized && attempt == 0) { _token = null; continue; }
            if (resp.IsSuccessStatusCode || (allow404 && resp.StatusCode == HttpStatusCode.NotFound))
                return (resp.StatusCode, body);
            throw new SyncException($"Google Drive: HTTP {(int)resp.StatusCode} ({ctx}){SyncHttp.Detail(body)}");
        }
    }

    private static string Url(string baseUrl, params (string K, string V)[] q) =>
        baseUrl + "?" + string.Join("&", q.Select(x => x.K + "=" + Uri.EscapeDataString(x.V)));

    private static string Quote(string s) => s.Replace("\\", "\\\\").Replace("'", "\\'");

    private async Task<JsonArray> QueryAsync(string q, string fields, string ctx, CancellationToken ct, string? orderBy = null)
    {
        var args = new List<(string, string)> { ("q", q), ("spaces", "drive"), ("pageSize", "1000"), ("fields", $"files({fields})") };
        if (orderBy is not null) args.Add(("orderBy", orderBy));
        string url = Url(_api, args.ToArray());
        var (_, body) = await SendAsync(() => new HttpRequestMessage(HttpMethod.Get, url), ctx, ct).ConfigureAwait(false);
        return JsonNode.Parse(body)?["files"] as JsonArray ?? new JsonArray();
    }

    public async Task<List<RemoteFile>> ListAsync(CancellationToken ct)
    {
        var files = await QueryAsync(Mine, "id,name,md5Checksum,modifiedTime,size", "список файлов", ct).ConfigureAwait(false);
        var list = new List<RemoteFile>();
        foreach (var f in files)
        {
            string? id = f?["id"]?.GetValue<string>();
            string name = f?["name"]?.GetValue<string>() ?? "";
            if (string.IsNullOrEmpty(id) || !name.EndsWith(".qssync", StringComparison.OrdinalIgnoreCase)) continue;
            string version = f?["md5Checksum"]?.GetValue<string>()
                             ?? $"{f?["modifiedTime"]?.GetValue<string>()}|{f?["size"]?.GetValue<string>()}";
            list.Add(new RemoteFile(id, name, version));
        }
        return list;
    }

    public async Task<byte[]> GetAsync(RemoteFile file, CancellationToken ct)
    {
        string url = $"{_api}/{Uri.EscapeDataString(file.Id)}?alt=media";
        var (_, body) = await SendAsync(() => new HttpRequestMessage(HttpMethod.Get, url), "скачивание", ct).ConfigureAwait(false);
        return body;
    }

    public async Task PutAsync(string name, byte[] data, IDictionary<string, string> cache, CancellationToken ct)
    {
        cache.TryGetValue("gdrive.own", out string? id);
        if (string.IsNullOrEmpty(id))
        {
            var found = await QueryAsync($"name = '{Quote(name)}' and {Mine}", "id", "поиск своего файла", ct).ConfigureAwait(false);
            id = found.FirstOrDefault()?["id"]?.GetValue<string>();
        }
        if (!string.IsNullOrEmpty(id) && await UploadAsync(id, data, ct).ConfigureAwait(false))
        {
            cache["gdrive.own"] = id;
            return;
        }
        // Своего файла нет (первый раз или удалили руками) — создать в папке QSwitcher
        string folder = await FolderAsync(ct).ConfigureAwait(false);
        var meta = new JsonObject
        {
            ["name"] = name,
            ["parents"] = new JsonArray(folder),
            ["mimeType"] = "application/octet-stream",
            ["appProperties"] = new JsonObject { ["qswitcher"] = "sync", ["device"] = _device },
        };
        string metaJson = meta.ToJsonString(SkillsFile.Json);
        var (_, created) = await SendAsync(() => new HttpRequestMessage(HttpMethod.Post, $"{_api}?fields=id")
        {
            Content = new StringContent(metaJson, Encoding.UTF8, "application/json"),
        }, "создание файла", ct).ConfigureAwait(false);
        id = JsonNode.Parse(created)?["id"]?.GetValue<string>();
        if (string.IsNullOrEmpty(id)) throw new SyncException("Google Drive: файл не создался (нет id)");
        if (!await UploadAsync(id, data, ct).ConfigureAwait(false))
            throw new SyncException("Google Drive: созданный файл не найден при записи");
        cache["gdrive.own"] = id;
    }

    /// Записать содержимое. false — файла с таким id больше нет.
    private async Task<bool> UploadAsync(string id, byte[] data, CancellationToken ct)
    {
        string url = $"{_uploadApi}/{Uri.EscapeDataString(id)}?uploadType=media";
        var (code, _) = await SendAsync(() =>
        {
            var content = new ByteArrayContent(data);
            content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
            return new HttpRequestMessage(HttpMethod.Patch, url) { Content = content };
        }, "отправка", ct, allow404: true).ConfigureAwait(false);
        return code != HttpStatusCode.NotFound;
    }

    /// Папка QSwitcher: самая ранняя из найденных (два устройства, создавшие её одновременно,
    /// сходятся в одну), нет — создать.
    private async Task<string> FolderAsync(CancellationToken ct)
    {
        var found = await QueryAsync($"name = '{FolderName}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
                                     "id", "поиск папки", ct, orderBy: "createdTime").ConfigureAwait(false);
        string? id = found.FirstOrDefault()?["id"]?.GetValue<string>();
        if (!string.IsNullOrEmpty(id)) return id;
        string metaJson = new JsonObject { ["name"] = FolderName, ["mimeType"] = "application/vnd.google-apps.folder" }
            .ToJsonString(SkillsFile.Json);
        var (_, body) = await SendAsync(() => new HttpRequestMessage(HttpMethod.Post, $"{_api}?fields=id")
        {
            Content = new StringContent(metaJson, Encoding.UTF8, "application/json"),
        }, "создание папки", ct).ConfigureAwait(false);
        return JsonNode.Parse(body)?["id"]?.GetValue<string>() ?? throw new SyncException("Google Drive: папка не создалась");
    }
}

/// <summary>WebDAV: папка QSwitcher на сервере (Яндекс Диск — https://webdav.yandex.ru,
/// пароль приложения из настроек Яндекс ID).</summary>
public sealed class WebDavTransport : ISyncTransport
{
    public const string DefaultUrl = "https://webdav.yandex.ru";
    private const string Propfind =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop>" +
        "<d:getetag/><d:getlastmodified/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>";

    private readonly HttpClient _http;
    private readonly Uri _base, _folder;
    private readonly string _auth;

    public WebDavTransport(HttpClient http, string baseUrl, string user, string password, string folder = "QSwitcher")
    {
        _http = http;
        string b = (string.IsNullOrWhiteSpace(baseUrl) ? DefaultUrl : baseUrl.Trim());
        if (!b.EndsWith('/')) b += "/";
        _base = new Uri(b);
        _folder = new Uri(_base, Uri.EscapeDataString(folder) + "/");
        _auth = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes($"{user}:{password}"));
        Title = $"WebDAV ({_base.Host})";
    }

    public string Title { get; }

    private HttpRequestMessage Req(HttpMethod m, Uri u)
    {
        var r = new HttpRequestMessage(m, u);
        r.Headers.TryAddWithoutValidation("Authorization", _auth);
        return r;
    }

    private static SyncException Fail(HttpResponseMessage resp, string ctx) => (int)resp.StatusCode switch
    {
        401 => new SyncException("WebDAV: неверный логин или пароль (401). Для Яндекса нужен пароль приложения", auth: true),
        403 => new SyncException($"WebDAV: доступ запрещён (403, {ctx})"),
        507 => new SyncException("WebDAV: на диске нет места (507)"),
        var c => new SyncException($"WebDAV: HTTP {c} ({ctx})"),
    };

    /// <summary>Проверка подключения: корень отвечает на PROPFIND.</summary>
    public async Task TestAsync(CancellationToken ct)
    {
        using var req = Req(new HttpMethod("PROPFIND"), _base);
        req.Headers.Add("Depth", "0");
        req.Content = new StringContent(Propfind, Encoding.UTF8, "application/xml");
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode) throw Fail(resp, "проверка");
    }

    public async Task<List<RemoteFile>> ListAsync(CancellationToken ct)
    {
        using var req = Req(new HttpMethod("PROPFIND"), _folder);
        req.Headers.Add("Depth", "1");
        req.Content = new StringContent(Propfind, Encoding.UTF8, "application/xml");
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        if (resp.StatusCode == HttpStatusCode.NotFound) return new();     // папки ещё нет
        if (!resp.IsSuccessStatusCode) throw Fail(resp, "список файлов");
        string xml = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        XNamespace d = "DAV:";
        var list = new List<RemoteFile>();
        foreach (var r in XDocument.Parse(xml).Descendants(d + "response"))
        {
            string href = r.Element(d + "href")?.Value ?? "";
            if (href.Length == 0 || r.Descendants(d + "collection").Any()) continue;
            string name = Uri.UnescapeDataString(href.TrimEnd('/').Split('/').Last());
            if (!name.EndsWith(".qssync", StringComparison.OrdinalIgnoreCase)) continue;
            string etag = r.Descendants(d + "getetag").FirstOrDefault()?.Value ?? "";
            string mod = r.Descendants(d + "getlastmodified").FirstOrDefault()?.Value ?? "";
            string len = r.Descendants(d + "getcontentlength").FirstOrDefault()?.Value ?? "";
            var uri = new Uri(_folder, href);
            list.Add(new RemoteFile(uri.AbsoluteUri, name, etag.Length > 0 ? etag : $"{mod}|{len}"));
        }
        return list;
    }

    public async Task<byte[]> GetAsync(RemoteFile file, CancellationToken ct)
    {
        using var req = Req(HttpMethod.Get, new Uri(file.Id));
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode) throw Fail(resp, "скачивание");
        return await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
    }

    public async Task PutAsync(string name, byte[] data, IDictionary<string, string> cache, CancellationToken ct)
    {
        var uri = new Uri(_folder, Uri.EscapeDataString(name));
        var code = await PutOnceAsync(uri, data, ct).ConfigureAwait(false);
        if (code is HttpStatusCode.NotFound or HttpStatusCode.Conflict)
        {
            // Папки ещё нет — создать и повторить (405 — уже есть, это нормально)
            using (var mk = Req(new HttpMethod("MKCOL"), _folder))
            using (var r = await _http.SendAsync(mk, ct).ConfigureAwait(false))
                if (!r.IsSuccessStatusCode && r.StatusCode != HttpStatusCode.MethodNotAllowed) throw Fail(r, "создание папки");
            code = await PutOnceAsync(uri, data, ct).ConfigureAwait(false);
            if (code is HttpStatusCode.NotFound or HttpStatusCode.Conflict)
                throw new SyncException($"WebDAV: папка не создалась (HTTP {(int)code})");
        }
    }

    private async Task<HttpStatusCode> PutOnceAsync(Uri uri, byte[] data, CancellationToken ct)
    {
        using var req = Req(HttpMethod.Put, uri);
        req.Content = new ByteArrayContent(data);
        req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        if (resp.IsSuccessStatusCode || resp.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Conflict)
            return resp.StatusCode;
        throw Fail(resp, "отправка");
    }
}

/// <summary>Вход в Google для десктопа: браузер + редирект на 127.0.0.1 (loopback), PKCE.
/// Возвращает refresh token (хранится у приложения зашифрованным).</summary>
public static class GoogleOAuth
{
    public const string AuthUrl = "https://accounts.google.com/o/oauth2/v2/auth";

    /// authUrl и tokenUrl — для проверки на подставном сервере.
    public static async Task<string> SignInAsync(HttpClient http, string clientId, string clientSecret,
                                                 Action<string> openBrowser, CancellationToken ct,
                                                 string authUrl = AuthUrl, string tokenUrl = GoogleDriveTransport.TokenUrl)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            string redirect = $"http://127.0.0.1:{port}";
            string state = B64Url(RandomNumberGenerator.GetBytes(16));
            string verifier = B64Url(RandomNumberGenerator.GetBytes(48));
            string challenge = B64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
            string url = authUrl + "?" + string.Join("&", new (string K, string V)[]
            {
                ("client_id", clientId), ("redirect_uri", redirect), ("response_type", "code"),
                ("scope", GoogleDriveTransport.Scope), ("access_type", "offline"), ("prompt", "consent"),
                ("state", state), ("code_challenge", challenge), ("code_challenge_method", "S256"),
            }.Select(x => x.K + "=" + Uri.EscapeDataString(x.V)));
            openBrowser(url);

            Dictionary<string, string>? q = null;
            while (q is null)
            {
                using var client = await listener.AcceptTcpClientAsync(ct).ConfigureAwait(false);
                q = await HandleAsync(client, ct).ConfigureAwait(false);
            }
            if (q.TryGetValue("error", out var err))
                throw new SyncException(err == "access_denied" ? "Доступ не выдан (отменено в браузере)" : $"Google: {err}");
            if (!q.TryGetValue("state", out var st) || st != state || !q.TryGetValue("code", out var code))
                throw new SyncException("Google: в ответе нет кода или он чужой");

            using var req = new HttpRequestMessage(HttpMethod.Post, tokenUrl)
            {
                Content = new FormUrlEncodedContent(new Dictionary<string, string>
                {
                    ["code"] = code,
                    ["client_id"] = clientId,
                    ["client_secret"] = clientSecret,
                    ["redirect_uri"] = redirect,
                    ["grant_type"] = "authorization_code",
                    ["code_verifier"] = verifier,
                }),
            };
            using var resp = await http.SendAsync(req, ct).ConfigureAwait(false);
            byte[] body = await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            JsonNode? j = null;
            try { j = JsonNode.Parse(body); } catch { }
            string? refresh = j?["refresh_token"]?.GetValue<string>();
            if (!resp.IsSuccessStatusCode || string.IsNullOrEmpty(refresh))
                throw new SyncException("Google: обмен кода не удался" + SyncHttp.Detail(body));
            return refresh;
        }
        finally { listener.Stop(); }
    }

    /// Один запрос браузера: редирект с кодом — ответить «можно закрыть» и вернуть параметры;
    /// что-то другое (favicon) — 404 и ждать дальше.
    private static async Task<Dictionary<string, string>?> HandleAsync(TcpClient client, CancellationToken ct)
    {
        var stream = client.GetStream();
        var buf = new byte[8192];
        int n = 0;
        using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            cts.CancelAfter(TimeSpan.FromSeconds(10));
            try
            {
                while (n < buf.Length)
                {
                    int r = await stream.ReadAsync(buf.AsMemory(n), cts.Token).ConfigureAwait(false);
                    if (r <= 0) break;
                    n += r;
                    if (Encoding.ASCII.GetString(buf, 0, n).Contains("\r\n\r\n")) break;
                }
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
        }
        string head = Encoding.ASCII.GetString(buf, 0, n);
        string line = head.Split("\r\n")[0];
        string target = line.Split(' ').Skip(1).FirstOrDefault() ?? "";
        int qi = target.IndexOf('?');
        var q = new Dictionary<string, string>(StringComparer.Ordinal);
        if (qi >= 0)
            foreach (var part in target[(qi + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                int e = part.IndexOf('=');
                string k = Uri.UnescapeDataString((e < 0 ? part : part[..e]).Replace('+', ' '));
                string v = e < 0 ? "" : Uri.UnescapeDataString(part[(e + 1)..].Replace('+', ' '));
                q[k] = v;
            }
        bool callback = q.ContainsKey("code") || q.ContainsKey("error");
        string html = !callback ? "" : q.ContainsKey("code")
            ? "<h3>QSwitcher подключён к Google Drive</h3><p>Окно можно закрыть.</p>"
            : "<h3>QSwitcher: доступ не выдан</h3><p>Окно можно закрыть.</p>";
        byte[] page = Encoding.UTF8.GetBytes(
            $"<!doctype html><html><head><meta charset=\"utf-8\"><title>QSwitcher</title></head>" +
            $"<body style=\"font-family:system-ui,-apple-system,Segoe UI,sans-serif;margin:3em\">{html}</body></html>");
        string status = callback ? "200 OK" : "404 Not Found";
        byte[] headBytes = Encoding.ASCII.GetBytes(
            $"HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {(callback ? page.Length : 0)}\r\nConnection: close\r\n\r\n");
        try
        {
            await stream.WriteAsync(headBytes, ct).ConfigureAwait(false);
            if (callback) await stream.WriteAsync(page, ct).ConfigureAwait(false);
            await stream.FlushAsync(ct).ConfigureAwait(false);
        }
        catch { }
        return callback ? q : null;
    }

    private static string B64Url(byte[] b) => Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
