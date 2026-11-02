# Draws the TamaiOS app icon: a Tamagotchi ON-style egg (tall egg, big colour
# screen in a thick frame, three buttons in a smile underneath), centred exactly.
# Usage: icon.py OUT.png [size]
import sys, math
from PIL import Image, ImageDraw, ImageFilter, ImageChops

OUT = sys.argv[1]
SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
SS = 4
S = SIZE * SS

INK = (58, 36, 78)
SHELL_T, SHELL_B = (255, 214, 232), (247, 132, 182)
FRAME_T, FRAME_B = (180, 228, 255), (110, 170, 250)
BTN_T, BTN_B = (255, 246, 190), (250, 205, 90)
BG_T, BG_B = (255, 241, 247), (233, 218, 255)

def lerp(a, b, t): return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))

def vgrad(c0, c1, y0, y1):
    im = Image.new("RGB", (S, S)); d = ImageDraw.Draw(im)
    for y in range(S):
        d.line([(0, y), (S, y)], fill=lerp(c0, c1, max(0.0, min(1.0, (y - y0) / max(1, y1 - y0)))))
    return im

def bez(p0, p1, p2, p3, n=120):
    for i in range(n + 1):
        t = i / n; u = 1 - t
        yield (u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0],
               u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1])

def egg(cx, cy, w, h):
    """Symmetric egg, a bit narrower at the top, centred on its bounding box."""
    x, y = cx - w / 2, cy - h / 2
    pts = []
    pts += bez((cx, y), (x + w*0.86, y), (x + w, y + h*0.25), (x + w, y + h*0.58))
    pts += bez((x + w, y + h*0.58), (x + w, y + h*0.86), (x + w*0.82, y + h), (cx, y + h))
    pts += bez((cx, y + h), (x + w*0.18, y + h), (x, y + h*0.86), (x, y + h*0.58))
    pts += bez((x, y + h*0.58), (x, y + h*0.25), (x + w*0.14, y), (cx, y))
    return pts

def mask(draw_fn):
    m = Image.new("L", (S, S), 0); draw_fn(ImageDraw.Draw(m)); return m

img = vgrad(BG_T, BG_B, 0, S)
d = ImageDraw.Draw(img)
C = S / 2

# Egg geometry: centred on the canvas (shadow excluded so the egg itself is centred).
H = S * 0.82; W = H / 1.24
lw = W * 0.022
top = C - H / 2

# soft drop shadow
sh = mask(lambda g: g.polygon(egg(C, C + H*0.025, W, H), fill=110))
img.paste((120, 70, 120), (0, 0), sh.filter(ImageFilter.GaussianBlur(W * 0.04)))

# shell: gradient, darker rim lower right, outline
shell = egg(C, C, W, H)
img.paste(vgrad(SHELL_T, SHELL_B, top, top + H), (0, 0), mask(lambda g: g.polygon(shell, fill=255)))
inner = mask(lambda g: g.polygon(egg(C - W*0.03, C - H*0.03, W*0.94, H*0.94), fill=255))
outer = mask(lambda g: g.polygon(shell, fill=255))
rim = ImageChops.subtract(outer, inner).filter(ImageFilter.GaussianBlur(W * 0.012))
img.paste(lerp(SHELL_B, INK, 0.25), (0, 0), ImageChops.multiply(rim, outer))
d = ImageDraw.Draw(img)
d.line(shell + [shell[0]], fill=INK, width=int(lw), joint="curve")

# shine along the upper-left edge (same as the app: inset egg, 86%..92.5% of its outline)
def trim(pts, a, b):
    L = [0.0]
    for i in range(1, len(pts)): L.append(L[-1] + math.dist(pts[i-1], pts[i]))
    T = L[-1]; return [p for p, l in zip(pts, L) if a*T <= l <= b*T]
gl = Image.new("L", (S, S), 0); gd = ImageDraw.Draw(gl)
arc = trim(egg(C, C, W*0.93, H*0.93), 0.86, 0.925)
gd.line(arc, fill=190, width=int(W*0.03), joint="curve")
for q in (arc[0], arc[-1]):
    gd.ellipse([q[0] - W*0.015, q[1] - W*0.015, q[0] + W*0.015, q[1] + W*0.015], fill=190)
img.paste((255, 255, 255), (0, 0), gl.filter(ImageFilter.GaussianBlur(W * 0.002)))
d = ImageDraw.Draw(img)

# screen frame: the ON's big, thick, coloured surround
sy = top + H * 0.41                       # screen centre
F = W * 0.72                              # frame outer size
fr = [C - F/2, sy - F/2, C + F/2, sy + F/2]
d.rounded_rectangle([fr[0], fr[1] + lw*0.9, fr[2], fr[3] + lw*0.9], radius=F*0.30, fill=lerp(FRAME_B, INK, 0.45))
img.paste(vgrad(FRAME_T, FRAME_B, fr[1], fr[3]), (0, 0), mask(lambda g: g.rounded_rectangle(fr, radius=F*0.30, fill=255)))
d = ImageDraw.Draw(img)
d.rounded_rectangle(fr, radius=F*0.30, outline=INK, width=int(lw))
# tiny star on the frame, centred between its top edge and the screen
def star(cx, cy, R, fill):
    pts = []
    for i in range(10):
        ang = -math.pi/2 + i*math.pi/5; rr = R if i % 2 == 0 else R*0.48
        pts.append((cx + math.cos(ang)*rr, cy + R*0.08 + math.sin(ang)*rr))
    d.polygon(pts, fill=fill); d.line(pts + [pts[0]], fill=INK, width=max(2, int(lw*0.5)), joint="curve")

# LCD
L = F * 0.70
star(C, fr[1] + (F - L) / 4, W * 0.028, (255, 255, 255))
lcd = [C - L/2, sy - L/2, C + L/2, sy + L/2]
d.rounded_rectangle([lcd[0] - lw*0.6, lcd[1] - lw*0.6, lcd[2] + lw*0.6, lcd[3] + lw*0.6], radius=L*0.10, fill=INK)
scene = Image.new("RGB", (16, 16))
sd = ImageDraw.Draw(scene)
for yy in range(16):
    sd.line([(0, yy), (15, yy)], fill=lerp((150, 214, 255), (215, 240, 255), yy / 10) if yy < 11 else ((150, 214, 110) if yy % 2 else (132, 200, 96)))
for x, y in [(2, 2), (3, 2), (4, 2), (3, 1), (11, 3), (12, 3), (13, 3), (12, 2)]:   # clouds
    sd.point((x, y), fill=(255, 255, 255))
pet = ["....XXXXXX....",
       "..XXWWWWWWXX..",
       ".XWWWWWWWWWWX.",
       "XWWWKWWWWKWWWX",
       "XWWWKWWWWKWWWX",
       "XWPPWWWWWWPPWX",
       "XWWWWWKKWWWWWX",
       ".XWWWWWWWWWWX.",
       "..XXWXXXXWXX..",
       "....X....X...."]
cols = {"X": (70, 44, 96), "W": (255, 250, 245), "K": (70, 44, 96), "P": (255, 140, 175)}
for r, row in enumerate(pet):
    for c, ch in enumerate(row):
        if ch in cols: sd.point((c + 1, r + 5), fill=cols[ch])
lcd_img = scene.resize((int(L), int(L)), Image.NEAREST)
lm = Image.new("L", lcd_img.size, 0); ImageDraw.Draw(lm).rounded_rectangle([0, 0, lcd_img.size[0]-1, lcd_img.size[1]-1], radius=L*0.09, fill=255)
img.paste(lcd_img, (int(lcd[0]), int(lcd[1])), lm)
d = ImageDraw.Draw(img)
# screen glare
gl2 = mask(lambda g: g.polygon([(lcd[0], lcd[1] + L*0.35), (lcd[0] + L*0.35, lcd[1]), (lcd[0] + L*0.55, lcd[1]), (lcd[0], lcd[1] + L*0.55)], fill=60))
img.paste((255, 255, 255), (0, 0), ImageChops.multiply(gl2, mask(lambda g: g.rounded_rectangle(lcd, radius=L*0.09, fill=255))))
d = ImageDraw.Draw(img)

# three buttons in a smile: A, B (lower), C
bd = W * 0.145
by = top + H * 0.81
for i, drop in ((-1, 0.0), (0, 0.30), (1, 0.0)):
    x = C + i * W * 0.24
    y = by + drop * bd * 0.55 - (0 if i == 0 else bd * 0.05)
    d.ellipse([x - bd/2, y - bd/2 + bd*0.10, x + bd/2, y + bd/2 + bd*0.10], fill=lerp(SHELL_B, INK, 0.55))
    bm = mask(lambda g: g.ellipse([x - bd/2, y - bd/2, x + bd/2, y + bd/2], fill=255))
    img.paste(vgrad(BTN_T, BTN_B, y - bd/2, y + bd/2), (0, 0), bm)
    d = ImageDraw.Draw(img)
    d.ellipse([x - bd/2, y - bd/2, x + bd/2, y + bd/2], outline=INK, width=int(lw))
    d.ellipse([x - bd*0.27, y - bd*0.30, x - bd*0.03, y - bd*0.10], fill=(255, 255, 245))

img = img.resize((SIZE, SIZE), Image.LANCZOS)
img.save(OUT)