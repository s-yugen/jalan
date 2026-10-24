"""Draws Jalan's app icon (a route shaped like a J, ending in an arrow) as a 1024x1024 PNG.

    python3 scripts/make_app_icon.py Jalan/Assets.xcassets/AppIcon.appiconset/AppIcon.png

Needs Pillow (pip install pillow). Xcode makes every other size, CarPlay's included, from this one.
"""
import math, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4  # supersample
N = 1024 * S
out = sys.argv[1]

def mix(c1, c2, t): return tuple(round(a + (b - a) * t) for a, b in zip(c1, c2))

# Background: soft vertical blue gradient
top, bottom = (48, 170, 255), (0, 98, 224)
img = Image.new("RGB", (1, N))
for y in range(N):
    img.putpixel((0, y), mix(top, bottom, y / (N - 1)))
img = img.resize((N, N))
white = (255, 255, 255)
mark = Image.new("L", (N, N), 0)  # the white mark, drawn as a mask
d = ImageDraw.Draw(mark)

# Route: a stem going up, hooking left at the bottom like a J
w = 116            # line width
x, y0, y1 = 600, 360, 640   # stem
r = 170            # hook radius, centred at (x - r, y1)
path = [(x, yy) for yy in range(y0, y1)]
for i in range(0, 161):
    a = math.radians(i)
    path.append((x - r + r * math.cos(a), y1 + r * math.sin(a)))
for px, py in path:
    d.ellipse(((px - w / 2) * S, (py - w / 2) * S, (px + w / 2) * S, (py + w / 2) * S), fill=255)

# Arrowhead on top of the stem
tip, base, half = 160, 405, 200
d.polygon([(x * S, tip * S), ((x + half) * S, base * S), ((x - half) * S, base * S)], fill=255)

# Soften every corner: blur the mark and cut it back at half strength
mark = mark.filter(ImageFilter.GaussianBlur(7 * S)).point(lambda v: 255 if v >= 128 else 0)
img.paste(white, (0, 0), mark)

img.resize((1024, 1024), Image.LANCZOS).save(out, optimize=True)
