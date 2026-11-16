# Draws the app icon (1024x1024 PNG): a triangular Möbius strip whose hole forms a play button.
# Usage: python3 make_icon.py AppIcon.png [twist spread, default 0.06]
import math, sys
from PIL import Image, ImageDraw

out = sys.argv[1]
S = 2048
cx, cy = S / 2, S / 2
img = Image.new("RGB", (S, S), (0, 0, 0))

g = ImageDraw.Draw(img)
for i in range(70, 0, -1):
    r = S * 0.48 * i / 70
    c = int(60 * (1 - i / 70) ** 1.8)
    g.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(c, 0, int(c * 0.08)))

# Centre line: a triangle pointing right with rounded corners, in the screen plane.
Rv = S * 0.335                     # vertex radius
corner = S * 0.13                 # corner rounding
verts = [(cx + Rv * math.cos(a), cy + Rv * math.sin(a))
         for a in (math.radians(0), math.radians(120), math.radians(240))]
verts = [(x + S * 0.03, y) for x, y in verts]   # optical centring (play buttons sit left-heavy)

def sub(a, b): return (a[0] - b[0], a[1] - b[1])
def add(a, b): return (a[0] + b[0], a[1] + b[1])
def mul(a, k): return (a[0] * k, a[1] * k)
def norm(a):
    l = math.hypot(*a); return (a[0] / l, a[1] / l)

# Build the rounded triangle as a dense list of (point, tangent, side index, t-in-corner).
path = []
n = len(verts)
for i in range(n):
    p0, p1, p2 = verts[i - 1], verts[i], verts[(i + 1) % n]
    d_in, d_out = norm(sub(p1, p0)), norm(sub(p2, p1))
    half = math.acos(max(-1, min(1, -(d_in[0] * d_out[0] + d_in[1] * d_out[1])))) / 2
    cut = corner / math.tan(half)
    a, b = sub(p1, mul(d_in, cut)), add(p1, mul(d_out, cut))
    # corner arc (quadratic Bézier approximates it well enough here)
    for k in range(120):
        t = k / 120
        q = add(add(mul(a, (1 - t) ** 2), mul(p1, 2 * (1 - t) * t)), mul(b, t * t))
        tan = norm(add(mul(sub(p1, a), 2 * (1 - t)), mul(sub(b, p1), 2 * t)))
        path.append((q, tan, i, t))
    # straight side to the next corner
    nxt = verts[(i + 1) % n]
    d2 = norm(sub(verts[(i + 2) % n], nxt))
    h2 = math.acos(max(-1, min(1, -(d_out[0] * d2[0] + d_out[1] * d2[1])))) / 2
    end = sub(nxt, mul(d_out, corner / math.tan(h2)))
    for k in range(240):
        t = k / 240
        path.append((add(mul(b, 1 - t), mul(end, t)), d_out, i, -t))

# Band direction: rotates about the centre line by half a turn in total (Möbius), kept constant
# along the sides and turned in the corners, with most of it in one corner (the fold).
# Every corner is a half-twist fold (three in total – still a Möbius strip, any odd number is),
# so each side faces the viewer; small per-side tilts give each side its own shade.
tilts = [math.radians(a) for a in (18, -14, 6)]
steps = [tilts[2] - 3 * math.pi, tilts[0] - 2 * math.pi, tilts[1] - math.pi, tilts[2]]
def smooth(t): return t * t * (3 - 2 * t)
W = S * 0.20
SPREAD_FRAC = float(sys.argv[2]) if len(sys.argv) > 2 else 0.06
theta0 = 0.0

# Each twist is centred on its corner and spread over the corner plus part of both sides.
# Start the loop mid-way along the last side, so no twist straddles the start.
N = len(path)
start = N - 120
path = path[start:] + path[:start]
centres = [k for k, (q, tan, i, t) in enumerate(path) if t is not None and t >= 0 and abs(t - 0.5) < 1e-9]
SPREAD = int(N * SPREAD_FRAC)
def theta_at(k):
    th = steps[0]
    for c, (a, b) in zip(centres, zip(steps, steps[1:])):
        dk = k - c                                   # signed distance along the loop
        x = min(1.0, max(0.0, (dk + SPREAD) / (2 * SPREAD)))
        th += (b - a) * smooth(x)
    return th
pts = []
for k, (q, tan, i, t) in enumerate(path):
    th = theta0 + theta_at(k)
    nrm = (tan[1], -tan[0])                       # in-plane normal (pointing outward here)
    off = (math.cos(th), math.sin(th))            # (in-plane, toward viewer)
    along = math.sin(math.pi * -t) if t < 0 else 0.0   # 0 at corners, 1 mid-side
    pts.append((q, tan, nrm, off, along))

light = (-0.45, -0.55, 0.70)
ll = math.sqrt(sum(c * c for c in light)); light = tuple(c / ll for c in light)
quads = []
for k in range(len(pts)):
    (q0, t0, n0, o0, al), (q1, t1, n1, o1, _) = pts[k], pts[(k + 1) % len(pts)]
    def edge(q, nrm, off, s):
        return (q[0] + nrm[0] * off[0] * s * W / 2, q[1] + nrm[1] * off[0] * s * W / 2, off[1] * s * W / 2)
    A, B = edge(q0, n0, o0, -1), edge(q1, n1, o1, -1)
    C, D = edge(q1, n1, o1, 1), edge(q0, n0, o0, 1)
    # surface normal = tangent x width direction
    wdir = (n0[0] * o0[0], n0[1] * o0[0], o0[1])
    tv = (t0[0], t0[1], 0.0)
    nn = (tv[1] * wdir[2] - tv[2] * wdir[1], tv[2] * wdir[0] - tv[0] * wdir[2], tv[0] * wdir[1] - tv[1] * wdir[0])
    l = math.sqrt(sum(c * c for c in nn)) or 1
    nn = tuple(c / l for c in nn)
    if nn[2] < 0: nn = tuple(-c for c in nn)
    diff = max(0.0, sum(nn[j] * light[j] for j in range(3)))
    spec = max(0.0, nn[2] * 0.5 + diff * 0.5) ** 30
    # deep red in shadow to bright red in light, a touch of highlight
    sh = (0.22 + 0.9 * diff) * (0.72 + 0.28 * al)
    col = (min(255, int(235 * sh + 120 * spec)), min(255, int(26 * sh + 60 * spec)), min(255, int(40 * sh + 60 * spec)))
    depth = (A[2] + B[2] + C[2] + D[2]) / 4
    quads.append((depth, [A[:2], B[:2], C[:2], D[:2]], col))

# Centre the strip's bounds on the canvas.
xs = [x for _, poly, _ in quads for x, _ in poly]
ys = [y for _, poly, _ in quads for _, y in poly]
dx, dy = cx - (min(xs) + max(xs)) / 2, cy - (min(ys) + max(ys)) / 2
quads.sort(key=lambda x: x[0])
d = ImageDraw.Draw(img)
for _, poly, col in quads:
    poly = [(x + dx, y + dy) for x, y in poly]
    d.polygon(poly, fill=col, outline=col, width=3)

img.resize((1024, 1024), Image.LANCZOS).save(out)
