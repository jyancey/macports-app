#!/usr/bin/env python3
"""Generates Design/AppIcon.icns (a package cube on a blue squircle). Requires Pillow."""
import math, os, shutil, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # supersampled canvas
OUT = os.path.dirname(os.path.abspath(__file__))

def squircle_mask(size, inset, n=5.0):
    m = Image.new("L", (size, size), 0)
    px = m.load()
    r = size / 2 - inset
    c = size / 2
    for y in range(size):
        dy = abs(y - c) / r
        if dy > 1: continue
        # solve |x|^n = 1 - |y|^n
        w = (1 - dy ** n) ** (1 / n) * r
        d = ImageDraw.Draw(m)
        d.line([(c - w, y), (c + w, y)], fill=255)
    return m

def gradient(size, top, bottom):
    g = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        g.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return g.resize((size, size))

def build():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = squircle_mask(S, int(S * 0.098))
    bg = gradient(S, (86, 170, 255), (14, 62, 168)).convert("RGBA")
    img.paste(bg, (0, 0), mask)

    # isometric cube
    cx, cy = S / 2, S / 2 + S * 0.01
    R = S * 0.29
    pts = [(cx + R * math.sin(math.radians(a)), cy - R * math.cos(math.radians(a)))
           for a in range(0, 360, 60)]  # top, ur, lr, bottom, ll, ul
    top, ur, lr, bot, ll, ul = pts
    ctr = (cx, cy)
    # drop shadow
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(sh).polygon([(x, y + S * 0.03) for x, y in pts], fill=(0, 20, 70, 140))
    sh = sh.filter(ImageFilter.GaussianBlur(S * 0.025))
    img = Image.alpha_composite(img, sh)
    d = ImageDraw.Draw(img)
    d.polygon([ul, top, ur, ctr], fill=(255, 255, 255, 255))
    d.polygon([ul, ctr, bot, ll], fill=(205, 226, 255, 255))
    d.polygon([ctr, ur, lr, bot], fill=(150, 190, 245, 255))
    # tape across the top face
    tape = (255, 190, 60, 255)
    def lerp(a, b, t): return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
    d.polygon([lerp(ul, top, .42), lerp(ul, top, .58), lerp(ctr, ur, .58), lerp(ctr, ur, .42)], fill=tape)
    # clip to the shape's alpha so nothing escapes the squircle
    clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    clipped.paste(img, (0, 0), mask)
    return clipped

def main():
    master = build().resize((1024, 1024), Image.LANCZOS)
    iconset = os.path.join(OUT, "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    for base in (16, 32, 128, 256, 512):
        master.resize((base, base), Image.LANCZOS).save(f"{iconset}/icon_{base}x{base}.png")
        master.resize((base * 2, base * 2), Image.LANCZOS).save(f"{iconset}/icon_{base}x{base}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", "-o", os.path.join(OUT, "AppIcon.icns"), iconset], check=True)
    shutil.rmtree(iconset)
    master.save(os.path.join(OUT, "AppIcon-1024.png"))

main()
