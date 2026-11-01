/* Hot Mic design lab: the notepad (lyrics) and the 8 ways to flip between versions. */
(function (HM) {
  let lineRefs = [];
  const S = () => HM.S;
  const h = (html) => { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstElementChild; };
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const pct = (x) => `${Math.round(x * 100)}%`;

  // ---------- shared pieces ----------
  function tokens(s) { return s.toLowerCase().replace(/[^a-z' ]/g, '').split(/\s+/); }
  function changedIdx(a, b) { // indexes of words in a that aren't in the longest common run with b
    const A = tokens(a), B = tokens(b), dp = A.map(() => Array(B.length + 1).fill(0));
    for (let i = A.length - 1; i >= 0; i--) for (let j = B.length - 1; j >= 0; j--) dp[i][j] = A[i] === B[j] ? 1 + ((dp[i + 1] || [])[j + 1] || 0) : Math.max((dp[i + 1] || [])[j] || 0, dp[i][j + 1]);
    const keep = new Set(); let i = 0, j = 0;
    while (i < A.length && j < B.length) { if (A[i] === B[j]) { keep.add(i); i++; j++; } else if (((dp[i + 1] || [])[j] || 0) >= dp[i][j + 1]) i++; else j++; }
    return new Set(A.map((_, k) => k).filter((k) => !keep.has(k)));
  }

  function lyric(sec, slot, sh, opts = {}) {
    const S0 = S(), base = HM.timeOf(sh.pass), edited = sh.edited;
    const el = h(`<div class="lyric${opts.cls ? ` ${opts.cls}` : ''}" data-sec="${sec.id}" data-slot="${slot}"></div>`);
    const words = edited ? edited.split(/\s+/).map((w) => ({ w, off: slot * HM.LINE_DUR, dur: 0.3 })) : sh.line.words;
    const showCh = ['over', 'numbers'].includes(S0.music);
    // A typed line keeps its chords: first chord on the first word, second halfway through.
    const marks = !showCh ? [] : edited ? sh.line.chords.map((chord, i) => ({ chord, wi: i ? Math.floor(words.length / 2) : 0 })) : HM.chordMarks(sh.line, slot);
    const chg = opts.diff && !edited ? changedIdx(sh.version.text, opts.diff.text) : new Set();
    const flex = opts.flex || new Set();
    const ref = { el, t0: base + slot * HM.LINE_DUR, t1: base + (slot + 1) * HM.LINE_DUR, words: [] };
    words.forEach((w, i) => {
      const m = marks.find((k) => k.wi === i);
      const span = h(`<span class="w${chg.has(i) ? ' chg' : ''}${flex.has(i) ? ' flex' : ''}">${m ? `<span class="ch">${esc(HM.chordLabel(m.chord, S0.music))}</span>` : ''}${esc(w.w)}</span>`);
      span.addEventListener('click', (e) => {
        if (flex.has(i) && opts.onFlex) { opts.onFlex(e, span, i); return; }
        if (S0.editing) return; // in edit mode a click just puts the cursor there
        e.stopPropagation(); HM.seek(base + w.off, true);
      });
      el.appendChild(span); el.appendChild(document.createTextNode(' '));
      ref.words.push({ el: span, t: base + w.off });
    });
    if (!opts.noTags) {
      if (edited) el.appendChild(h('<span class="tag typed" title="You typed this">✎ typed</span>'));
      else {
        if (HM.isTrying(sh.version, sh.passes)) el.appendChild(h('<span class="tag trying" title="Only sung once, on the newest take">trying</span>'));
        if (sh.version.chordChanged && S0.music !== 'off') el.appendChild(h('<span class="tag chord" title="The chords changed when you changed these words">new chord</span>'));
        if (sh.source === 'pick') el.appendChild(h('<button class="tag pick" title="Your pick for this line. Click to go back to the section\'s take">your pick ×</button>'));
      }
    }
    // The notes you sang on this line (Nate 2026-10-14). Rap and talk lines have none, so nothing shows.
    if (!edited && sh.line.sung && sh.line.sung.length && S0.chords !== 'off') el.appendChild(h(`<span class="sung" title="The notes you sang">♪ ${esc(sh.line.sung.join(' '))}</span>`));
    const pickTag = el.querySelector('.tag.pick');
    if (pickTag) pickTag.addEventListener('click', (e) => { e.stopPropagation(); HM.clearLine(sec, slot); });
    lineRefs.push(ref);
    return el;
  }

  function below(sh, slot) {
    if (sh.edited) return null;
    const m = S().music, sp = S().shapes;
    if ((m === 'over' || m === 'numbers') && sp && sp !== 'off') return HM.musicBelow(sh.line, slot, sp === 'piano' ? 'keys' : 'shapes');
    return HM.musicBelow(sh.line, slot, m);
  }

  function header(sec, extra, g) {
    const p = HM.shownPass(sec), picked = !!S().picks[sec.id], n = HM.visiblePasses(sec).length, sc = p.score;
    const why = `${sc.whole >= 0.99 ? 'whole section, no stops' : pct(sc.whole) + ' of the section'} · on pitch ${pct(sc.pitch)} · on the beat ${pct(sc.timing)}`;
    const badge = picked
      ? `<span class="badge pick" title="${why}"><svg class="i"><use href="#i-star"/></svg>Your pick · Take ${p.n}</span>`
      : `<span class="badge sug" title="Showing your most recent take until you pick one">Latest · Take ${p.n}</span>`;
    const el = h(`<header class="sec-head"><div class="sec-title"><span class="dot tone-${sec.tone}"></span><h3 class="sec-name" title="Click to rename">${esc(g ? g.name : sec.name)}</h3><span class="dim">${n} take${n > 1 ? 's' : ''} · ${HM.fmt(HM.timeOf(p))}</span>${badge}</div><div class="sec-tools"></div></header>`);
    if (!picked) el.querySelector('.badge').insertAdjacentHTML('afterend', S().pickBy === 'section' ? '' : '<span class="dim small">lines picked one by one</span>');
    if (picked) { const b = h('<button class="link">back to latest</button>'); b.addEventListener('click', () => HM.clearPass(sec)); el.querySelector('.sec-title').appendChild(b); }
    if (extra) el.querySelector('.sec-tools').appendChild(extra);
    if (g) HM.sheet.wireName(el, g);
    return el;
  }

  function passPills(sec, cls = 'pills') {
    const shown = HM.shownPass(sec), sug = HM.suggestPass(sec, HM.visiblePasses(sec), S().sectionDefault);
    const box = h(`<div class="${cls}"></div>`);
    HM.visiblePasses(sec).forEach((p) => {
      const b = h(`<button class="pill${p === shown ? ' on' : ''}${p === sug ? ' sug' : ''}" title="Take ${p.n} · ${HM.fmt(p.at)} · ${pct(p.score.total)}${p.note ? ' · ' + p.note : ''}">${p === sug ? '<svg class="i"><use href="#i-spark"/></svg>' : ''}${p.n}</button>`);
      b.addEventListener('click', () => HM.pickPass(sec, p));
      box.appendChild(b);
    });
    return box;
  }

  function stepper(label, i, n, onStep, title = '') {
    const el = h(`<span class="stepper" title="${title}"><button aria-label="Previous"><svg class="i"><use href="#i-chev-left"/></svg></button><span>${label} <b>${i + 1}</b>/${n}</span><button aria-label="Next"><svg class="i"><use href="#i-chev-right"/></svg></button></span>`);
    const [prev, next] = el.querySelectorAll('button');
    prev.disabled = i <= 0; next.disabled = i >= n - 1;
    prev.addEventListener('click', (e) => { e.stopPropagation(); onStep(-1); });
    next.addEventListener('click', (e) => { e.stopPropagation(); onStep(1); });
    return el;
  }

  function vMeta(v, sh) {
    const takes = v.passes.map((p) => p.n).join(', ');
    return `Take${v.passes.length > 1 ? 's' : ''} ${takes} · ${v.flow}${v === sh.version ? ' · showing' : ''}${HM.isTrying(v, sh.passes) ? ' · trying' : ''}`;
  }
  function playBtn(sec, slot, v) {
    const b = h('<button class="icon-btn" title="Hear it"><svg class="i"><use href="#i-play"/></svg></button>');
    b.addEventListener('click', (e) => { e.stopPropagation(); HM.seek(HM.timeOf(v.best) + slot * HM.LINE_DUR, true); });
    return b;
  }

  // ---------- popover ----------
  const pop = h('<div class="pop" hidden></div>');
  document.addEventListener('mousedown', (e) => { if (!pop.hidden && !pop.contains(e.target)) pop.hidden = true; });
  function openPop(anchor, items) {
    if (!pop.isConnected) document.body.appendChild(pop);
    pop.innerHTML = ''; items.forEach((it) => pop.appendChild(it)); pop.hidden = false;
    const r = anchor.getBoundingClientRect();
    pop.style.left = `${Math.min(window.innerWidth - 340, r.left)}px`; pop.style.top = `${r.bottom + 6}px`;
  }
  // The stretch of words around word wi that differs between the shown line and another version.
  function hunk(cur, alt, wi) {
    const A = cur.split(/\s+/), B = alt.split(/\s+/), a = tokens(cur), b = tokens(alt);
    const dp = a.map(() => Array(b.length + 1).fill(0));
    for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--) dp[i][j] = a[i] === b[j] ? 1 + ((dp[i + 1] || [])[j + 1] || 0) : Math.max((dp[i + 1] || [])[j] || 0, dp[i][j + 1]);
    const pairs = [[-1, -1]]; let i = 0, j = 0;
    while (i < a.length && j < b.length) { if (a[i] === b[j]) { pairs.push([i, j]); i++; j++; } else if (((dp[i + 1] || [])[j] || 0) >= dp[i][j + 1]) i++; else j++; }
    pairs.push([a.length, b.length]);
    for (let k = 0; k < pairs.length - 1; k++) {
      const [pa, pb] = pairs[k], [na, nb] = pairs[k + 1];
      if (wi > pa && wi < na) return { from: pa + 1, to: na, repl: B.slice(pb + 1, nb), A };
    }
    return null;
  }
  function altRow(sec, slot, v, sh, opts = {}) {
    const row = h(`<div class="alt${v === sh.version ? ' current' : ''}"></div>`);
    row.appendChild(playBtn(sec, slot, v));
    const chg = changedIdx(v.text, sh.version.text);
    row.appendChild(h(`<div class="alt-body"><div class="alt-text">${v.text.split(/\s+/).map((w, i) => (chg.has(i) ? `<mark>${esc(w)}</mark>` : esc(w))).join(' ')}</div><div class="alt-meta">${vMeta(v, sh)}</div></div>`));
    if (v !== sh.version) {
      const cur = sh.edited || sh.version.text, hk = opts.word != null ? hunk(cur, v.text, opts.word) : null;
      if (hk && hk.repl.length) {
        const words = h(`<button class="mini-btn word-swap" title="Swap only these words, keep the rest of your line">Just “${esc(hk.repl.join(' '))}”</button>`);
        words.addEventListener('click', (e) => {
          e.stopPropagation(); pop.hidden = true;
          const next = [...hk.A.slice(0, hk.from), ...hk.repl, ...hk.A.slice(hk.to)].join(' '), k = `${sec.id}:${slot}`;
          const same = sh.versions.find((x) => x.text === next);
          if (same) { delete S().edits[k]; HM.pickLine(sec, slot, same.key); } else { S().edits[k] = next; HM.save(); HM.renderNotes(); if (S().editing) HM.sheet.makeEditable(); }
        });
        row.appendChild(words);
      }
      const use = h('<button class="mini-btn">Whole line</button>');
      use.addEventListener('click', (e) => { e.stopPropagation(); pop.hidden = true; delete S().edits[`${sec.id}:${slot}`]; HM.pickLine(sec, slot, v.key); });
      row.appendChild(use);
    } else row.appendChild(h('<span class="check"><svg class="i"><use href="#i-check"/></svg></span>'));
    if (opts.whole) row.addEventListener('click', () => { if (v !== sh.version) HM.pickLine(sec, slot, v.key); });
    return row;
  }

  // ---------- the variants: one row per line, plus the section-level control ----------
  const mk = (sec, slot, cls = '') => { const r = h(`<div class="row${cls}" data-key="${sec.id}:${slot}"></div>`), m = h('<div class="row-main"></div>'); r.appendChild(m); return [r, m]; };
  const withBelow = (m, sh, slot) => { const mb = below(sh, slot); if (mb) m.appendChild(mb); };
  const ROWS = {}, HEADS = {};
  ROWS.arrows = (sec, slot) => {
    const sh = HM.shown(sec, slot), [row, main] = mk(sec, slot);
    main.appendChild(lyric(sec, slot, sh)); withBelow(main, sh, slot);
    const vi = sh.versions.indexOf(sh.version);
    if (sh.versions.length > 1) row.appendChild(stepper('', vi, sh.versions.length, (d) => HM.pickLine(sec, slot, sh.versions[vi + d].key), 'Flip this line'));
    return row;
  };
  HEADS.arrows = (sec) => { const ps = HM.visiblePasses(sec), i = ps.indexOf(HM.shownPass(sec)); return { tools: stepper('Take', i, ps.length, (d) => HM.pickPass(sec, ps[i + d]), 'Flip the whole section') }; };

  ROWS.unfold = (sec, slot) => {
    const sh = HM.shown(sec, slot), k = `${sec.id}:${slot}`, open = S().open[k], [row, main] = mk(sec, slot, ` unfold${open ? ' open' : ''}`);
    main.appendChild(lyric(sec, slot, sh));
    if (sh.versions.length > 1) {
      const t = h(`<button class="count" title="Show every version">${sh.versions.length} versions<svg class="i"><use href="#i-chev-down"/></svg></button>`);
      t.addEventListener('click', (e) => { e.stopPropagation(); S().open[k] = !open; HM.renderNotes(); });
      main.querySelector('.lyric').appendChild(t);
    }
    withBelow(main, sh, slot);
    if (open) { const list = h('<div class="alts"></div>'); sh.versions.forEach((v) => list.appendChild(altRow(sec, slot, v, sh))); row.appendChild(list); }
    return row;
  };
  HEADS.unfold = (sec) => ({ tools: passPills(sec) });

  ROWS.ghosts = (sec, slot) => {
    const sh = HM.shown(sec, slot), [row, main] = mk(sec, slot);
    main.appendChild(lyric(sec, slot, sh));
    sh.versions.filter((v) => v !== sh.version).slice(-3).forEach((v) => {
      const chg = changedIdx(v.text, sh.version.text);
      const g = h(`<div class="ghost" title="${esc(vMeta(v, sh))}. Click to use."><span class="ghost-n">${v.passes.map((p) => p.n).join('·')}</span>${v.text.split(/\s+/).map((w, i) => (chg.has(i) ? `<b>${esc(w)}</b>` : esc(w))).join(' ')}${v.flow !== sh.version.flow ? ` <i>${v.flow}</i>` : ''}</div>`);
      g.addEventListener('click', () => HM.pickLine(sec, slot, v.key));
      main.appendChild(g);
    });
    withBelow(main, sh, slot);
    return row;
  };
  HEADS.ghosts = (sec) => ({ tools: passPills(sec, 'tabs') });

  ROWS.rail = (sec, slot) => {
    const sh = HM.shown(sec, slot), [row, main] = mk(sec, slot, ' rail-row');
    main.appendChild(lyric(sec, slot, sh)); withBelow(main, sh, slot);
    const sug = HM.suggestVersion(sec, slot, sh.passes, S().sectionDefault), rail = h('<div class="rail"></div>');
    sh.versions.forEach((v) => {
      const d = h(`<button class="rdot${v === sh.version ? ' on' : ''}${sug && v.key === sug.key ? ' sug' : ''}" title="${esc(v.text)} — ${esc(vMeta(v, sh))}"></button>`);
      d.addEventListener('click', () => HM.pickLine(sec, slot, v.key)); rail.appendChild(d);
    });
    row.appendChild(rail);
    return row;
  };
  HEADS.rail = (sec) => {
    const r = h('<div class="rail head-rail"></div>'), shown = HM.shownPass(sec), sug = HM.suggestPass(sec, HM.visiblePasses(sec), S().sectionDefault);
    HM.visiblePasses(sec).forEach((p) => {
      const d = h(`<button class="rdot big${p === shown ? ' on' : ''}${p === sug ? ' sug' : ''}" title="Take ${p.n} · ${pct(p.score.total)}">${p.n}</button>`);
      d.addEventListener('click', () => HM.pickPass(sec, p)); r.appendChild(d);
    });
    return { tools: r };
  };

  ROWS.cards = (sec, slot) => {
    const sh = HM.shown(sec, slot), [row, main] = mk(sec, slot);
    main.appendChild(lyric(sec, slot, sh));
    if (sh.versions.length > 1) {
      const chip = h(`<button class="count">+${sh.versions.length - 1}</button>`);
      chip.addEventListener('click', (e) => { e.stopPropagation(); openPop(chip, sh.versions.map((v) => altRow(sec, slot, v, sh))); });
      main.querySelector('.lyric').appendChild(chip);
    }
    withBelow(main, sh, slot);
    return row;
  };
  HEADS.cards = (sec) => {
    const ps = HM.visiblePasses(sec), shown = HM.shownPass(sec), i = ps.indexOf(shown);
    const car = h(`<div class="carousel"><button class="car-btn" aria-label="Previous take"><svg class="i"><use href="#i-chev-left"/></svg></button><div class="car-mid"><b>Take ${shown.n}</b><span>of ${ps.length} · ${HM.fmt(HM.timeOf(shown))}</span><div class="car-dots">${ps.map((p) => `<i class="${p === shown ? 'on' : ''}"></i>`).join('')}</div></div><button class="car-btn" aria-label="Next take"><svg class="i"><use href="#i-chev-right"/></svg></button></div>`);
    const [prev, next] = car.querySelectorAll('.car-btn');
    prev.disabled = i <= 0; next.disabled = i >= ps.length - 1;
    prev.addEventListener('click', () => HM.pickPass(sec, ps[i - 1]));
    next.addEventListener('click', () => HM.pickPass(sec, ps[i + 1]));
    return { after: car };
  };

  ROWS.diff = (sec, slot) => {
    const sh = HM.shown(sec, slot), [row, main] = mk(sec, slot), flex = new Set();
    sh.versions.filter((v) => v !== sh.version).forEach((v) => changedIdx(sh.version.text, v.text).forEach((k) => flex.add(k)));
    main.appendChild(lyric(sec, slot, sh, { flex, onFlex: (e, span, wi) => { if (!S().editing) e.stopPropagation(); openPop(span, sh.versions.map((v) => altRow(sec, slot, v, sh, { word: wi }))); } }));
    if (sh.versions.some((v) => v.flow !== sh.version.flow) && !flex.size) main.querySelector('.lyric').classList.add('flex-flow');
    withBelow(main, sh, slot);
    const vi = sh.versions.indexOf(sh.version);
    if (sh.versions.length > 1) {
      const key = `${sec.id}:${slot}`;
      const st = stepper('', vi, sh.versions.length, (d) => { S()._flash = key; HM.pickLine(sec, slot, sh.versions[vi + d].key); }, 'Flip this line between the ways you sang it');
      // The words that would swap light up only while you reach for the arrows (Nate 2026-10-14).
      st.addEventListener('mouseenter', () => row.classList.add('peek'));
      st.addEventListener('mouseleave', () => row.classList.remove('peek'));
      row.appendChild(st);
    }
    row.addEventListener('mouseenter', () => { S()._hoverKey = `${sec.id}:${slot}`; });
    if (S()._flash === `${sec.id}:${slot}`) { S()._flash = null; row.classList.add('flash'); setTimeout(() => row.classList.remove('flash'), 1100); }
    return row;
  };
  // ‹ › (the , and . keys): flip the line under the pointer, with the same wash on what changed.
  document.addEventListener('keydown', (e) => {
    if (!['<', '>', ',', '.'].includes(e.key) || e.metaKey || e.ctrlKey || e.target.isContentEditable || /INPUT|TEXTAREA|SELECT/.test(e.target.tagName)) return;
    const k = S()._hoverKey; if (!k) return;
    const [id, slot] = k.split(':'), sec = HM.sec(id); if (!sec) return;
    const sh = HM.shown(sec, +slot), i = sh.versions.indexOf(sh.version) + (e.key === '<' || e.key === ',' ? -1 : 1);
    if (!sh.versions[i]) return;
    e.preventDefault(); S()._flash = k; HM.pickLine(sec, +slot, sh.versions[i].key);
  });
  HEADS.diff = (sec) => { const ps = HM.visiblePasses(sec), i = ps.indexOf(HM.shownPass(sec)); return { tools: stepper('Take', i, ps.length, (d) => HM.pickPass(sec, ps[i + d]), 'Flip the whole section between takes') }; };

  ROWS.lanes = (sec, slot) => { const sh = HM.shown(sec, slot), [row, main] = mk(sec, slot); main.appendChild(lyric(sec, slot, sh)); withBelow(main, sh, slot); return row; };
  HEADS.lanes = (sec) => {
    const ps = HM.visiblePasses(sec), sug = HM.suggestPass(sec, ps, S().sectionDefault), shs = [];
    for (let slot = 0; slot < sec.slots; slot++) shs.push(HM.shown(sec, slot));
    const grid = h(`<div class="lanes" style="--cols:${sec.slots}"></div>`);
    grid.appendChild(h('<span class="lane-h"></span>'));
    shs.forEach((_, slot) => grid.appendChild(h(`<span class="lane-col">Line ${slot + 1}</span>`)));
    ps.forEach((p) => {
      const rh = h(`<button class="lane-h${p === HM.shownPass(sec) ? ' on' : ''}" title="Use all of take ${p.n}">${p === sug ? '<svg class="i"><use href="#i-spark"/></svg>' : ''}${p.n}</button>`);
      rh.addEventListener('click', () => HM.pickPass(sec, p)); grid.appendChild(rh);
      p.lines.forEach((ln, slot) => {
        const sh = shs[slot], on = sh.pass === p && sh.version.key === ln.key, same = sh.version.key === ln.key;
        const c = h(`<button class="cell${on ? ' on' : same ? ' same' : ''}" title="${esc(ln.text)}"><span>${esc(ln.text)}</span><i style="width:${pct(p.score.total)}"></i></button>`);
        c.addEventListener('click', () => HM.pickLine(sec, slot, ln.key)); grid.appendChild(c);
      });
    });
    return { after: grid };
  };

  ROWS.keys = (sec, slot) => {
    const sh = HM.shown(sec, slot), k = `${sec.id}:${slot}`, [row, main] = mk(sec, slot, ` keyrow${S().focus === k ? ' focus' : ''}`);
    main.appendChild(lyric(sec, slot, sh));
    if (sh.versions.length > 1) main.querySelector('.lyric').appendChild(h(`<span class="tag count-tag">${sh.versions.indexOf(sh.version) + 1}/${sh.versions.length}</span>`));
    withBelow(main, sh, slot);
    row.addEventListener('click', () => { S().focus = k; HM.renderNotes(); });
    return row;
  };
  HEADS.keys = () => ({ tools: h('<span class="kbd-hint"><kbd>↑</kbd><kbd>↓</kbd> line · <kbd>←</kbd><kbd>→</kbd> take</span>') });

  HM.ui = { h, esc, header, lyric, refs: () => lineRefs, resetRefs: () => { lineRefs = []; }, ROWS, HEADS };

  function hud() {
    const f = S().focus; if (S().flip !== 'keys' || !f || S().editing) return null;
    const [id, slot] = f.split(':'), sec = HM.sec(id); if (!sec || !HM.visiblePasses(sec).length) return null;
    const sh = HM.shown(sec, +slot);
    return h(`<div class="hud"><b>${esc(sec.name)} · line ${+slot + 1}</b><span>Version ${sh.versions.indexOf(sh.version) + 1} of ${sh.versions.length}</span><span>Take ${sh.pass.n} · ${HM.fmt(HM.timeOf(sh.pass))}</span><span>${sh.line.flow}</span></div>`);
  }
  HM.ui.hud = hud;

  HM.highlight = () => {
    const t = S().t;
    lineRefs.forEach((r) => {
      // Only while it's actually playing, and never while you edit or type: the other lines dim around the
      // one playing, and a paused playhead left in a line dimmed the whole sheet the moment you edited (Nate 2026-10-14).
      const inLine = S().playing && !S().editing && !S()._typing && t >= r.t0 && t < r.t1;
      r.el.classList.toggle('playing', inLine);
      let cur = -1; if (inLine) r.words.forEach((w, i) => { if (w.t <= t) cur = i; });
      r.words.forEach((w, i) => w.el.classList.toggle('now', i === cur));
    });
  };

  // Keyboard flip (variant 08).
  document.addEventListener('keydown', (e) => {
    if (S().flip !== 'keys' || !S().focus || e.target.isContentEditable || /INPUT|TEXTAREA|SELECT/.test(e.target.tagName)) return;
    const [id, slot] = S().focus.split(':'), sec = HM.sec(id), sh = HM.shown(sec, +slot);
    if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      const i = sh.versions.indexOf(sh.version) + (e.key === 'ArrowDown' ? 1 : -1);
      if (sh.versions[i]) HM.pickLine(sec, +slot, sh.versions[i].key); e.preventDefault();
    } else if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      const ps = HM.visiblePasses(sec), i = ps.indexOf(HM.shownPass(sec)) + (e.key === 'ArrowRight' ? 1 : -1);
      if (ps[i]) HM.pickPass(sec, ps[i]); e.preventDefault();
    }
  });
})(window.HM);
