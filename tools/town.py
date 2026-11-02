# Draws TamaiOS's own Tamatown background (an original illustration):
# Tama Party chapel on the left, an unnamed tower in the middle, the Arcade
# on the right, a sunny plaza in front for Tamas to walk on.
# Usage: town.py OUT.png [width]
import sys, math, random
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = sys.argv[1]
WOUT = int(sys.argv[2]) if len(sys.argv) > 2 else 1920
HOUT = WOUT * 5 // 7          # 1.4 : 1, fits the town card in the app
SS = 2
W, H = WOUT * SS, HOUT * SS
U = W / 1920.0            # design units: 1920 wide
INK = (74, 44, 92)
LW = int(5 * U)
random.seed(7)

def u(v): return v * U

def font(size, bold=True):
    cands = ["/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
             "/Library/Fonts/Arial Rounded Bold.ttf",
             "/usr/share/fonts/truetype/google-fonts/Poppins-ExtraBold.ttf",
             "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf",
             "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]
    for c in cands:
        try: return ImageFont.truetype(c, int(size))
        except Exception: pass
    return ImageFont.load_default()

def lerp(a, b, t): return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))
def shade(c, k): return lerp(c, (0, 0, 0), k)
def tint(c, k): return lerp(c, (255, 255, 255), k)

img = Image.new("RGB", (W, H))
d = ImageDraw.Draw(img)

def vgrad(box, c0, c1, mask=None):
    x0, y0, x1, y1 = [int(v) for v in box]
    g = Image.new("RGB", (max(1, x1 - x0), max(1, y1 - y0)))
    gd = ImageDraw.Draw(g)
    for y in range(y1 - y0):
        gd.line([(0, y), (x1 - x0, y)], fill=lerp(c0, c1, y / max(1, y1 - y0 - 1)))
    if mask is None:
        img.paste(g, (x0, y0))
    else:
        img.paste(g, (x0, y0), mask.crop((x0, y0, x1, y1)))

def mask_of(fn):
    m = Image.new("L", (W, H), 0); fn(ImageDraw.Draw(m)); return m

def shadow(fn, off=(0, 10), blur=14, alpha=70):
    m = mask_of(fn).point(lambda v: v * alpha // 255)
    m = m.filter(ImageFilter.GaussianBlur(u(blur)))
    sh = Image.new("RGB", (W, H), (60, 30, 80))
    img.paste(sh, (int(u(off[0])), int(u(off[1]))), m)

def rrect(box, r, fill, outline=INK, width=None, top=None):
    """Rounded rect with optional vertical gradient (fill -> top)."""
    width = LW if width is None else width
    if top:
        vgrad(box, top, fill, mask_of(lambda g: g.rounded_rectangle(box, radius=r, fill=255)))
    else:
        d.rounded_rectangle(box, radius=r, fill=fill)
    if outline: d.rounded_rectangle(box, radius=r, outline=outline, width=width)

def poly(pts, fill, outline=INK, width=None):
    d.polygon(pts, fill=fill)
    if outline: d.line(pts + [pts[0]], fill=outline, width=LW if width is None else width, joint="curve")

def ell(box, fill, outline=INK, width=None):
    d.ellipse(box, fill=fill)
    if outline: d.ellipse(box, outline=outline, width=LW if width is None else width)

def heart(cx, cy, s, fill, outline=INK):
    pts = [(cx + s * 16 * math.sin(t) ** 3 / 16, cy - s * (13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)) / 16)
           for t in [i / 80 * 2 * math.pi for i in range(81)]]
    poly(pts, fill, outline, max(2, LW - 1))

def star(cx, cy, r, fill, outline=INK, k=0.45):
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        rr = r if i % 2 == 0 else r * k
        pts.append((cx + math.cos(a) * rr, cy + math.sin(a) * rr))
    poly(pts, fill, outline, max(2, LW - 1))

def sparkle(cx, cy, r, fill=(255, 255, 255)):
    pts = []
    for i in range(8):
        a = -math.pi / 2 + i * math.pi / 4
        rr = r if i % 2 == 0 else r * 0.22
        pts.append((cx + math.cos(a) * rr, cy + math.sin(a) * rr))
    d.polygon(pts, fill=fill)

def text(cx, cy, s, size, fill, outline=INK, stroke=None):
    f = font(size)
    stroke = int(u(6)) if stroke is None else stroke
    d.text((cx, cy), s, font=f, fill=fill, anchor="mm", stroke_width=stroke, stroke_fill=outline)

# ---------------------------------------------------------------- sky
HORIZON = u(820)
vgrad((0, 0, W, HORIZON), (120, 196, 255), (214, 238, 255))
vgrad((0, HORIZON - u(160), W, HORIZON), (214, 238, 255), (255, 240, 248))

def cloud(cx, cy, s):
    blobs = [(-0.9, 0.15, 0.55), (-0.35, -0.25, 0.75), (0.35, -0.3, 0.7), (0.9, 0.1, 0.55), (0, 0.2, 0.7)]
    sh = mask_of(lambda g: [g.ellipse((cx + bx * s - r * s, cy + by * s - r * s + u(8), cx + bx * s + r * s, cy + by * s + r * s + u(8)), fill=255) for bx, by, r in blobs])
    img.paste((198, 222, 248), (0, 0), sh)
    for bx, by, r in blobs:
        d.ellipse((cx + bx * s - r * s, cy + by * s - r * s, cx + bx * s + r * s, cy + by * s + r * s), fill=(255, 255, 255))
    d.ellipse((cx - s * 0.6, cy - s * 0.5, cx - s * 0.1, cy - s * 0.25), fill=(255, 255, 255))

for cx, cy, s in [(250, 160, 85), (760, 100, 60), (1180, 190, 70), (1640, 130, 90), (1450, 330, 45), (520, 320, 40), (90, 420, 40), (1850, 430, 38)]:
    cloud(u(cx), u(cy), u(s))
for cx, cy, r in [(400, 70, 18), (980, 240, 14), (1320, 60, 20), (1820, 260, 13), (120, 330, 12), (640, 200, 10)]:
    sparkle(u(cx), u(cy), u(r))

# far hills and a little town in the distance
def hills(y, color, amp, seed):
    random.seed(seed)
    pts = [(0, H)]
    for i in range(0, 21):
        x = W * i / 20
        pts.append((x, y - amp * (0.6 + 0.4 * math.sin(i * 1.3 + seed)) - random.random() * amp * 0.3))
    pts.append((W, H))
    d.polygon(pts, fill=color)
hills(HORIZON - u(30), (176, 222, 214), u(70), 2)
for i in range(16):
    x = u(60 + i * 120 + (i % 3) * 20); bw = u(40 + (i % 4) * 8); bh = u(40 + (i * 37) % 50)
    col = [(250, 214, 226), (220, 214, 250), (255, 236, 200), (210, 236, 250)][i % 4]
    by = HORIZON - u(20)
    d.rectangle((x, by - bh, x + bw, by), fill=col)
    d.polygon([(x - u(6), by - bh), (x + bw / 2, by - bh - u(26)), (x + bw + u(6), by - bh)], fill=tint((200, 120, 150), 0.3) if i % 2 else tint((120, 140, 210), 0.3))
hills(HORIZON + u(10), (150, 214, 150), u(45), 5)

# tree line
def tree(cx, by, s, c=(104, 190, 110)):
    d.rectangle((cx - s * 0.12, by - s * 0.5, cx + s * 0.12, by), fill=(150, 104, 80))
    for dx, dy, r in [(-0.45, -0.75, 0.5), (0.45, -0.75, 0.5), (0, -1.15, 0.6), (0, -0.7, 0.55)]:
        d.ellipse((cx + dx * s - r * s, by + dy * s - r * s, cx + dx * s + r * s, by + dy * s + r * s), fill=c)
    d.ellipse((cx - s * 0.3, by - s * 1.55, cx + s * 0.05, by - s * 1.3), fill=tint(c, 0.35))
for i in range(22):
    tree(u(20 + i * 90 + (i % 2) * 30), HORIZON + u(30), u(46 + (i * 13) % 18), [(98, 186, 108), (86, 170, 100), (112, 198, 120)][i % 3])

# ---------------------------------------------------------------- plaza
GROUND = HORIZON + u(30)
vgrad((0, GROUND, W, H), (255, 237, 208), (247, 220, 185))
# perspective paving
vx, vy = W / 2, GROUND - u(260)
for i in range(-14, 15):
    x = W / 2 + i * u(150)
    d.line([(vx + (x - vx) * (GROUND - vy) / (H - vy) * 1.0, GROUND), (x, H)], fill=(234, 208, 174), width=max(1, int(u(2))))
y = GROUND
k = 0
while y < H:
    d.line([(0, y), (W, y)], fill=(234, 208, 174), width=max(1, int(u(2))))
    k += 1
    y += u(14 + k * 9)
# path glow in the middle
glow = mask_of(lambda g: g.ellipse((W / 2 - u(520), GROUND + u(120), W / 2 + u(520), H + u(200)), fill=90)).filter(ImageFilter.GaussianBlur(u(60)))
img.paste((255, 246, 222), (0, 0), glow)

# grass corners with flowers
for side in (-1, 1):
    cx = W / 2 + side * u(1080)
    d.ellipse((cx - u(420), H - u(170), cx + u(420), H + u(260)), fill=(132, 206, 120))
    d.ellipse((cx - u(380), H - u(150), cx + u(380), H + u(230)), fill=(148, 218, 132))
    for j in range(9):
        fx = cx + side * -u(60 + j * 38) + u(random.randint(-10, 10)); fy = H - u(60 + (j % 3) * 30)
        col = [(255, 150, 190), (255, 230, 120), (255, 255, 255), (190, 160, 255)][j % 4]
        for a in range(5):
            ang = a * 2 * math.pi / 5
            d.ellipse((fx + math.cos(ang) * u(8) - u(7), fy + math.sin(ang) * u(8) - u(7), fx + math.cos(ang) * u(8) + u(7), fy + math.sin(ang) * u(8) + u(7)), fill=col)
        d.ellipse((fx - u(5), fy - u(5), fx + u(5), fy + u(5)), fill=(255, 200, 80))

# white picket fence along the back of the plaza
fy = GROUND + u(20)
d.rectangle((0, fy - u(26), W, fy - u(18)), fill=(255, 255, 255))
d.rectangle((0, fy - u(8), W, fy), fill=(255, 255, 255))
for i in range(0, 64):
    x = u(i * 31)
    d.polygon([(x, fy + u(4)), (x, fy - u(36)), (x + u(9), fy - u(46)), (x + u(18), fy - u(36)), (x + u(18), fy + u(4))], fill=(255, 255, 255), outline=(214, 200, 220))

# ---------------------------------------------------------------- Tama ♥ Party (left)
def party(cx, base):
    pink, pink_top = (255, 168, 204), (255, 214, 232)
    w, h = u(440), u(330)
    shadow(lambda g: g.rounded_rectangle((cx - w / 2, base - h, cx + w / 2, base), radius=u(40), fill=255), off=(14, 14))
    rrect((cx - w / 2, base - h, cx + w / 2, base), u(40), pink, top=pink_top)
    # scalloped white roof trim
    for i in range(9):
        x = cx - w / 2 + u(12) + i * (w - u(24)) / 8
        ell((x - u(30), base - h - u(24), x + u(30), base - h + u(30)), (255, 255, 255), width=int(u(4)))
    d.rectangle((cx - w / 2 + u(6), base - h + u(4), cx + w / 2 - u(6), base - h + u(30)), fill=(255, 255, 255))
    # tower with a bell
    tw = u(150)
    rrect((cx - tw / 2, base - h - u(200), cx + tw / 2, base - h + u(10)), u(24), (255, 190, 220), top=(255, 230, 240))
    poly([(cx - tw / 2 - u(26), base - h - u(195)), (cx, base - h - u(330)), (cx + tw / 2 + u(26), base - h - u(195))], (240, 110, 160))
    d.polygon([(cx - u(30), base - h - u(250)), (cx, base - h - u(318)), (cx + u(4), base - h - u(250))], fill=(255, 160, 196))
    ell((cx - u(46), base - h - u(170), cx + u(46), base - h - u(78)), (255, 246, 210))
    poly([(cx - u(28), base - h - u(100)), (cx - u(20), base - h - u(150)), (cx, base - h - u(160)), (cx + u(20), base - h - u(150)), (cx + u(28), base - h - u(100))], (255, 210, 90))
    heart(cx, base - h - u(345), u(26), (255, 90, 140))
    # big arched door with a heart window
    dw, dh = u(150), u(190)
    d.rounded_rectangle((cx - dw / 2, base - dh, cx + dw / 2, base + u(20)), radius=dw / 2, fill=(255, 240, 246), outline=INK, width=LW)
    d.rounded_rectangle((cx - dw / 2 + u(16), base - dh + u(16), cx + dw / 2 - u(16), base), radius=dw / 2, fill=(236, 120, 170))
    d.line([(cx, base - dh + u(70)), (cx, base)], fill=INK, width=int(u(4)))
    heart(cx, base - dh + u(52), u(30), (255, 255, 255))
    # side windows
    for sgn in (-1, 1):
        x = cx + sgn * u(150)
        ell((x - u(42), base - u(170), x + u(42), base - u(86)), (200, 236, 255))
        heart(x, base - u(130), u(22), (255, 120, 170))
    # bunting
    for row, yy in enumerate([base - h + u(60)]):
        pts = [(cx - w / 2 + i * w / 10, yy + math.sin(i / 10 * math.pi) * u(30)) for i in range(11)]
        d.line(pts, fill=INK, width=int(u(3)))
        for i in range(10):
            (x0, y0), (x1, y1) = pts[i], pts[i + 1]
            mx = (x0 + x1) / 2
            d.polygon([(x0 + u(4), y0), (x1 - u(4), y1), (mx, (y0 + y1) / 2 + u(34))], fill=[(255, 120, 170), (255, 220, 110), (130, 200, 255), (190, 150, 255)][i % 4])
    # balloons
    for i, (bx, by, col) in enumerate([(-260, -470, (255, 90, 120)), (-205, -540, (255, 210, 90)), (-150, -480, (120, 190, 255)), (-205, -420, (255, 150, 210))]):
        x, y = cx + u(bx), base + u(by)
        d.line([(x, y + u(40)), (cx - u(200), base - u(250))], fill=(120, 100, 140), width=int(u(3)))
        ell((x - u(34), y - u(42), x + u(34), y + u(42)), col)
        d.ellipse((x - u(18), y - u(28), x - u(4), y - u(10)), fill=tint(col, 0.6))
    # name plaque over the door: "Tama ♥ Party" (the heart is drawn, fonts lack it)
    pw = u(330); py = base - h + u(118)
    shadow(lambda g: g.rounded_rectangle((cx - pw / 2, py - u(40), cx + pw / 2, py + u(40)), radius=u(40), fill=255), off=(6, 6), blur=6)
    rrect((cx - pw / 2, py - u(40), cx + pw / 2, py + u(40)), u(40), (255, 255, 255), top=(255, 255, 255))
    f = font(u(44))
    a, b = "Tama", "Party"
    wa, wb, gap = d.textlength(a, font=f), d.textlength(b, font=f), u(52)
    x0 = cx - (wa + wb + gap) / 2
    d.text((x0 + wa / 2, py + u(2)), a, font=f, fill=(236, 90, 150), anchor="mm")
    heart(x0 + wa + gap / 2, py, u(20), (255, 90, 140), outline=None)
    d.text((x0 + wa + gap + wb / 2, py + u(2)), b, font=f, fill=(236, 90, 150), anchor="mm")

# ---------------------------------------------------------------- Arcade (right)
def arcade(cx, base):
    w, h = u(460), u(340)
    shadow(lambda g: g.rounded_rectangle((cx - w / 2, base - h, cx + w / 2, base), radius=u(30), fill=255), off=(14, 14))
    rrect((cx - w / 2, base - h, cx + w / 2, base), u(30), (176, 150, 255), top=(214, 200, 255))
    # checkered base stripe
    for i in range(12):
        x0 = cx - w / 2 + i * w / 12
        d.rectangle((x0, base - u(40), x0 + w / 12, base - u(4)), fill=(255, 255, 255) if i % 2 else (120, 90, 210))
    d.line([(cx - w / 2, base - u(40)), (cx + w / 2, base - u(40))], fill=INK, width=int(u(4)))
    # big marquee arch with bulbs
    mw, mh = u(520), u(190)
    top = base - h - u(120)
    shadow(lambda g: g.rounded_rectangle((cx - mw / 2, top, cx + mw / 2, top + mh), radius=mh / 2, fill=255), off=(8, 8), blur=8)
    rrect((cx - mw / 2, top, cx + mw / 2, top + mh), mh / 2, (255, 120, 170), top=(255, 170, 205))
    rrect((cx - mw / 2 + u(26), top + u(26), cx + mw / 2 - u(26), top + mh - u(26)), (mh - u(52)) / 2, (88, 60, 160), width=int(u(4)))
    for i in range(22):
        t = i / 22
        # bulbs around the marquee
        per = 2 * (mw - mh) + math.pi * mh
        s = t * per
        if s < mw - mh:
            x, y = cx - (mw - mh) / 2 + s, top + u(12)
        elif s < mw - mh + math.pi * mh / 2:
            a = (s - (mw - mh)) / (mh / 2) - math.pi / 2
            x, y = cx + (mw - mh) / 2 + math.cos(a) * (mh / 2 - u(12)), top + mh / 2 + math.sin(a) * (mh / 2 - u(12))
        elif s < 2 * (mw - mh) + math.pi * mh / 2:
            x, y = cx + (mw - mh) / 2 - (s - (mw - mh) - math.pi * mh / 2), top + mh - u(12)
        else:
            a = (s - 2 * (mw - mh) - math.pi * mh / 2) / (mh / 2) + math.pi / 2
            x, y = cx - (mw - mh) / 2 + math.cos(a) * (mh / 2 - u(12)), top + mh / 2 + math.sin(a) * (mh / 2 - u(12))
        col = (255, 245, 170) if i % 2 == 0 else (255, 255, 255)
        d.ellipse((x - u(8), y - u(8), x + u(8), y + u(8)), fill=col, outline=INK, width=int(u(2)))
    # rainbow letters
    f = font(u(84))
    letters = "ARCADE"
    cols = [(255, 110, 120), (255, 170, 80), (255, 225, 90), (110, 220, 140), (110, 180, 255), (190, 140, 255)]
    total = sum(d.textlength(c, font=f) for c in letters) + u(6) * (len(letters) - 1)
    x = cx - total / 2
    for c, col in zip(letters, cols):
        cw = d.textlength(c, font=f)
        d.text((x + cw / 2, top + mh / 2 + u(4)), c, font=f, fill=col, anchor="mm", stroke_width=int(u(7)), stroke_fill=(255, 255, 255))
        x += cw + u(6)
    star(cx - mw / 2 + u(10), top + u(10), u(40), (255, 220, 90))
    star(cx + mw / 2 - u(4), top + mh - u(10), u(30), (255, 160, 210))
    # doorway with a claw machine inside
    dw = u(170)
    d.rounded_rectangle((cx - dw / 2, base - u(210), cx + dw / 2, base - u(40)), radius=u(30), fill=(70, 46, 120), outline=INK, width=LW)
    rrect((cx - u(55), base - u(190), cx + u(55), base - u(44)), u(10), (255, 200, 230), width=int(u(4)))
    rrect((cx - u(42), base - u(178), cx + u(42), base - u(110)), u(6), (210, 240, 255), width=int(u(3)))
    d.line([(cx, base - u(178)), (cx, base - u(145))], fill=INK, width=int(u(3)))
    d.arc((cx - u(14), base - u(150), cx + u(14), base - u(126)), 0, 180, fill=INK, width=int(u(4)))
    for i, col in enumerate([(255, 140, 170), (255, 220, 110), (140, 200, 255)]):
        ell((cx - u(34) + i * u(24), base - u(132), cx - u(14) + i * u(24), base - u(112)), col, width=int(u(2)))
    # side screens like game cabinets
    for sgn in (-1, 1):
        x = cx + sgn * u(155)
        rrect((x - u(60), base - u(250), x + u(60), base - u(60)), u(16), (255, 214, 120), top=(255, 236, 170), width=int(u(4)))
        rrect((x - u(44), base - u(234), x + u(44), base - u(160)), u(10), (60, 50, 110), width=int(u(3)))
        # little pixel critter on each screen
        for (px, py) in [(0, 0), (1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (2, 1), (3, 1), (0, 2), (2, 2)]:
            d.rectangle((x - u(20) + px * u(10), base - u(212) + py * u(10), x - u(11) + px * u(10), base - u(203) + py * u(10)), fill=(130, 255, 200) if sgn < 0 else (255, 160, 220))
        ell((x - u(14), base - u(140), x + u(14), base - u(112)), (255, 90, 120), width=int(u(3)))
        d.rectangle((x - u(3), base - u(150), x + u(3), base - u(126)), fill=INK)

# ---------------------------------------------------------------- unnamed plaza tower
def skyscraper(cx, base):
    lavender, mint, cream = (172, 161, 235), (169, 229, 224), (255, 245, 216)
    top = base - u(610)
    shadow(lambda g: g.ellipse((cx - u(258), base - u(18), cx + u(258), base + u(53)), fill=255), off=(6, 7), blur=16, alpha=65)
    for side in (-1, 1):
        x = cx + side * u(178)
        rrect((x - u(58), base - u(300), x + u(58), base), u(25), lavender, top=(227, 221, 255))
        rrect((x - u(63), base - u(314), x + u(63), base - u(288)), u(11), cream)
        for row in range(3):
            y = base - u(263) + row * u(72)
            rrect((x - u(28), y, x + u(28), y + u(48)), u(10), (111, 186, 211), top=(219, 247, 255), width=max(1, int(u(3))))
    rrect((cx - u(175), top, cx + u(175), base), u(30), lavender, top=(237, 228, 255))
    for side in (-1, 1):
        x = cx + side * u(153)
        rrect((x - u(8), top + u(35), x + u(8), base - u(18)), u(6), (249, 240, 255), outline=None)
    for row in range(5):
        y = top + u(59) + row * u(81)
        for col in range(3):
            x = cx + (col - 1) * u(87)
            rrect((x - u(31), y, x + u(31), y + u(57)), u(12), (112, 191, 214), top=(224, 250, 255), width=max(1, int(u(3))))
            d.line([(x - u(18), y + u(10)), (x - u(18), y + u(41))], fill=(249, 255, 255), width=max(1, int(u(4))))
            d.line([(x - u(21), y + u(50)), (x + u(21), y + u(50))], fill=(151, 214, 228), width=max(1, int(u(2))))
        d.line([(cx - u(130), y + u(69)), (cx + u(130), y + u(69))], fill=(248, 225, 182), width=max(1, int(u(4))))
    rrect((cx - u(126), top - u(106), cx + u(126), top + u(8)), u(20), lavender, top=(236, 226, 255))
    for offset in (-66, 0, 66):
        x = cx + u(offset)
        rrect((x - u(19), top - u(79), x + u(19), top - u(32)), u(10), (123, 201, 219), top=(222, 250, 255), width=max(1, int(u(3))))
    rrect((cx - u(65), top - u(150), cx + u(65), top - u(100)), u(5), mint, top=(223, 252, 242))
    d.pieslice((cx - u(65), top - u(215), cx + u(65), top - u(85)), 180, 360, fill=mint, outline=INK, width=LW)
    d.arc((cx - u(46), top - u(204), cx + u(46), top - u(96)), 195, 258, fill=(239, 255, 248), width=max(1, int(u(6))))
    d.line([(cx, top - u(212)), (cx, top - u(247))], fill=INK, width=max(1, int(u(5))))
    star(cx, top - u(254), u(20), (255, 224, 136))
    rrect((cx - u(140), top - u(118), cx + u(140), top - u(96)), u(9), cream)
    rrect((cx - u(192), top - u(17), cx + u(192), top + u(23)), u(14), mint, top=(226, 255, 247))
    rrect((cx - u(108), base - u(155), cx + u(108), base - u(121)), u(13), cream, top=(255, 253, 237))
    rrect((cx - u(68), base - u(130), cx + u(68), base + u(4)), u(33), (93, 83, 149))
    rrect((cx - u(53), base - u(112), cx + u(53), base + u(2)), u(26), (156, 222, 220), top=(224, 255, 246), width=max(1, int(u(3))))
    d.line([(cx, base - u(106)), (cx, base)], fill=INK, width=max(1, int(u(3))))
    for side in (-1, 1):
        x = cx + side * u(122)
        rrect((x - u(23), base - u(37), x + u(23), base + u(2)), u(8), (243, 185, 210), width=max(1, int(u(3))))
        ell((x - u(29), base - u(82), x + u(29), base - u(25)), (128, 201, 163), width=max(1, int(u(3))))
        ell((x - u(17), base - u(70), x + u(3), base - u(51)), (193, 241, 195), outline=None)
        ell((cx + side * u(14) - u(3), base - u(54), cx + side * u(14) + u(3), base - u(48)), cream, outline=None)
    rrect((cx - u(109), base + u(1), cx + u(109), base + u(17)), u(7), cream, width=max(1, int(u(3))))
    rrect((cx - u(131), base + u(17), cx + u(131), base + u(32)), u(7), (221, 208, 244), width=max(1, int(u(3))))

# lamp posts between the buildings
def lamp(x, base):
    d.rectangle((x - u(7), base - u(250), x + u(7), base), fill=(90, 80, 130))
    ell((x - u(26), base - u(296), x + u(26), base - u(244)), (255, 246, 190))
    d.rectangle((x - u(20), base - u(8), x + u(20), base + u(6)), fill=(90, 80, 130))

party(u(330), GROUND + u(70))
skyscraper(u(960), GROUND + u(60))
arcade(u(1590), GROUND + u(70))
lamp(u(640), GROUND + u(110))
lamp(u(1280), GROUND + u(110))

# flower planters along the front of the buildings
def planter(cx, y, w):
    rrect((cx - w / 2, y - u(40), cx + w / 2, y), u(14), (214, 150, 110), top=(236, 180, 140), width=int(u(4)))
    for i in range(int(w / u(34))):
        x = cx - w / 2 + u(20) + i * u(34)
        d.ellipse((x - u(18), y - u(66), x + u(18), y - u(30)), fill=(110, 196, 110))
        col = [(255, 140, 180), (255, 220, 100), (255, 255, 255), (180, 150, 255)][i % 4]
        d.ellipse((x - u(9), y - u(62), x + u(9), y - u(44)), fill=col)
planter(u(120), GROUND + u(150), u(170))
planter(u(570), GROUND + u(150), u(120))
planter(u(1350), GROUND + u(150), u(120))
planter(u(1800), GROUND + u(150), u(170))

img = img.resize((WOUT, HOUT), Image.LANCZOS)
img.save(OUT, optimize=True)