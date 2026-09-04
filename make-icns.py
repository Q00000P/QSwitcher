#!/usr/bin/env python3
"""
Собирает иконки обеих платформ из одного PNG 1024x1024, без macOS и без
ImageMagick — только Pillow.

  QSwitcher.icns  — для мака (Finder, Dock)
  qswitcher.ico   — для винды (exe в проводнике и на панели задач)

На маке эту работу делает make-icon.sh (sips + iconutil), но их нет на
Windows/Linux. ImageMagick для .icns не годится: пишет файл, внутри
которого просто PNG вместо структуры иконки — Finder такую не покажет.
Формат icns простой (заголовок + чанки), поэтому собираем сами.

Требуется только Pillow:  pip install pillow

ImageMagick для .icns не годится: пишет файл, внутри которого просто PNG
вместо структуры иконки — Finder такую не покажет.

Запуск (из корня репозитория):
    python make-icns.py                      # оба файла на штатные места
    python make-icns.py путь/к/иконке.png    # свой исходник
"""
import io
import struct
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Нужен Pillow: pip install pillow")

# (тег чанка, сторона в пикселях). Теги ic11..ic14 — это @2x-варианты
# для ретины: система берёт их для 16/32/128/256 на плотных экранах.
TYPES = [
    (b"icp4", 16), (b"icp5", 32), (b"ic07", 128), (b"ic08", 256),
    (b"ic09", 512), (b"ic10", 1024),
    (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
]


def build_ico(src: "Image.Image", out_path: str) -> None:
    """ICO для винды. Внутри должны лежать все размеры, иначе проводник
    масштабирует 256-й в 16-й и получается мыло."""
    sizes = [(s, s) for s in (256, 128, 64, 48, 32, 16)]
    src.save(out_path, format="ICO", sizes=sizes)
    print(f"✅ {out_path} — {len(sizes)} размеров")


def build(src_path: str, out_path: str, ico_path: str = "") -> None:
    src = Image.open(src_path).convert("RGBA")
    if src.size != (1024, 1024):
        print(f"⚠️  Исходник {src.size[0]}x{src.size[1]}, ожидался 1024x1024 — "
              f"мелкие размеры получатся мыльными")

    chunks = b""
    for tag, size in TYPES:
        buf = io.BytesIO()
        src.resize((size, size), Image.LANCZOS).save(buf, format="PNG")
        data = buf.getvalue()
        # Чанк: тег (4 байта) + длина ВМЕСТЕ с заголовком (4 байта) + данные
        chunks += tag + struct.pack(">I", len(data) + 8) + data

    icns = b"icns" + struct.pack(">I", len(chunks) + 8) + chunks
    with open(out_path, "wb") as f:
        f.write(icns)
    print(f"✅ {out_path} — {len(icns)} байт, {len(TYPES)} размеров")

    if ico_path:
        build_ico(src, ico_path)
    print("   Мак: ./make-app.sh подхватит icns сам. Винда: dotnet publish.")


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else "icon/QSwitcher-1024.png"
    out = sys.argv[2] if len(sys.argv) > 2 else "icon/QSwitcher.icns"
    ico = sys.argv[3] if len(sys.argv) > 3 else \
        "windows/src/QSwitcher.App/Resources/qswitcher.ico"
    import os
    if not os.path.isfile(src):
        sys.exit(f"Нет исходника: {src}")
    if not os.path.isdir(os.path.dirname(ico) or "."):
        print(f"⚠️  Нет каталога для ico ({ico}) — делаю только icns")
        ico = ""
    build(src, out, ico)
