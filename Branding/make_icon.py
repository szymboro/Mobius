# Draws the Aeternus app icon (1024x1024 PNG): a red Möbius strip around a play button, on black.
# Usage: python3 make_icon.py AppIcon.png [rotation in degrees, default -90]
import math, sys
ROTZ = float(sys.argv[2]) if len(sys.argv) > 2 else -90
from PIL import Image, ImageDraw, ImageFilter

out = sys.argv[1]
S = 2048
cx, cy = S / 2, S / 2
img = Image.new("RGB", (S, S), (0, 0, 0))

# Dark-red glow.
g = ImageDraw.Draw(img)
for i in range(70, 0, -1):
    r = S * 0.47 * i / 70
    c = int(78 * (1 - i / 70) ** 1.7)
    g.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(c, 0, int(c * 0.08)))

# Möbius strip: the band turns half a revolution as it goes once around.
R, Wd = 1.0, 0.30            # radius, half-width
NU, NV = 720, 14
tiltX = math.radians(58)     # look from above, so the loop is flattened
rotZ = math.radians(ROTZ)
scale = S * 0.40
light = (-0.35, -0.55, 0.76)
ln = math.sqrt(sum(c * c for c in light))
light = tuple(c / ln for c in light)

def point(u, v):
    x = (R + v * math.cos(u / 2)) * math.cos(u)
    y = (R + v * math.cos(u / 2)) * math.sin(u)
    z = v * math.sin(u / 2)
    # spin, then tilt toward the viewer
    x, y = x * math.cos(rotZ) - y * math.sin(rotZ), x * math.sin(rotZ) + y * math.cos(rotZ)
    y, z = y * math.cos(tiltX) - z * math.sin(tiltX), y * math.sin(tiltX) + z * math.cos(tiltX)
    return x, y, z   # z toward the viewer

# Fit the strip into the icon: centre its projected bounds and scale them to ~84% of the width.
_pts = [point(2 * math.pi * i / 360, v) for i in range(360) for v in (-Wd, Wd)]
_minx, _maxx = min(q[0] for q in _pts), max(q[0] for q in _pts)
_miny, _maxy = min(q[1] for q in _pts), max(q[1] for q in _pts)
scale = S * 0.84 / max(_maxx - _minx, (_maxy - _miny) * 1.15)
_ox, _oy = (_minx + _maxx) / 2, (_miny + _maxy) / 2

def project(p):
    return (cx + (p[0] - _ox) * scale, cy + (p[1] - _oy) * scale)

quads = []
for i in range(NU):
    u0, u1 = 2 * math.pi * i / NU, 2 * math.pi * (i + 1) / NU
    for j in range(NV):
        v0, v1 = -Wd + 2 * Wd * j / NV, -Wd + 2 * Wd * (j + 1) / NV
        p = [point(u0, v0), point(u1, v0), point(u1, v1), point(u0, v1)]
        a = [p[1][k] - p[0][k] for k in range(3)]
        b = [p[3][k] - p[0][k] for k in range(3)]
        n = (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
        nl = math.sqrt(sum(c * c for c in n)) or 1
        n = tuple(c / nl for c in n)
        facing = n[2] >= 0           # which side of the band we see
        if not facing:
            n = tuple(-c for c in n)
        diffuse = max(0.0, sum(n[k] * light[k] for k in range(3)))
        spec = max(0.0, n[2] * 0.6 + diffuse * 0.4) ** 24
        base = (232, 26, 40)
        shade = 0.40 + 0.70 * diffuse
        # Darker rims along both edges of the band keep its shape readable through the twist.
        if j == 0 or j == NV - 1:
            shade *= 0.55
        col = tuple(min(255, int(base[k] * shade + 255 * 0.55 * spec)) for k in range(3))
        depth = sum(q[2] for q in p) / 4
        quads.append((depth, [project(q) for q in p], col))

quads.sort(key=lambda q: q[0])  # far to near
d = ImageDraw.Draw(img)

# Play triangle sits in the middle: draw the strip behind it, then the triangle, then the front.
tri = Image.new("L", (S, S), 0)
td = ImageDraw.Draw(tri)
# Centred on the loop's hole (the projected centre of the strip), sized to fit inside it.
hx, hy = project((0.0, 0.0, 0.0))
h = S * 0.20
left = hx - h * 0.36
td.polygon([(left, hy - h / 2), (left, hy + h / 2), (left + h * 0.88, hy)], fill=255)
tri = tri.filter(ImageFilter.GaussianBlur(S * 0.012)).point(lambda v: 255 if v > 128 else 0)
grad = Image.new("RGB", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(0, S, 4):
    t = y / S
    gd.rectangle([0, y, S, y + 4], fill=(int(255 - 60 * t), int(240 - 70 * t), int(240 - 70 * t)))

drawn_triangle = False
for depth, poly, col in quads:
    if not drawn_triangle and depth > 0:
        # A soft shadow, then the triangle (light, so it stands out from the red band).
        shadow = tri.filter(ImageFilter.GaussianBlur(S * 0.02))
        img.paste((0, 0, 0), (0, 0), shadow.point(lambda v: int(v * 0.8)))
        img.paste(grad, (0, 0), tri)
        d = ImageDraw.Draw(img)
        drawn_triangle = True
    d.polygon(poly, fill=col, outline=col)
if not drawn_triangle:
    img.paste(grad, (0, 0), tri)

img.resize((1024, 1024), Image.LANCZOS).save(out)
