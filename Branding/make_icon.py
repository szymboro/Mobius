# Draws the Aeternus app icon (1024x1024 PNG): python3 make_icon.py AppIcon.png
import math, sys
from PIL import Image, ImageDraw, ImageFilter

out = sys.argv[1]
S = 4096
cx, cy = S / 2, S / 2
img = Image.new("RGB", (S, S), (0, 0, 0))

# Dark-red glow behind everything.
glow = Image.new("RGB", (S, S), (0, 0, 0))
g = ImageDraw.Draw(glow)
for i in range(70, 0, -1):
    r = S * 0.46 * i / 70
    c = int(80 * (1 - i / 70) ** 1.7)
    g.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(c, 0, int(c * 0.08)))
img.paste(glow)

# Flattened ring (an orbit seen from slightly above), tilted.
A, B = S * 0.43, S * 0.155       # semi-axes
tilt = math.radians(-16)
W = S * 0.058                    # thickness at the front
N = 1800

def ring_point(t):
    x, y = A * math.cos(t), B * math.sin(t)
    return (cx + x * math.cos(tilt) - y * math.sin(tilt),
            cy + S * 0.02 + x * math.sin(tilt) + y * math.cos(tilt))

def depth(t):  # 0 at the back (top), 1 at the front (bottom)
    return (math.sin(t) + 1) / 2

def draw_ring(d, front, outline=False):
    for k in range(N):
        t = 2 * math.pi * k / N
        z = depth(t)
        if (z >= 0.5) != front:
            continue
        w = W * (0.45 + 0.55 * z)
        x, y = ring_point(t)
        if outline:
            w += S * 0.03
            col = (0, 0, 0)
        else:
            col = (int(110 + 125 * z), int(6 + 22 * z), int(14 + 26 * z))
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=col)

d = ImageDraw.Draw(img)
draw_ring(d, front=False)

# Play triangle with rounded corners and a red gradient.
tri = Image.new("L", (S, S), 0)
td = ImageDraw.Draw(tri)
h = S * 0.40
left = cx - h * 0.40
td.polygon([(left, cy - h / 2), (left, cy + h / 2), (left + h * 0.88, cy)], fill=255)
tri = tri.filter(ImageFilter.GaussianBlur(S * 0.014)).point(lambda v: 255 if v > 128 else 0)
grad = Image.new("RGB", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(0, S, 8):
    t = y / S
    gd.rectangle([0, y, S, y + 8], fill=(int(255 - 80 * t), int(60 - 46 * t), int(70 - 50 * t)))
img.paste(grad, (0, 0), tri)

# Front half of the ring passes in front of the triangle, with a black gap for depth.
# The black gap only where the ring crosses the triangle (elsewhere it notched the ring's ends).
gap = Image.new("L", (S, S), 0)
draw_ring_mask = ImageDraw.Draw(gap)
for k in range(N):
    t = 2 * math.pi * k / N
    z = depth(t)
    if z < 0.5:
        continue
    w = W * (0.45 + 0.55 * z) + S * 0.014
    x, y = ring_point(t)
    draw_ring_mask.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)
near_triangle = tri.filter(ImageFilter.GaussianBlur(S * 0.012)).point(lambda v: 255 if v > 8 else 0)
gap = Image.composite(gap, Image.new("L", (S, S), 0), near_triangle)
img.paste((0, 0, 0), (0, 0), gap)

front = Image.new("RGBA", (S, S), (0, 0, 0, 0))
fd = ImageDraw.Draw(front)
draw_ring(fd, front=True)
img.paste(front, (0, 0), front)

img.resize((1024, 1024), Image.LANCZOS).save(out)
