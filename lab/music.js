/* Hot Mic design lab: chords, shapes, tab, piano roll, keys, numbers, and the tuning lane. */
(function (HM) {
  const NS = 'http://www.w3.org/2000/svg';
  // Frets low E → high e; -1 = muted.
  const SHAPES = {
    Am: [-1, 0, 2, 2, 1, 0], Am7: [-1, 0, 2, 0, 1, 0], F: [1, 3, 3, 2, 1, 1], Fmaj7: [-1, -1, 3, 2, 1, 0],
    Fadd9: [-1, -1, 3, 2, 1, 3], C: [-1, 3, 2, 0, 1, 0], 'C/E': [0, 3, 2, 0, 1, 0], G: [3, 2, 0, 0, 0, 3],
    G6: [3, 2, 0, 0, 0, 0], Dm7: [-1, -1, 0, 2, 1, 1], Esus4: [0, 2, 2, 2, 0, 0], E: [0, 2, 2, 1, 0, 0],
  };
  HM.SHAPES = SHAPES;
  const ROMAN = { Am: 'i', Am7: 'i7', F: 'VI', Fmaj7: 'VImaj7', Fadd9: 'VIadd9', C: 'III', 'C/E': 'III⁶', G: 'VII', G6: 'VII6', Dm7: 'iv7', Esus4: 'Vsus4', E: 'V' };
  const OPEN = [4, 9, 2, 7, 11, 4];
  const pcs = (name) => [...new Set((SHAPES[name] || []).map((f, s) => (f < 0 ? null : (OPEN[s] + f) % 12)).filter((x) => x !== null))];

  const el = (tag, attrs = {}, kids = []) => {
    const n = document.createElementNS(NS, tag);
    Object.entries(attrs).forEach(([k, v]) => n.setAttribute(k, v));
    kids.forEach((k) => n.appendChild(k));
    return n;
  };
  const text = (x, y, s, attrs = {}) => { const t = el('text', { x, y, ...attrs }); t.textContent = s; return t; };

  // Where each chord lands in a line: the first word, then the first word past the bar line.
  HM.chordMarks = (line, slot) => {
    if (!line.chords || !line.chords[0]) return [];
    const base = slot * HM.LINE_DUR, marks = [{ chord: line.chords[0], wi: 0, t: 0 }];
    if (line.chords[1]) {
      let wi = line.words.findIndex((w) => w.off - base >= HM.BAR - 0.05);
      if (wi < 0) wi = line.words.length - 1;
      marks.push({ chord: line.chords[1], wi, t: HM.BAR });
    }
    return marks;
  };
  HM.chordLabel = (name, kind) => (kind === 'numbers' ? ROMAN[name] || name : name);

  function shape(name) {
    const frets = SHAPES[name] || [-1, -1, -1, -1, -1, -1];
    const svg = el('svg', { viewBox: '0 0 46 52', class: 'shape-svg' });
    for (let s = 0; s < 6; s++) svg.appendChild(el('line', { x1: 8 + s * 6, y1: 12, x2: 8 + s * 6, y2: 48, class: 'sv-str' }));
    for (let f = 0; f < 5; f++) svg.appendChild(el('line', { x1: 8, y1: 12 + f * 9, x2: 38, y2: 12 + f * 9, class: f === 0 ? 'sv-nut' : 'sv-fret' }));
    const barre = frets.every((f) => f >= 1) ? Math.min(...frets) : 0;
    if (barre) svg.appendChild(el('rect', { x: 6, y: 12 + (barre - 0.5) * 9 - 3, width: 34, height: 6, rx: 3, class: 'sv-dot' }));
    frets.forEach((f, s) => {
      const x = 8 + s * 6;
      if (f < 0) svg.appendChild(text(x, 8, '×', { class: 'sv-mark', 'text-anchor': 'middle' }));
      else if (f === 0) svg.appendChild(el('circle', { cx: x, cy: 6, r: 2, class: 'sv-open' }));
      else if (f !== barre) svg.appendChild(el('circle', { cx: x, cy: 12 + (f - 0.5) * 9, r: 2.6, class: 'sv-dot' }));
    });
    return svg;
  }

  function tab(line, slot) {
    const W = 600, top = 20, gap = 10, svg = el('svg', { viewBox: `0 0 ${W} 76`, class: 'tab-svg' });
    'eBGDAE'.split('').forEach((s, i) => {
      svg.appendChild(el('line', { x1: 18, y1: top + i * gap, x2: W - 4, y2: top + i * gap, class: 'tab-line' }));
      svg.appendChild(text(4, top + i * gap + 3.5, s, { class: 'tab-str' }));
    });
    const marks = HM.chordMarks(line, slot);
    for (let b = 0; b < 8; b += 2) {
      const t = b * HM.BEAT, m = marks.filter((k) => k.t <= t + 0.01).pop(), x = 30 + (t / HM.LINE_DUR) * (W - 44);
      const frets = SHAPES[m.chord] || [];
      const isChange = marks.some((k) => Math.abs(k.t - t) < 0.01);
      if (isChange) svg.appendChild(text(x, 10, m.chord, { class: 'tab-name' }));
      for (let s = 5; s >= 0; s--) {
        const f = frets[s]; if (f === undefined || f < 0) continue;
        const y = top + (5 - s) * gap;
        svg.appendChild(el('rect', { x: x - 5, y: y - 5.5, width: f > 9 ? 14 : 10, height: 11, class: 'tab-mask' }));
        svg.appendChild(text(x, y + 4, String(f), { class: isChange ? 'tab-num strong' : 'tab-num' }));
      }
    }
    return svg;
  }

  function roll(line, slot) {
    const W = 600, H = 58, base = slot * HM.LINE_DUR, svg = el('svg', { viewBox: `0 0 ${W} ${H}`, class: 'roll-svg' });
    const xOf = (t) => 6 + (t / HM.LINE_DUR) * (W - 12);
    const marks = HM.chordMarks(line, slot);
    marks.forEach((m, i) => {
      const x0 = xOf(m.t), x1 = xOf(i + 1 < marks.length ? marks[i + 1].t : HM.LINE_DUR);
      svg.appendChild(el('rect', { x: x0, y: 0, width: x1 - x0 - 2, height: H, rx: 4, class: `roll-chord c${i % 2}` }));
      svg.appendChild(text(x0 + 5, H - 5, m.chord, { class: 'roll-name' }));
    });
    for (let b = 1; b < 8; b++) svg.appendChild(el('line', { x1: xOf(b * HM.BEAT), y1: 0, x2: xOf(b * HM.BEAT), y2: H, class: b % 4 ? 'roll-beat' : 'roll-bar' }));
    line.words.forEach((w) => {
      const y = 46 - (w.note - 55) * 2.2;
      svg.appendChild(el('rect', { x: xOf(w.off - base), y: y - 2.5, width: Math.max(4, xOf(w.off - base + w.dur) - xOf(w.off - base)), height: 5, rx: 2.5, class: 'roll-note' }));
    });
    return svg;
  }

  function keys(name) {
    const on = pcs(name), white = [0, 2, 4, 5, 7, 9, 11], black = [[1, 0], [3, 1], [6, 3], [8, 4], [10, 5]];
    const svg = el('svg', { viewBox: '0 0 71 34', class: 'keys-svg' });
    white.forEach((pc, i) => svg.appendChild(el('rect', { x: 0.5 + i * 10, y: 0.5, width: 10, height: 33, rx: 1.5, class: on.includes(pc) ? 'key-w on' : 'key-w' })));
    black.forEach(([pc, i]) => svg.appendChild(el('rect', { x: 7 + i * 10, y: 0.5, width: 6, height: 20, rx: 1, class: on.includes(pc) ? 'key-b on' : 'key-b' })));
    return svg;
  }

  // The block that sits under a lyric line (null when the chords ride on the words).
  HM.musicBelow = (line, slot, kind) => {
    if (!line || ['over', 'numbers', 'off'].includes(kind)) return null;
    const box = document.createElement('div');
    box.className = `music music-${kind}`;
    const uniq = [...new Set(line.chords)];
    if (kind === 'shapes' || kind === 'keys') {
      uniq.forEach((c) => {
        const cell = document.createElement('div'); cell.className = 'chord-cell';
        const lab = document.createElement('span'); lab.textContent = c;
        cell.append(lab, kind === 'shapes' ? shape(c) : keys(c));
        box.appendChild(cell);
      });
    } else if (kind === 'tab') box.appendChild(tab(line, slot));
    else if (kind === 'roll') box.appendChild(roll(line, slot));
    return box;
  };

  // ---------- tuning lane ----------
  const ROOTS = ['C', 'C♯', 'D', 'E♭', 'E', 'F', 'F♯', 'G', 'A♭', 'A', 'B♭', 'B'];
  const keyName = () => HM.S.key || HM.KEY;
  function scaleOf(name) {
    const [root, mode] = name.split(' '), r = ROOTS.indexOf(root.replace('#', '♯').replace('b', '♭'));
    const steps = mode === 'major' ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10];
    return { root: r < 0 ? 9 : r, pcs: steps.map((s) => ((r < 0 ? 9 : r) + s) % 12) };
  }
  function keyMenu(anchor) {
    const cur = keyName(), chip = (k) => `<button class="kchip${k === cur ? ' on' : ''}" data-key="${k}">${k.split(' ')[0]}</button>`;
    HM.menu(anchor, `
      <div class="menu-sec"><div class="menu-h">Hot Mic heard</div>
        <button class="menu-row${!HM.S.key ? ' on' : ''}" data-key=""><b>${HM.KEY}</b><span>86% sure · from your voice and the beat</span></button>
        <button class="menu-row${cur === 'C major' ? ' on' : ''}" data-key="C major"><b>C major</b><span>same notes, brighter home</span></button></div>
      <div class="menu-sec"><div class="menu-h">Major</div><div class="kgrid">${ROOTS.map((r) => chip(`${r} major`)).join('')}</div></div>
      <div class="menu-sec"><div class="menu-h">Minor</div><div class="kgrid">${ROOTS.map((r) => chip(`${r} minor`)).join('')}</div></div>
      <div class="menu-foot">Pick a key to override what Hot Mic heard. Chords and shapes follow it.</div>`,
    (m, close) => m.querySelectorAll('[data-key]').forEach((b) => b.addEventListener('click', () => { close(); HM.set({ key: b.dataset.key || null }); })));
  }
  HM.renderTune = (host) => {
    const S = HM.S, sp = S.shapes || 'off';
    host.className = 'tune';
    host.innerHTML = `<button class="tune-key" data-menu title="Change the key">${HM.S.elapsed < 50 && !S.key ? '<b>Key</b><span>listening…</span>' : `<b>${keyName()}</b><span>${S.key ? 'set by you' : 'detected'} · 88 BPM</span>`}<svg class="i"><use href="#i-chev-down"/></svg></button>
      <div class="shape-toggle chords-toggle" title="Show chords over the words"><span>Chords</span>${[['on', 'On'], ['off', 'Off']].map(([id, nm]) => `<button class="${(S.chords || 'on') === id ? 'on' : ''}" data-chords="${id}">${nm}</button>`).join('')}</div>
      <div class="shape-toggle" title="Show chord shapes under each line"${S.chords === 'off' ? ' hidden' : ''}><span>Chord shapes</span>${[['off', 'Off'], ['guitar', 'Guitar'], ['piano', 'Piano']].map(([id, nm]) => `<button class="${sp === id ? 'on' : ''}" data-shapes="${id}">${nm}</button>`).join('')}</div>`;
    host.querySelector('.tune-key').addEventListener('click', (e) => keyMenu(e.currentTarget));
    host.querySelectorAll('[data-chords]').forEach((b) => b.addEventListener('click', () => HM.set({ chords: b.dataset.chords })));
    host.querySelectorAll('[data-shapes]').forEach((b) => b.addEventListener('click', () => HM.set({ shapes: b.dataset.shapes, music: ['over', 'numbers'].includes(S.music) ? S.music : 'over' })));
  };
})(window.HM);
