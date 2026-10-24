"""Draws Jalan's app icon (a white lowercase j on blue) as a 1024x1024 PNG.

    python3 scripts/make_app_icon.py Jalan/Assets.xcassets/AppIcon.appiconset/AppIcon.png

Needs Pillow (pip install pillow). Xcode makes every other size, CarPlay's included, from this one.
"""
import math, sys
from PIL import Image, ImageChops, ImageDraw

S = 4  # supersample
N = 1024 * S
out = sys.argv[1]

def mix(c1, c2, t): return tuple(round(a + (b - a) * t) for a, b in zip(c1, c2))

def stroke(mask, path, w):
    d = ImageDraw.Draw(mask)
    for px, py in path:
        d.ellipse(((px - w / 2) * S, (py - w / 2) * S, (px + w / 2) * S, (py + w / 2) * S), fill=255)

# Background: soft vertical blue gradient
top, bottom = (48, 170, 255), (0, 98, 224)
img = Image.new("RGB", (1, N))
for y in range(N):
    img.putpixel((0, y), mix(top, bottom, y / (N - 1)))
img = img.resize((N, N))

white = Image.new("L", (N, N), 0)

# The j: a stem going down, hooking left at the bottom
w = 120                      # line width
x, y0, y1, r = 590, 470, 650, 165
path = [(x, yy) for yy in range(y0, y1)]
path += [(x - r + r * math.cos(math.radians(i)), y1 + r * math.sin(math.radians(i))) for i in range(161)]
stroke(white, path, w)

# The dot, a little wider than the stem
stroke(white, [(x, 280)], 136)

# Centre the whole mark
l, t, rgt, b = white.getbbox()
dx, dy = (N - (l + rgt)) // 2, (N - (t + b)) // 2
white = ImageChops.offset(white, dx, dy)

img.paste((255, 255, 255), (0, 0), white)
img.resize((1024, 1024), Image.LANCZOS).save(out, optimize=True)
