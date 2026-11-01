#!/usr/bin/env python3
"""Cuts the FLORA wordmarks (lab/brand/wordmark-{line,stacked}-source.png) to clean transparent PNGs:
the charcoal and its soft shadow go, chrome edges stay crisp (un-matted against the charcoal), the chrome is
brightened like the icon's (scripts/icon-build.py), cropped tight, written at 3x (source res), 2x and 1x."""
import os
from collections import deque
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = f'{ROOT}/lab/brand'

def brighten(x):
    rgb = x[..., :3]; v = rgb.max(-1)
    chrome = ((rgb[..., 2] - rgb[..., 1]) > 0.02) & (v > 0.2)
    w = np.clip((v - 0.15) / 0.25, 0, 1) * chrome
    v2 = 1 - (1 - v) ** 2.2; t = np.clip((v2 - 0.55) / 0.4, 0, 1)[..., None]
    col = np.array([0.80, 0.74, 1.0]) * v2[..., None] * (1 - t) + np.array([0.97, 0.96, 1.0]) * t * np.maximum(v2, 0.9)[..., None]
    x[..., :3] = np.clip(rgb * (1 - w[..., None]) + col * w[..., None], 0, 1)
    return x

def cut(name):
    a = np.array(Image.open(f'{BRAND}/wordmark-{name}-source.png').convert('RGB')).astype(np.float32) / 255
    ai = (a * 255).astype(int); r, g, b = ai[..., 0], ai[..., 1], ai[..., 2]; mx = np.maximum(np.maximum(r, g), b)
    letter = (b - g > 6) & (mx > 50)
    # outside = the charcoal (and its shadow) reachable from the corners without crossing chrome;
    # dark reflections inside the letters stay opaque
    h, w = letter.shape; outside = np.zeros_like(letter); q = deque([(0, 0), (0, w - 1), (h - 1, 0), (h - 1, w - 1)])
    for p in q: outside[p] = True
    while q:
        y, x = q.popleft()
        for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if 0 <= ny < h and 0 <= nx < w and not outside[ny, nx] and not letter[ny, nx]:
                outside[ny, nx] = True; q.append((ny, nx))
    # enclosed counters (inside the o, the H's loops) are charcoal too: any closed non-chrome pocket bigger
    # than a reflection and close to the background colour is see-through
    bgv = np.median(mx[:40, :40]); seen = outside.copy()
    for y0 in range(h):
        for x0 in range(w):
            if seen[y0, x0] or letter[y0, x0]: continue
            comp = [(y0, x0)]; seen[y0, x0] = True; i = 0
            while i < len(comp):
                y, x = comp[i]; i += 1
                for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                    if 0 <= ny < h and 0 <= nx < w and not seen[ny, nx] and not letter[ny, nx]:
                        seen[ny, nx] = True; comp.append((ny, nx))
            if len(comp) > 250:
                cy, cx = zip(*comp)
                if abs(np.median(mx[cy, cx]) - bgv) < 10: outside[cy, cx] = True
    hard = (~outside).astype(np.uint8) * 255
    hard = np.array(Image.fromarray(hard).filter(ImageFilter.MinFilter(3)))   # one pixel in: no dark rim
    alpha = np.array(Image.fromarray(hard).filter(ImageFilter.GaussianBlur(0.6))).astype(np.float32) / 255
    bg = np.median(a[:40, :40].reshape(-1, 3), axis=0)
    # un-matte the edge so no charcoal halo is left on light backgrounds
    al = np.clip(alpha, 1e-3, 1)[..., None]
    rgb = np.clip((a - bg * (1 - al)) / al, 0, 1)
    rgba = np.dstack([rgb, alpha])
    rgba = brighten(rgba)
    img = Image.fromarray((rgba * 255).astype(np.uint8), 'RGBA')
    ys, xs = np.where(alpha > 0.02); pad = 6
    img = img.crop((max(0, xs.min() - pad), max(0, ys.min() - pad), min(w, xs.max() + pad + 1), min(h, ys.max() + pad + 1)))
    img.save(f'{BRAND}/wordmark-{name}@3x.png')
    for k in (2, 1):
        img.resize((round(img.width * k / 3), round(img.height * k / 3)), Image.LANCZOS).save(f'{BRAND}/wordmark-{name}@{k}x.png' if k == 2 else f'{BRAND}/wordmark-{name}.png')
    print(name, img.size)

for n in ('line', 'stacked'): cut(n)
