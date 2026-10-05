#!/usr/bin/env python3
"""Erzeugt die App-Icons für alle Plattformen aus einer Zeichnung.

    python3 tool/make_icons.py            # alle Icons schreiben
    python3 tool/make_icons.py --preview  # nur build/icon-preview.png

Braucht Pillow. Motiv: ein Dokument mit Eselsohr und freundlichem Gesicht
vor einem zweiten Blatt, auf grünem Grund (Farbe wie im App-Theme). Die
Dev-Variante bekommt zusätzlich ein orangefarbenes DEV-Band.
"""

import json
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024          # Arbeitsgröße
SS = 4            # Überabtastung für glatte Kanten

GREEN_TOP = (58, 150, 128)
GREEN_BOTTOM = (31, 102, 87)
INK = (46, 125, 107)
SHEET_BACK = (214, 236, 229)
ORANGE = (232, 89, 12)
FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"


def _gradient(size):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        c = tuple(round(a + (b - a) * t) for a, b in zip(GREEN_TOP, GREEN_BOTTOM))
        d.line([(0, y), (size, y)], fill=c)
    return img


def motif(size, scale=1.0):
    """Dokumente auf transparentem Grund, mittig, `scale` = Anteil der Fläche."""
    n = size * SS
    layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))

    def box(x0, y0, x1, y1):
        # Koordinaten in Anteilen der Kantenlänge, um die Mitte skaliert.
        f = lambda v: round(n * (0.5 + (v - 0.5) * scale))
        return [f(x0), f(y0), f(x1), f(y1)]

    # Hinteres Blatt, leicht gedreht.
    back = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(back).rounded_rectangle(
        box(0.30, 0.20, 0.72, 0.76), radius=round(n * 0.035 * scale), fill=SHEET_BACK + (255,))
    back = back.rotate(-9, resample=Image.BICUBIC, center=(n * 0.5, n * 0.5))
    layer.alpha_composite(back)

    # Schatten des vorderen Blatts.
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        box(0.27, 0.27, 0.70, 0.83), radius=round(n * 0.035 * scale), fill=(0, 40, 30, 90))
    layer.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(n * 0.015)))

    # Vorderes Blatt mit Eselsohr oben rechts.
    x0, y0, x1, y1 = box(0.26, 0.24, 0.69, 0.80)
    r = round(n * 0.035 * scale)
    ear = round(n * 0.11 * scale)
    sheet = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheet)
    sd.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=(255, 255, 255, 255))
    sd.polygon([(x1 - ear, y0 - 2), (x1 + 2, y0 - 2), (x1 + 2, y0 + ear)], fill=(0, 0, 0, 0))
    sheet_alpha = sheet.split()[3]
    layer.alpha_composite(sheet)
    d = ImageDraw.Draw(layer)
    d.polygon([(x1 - ear, y0), (x1 - ear, y0 + ear), (x1, y0 + ear)], fill=SHEET_BACK + (255,))

    # Textzeilen.
    w = x1 - x0
    lh = round(n * 0.028 * scale)
    for i, frac in enumerate((0.55, 0.72, 0.62)):
        ly = y0 + round(n * (0.085 + i * 0.062) * scale)
        lx = x0 + round(w * 0.16)
        d.rounded_rectangle([lx, ly, lx + round((w * 0.68) * frac / 0.72), ly + lh],
                            radius=lh // 2, fill=INK + (255,))

    # Gesicht: zwei Augen und ein Lächeln.
    cx = (x0 + x1) // 2
    ey = y0 + round(n * 0.345 * scale)
    er = round(n * 0.03 * scale)
    for dx in (-0.085, 0.085):
        ex = cx + round(n * dx * scale)
        d.ellipse([ex - er, ey - er, ex + er, ey + er], fill=INK + (255,))
    sw = round(n * 0.15 * scale)
    sy = ey + round(n * 0.02 * scale)
    d.arc([cx - sw, sy - sw // 2, cx + sw, sy + round(sw * 0.75)], start=30, end=150,
          fill=INK + (255,), width=round(n * 0.028 * scale))
    return layer.resize((size, size), Image.LANCZOS)


def dev_band(img, mask=None, top=0.735, bottom=0.885, text=0.12):
    """Orangefarbenes DEV-Band im unteren Drittel, auf `mask` beschnitten."""
    n = img.width
    band = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(band)
    top, bottom = round(n * top), round(n * bottom)
    d.rectangle([0, top, n, bottom], fill=ORANGE + (255,))
    font = ImageFont.truetype(FONT, round(n * text))
    l, t, r, b = d.textbbox((0, 0), "DEV", font=font)
    d.text(((n - (r - l)) / 2 - l, top + ((bottom - top) - (b - t)) / 2 - t),
           "DEV", font=font, fill="white")
    if mask is not None:
        band.putalpha(Image.composite(band.split()[3], Image.new("L", img.size, 0), mask))
    out = img.copy()
    out.alpha_composite(band)
    return out


def full_bleed(size, dev=False):
    """Quadrat ohne Transparenz (iOS, Android-Legacy, Web)."""
    img = _gradient(size).convert("RGBA")
    img.alpha_composite(motif(size))
    return dev_band(img) if dev else img


def macos_icon(size, dev=False):
    """macOS: abgerundetes Quadrat mit Rand und Schatten (Apple-Raster)."""
    n = size * SS
    inset = round(n * 0.1)
    body = Image.new("L", (n, n), 0)
    ImageDraw.Draw(body).rounded_rectangle([inset, inset, n - inset, n - inset],
                                           radius=round(n * 0.18), fill=255)
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    shadow.putalpha(body.point(lambda v: v * 70 // 255).filter(ImageFilter.GaussianBlur(n * 0.012)))
    shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -round(n * 0.01)))
    inner = n - 2 * inset
    face = _gradient(inner).convert("RGBA")
    face.alpha_composite(motif(inner, scale=1.0))
    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    canvas.alpha_composite(shadow)
    tile = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    tile.paste(face, (inset, inset))
    tile.putalpha(body)
    canvas.alpha_composite(tile)
    if dev:
        canvas = dev_band(canvas, mask=body)
    return canvas.resize((size, size), Image.LANCZOS)


def save(img, path, rgb=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    (img.convert("RGB") if rgb else img).save(path)


def write_macos():
    base = os.path.join(ROOT, "macos/Runner/Assets.xcassets")
    for name, dev in (("AppIcon", False), ("AppIconDev", True)):
        src = macos_icon(1024, dev)
        for s in (16, 32, 64, 128, 256, 512, 1024):
            save(src.resize((s, s), Image.LANCZOS), f"{base}/{name}.appiconset/app_icon_{s}.png")
        contents = os.path.join(base, "AppIcon.appiconset/Contents.json")
        if name != "AppIcon":
            with open(contents) as f:
                data = f.read()
            with open(os.path.join(base, f"{name}.appiconset/Contents.json"), "w") as f:
                f.write(data)


def write_ios():
    base = os.path.join(ROOT, "ios/Runner/Assets.xcassets")
    with open(os.path.join(base, "AppIcon.appiconset/Contents.json")) as f:
        contents = json.load(f)
    for name, dev in (("AppIcon", False), ("AppIconDev", True)):
        src = full_bleed(1024, dev)
        folder = os.path.join(base, f"{name}.appiconset")
        for img in contents["images"]:
            fn = img.get("filename")
            if not fn:
                continue
            pts = float(img["size"].split("x")[0])
            px = round(pts * int(img["scale"].rstrip("x")))
            save(src.resize((px, px), Image.LANCZOS), os.path.join(folder, fn), rgb=True)
        with open(os.path.join(folder, "Contents.json"), "w") as f:
            json.dump(contents, f, indent=2)
            f.write("\n")


ANDROID_DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
"""


def write_android():
    for flavor, dev in (("main", False), ("dev", True)):
        res = os.path.join(ROOT, f"android/app/src/{flavor}/res")
        legacy = full_bleed(1024, dev)
        # Adaptive Icons: 108dp-Fläche, sichtbar ist die mittlere 72dp-Zone.
        fg = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
        fg.alpha_composite(motif(1024, scale=0.66))
        if dev:
            # Nur innerhalb der sicheren Zone (Kreis mit 66/108 Durchmesser).
            band_mask = Image.new("L", (1024, 1024), 0)
            ImageDraw.Draw(band_mask).ellipse([171, 171, 853, 853], fill=255)
            fg = dev_band(fg, mask=band_mask, top=0.645, bottom=0.765, text=0.095)
        bg = _gradient(1024)
        mono = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
        mono.putalpha(motif(1024, scale=0.66).split()[3])
        for dens, f in ANDROID_DENSITIES.items():
            d = os.path.join(res, f"mipmap-{dens}")
            save(legacy.resize((round(48 * f),) * 2, Image.LANCZOS), f"{d}/ic_launcher.png", rgb=True)
            px = round(108 * f)
            save(fg.resize((px, px), Image.LANCZOS), f"{d}/ic_launcher_foreground.png")
            save(bg.resize((px, px), Image.LANCZOS), f"{d}/ic_launcher_background.png", rgb=True)
            save(mono.resize((px, px), Image.LANCZOS), f"{d}/ic_launcher_monochrome.png")
        os.makedirs(os.path.join(res, "mipmap-anydpi-v26"), exist_ok=True)
        with open(os.path.join(res, "mipmap-anydpi-v26/ic_launcher.xml"), "w") as f:
            f.write(ADAPTIVE_XML)


def write_web():
    web = os.path.join(ROOT, "web")
    src = full_bleed(1024)
    save(src.resize((32, 32), Image.LANCZOS), f"{web}/favicon.png", rgb=True)
    for s in (192, 512):
        save(src.resize((s, s), Image.LANCZOS), f"{web}/icons/Icon-{s}.png", rgb=True)
        masked = _gradient(1024).convert("RGBA")
        masked.alpha_composite(motif(1024, scale=0.8))
        save(masked.resize((s, s), Image.LANCZOS), f"{web}/icons/Icon-maskable-{s}.png", rgb=True)


def main():
    if "--preview" in sys.argv:
        row = Image.new("RGBA", (4 * 520, 520), (240, 240, 240, 255))
        for i, img in enumerate((macos_icon(512), macos_icon(512, True),
                                 full_bleed(512), full_bleed(512, True))):
            row.alpha_composite(img, (i * 520 + 4, 4))
        os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
        row.save(os.path.join(ROOT, "build/icon-preview.png"))
        print(os.path.join(ROOT, "build/icon-preview.png"))
        return
    write_macos()
    write_ios()
    write_android()
    write_web()
    print("Icons geschrieben.")


if __name__ == "__main__":
    main()
