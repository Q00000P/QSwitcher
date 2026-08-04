using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using Microsoft.Win32;

namespace QSwitcher.App;

/// <summary>
/// Автозапуск через реестр — без установщика и без задач планировщика.
/// Приложение остаётся портативным: в реестр пишется путь к текущему exe,
/// перенёс папку — просто переключи галку заново.
/// </summary>
public static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "QSwitcher";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string s && s.Contains("QSwitcher", StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    public static bool Enable()
    {
        try
        {
            string exe = Environment.ProcessPath ?? "";
            if (exe.Length == 0) return false;
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            key.SetValue(ValueName, $"\"{exe}\"");
            return true;
        }
        catch { return false; }
    }

    public static void Disable()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            key?.DeleteValue(ValueName, throwOnMissingValue: false);
        }
        catch { }
    }

    /// Путь, записанный сейчас — чтобы показать в меню, если он устарел.
    public static string? CurrentPath()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) as string;
        }
        catch { return null; }
    }
}

/// <summary>
/// Иконка в трее с индикатором текущей раскладки.
///
/// Рисуется на лету: тёмный квадрат и две буквы. Заметно полезнее статичной
/// картинки — видно, в какой раскладке окажется следующее слово, особенно
/// после автопереключения.
/// </summary>
public static class TrayIconFactory
{
    private static readonly Dictionary<string, Icon> Cache = new();

    public static Icon ForLayout(string label, bool paused, bool noRights = false)
    {
        string key = $"{label}|{paused}|{noRights}";
        lock (Cache)
        {
            if (Cache.TryGetValue(key, out var cached)) return cached;
            var icon = Render(label, paused, noRights);
            Cache[key] = icon;
            return icon;
        }
    }

    private static Icon Render(string label, bool paused, bool noRights)
    {
        // Рисуем СРАЗУ в размере трея. Раньше рисовалось 32×32 и сжималось
        // системой до 16×16 — текст превращался в кашу и ничего не читалось.
        int size = SystemInformation.SmallIconSize.Width;
        if (size < 16) size = 16;
        if (size > 32) size = 32;

        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.None;
            // Для мелкого текста сглаживание вредит: буквы плывут.
            // Пиксельный рендер даёт чёткие штрихи.
            g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;

            Color fg = noRights ? Color.FromArgb(255, 90, 90)
                     : paused ? Color.FromArgb(150, 150, 160)
                     : Color.White;

            // Заливка на весь квадрат, без скруглений: на 16 пикселях
            // скругления съедают площадь, а читаемость важнее красоты.
            using var back = new SolidBrush(Color.FromArgb(235, 24, 26, 33));
            g.FillRectangle(back, 0, 0, size, size);

            // Цветная кромка слева — видно состояние даже боковым зрением
            Color accent = noRights ? Color.FromArgb(220, 70, 70)
                         : paused ? Color.FromArgb(110, 110, 120)
                         : Color.FromArgb(110, 108, 240);
            using var accentBrush = new SolidBrush(accent);
            g.FillRectangle(accentBrush, 0, 0, 2, size);

            // Шрифт подбираем под размер, чтобы две буквы влезли впритык
            float pt = size >= 24 ? 11f : size >= 20 ? 9f : 7.5f;
            using var font = new Font("Tahoma", pt, FontStyle.Bold, GraphicsUnit.Point);
            var sz = g.MeasureString(label, font);
            float x = (size - sz.Width) / 2f + 1;
            float y = (size - sz.Height) / 2f;
            using var fgBrush = new SolidBrush(fg);
            g.DrawString(label, font, fgBrush, x, y);
        }

        IntPtr h = bmp.GetHicon();
        try { return (Icon)Icon.FromHandle(h).Clone(); }
        finally { DestroyIcon(h); }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);

    private static GraphicsPath Rounded(Rectangle r, int radius)
    {
        var p = new GraphicsPath();
        int d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}
