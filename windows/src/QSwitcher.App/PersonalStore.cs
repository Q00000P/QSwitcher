using System.Security.Cryptography;
using System.Text;
using QSwitcher.Core;

namespace QSwitcher.App;

/// <summary>
/// Личный слой на диске: %APPDATA%\QSwitcher\personal.qsp —
/// "QSP1" + DPAPI(текущий пользователь) от JSON, сжатого raw DEFLATE. Там словарь и пары
/// соседних слов — производное от набора, поэтому открытым текстом не лежит (как и
/// защищённый лог). Не расшифровался (другая учётка, битый файл) — файл откладывается
/// в .broken, слой начинается заново.
/// </summary>
public static class PersonalStore
{
    private const string Magic = "QSP1";
    private static readonly byte[] Entropy = Encoding.ASCII.GetBytes("QSwitcher.personal.v1");
    private static readonly object SaveLock = new();

    public static string PathIn(string dir) => Path.Combine(dir, "personal.qsp");

    /// <summary>readOnly — для прогонов из командной строки: битый файл не трогать.</summary>
    public static PersonalLM Load(string dir, Action<string> log, bool readOnly = false)
    {
        string path = PathIn(dir);
        string name = Environment.MachineName;
        if (File.Exists(path))
        {
            try
            {
                byte[] data = File.ReadAllBytes(path);
                if (data.Length < 4 || Encoding.ASCII.GetString(data, 0, 4) != Magic)
                    throw new InvalidDataException("не QSP1");
                byte[] plain = ProtectedData.Unprotect(data[4..], Entropy, DataProtectionScope.CurrentUser);
                string json = Encoding.UTF8.GetString(SkillsFile.Inflate(plain));
                var lm = PersonalLM.FromJson(json, NewId(), name, "win");
                var s = lm.Stats();
                log($"🧠 Личный слой: слов ru {s.WordsRu}, en {s.WordsEn}, пар {s.Pairs}, опечаток {s.TypoForms}, устройств {s.Devices}");
                return lm;
            }
            catch (Exception e)
            {
                if (readOnly)
                {
                    log($"⚠️ Личный слой не прочитался ({e.Message}) — прогон без него");
                    return new PersonalLM(NewId(), name, "win");
                }
                string broken = path + ".broken";
                try { File.Move(path, broken, overwrite: true); } catch { }
                log($"⚠️ Личный слой не прочитался ({e.Message}) — начинаю заново, старый файл: {broken}");
            }
        }
        else log("🧠 Личный слой: пока пуст");
        return new PersonalLM(NewId(), name, "win");
    }

    /// <summary>Записать (в фоне): снимок под замком слоя, шифрование и файл — вне его.</summary>
    public static void Save(PersonalLM lm, string dir, Action<string> log)
    {
        string json = lm.Snapshot();
        lock (SaveLock)
        {
            try
            {
                byte[] enc = ProtectedData.Protect(SkillsFile.Deflate(Encoding.UTF8.GetBytes(json)), Entropy,
                                                   DataProtectionScope.CurrentUser);
                string path = PathIn(dir), tmp = path + ".tmp";
                using (var f = File.Create(tmp))
                {
                    f.Write(Encoding.ASCII.GetBytes(Magic));
                    f.Write(enc);
                }
                File.Move(tmp, path, overwrite: true);
            }
            catch (Exception e) { log($"⚠️ Личный слой не записался: {e.Message}"); }
        }
    }

    private static string NewId() => Guid.NewGuid().ToString("N");
}
