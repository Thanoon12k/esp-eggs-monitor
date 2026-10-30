"""Draws the app icon (a chick hatching from a warm egg) and writes the Android launcher icons.
Run from the repo root: python3 tool/make_icon.py  (needs Pillow)."""
import math
from PIL import Image, ImageDraw, ImageFilter

S = 1024  # drawing size; downscaled for each density
RES = 'android/app/src/main/res'

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def background(size):
    img = Image.new('RGBA', (size, size))
    px = img.load()
    top, bottom = (255, 190, 92, 255), (232, 98, 42, 255)
    cx, cy = size * 0.5, size * 0.42
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - cx, y - cy) / (size * 0.75)
            px[x, y] = lerp(top, bottom, min(1, d))
    return img

def egg_points(cx, cy, w, h, n=400):
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        x = math.sin(a)
        y = -math.cos(a)
        k = 0.82 if y < 0 else 1.0   # narrower top
        pts.append((cx + x * w * (k + (1 - k) * (1 + y) / 2 if y < 0 else 1), cy + y * h))
    return pts

def zigzag(cx, cy, w, teeth=7, amp=34):
    pts = []
    for i in range(teeth * 2 + 1):
        x = cx - w + (2 * w) * i / (teeth * 2)
        y = cy + (amp if i % 2 else -amp)
        pts.append((x, y))
    return pts

def art(size=S, scale=1.0):
    """Foreground art on a transparent canvas; scale < 1 shrinks it into the adaptive-icon safe zone."""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    c = size / 2
    u = size * scale / S  # units relative to a 1024 drawing
    ecx, ecy, ew, eh = c, c + 120 * u, 270 * u, 330 * u
    crack_y = ecy - 40 * u

    # soft shadow under the egg
    sh = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(sh).ellipse([ecx - 250 * u, ecy + eh - 40 * u, ecx + 250 * u, ecy + eh + 40 * u], fill=(120, 40, 0, 90))
    img = Image.alpha_composite(img, sh.filter(ImageFilter.GaussianBlur(18 * u)))

    # chick head peeking out of the shell
    d = ImageDraw.Draw(img)
    hx, hy, hr = ecx, crack_y - 70 * u, 170 * u
    d.ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=(255, 214, 64, 255))
    d.ellipse([hx - hr * 0.55, hy - hr * 0.75, hx + hr * 0.25, hy - hr * 0.2], fill=(255, 232, 130, 255))  # highlight
    # tuft
    for dx, ang in ((-18, -20), (10, 15)):
        d.ellipse([hx + dx * u - 22 * u, hy - hr - 40 * u, hx + dx * u + 22 * u, hy - hr + 30 * u], fill=(255, 205, 50, 255))
    # eyes
    for ex in (-62, 62):
        d.ellipse([hx + ex * u - 20 * u, hy - 30 * u, hx + ex * u + 20 * u, hy + 12 * u], fill=(60, 35, 20, 255))
        d.ellipse([hx + ex * u - 6 * u, hy - 24 * u, hx + ex * u + 6 * u, hy - 12 * u], fill=(255, 255, 255, 255))
    # beak
    d.polygon([(hx - 34 * u, hy + 30 * u), (hx + 34 * u, hy + 30 * u), (hx, hy + 78 * u)], fill=(240, 110, 40, 255))
    # cheeks
    for ex in (-110, 110):
        d.ellipse([hx + ex * u - 26 * u, hy + 30 * u, hx + ex * u + 26 * u, hy + 56 * u], fill=(255, 150, 110, 200))

    # lower shell, cut along a zigzag crack
    shell = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shell)
    sd.polygon(egg_points(ecx, ecy, ew, eh), fill=(255, 248, 236, 255))
    mask = Image.new('L', (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.polygon(zigzag(ecx, crack_y, ew + 20 * u) + [(ecx + ew + 40 * u, size), (ecx - ew - 40 * u, size)], fill=255)
    # gentle shading on the shell's right side
    shade = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shade).ellipse([ecx + 20 * u, ecy - eh * 0.6, ecx + ew * 1.9, ecy + eh * 1.4], fill=(230, 190, 150, 110))
    shade = shade.filter(ImageFilter.GaussianBlur(110 * u))
    shell_alpha = shell.split()[3]
    shell = Image.alpha_composite(shell, Image.composite(shade, Image.new('RGBA', (size, size)), shell_alpha))
    cut = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    cut.paste(shell, (0, 0), Image.composite(shell_alpha, Image.new('L', (size, size), 0), mask))
    img = Image.alpha_composite(img, cut)

    # cap of the shell resting on the head
    cap = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    cd = ImageDraw.Draw(cap)
    cd.polygon(egg_points(ecx, ecy, ew, eh), fill=(255, 248, 236, 255))
    capmask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(capmask).polygon(zigzag(ecx, crack_y, ew + 20 * u) + [(ecx + ew + 40 * u, 0), (ecx - ew - 40 * u, 0)], fill=255)
    capmask = Image.composite(cap.split()[3], Image.new('L', (size, size), 0), capmask)
    capimg = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    capimg.paste(cap, (0, 0), capmask)
    bbox = capimg.getbbox()
    capimg = capimg.crop(bbox).resize((int((bbox[2] - bbox[0]) * 0.62), int((bbox[3] - bbox[1]) * 0.62)), Image.LANCZOS)
    capimg = capimg.rotate(-16, expand=True, resample=Image.BICUBIC)
    img.alpha_composite(capimg, (int(hx - capimg.width / 2 + 40 * u), int(hy - hr - capimg.height + 60 * u)))
    return img

def rounded(img, radius):
    m = Image.new('L', img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], radius, fill=255)
    out = Image.new('RGBA', img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), m)
    return out

if __name__ == '__main__':
    full = Image.alpha_composite(background(S), art(S, 0.92))
    full.save('icon.png')
    import os; os.makedirs('assets', exist_ok=True)
    full.resize((256, 256), Image.LANCZOS).save('assets/icon.png')
    legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
    fg = art(S, 0.72)  # adaptive icons crop to the middle ~66%
    for dens, px in legacy.items():
        d = f'{RES}/mipmap-{dens}'
        import os; os.makedirs(d, exist_ok=True)
        rounded(full, S * 0.22).resize((px, px), Image.LANCZOS).save(f'{d}/ic_launcher.png')
        circ = Image.new('L', (S, S), 0); ImageDraw.Draw(circ).ellipse([0, 0, S - 1, S - 1], fill=255)
        r = Image.new('RGBA', (S, S), (0, 0, 0, 0)); r.paste(full, (0, 0), circ)
        r.resize((px, px), Image.LANCZOS).save(f'{d}/ic_launcher_round.png')
        fg.resize((px * 108 // 48, px * 108 // 48), Image.LANCZOS).save(f'{d}/ic_launcher_foreground.png')
    print('icons written')
