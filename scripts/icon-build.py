#!/usr/bin/env python3
"""Builds the app icon from Resources/Icon/source/flame-frame-H.png (FLORA art), no redrawing:
crop to the chrome frame on Apple's 824-px body (transparent outside the frame), center the H by moving it,
brighten the chrome to the wordmark's lilac ice, H-only tile for 16/32 px, .icns, title-bar tile, contact sheet.
Also writes the H alone (mask + pixels) for the wordmark composite. Usage: python3 scripts/icon-build.py <scratch dir>"""
import os, sys, subprocess
from collections import deque
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRATCH = sys.argv[1] if len(sys.argv) > 1 else '/tmp/hotmic-icon'
os.makedirs(SCRATCH, exist_ok=True)
src = Image.open(f'{ROOT}/Resources/Icon/source/flame-frame-H.png').convert('RGB')
a = np.array(src).astype(np.float32); ai = a.astype(int)
r, g, b = ai[..., 0], ai[..., 1], ai[..., 2]; mx = np.maximum(np.maximum(r, g), b)
lil = (mx > 55) & (b - g > 6)

def flood(mask, seeds):
    seen = np.zeros(mask.shape, bool); q = deque(seeds)
    for s in seeds: seen[s] = True
    while q:
        y, x = q.popleft()
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                ny, nx = y + dy, x + dx
                if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True; q.append((ny, nx))
    return seen

# the frame: lilac bbox; the H: the lilac blob through the middle of the tile
ys, xs = np.where(lil); fx0, fx1, fy0, fy1 = xs.min(), xs.max(), ys.min(), ys.max()
cy, cx = (fy0 + fy1) // 2, (fx0 + fx1) // 2
seed = next((cy + dy, x) for dy in range(0, 120, 2) for x in range(cx - 120, cx + 120) if lil[cy + dy, x])
H = flood(lil, [seed]); hy, hx = np.where(H)
print('frame', fx0, fx1, fy0, fy1, 'H', hx.min(), hx.max(), hy.min(), hy.max())
# center the H in the frame (optically a hair high), moving only the H
dy = int(round((fy0 + fy1) / 2 - 4 - (hy.min() + hy.max()) / 2)); dx = int(round((fx0 + fx1) / 2 - (hx.min() + hx.max()) / 2))
print('move H by', dx, dy)
hm = np.array(Image.fromarray(H.astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(9))) > 0
bg = np.median(a[fy0 + 60:fy0 + 90, cx - 40:cx + 60].reshape(-1, 3), axis=0)
out = a.copy(); out[hm] = bg; yy, xx = np.where(hm); out[yy + dy, xx + dx] = a[yy, xx]
# the H alone (for the wordmark): its pixels + soft alpha
hb = (hx.min() - 10, hy.min() - 10, hx.max() + 11, hy.max() + 11)
h_rgba = Image.fromarray(a.clip(0, 255).astype(np.uint8)).convert('RGBA')
h_rgba.putalpha(Image.fromarray(hm.astype(np.uint8) * 255).filter(ImageFilter.GaussianBlur(0.8)))
h_rgba.crop(hb).save(f'{SCRATCH}/icon-H.png')
# alpha: everything reachable from the corners without crossing the frame is outside
outside = flood(~lil & (mx < 200), [(0, 0), (0, 1023), (1023, 0), (1023, 1023)])
alpha = Image.fromarray((~outside).astype(np.uint8) * 255).filter(ImageFilter.GaussianBlur(0.7))
img = Image.fromarray(out.clip(0, 255).astype(np.uint8)).convert('RGBA'); img.putalpha(alpha)
side = max(fx1 - fx0, fy1 - fy0) + 1; ox, oy = (fx0 + fx1 - side) // 2, (fy0 + fy1 - side) // 2
big = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
big.alpha_composite(img.crop((ox, oy, ox + side, oy + side)).resize((824, 824), Image.LANCZOS), (100, 100))

def brighten(im):
    """Chrome only: highlights toward white, livelier lilac mids, the charcoal untouched."""
    x = np.array(im).astype(np.float32) / 255; rgb = x[..., :3]; v = rgb.max(-1)
    chrome = ((rgb[..., 2] - rgb[..., 1]) > 0.02) & (v > 0.2)
    w = np.clip((v - 0.15) / 0.25, 0, 1) * chrome
    v2 = 1 - (1 - v) ** 2.2; t = np.clip((v2 - 0.55) / 0.4, 0, 1)[..., None]
    col = np.array([0.80, 0.74, 1.0]) * v2[..., None] * (1 - t) + np.array([0.97, 0.96, 1.0]) * t * np.maximum(v2, 0.9)[..., None]
    x[..., :3] = np.clip(rgb * (1 - w[..., None]) + col * w[..., None], 0, 1)
    return Image.fromarray((x * 255).astype(np.uint8))

big = brighten(big)
Hb = brighten(Image.open(f'{SCRATCH}/icon-H.png')); Hb.save(f'{SCRATCH}/icon-H-bright.png')
# 16/32: the H alone on the same tile, lilac rim
small = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
S = 4; m = Image.new('L', (824 * S, 824 * S), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, 824 * S - 1, 824 * S - 1), radius=int(824 * S * 0.205), fill=255)
body = Image.new('RGBA', (824, 824), tuple(int(c) for c in bg) + (255,)); body.putalpha(m.resize((824, 824), Image.LANCZOS))
small.alpha_composite(body, (100, 100))
hs = Hb.resize((int(Hb.width * 1.45), int(Hb.height * 1.45)), Image.LANCZOS)
small.alpha_composite(hs, ((1024 - hs.width) // 2, (1024 - hs.height) // 2 - 8))
ImageDraw.Draw(small).rounded_rectangle((112, 112, 911, 911), radius=160, outline=(214, 206, 252, 255), width=36)
big.save(f'{ROOT}/Resources/Icon/app-icon.png'); small.save(f'{ROOT}/Resources/Icon/app-icon-small.png')
iconset = f'{SCRATCH}/HotMic.iconset'; os.makedirs(iconset, exist_ok=True)
for s in (16, 32, 128, 256, 512):
    for k, px in (('', s), ('@2x', 2 * s)):
        (small if px <= 32 else big).resize((px, px), Image.LANCZOS).save(f'{iconset}/icon_{s}x{s}{k}.png')
subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', f'{ROOT}/Resources/HotMic.icns'], check=True)
big.resize((112, 112), Image.LANCZOS).save(f'{ROOT}/lab/hm-icon.png')
sizes = [1024, 512, 256, 128, 64, 32, 16]
W = sum(min(s, 512) for s in sizes) + 20 * len(sizes) + 20
sheet = Image.new('RGBA', (W, 1080), (242, 242, 246, 255)); d = ImageDraw.Draw(sheet); d.rectangle((0, 550, W, 1080), fill=(30, 30, 34, 255))
x = 20
for s in sizes:
    im = (small if s <= 32 else big).resize((s, s), Image.LANCZOS); dd = min(s, 512)
    if s > 512: im = im.resize((512, 512), Image.LANCZOS)
    sheet.alpha_composite(im, (x, 520 - dd)); sheet.alpha_composite(im, (x, 1060 - dd)); d.text((x, 526), str(s), fill=(90, 90, 100, 255)); x += dd + 20
sheet.save(f'{ROOT}/lab/brand-icon-contact-sheet.png')
print('ok')
