"""Draws the LavaHop CurseForge avatar (400x400 PNG, original art).

A glowing lava pool with a jump arc over it, and the addon's jump bar on top:
dark track, green jump zone, white marker, red tick line. "LavaHop" underneath.
Rendered at 4x and scaled down for smooth edges.

    python3 media/make_avatar.py      (needs Pillow)
"""
import math
import pathlib
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = pathlib.Path(__file__).resolve().parent / "avatar.png"
S = 4
W = 400 * S

INK = (14, 10, 8)
GOLD = (255, 200, 90)
ORANGE = (255, 120, 20)
GREEN = (40, 200, 60)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


# background: dark rock, warmer toward the bottom where the lava is
bg = Image.new("RGB", (W, W))
px = bg.load()
for y in range(W):
    t = y / W
    row = lerp((24, 16, 22), (70, 22, 8), t ** 1.6)
    for x in range(W):
        px[x, y] = row
img = bg.convert("RGBA")

# lava pool with wavy surface
lava = Image.new("RGBA", (W, W), (0, 0, 0, 0))
d = ImageDraw.Draw(lava)
surface = []
for i in range(0, W + 1, 8):
    surface.append((i, int(W * 0.70 + math.sin(i / W * math.pi * 5) * 10 * S)))
d.polygon(surface + [(W, W), (0, W)], fill=(255, 90, 10, 255))
# hot streaks
for k in range(7):
    y0 = int(W * (0.76 + k * 0.035))
    pts = [(x, y0 + int(math.sin(x / W * math.pi * (4 + k) + k) * 6 * S)) for x in range(0, W + 1, 8)]
    d.line(pts, fill=(255, 190 - k * 12, 60, 200), width=4 * S)
glow = lava.filter(ImageFilter.GaussianBlur(28 * S))
img = Image.alpha_composite(img, glow)
img = Image.alpha_composite(img, lava)

# jump arc (dashed) from the lava up and back down
d = ImageDraw.Draw(img)
cx, base, rx, ry = W * 0.5, W * 0.70, W * 0.30, W * 0.30
pts = [(cx + rx * math.cos(a), base - ry * math.sin(a)) for a in [math.pi * i / 60 for i in range(61)]]
for i in range(0, 60, 4):
    d.line(pts[i:i + 3], fill=(255, 255, 255, 230), width=6 * S)
# a hopping ember at the top of the arc
ember = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(ember).ellipse((cx - 26 * S, base - ry - 26 * S, cx + 26 * S, base - ry + 26 * S), fill=(255, 170, 40, 255))
img = Image.alpha_composite(img, ember.filter(ImageFilter.GaussianBlur(14 * S)))
d = ImageDraw.Draw(img)
d.ellipse((cx - 17 * S, base - ry - 17 * S, cx + 17 * S, base - ry + 17 * S), fill=(255, 235, 150, 255),
          outline=INK, width=3 * S)
# little splashes where it leaves and lands
for sx in (cx - rx, cx + rx):
    for a in (-0.9, -0.5, -0.1):
        ex, ey = sx + math.sin(a) * 22 * S, base - math.cos(a) * 26 * S
        d.line((sx, base, ex, ey), fill=(255, 210, 90, 255), width=5 * S)

# the jump bar
bx0, bx1, by0, by1 = W * 0.10, W * 0.90, W * 0.10, W * 0.19
d.rounded_rectangle((bx0 - 6 * S, by0 - 6 * S, bx1 + 6 * S, by1 + 6 * S), radius=10 * S, fill=(0, 0, 0, 200))
d.rectangle((bx0, by0, bx1, by1), fill=(80, 22, 0, 255))
zx0, zx1 = bx0 + (bx1 - bx0) * 0.58, bx0 + (bx1 - bx0) * 0.80
d.rectangle((zx0, by0, zx1, by1), fill=GREEN + (255,))
mx = bx0 + (bx1 - bx0) * 0.68
d.rectangle((mx - 4 * S, by0 - 10 * S, mx + 4 * S, by1 + 10 * S), fill=(255, 255, 255, 255), outline=INK, width=2 * S)
d.rectangle((bx1 - 4 * S, by0 - 12 * S, bx1 + 4 * S, by1 + 12 * S), fill=(255, 30, 20, 255))

# title
font = ImageFont.truetype(r"C:\Windows\Fonts\seguibl.ttf", 66 * S)
text = "LavaHop"
tw = d.textlength(text, font=font)
tx, ty = (W - tw) / 2, W * 0.79
shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(shadow).text((tx + 3 * S, ty + 5 * S), text, font=font, fill=(0, 0, 0, 190))
img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(4 * S)))
d = ImageDraw.Draw(img)
lw = d.textlength("Lava", font=font)
d.text((tx, ty), "Lava", font=font, fill=ORANGE, stroke_width=3 * S, stroke_fill=INK)
d.text((tx + lw, ty), "Hop", font=font, fill=GOLD, stroke_width=3 * S, stroke_fill=INK)

img.convert("RGB").resize((400, 400), Image.LANCZOS).save(OUT)
print(OUT)
