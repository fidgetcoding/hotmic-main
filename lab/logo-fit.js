/* Hot Mic design lab: fit the script H to its real ink so it sits centered in its tile. */
(function () {
  function fit() {
    const W = 300, c = document.createElement('canvas'); c.width = W; c.height = W;
    const g = c.getContext('2d'); g.font = `${W * 0.7}px Yellowtail`; g.fillText('H', W * 0.15, W * 0.75);
    const d = g.getImageData(0, 0, W, W).data; let x0 = W, y0 = W, x1 = 0, y1 = 0;
    for (let y = 0; y < W; y++) for (let x = 0; x < W; x++) if (d[(y * W + x) * 4 + 3] > 20) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    if (x1 <= x0) return;
    // map canvas ink box into the svg's text space (font-size 100, x=0, baseline y=80)
    const k = 100 / (W * 0.7), ix = (x0 - W * 0.15) * k, iy = (y0 - W * 0.75) * k + 80, iw = (x1 - x0) * k, ih = (y1 - y0) * k;
    const side = Math.max(iw, ih) * 1.95, cx = ix + iw / 2, cy = iy + ih / 2;
    document.querySelectorAll('.hm-tile svg').forEach((svg) => {
      const t = svg.querySelector('text'); t.setAttribute('x', '0'); t.setAttribute('y', '80'); t.setAttribute('font-size', '100'); t.removeAttribute('text-anchor');
      svg.setAttribute('viewBox', `${cx - side / 2} ${cy - side / 2} ${side} ${side}`);
    });
  }
  const go = () => (document.fonts ? document.fonts.load('100px Yellowtail').then(fit) : fit());
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', go); else go();
})();
