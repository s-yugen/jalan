"""Draws Jalan's app icon (a road leading to a location pin) as a 1024x1024 PNG.

    python3 scripts/make_app_icon.py Jalan/Assets.xcassets/AppIcon.appiconset/AppIcon.png

Needs Pillow (pip install pillow). Xcode makes every other size, CarPlay's included, from this one.
"""
import math, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4  # supersample
N = 1024 * S
out = sys.argv[1]

def lerp(a, b, t): return a + (b - a) * t
def mix(c1, c2, t): return tuple(round(lerp(a, b, t)) for a, b in zip(c1, c2))

# Background: vertical gradient, sky blue to deep navy (matches the app's blue route line)
top, bottom = (40, 160, 255), (8, 52, 140)
bg = Image.new("RGB", (1, N))
for y in range(N):
    bg.putpixel((0, y), mix(top, bottom, y / (N - 1)))
img = bg.resize((N, N))
d = ImageDraw.Draw(img)

# Road centerline: cubic bezier sweeping from the bottom up to the horizon
P = [(470, 1180), (470, 880), (720, 700), (570, 470)]
def bez(t):
    u = 1 - t
    x = u**3*P[0][0] + 3*u*u*t*P[1][0] + 3*u*t*t*P[2][0] + t**3*P[3][0]
    y = u**3*P[0][1] + 3*u*u*t*P[1][1] + 3*u*t*t*P[2][1] + t**3*P[3][1]
    return x * S, y * S
def width(t):  # perspective: wide near, narrow far
    return lerp(760, 60, t ** 0.7) * S

steps = 400
pts = [bez(i / steps) for i in range(steps + 1)]
def normal(i):
    a, b = pts[max(i - 1, 0)], pts[min(i + 1, steps)]
    dx, dy = b[0] - a[0], b[1] - a[1]
    l = math.hypot(dx, dy)
    return -dy / l, dx / l

def band(t0, t1, w_scale, off=0.0):
    i0, i1 = int(t0 * steps), int(t1 * steps)
    left, right = [], []
    for i in range(i0, i1 + 1):
        nx, ny = normal(i)
        w = width(i / steps)
        c = off * w
        h = w * w_scale / 2
        x, y = pts[i]
        left.append((x + nx * (c - h), y + ny * (c - h)))
        right.append((x + nx * (c + h), y + ny * (c + h)))
    return left + right[::-1]

# Soft shadow under the road
shadow = Image.new("L", (N, N), 0)
ImageDraw.Draw(shadow).polygon(band(0, 1, 1.08), fill=110)
shadow = shadow.filter(ImageFilter.GaussianBlur(14 * S))
img.paste((4, 30, 90), (0, 0), shadow)

# Road surface with white edge lines
d.polygon(band(0, 1, 1.0), fill=(250, 250, 252))
d.polygon(band(0, 1, 0.88), fill=(46, 52, 64))

# Yellow center dashes, shrinking with distance
t, dash, gap = 0.0, 0.085, 0.06
while t < 0.97:
    t1 = min(t + dash, 0.97)
    d.polygon(band(t, t1, 0.07), fill=(255, 204, 0))
    k = 1 - t  # spacing shrinks toward the horizon
    t += (dash + gap) * (0.55 + 0.45 * k)
    dash *= 0.9

# Location pin at the end of the road
cx, cy, r = 570 * S, 250 * S, 140 * S
tip = (cx, cy + r * 2.05)
pin_shadow = Image.new("L", (N, N), 0)
sd = ImageDraw.Draw(pin_shadow)
sd.ellipse((cx - r, cy - r + 18 * S, cx + r, cy + r + 18 * S), fill=120)
sd.polygon([(cx - r * 0.86, cy + r * 0.5 + 18 * S), (cx + r * 0.86, cy + r * 0.5 + 18 * S), (tip[0], tip[1] + 18 * S)], fill=120)
pin_shadow = pin_shadow.filter(ImageFilter.GaussianBlur(16 * S))
img.paste((4, 30, 90), (0, 0), pin_shadow)

red = (255, 59, 48)
d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=red)
d.polygon([(cx - r * 0.86, cy + r * 0.5), (cx + r * 0.86, cy + r * 0.5), tip], fill=red)
ri = r * 0.42
d.ellipse((cx - ri, cy - ri, cx + ri, cy + ri), fill=(255, 255, 255))

img.resize((1024, 1024), Image.LANCZOS).save(out, optimize=True)
