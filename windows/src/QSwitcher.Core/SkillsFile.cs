using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace QSwitcher.Core;

/// <summary>
/// Файл навыков QSwitcher — экспорт/импорт и (дальше) синхронизация между устройствами.
/// Один формат на маке и винде:
///
///   без пароля — JSON как есть (UTF-8, читается глазами);
///   с паролем  — "QSX1" | соль 16 | итерации u32 LE | nonce 12 | шифротекст | тег 16
///                ключ = PBKDF2-HMAC-SHA256(пароль, соль, итерации, 32 байта),
///                шифр = AES-256-GCM, внутри — JSON, сжатый raw DEFLATE (RFC 1951).
///
/// Содержимое (всё необязательно):
///   format "qswitcher-skills", v 1, created, from {device, name, platform}
///   learned {force [], stop []}          — выученные правила
///   forceWords [], stopWords []          — списки из меню
///   apps {mac|win: {excluded [], english [], lang {приложение: [ru, en]}}} — своё для платформы
///   profileJournal "…"                   — журнал профиля (мак); винда хранит и передаёт дальше
///   personal {…}                         — личный слой, таблицы по устройствам (PersonalLM)
/// </summary>
public static class SkillsFile
{
    public const string Format = "qswitcher-skills";
    public const string Magic = "QSX1";
    public const int Iterations = 600_000;

    public static readonly JsonSerializerOptions Json = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        WriteIndented = false,
        TypeInfoResolver = new System.Text.Json.Serialization.Metadata.DefaultJsonTypeInfoResolver(),
    };

    public static readonly JsonSerializerOptions JsonIndented = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        WriteIndented = true,
        TypeInfoResolver = new System.Text.Json.Serialization.Metadata.DefaultJsonTypeInfoResolver(),
    };

    public sealed class WrongPasswordException : Exception
    {
        public WrongPasswordException() : base("Неверный пароль или файл повреждён") { }
    }

    /// <summary>Файл зашифрован (нужен пароль)?</summary>
    public static bool IsEncrypted(byte[] data) =>
        data.Length >= 4 && Encoding.ASCII.GetString(data, 0, 4) == Magic;

    /// <summary>Упаковать: пустой пароль — открытый JSON с отступами.</summary>
    public static byte[] Pack(JsonObject doc, string? password)
    {
        if (string.IsNullOrEmpty(password))
            return Encoding.UTF8.GetBytes(doc.ToJsonString(JsonIndented));
        byte[] plain = Deflate(Encoding.UTF8.GetBytes(doc.ToJsonString(Json)));
        byte[] salt = RandomNumberGenerator.GetBytes(16);
        byte[] nonce = RandomNumberGenerator.GetBytes(12);
        byte[] key = Rfc2898DeriveBytes.Pbkdf2(password, salt, Iterations, HashAlgorithmName.SHA256, 32);
        byte[] cipher = new byte[plain.Length];
        byte[] tag = new byte[16];
        using (var gcm = new AesGcm(key, 16)) gcm.Encrypt(nonce, plain, cipher, tag);
        using var ms = new MemoryStream();
        ms.Write(Encoding.ASCII.GetBytes(Magic));
        ms.Write(salt);
        ms.Write(BitConverter.GetBytes((uint)Iterations));   // little-endian на x86/arm
        ms.Write(nonce);
        ms.Write(cipher);
        ms.Write(tag);
        return ms.ToArray();
    }

    /// <summary>Распаковать. Зашифрованный без пароля или с неверным — WrongPasswordException.</summary>
    public static JsonNode Unpack(byte[] data, string? password)
    {
        string text;
        if (IsEncrypted(data))
        {
            if (string.IsNullOrEmpty(password) || data.Length < 4 + 16 + 4 + 12 + 16) throw new WrongPasswordException();
            var salt = data.AsSpan(4, 16);
            uint iters = BitConverter.ToUInt32(data, 20);
            if (iters < 1000 || iters > 10_000_000) throw new InvalidDataException("странное число итераций");
            var nonce = data.AsSpan(24, 12);
            int clen = data.Length - 36 - 16;
            var cipher = data.AsSpan(36, clen);
            var tag = data.AsSpan(36 + clen, 16);
            byte[] key = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), salt.ToArray(), (int)iters, HashAlgorithmName.SHA256, 32);
            byte[] plain = new byte[clen];
            try
            {
                using var gcm = new AesGcm(key, 16);
                gcm.Decrypt(nonce, cipher, tag, plain);
            }
            catch (CryptographicException) { throw new WrongPasswordException(); }
            text = Encoding.UTF8.GetString(Inflate(plain));
        }
        else
        {
            text = Encoding.UTF8.GetString(data).TrimStart('﻿');
        }
        var node = JsonNode.Parse(text) ?? throw new InvalidDataException("пустой файл");
        if (node["format"]?.GetValue<string>() != Format) throw new InvalidDataException("это не файл навыков QSwitcher");
        return node;
    }

    public static byte[] Deflate(byte[] input)
    {
        using var ms = new MemoryStream();
        using (var z = new DeflateStream(ms, CompressionLevel.Optimal, leaveOpen: true)) z.Write(input);
        return ms.ToArray();
    }

    public static byte[] Inflate(byte[] input)
    {
        using var src = new MemoryStream(input);
        using var z = new DeflateStream(src, CompressionMode.Decompress);
        using var dst = new MemoryStream();
        z.CopyTo(dst);
        return dst.ToArray();
    }

    /// <summary>Заготовка документа: формат, время, откуда.</summary>
    public static JsonObject NewDocument(string device, string name, string platform) => new()
    {
        ["format"] = Format,
        ["v"] = 1,
        ["created"] = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
        ["from"] = new JsonObject { ["device"] = device, ["name"] = name, ["platform"] = platform },
    };

    public static JsonArray Strings(IEnumerable<string> xs)
    {
        var a = new JsonArray();
        foreach (var x in xs.OrderBy(s => s, StringComparer.Ordinal)) a.Add(x);
        return a;
    }

    public static List<string> ReadStrings(JsonNode? n)
    {
        var r = new List<string>();
        if (n is JsonArray a)
            foreach (var x in a)
                if (x is JsonValue v && v.TryGetValue<string>(out var s) && s.Length > 0) r.Add(s);
        return r;
    }

    /// <summary>Строки журнала, которых ещё нет в текущем (без повторов, порядок файла).</summary>
    public static List<string> NewJournalLines(string current, string incoming)
    {
        var have = new HashSet<string>(current.Split('\n').Select(l => l.TrimEnd('\r')), StringComparer.Ordinal);
        var add = new List<string>();
        foreach (var raw in incoming.Split('\n'))
        {
            string l = raw.TrimEnd('\r');
            if (l.Trim().Length == 0 || have.Contains(l)) continue;
            have.Add(l);
            add.Add(l);
        }
        return add;
    }
}
