/* Hot Mic design lab: the strip at the top (session waveform in solo, the beat in beat mode) + transport. */
(function (HM) {
  let host, canvas, ctx, tip, head, W = 0, H = 0, dpr = 1, colors = {}, drag = null, hits = [];
  const fmt = (t) => { t = Math.max(0, t); const m = Math.floor(t / 60), s = Math.floor(t % 60); return `${m}:${String(s).padStart(2, '0')}`; };
  HM.fmt = fmt;

  const isBeat = () => HM.S.mode === 'beat';
  HM.timeOf = (pass) => (isBeat() ? pass.beatAt : pass.at);
  HM.totalLen = () => (isBeat() ? (HM.host && !HM.beat.custom ? 0 : HM.beat.len) : HM.S.elapsed);
  function view() {
    if (isBeat()) return [0, HM.beat.len];
    const e = Math.max(1, HM.S.elapsed);
    if (HM.S.zoom === 'steps') return [0, [60, 120, 300, 600, 1200, 2400].find((s) => s >= e * 1.04) || e * 1.1];
    return [0, Math.max(45, e * 1.12)];
  }

  HM.strip = {
    init(el) {
      host = el;
      host.innerHTML = `<div class="strip-head"></div><div class="strip-canvas"><canvas></canvas><div class="strip-tip" hidden></div><div class="strip-drop" hidden><div><b>Drop a beat here</b><span>WAV, MP3, AIFF or M4A · or <button data-act-pick>choose a file</button></span></div></div><div class="strip-empty" hidden><button class="rec-btn big" data-big-rec><span></span></button><div><b>Ready when you are</b><span>Hit record or press R.</span><span class="import-hint">Got a voice memo? Drop it here or <button data-act-import>import a recording</button></span></div></div></div>`;
      host.querySelector('[data-big-rec]').addEventListener('click', () => HM.record());
      host.querySelector('[data-act-pick]').addEventListener('click', () => HM.pickBeat());
      head = host.querySelector('.strip-head');
      canvas = host.querySelector('canvas'); ctx = canvas.getContext('2d'); tip = host.querySelector('.strip-tip');
      new ResizeObserver(() => this.resize()).observe(host.querySelector('.strip-canvas'));
      canvas.addEventListener('mousedown', down);
      window.addEventListener('mousemove', move);
      window.addEventListener('mouseup', up);
      canvas.addEventListener('mouseleave', () => { tip.hidden = true; hoverX = null; draw(); });
      canvas.addEventListener('dblclick', (e) => { const [x, y] = local(e); if (isBeat() && zone(x, y).kind !== 'none' && y < ROW.loop[1]) HM.set({ loop: { ...HM.S.loop, on: !HM.S.loop.on }, loopPass: 1 }); });
    },
    resize() {
      const box = host.querySelector('.strip-canvas');
      dpr = window.devicePixelRatio || 1; H = isBeat() ? 150 : 100;
      const cs = getComputedStyle(box), padY = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
      W = canvas.clientWidth || box.clientWidth;
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
      canvas.style.height = `${H}px`; box.style.height = `${H + padY}px`;
      this.draw();
    },
    refresh() {
      const cs = getComputedStyle(host.querySelector('.strip-canvas') || host);
      ['wave', 'wave-played', 'tone-a', 'tone-b', 'tone-c', 'grid', 'faint', 'playhead', 'loop', 'rec', 'ink', 'surface'].forEach((k) => { colors[k] = cs.getPropertyValue(`--${k}`).trim() || '#888'; });
      this.head(); this.resize();
    },
    head() {
      const S = HM.S, playing = S.playing;
      HM.recPill();
      const left = isBeat()
        ? (HM.host && !HM.beat.custom
          ? `<span class="strip-title"><svg class="i"><use href="#i-wave"/></svg><b>No beat yet</b></span>`
          : `<span class="strip-title"><svg class="i"><use href="#i-wave"/></svg><b>${HM.ui.esc(String(HM.beat.name))}</b><span class="dim">${Math.round(HM.BPM)} BPM · ${fmt(HM.beat.len)}</span></span>`) + `<button class="mini-btn" data-act="beat">${HM.beat.custom ? "Replace beat" : "Load a beat"}</button>`
        : `<span class="strip-title">${S.growing ? `<span class="rec-dot"></span><b>Recording</b>` : '<svg class="i"><use href="#i-wave"/></svg><b>Whole session</b>'}<span class="dim" data-live>${fmt(S.elapsed)} · ${HM.countTakes()} takes</span></span>`;
      const L = S.loop, bars = Math.round((L.b - L.a) / HM.BAR);
      const loop = isBeat() ? `<button class="tbtn${L.on ? ' on' : ''}" data-act="loop" title="Loop on/off (L). Drag the bar above the beat to move it, drag its ends to resize."><svg class="i"><use href="#i-loop"/></svg></button>` : '';
      const lp = '';
      head.innerHTML = `<div class="strip-left">${left}</div><div class="transport">${lp}
        <button class="tbtn stop" data-act="stop" title="Stop · press again to go back to the start"><span class="sq"></span></button>
        <button class="rec-btn${S.growing ? ' on' : ''}" data-act="rec" title="${S.growing ? 'Stop recording' : 'Record'} (R)"><span></span></button>
        <button class="tbtn play" data-act="play" title="Play / pause (space)"><svg class="i"><use href="#i-${playing ? 'pause' : 'play'}"/></svg></button>
        ${loop}${isBeat() ? '' : '<button class="tbtn" data-act-import title="Import a recording (or drop one anywhere on the window)"><svg class="i"><use href="#i-import"/></svg></button>'}<button class="tbtn snap${S.snap ? ' on' : ''}" data-act="snap" title="Snap ${S.snap ? 'on' : 'off'}: ${isBeat() ? 'clicks and loops land on bars' : 'clicks land on the nearest transient (the start of a word or a strum)'}">SNAP</button><button class="tbtn${HM.audio.on ? '' : ' off'}" data-act="sound" title="Demo sound on/off"><svg class="i"><use href="#i-${HM.audio.on ? 'sound' : 'mute'}"/></svg></button><span class="clock" data-clock>${fmt(S.t)} / ${fmt(HM.totalLen())}</span></div>`;
      head.querySelectorAll('[data-act]').forEach((b) => b.addEventListener('click', () => {
        const a = b.dataset.act;
        if (a === 'play') HM.play();
        if (a === 'stop') HM.stop();
        if (a === 'snap') HM.set({ snap: !S.snap });
        if (a === 'rec') HM.record();
        if (a === 'beat') HM.pickBeat();
        if (a === 'loop') HM.set({ loop: { ...S.loop, on: !S.loop.on }, loopPass: 1 });
        if (a === 'sound') { HM.audio.toggle(); HM.strip.head(); }
      }));
    },
    draw,
  };
  function emptyState() {
    const el = host && host.querySelector('.strip-empty'); if (!el) return;
    el.hidden = !(HM.S.elapsed === 0 && !HM.S.growing && !isBeat());
    host.querySelector('.strip-drop').hidden = !(isBeat() && (HM.S.fresh || HM.host) && !HM.beat.custom);
  }

  // Beat-mode rows, top to bottom (y ranges in px).
  const ROW = { ruler: [0, 13], loop: [14, 28], parts: [30, 42], wave: [46, 100], lanes: [104, 150] };
  const barLabel = (t) => String(Math.round(t / HM.BAR) + 1);
  // Where a click lands: nearest bar in beat mode (Option = nearest beat); nearest sung word in solo.
  function snapClick(t, e) {
    if (isBeat()) { const unit = e && e.altKey ? HM.BEAT : HM.S.snap ? HM.BAR : HM.BEAT; return Math.max(0, Math.min(HM.beat.len - 0.01, Math.round(t / unit) * unit)); }
    // Freestyle: snap off = exactly where you clicked; snap on = the nearest transient (the attack
    // of a word, a breath, a strum) within a couple of seconds.
    if (!HM.S.snap || (e && e.altKey)) return Math.max(0, Math.min(HM.S.elapsed, t));
    let best = t, d = 2.5;
    transients().forEach((tt) => { if (tt <= HM.S.elapsed && Math.abs(tt - t) < d) { d = Math.abs(tt - t); best = tt; } });
    return Math.max(0, Math.min(HM.S.elapsed, best));
  }
  let hoverX = null, onsets = null;
  // Onsets in the recording: where the level jumps up sharply after being quieter.
  function transients() {
    if (onsets) return onsets;
    const env = HM.envelopes.session, rate = HM.envelopes.sRate, out = [];
    let last = -1;
    for (let i = 2; i < env.length; i++) {
      const rise = env[i] - Math.min(env[i - 1], env[i - 2]);
      if (rise > 0.18 && env[i] > 0.3 && (i - last) / rate > 0.18) { out.push((i - 1) / rate); last = i; }
    }
    return (onsets = out);
  }
  function snapT(t, e) {
    const unit = e && e.altKey ? HM.BEAT : HM.S.snap ? HM.BAR : HM.BEAT / 4;
    return Math.max(0, Math.min(HM.beat.len, Math.round(t / unit) * unit));
  }

  // Everything in the panel sits inside the frame's rounded corners: time maps onto W minus a pad each side,
  // so the start marker and playhead at 0:00 no longer poke past the chrome frame (Nate 2026-10-14).
  const PAD = 12;
  const xOf = (t) => { const [a, b] = view(); return PAD + ((t - a) / (b - a)) * (W - 2 * PAD); };
  const tOf = (x) => { const [a, b] = view(); return a + ((x - PAD) / (W - 2 * PAD)) * (b - a); };

  function wave(env, rate, y0, h, upto) {
    const [a, b] = view(), style = HM.S.wave, mid = y0 + h / 2, limit = isBeat() ? HM.beat.len : HM.S.elapsed;
    const col = style === 'bars' ? 3 : style === 'dots' ? 4 : 1.5;
    const amps = [];
    for (let x = 0; x < W; x += col) {
      const t0 = a + (x / W) * (b - a), t1 = a + ((x + col) / W) * (b - a);
      if (t0 >= limit) break;
      let m = 0, sum = 0, n = 0; const i0 = Math.floor(t0 * rate), i1 = Math.max(i0 + 1, Math.floor(Math.min(t1, limit) * rate));
      for (let i = i0; i < i1 && i < env.length; i++) { m = Math.max(m, env[i]); sum += env[i]; n++; }
      if (isBeat() && n) m = Math.min(1, (sum / n) * 1.25 + m * 0.25);
      amps.push([x, m]);
    }
    const colorAt = (x) => (tOf(x) <= upto ? colors['wave-played'] : colors.wave);
    if (style === 'bars') {
      amps.forEach(([x, m]) => { const hh = Math.max(1.5, m * h); ctx.fillStyle = colorAt(x); rr(x, mid - hh / 2, 2, hh, 1); ctx.fill(); });
    } else if (style === 'dots') {
      amps.forEach(([x, m]) => { const n = Math.max(1, Math.round(m * 9)); ctx.fillStyle = colorAt(x); for (let k = 0; k < n; k++) { const dy = (k - (n - 1) / 2) * (h / 10); ctx.beginPath(); ctx.arc(x + 1.5, mid + dy, 1.15, 0, 7); ctx.fill(); } });
    } else {
      const xp = amps.length ? Math.min(W, xOf(upto)) : 0;
      [[0, xp, colors['wave-played']], [xp, W, colors.wave]].forEach(([x0, x1, c]) => {
        const seg = amps.filter(([x]) => x >= x0 - 1.5 && x <= x1);
        if (seg.length < 2) return;
        ctx.beginPath();
        seg.forEach(([x, m], i) => { const y = mid - (m * h) / 2; if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y); });
        if (style === 'mirror') {
          for (let i = seg.length - 1; i >= 0; i--) ctx.lineTo(seg[i][0], mid + (seg[i][1] * h) / 2);
          ctx.closePath(); ctx.fillStyle = c; ctx.fill();
        } else {
          ctx.strokeStyle = c; ctx.lineWidth = 1.2; ctx.stroke();
          ctx.beginPath(); seg.forEach(([x, m], i) => { const y = mid + (m * h) / 2; if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y); }); ctx.stroke();
          ctx.globalAlpha = 0.12; ctx.fillStyle = c; ctx.fillRect(seg[0][0], mid - 0.5, seg[seg.length - 1][0] - seg[0][0], 1); ctx.globalAlpha = 1;
        }
      });
    }
    return amps.length ? amps[amps.length - 1][0] : 0;
  }

  function rr(x, y, w, h, r) { ctx.beginPath(); ctx.roundRect ? ctx.roundRect(x, y, w, h, r) : ctx.rect(x, y, w, h); }

  function ruler(y) {
    const [a, b] = view(), span = b - a;
    // Ruler labels readable on the dark panel (Nate 2026-10-14: "hard to read"): ~70% ink, mono, a touch bigger.
    const label = () => { ctx.fillStyle = colors.ink; ctx.globalAlpha = 0.72; };
    ctx.font = '600 10.5px ui-monospace, "Geist Mono", Menlo, monospace'; ctx.textBaseline = 'top';
    if (isBeat()) {
      for (let bar = 0; bar <= HM.beat.bars; bar++) {
        const x = xOf(bar * HM.BAR); ctx.fillStyle = colors.grid; ctx.fillRect(x, y + (bar % 4 ? 9 : 4), 1, bar % 4 ? 3 : 8);
        if (bar % 4 === 0 && bar < HM.beat.bars) { label(); ctx.fillText(String(bar + 1), x + 3, y + 1); ctx.globalAlpha = 1; }
      }
      return;
    }
    const step = [10, 15, 30, 60, 120, 300, 600].find((s) => span / s <= 12) || 600;
    for (let t = 0; t <= b; t += step) {
      const x = xOf(t); ctx.fillStyle = colors.grid; ctx.fillRect(x, y + 4, 1, 8);
      if (x < W - 34) { label(); ctx.fillText(fmt(t), x + 3, y + 1); ctx.globalAlpha = 1; }
    }
  }

  function draw() {
    if (!ctx || !W) return;
    emptyState();
    const S = HM.S, beat = isBeat();
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, W, H); hits = [];
    // In the app with no beat of yours loaded: an empty strip under the drop zone (the lab's sample beat
    // was showing its name, sections, waveform and loop).
    if (beat && HM.host && !HM.beat.custom) return;
    ruler(0);
    const upto = S.t;
    if (beat) {
      const L = S.loop, lx0 = xOf(L.a), lx1 = xOf(L.b);
      if (L.on) { ctx.fillStyle = colors.loop; ctx.globalAlpha = 0.12; ctx.fillRect(lx0, ROW.parts[0], lx1 - lx0, H - ROW.parts[0]); ctx.globalAlpha = 1; }
      ctx.fillStyle = colors.grid; ctx.globalAlpha = 0.25; ctx.fillRect(0, ROW.loop[0], W, ROW.loop[1] - ROW.loop[0]); ctx.globalAlpha = 1;
      HM.beat.parts.forEach(([nm, b0, b1]) => {
        const x0 = xOf(b0 * HM.BAR), x1 = xOf(b1 * HM.BAR);
        ctx.fillStyle = colors.grid; ctx.globalAlpha = 0.35; rr(x0 + 1, ROW.parts[0], x1 - x0 - 2, 12, 3); ctx.fill(); ctx.globalAlpha = 1;
        ctx.fillStyle = colors.faint; ctx.font = '10px -apple-system, system-ui, sans-serif'; ctx.textBaseline = 'middle';
        if (x1 - x0 > 30) ctx.fillText(nm, x0 + 6, ROW.parts[0] + 6.5);
      });
      wave(HM.envelopes.beat, HM.envelopes.bRate, ROW.wave[0], ROW.wave[1] - ROW.wave[0], upto);
      lanes(ROW.lanes[0]);
      // the loop brace (Ableton-style): solid when on, grey when off, handles on both ends
      const by = ROW.loop[0] + 2, bh = ROW.loop[1] - ROW.loop[0] - 4;
      ctx.fillStyle = L.on ? colors.loop : colors.grid; rr(lx0, by, lx1 - lx0, bh, 3); ctx.fill();
      ctx.fillStyle = L.on ? colors.surface : colors.faint; ctx.globalAlpha = 0.85;
      rr(lx0 + 2, by + 3, 2, bh - 6, 1); ctx.fill(); rr(lx1 - 4, by + 3, 2, bh - 6, 1); ctx.fill(); ctx.globalAlpha = 1;
      if (lx1 - lx0 > 70) {
        ctx.fillStyle = L.on ? colors.surface : colors.ink; ctx.font = '600 10px -apple-system, system-ui, sans-serif'; ctx.textBaseline = 'middle';
        ctx.fillText(`${barLabel(L.a)} → ${barLabel(L.b)}  ·  ${Math.round((L.b - L.a) / HM.BAR)} bars`, lx0 + 9, by + bh / 2 + 0.5);
      }
      if (L.on) { ctx.fillStyle = colors.loop; ctx.fillRect(lx0, ROW.parts[0], 1.5, H - ROW.parts[0]); ctx.fillRect(lx1 - 1.5, ROW.parts[0], 1.5, H - ROW.parts[0]); }
    } else {
      sectionBlocks(14, H - 14);
      const edge = wave(HM.envelopes.session, HM.envelopes.sRate, 16, 48, upto);
      takeChunks(TAKES[0], TAKES[1] - TAKES[0]);
      hiddenAndSelection();
      if (edge < W - 4) {
        ctx.strokeStyle = colors.grid; ctx.setLineDash([2, 4]); ctx.beginPath(); ctx.moveTo(edge + 4, 40); ctx.lineTo(W, 40); ctx.stroke(); ctx.setLineDash([]);
        if (S.growing) { const pulse = 0.55 + 0.45 * Math.sin(performance.now() / 180); ctx.fillStyle = colors.rec; ctx.globalAlpha = pulse; ctx.beginPath(); ctx.arc(edge + 4, 40, 4, 0, 7); ctx.fill(); ctx.globalAlpha = 1; }
      }
      markers(82);
    }
    if (hoverX !== null && !drag) { ctx.fillStyle = colors.ink; ctx.globalAlpha = 0.25; ctx.fillRect(hoverX - 0.5, 12, 1, H - 12); ctx.globalAlpha = 1; }
    if (!S.growing || beat) {
      const cx = xOf(S.cue || 0); ctx.fillStyle = colors.ink; ctx.globalAlpha = 0.9;
      ctx.beginPath(); ctx.moveTo(cx - 5, 0); ctx.lineTo(cx + 5, 0); ctx.lineTo(cx, 7); ctx.fill();
      ctx.globalAlpha = 0.35; ctx.fillRect(cx - 0.5, 7, 1, H - 7); ctx.globalAlpha = 1;
    }
    if (!S.growing || beat) {
      const x = xOf(S.t); ctx.fillStyle = colors.playhead; ctx.fillRect(x - 0.75, 12, 1.5, H - 12);
      ctx.beginPath(); ctx.moveTo(x - 4, 12); ctx.lineTo(x + 4, 12); ctx.lineTo(x, 17); ctx.fill();
    }
  }

  // Takes as big colored chunks (like arrangement markers in a DAW). Click one to
  // select it, drag across the strip to select a stretch; Delete hides it from the session (⌘Z undoes).
  const TAKES = [66, 80];
  HM.takeSpans = () => {
    const list = HM.real && HM.real.takes ? HM.real.takes.map((t) => ({ a: t.at, b: t.at + t.dur }))
      : HM.sections.flatMap((sec) => HM.visiblePasses(sec).map((p) => ({ a: p.at, b: p.at + p.dur })));
    return list.filter((t) => !HM.isHidden(t.a, t.b)).sort((x, y) => x.a - y.a);
  };
  function takeChunks(y, h) {
    HM.takeSpans().forEach((t, i) => {
      const x0 = xOf(t.a), x1 = Math.max(x0 + 5, xOf(t.b)), col = colors[`tone-${'abc'[i % 3]}`];
      ctx.fillStyle = col; ctx.globalAlpha = 0.85; rr(x0, y, x1 - x0, h, 4); ctx.fill(); ctx.globalAlpha = 1;
      if (x1 - x0 > 40) { ctx.fillStyle = colors.surface; ctx.font = '700 9.5px -apple-system, system-ui, sans-serif'; ctx.textBaseline = 'middle'; ctx.fillText(`Take ${i + 1}`, x0 + 5, y + h / 2 + 0.5); }
      hits.push({ x0, x1, y0: y, y1: y + h, take: t });
    });
  }
  function hiddenAndSelection() {
    HM.hiddenRanges().forEach((r) => {
      const x0 = xOf(r.a), x1 = Math.max(x0 + 2, xOf(r.b));
      ctx.fillStyle = colors.surface; ctx.globalAlpha = 0.7; ctx.fillRect(x0, 14, x1 - x0, H - 14); ctx.globalAlpha = 1;
    });
    const sel = HM.S.sel; if (!sel) return;
    const x0 = xOf(sel.a), x1 = Math.max(x0 + 2, xOf(sel.b));
    ctx.fillStyle = colors.ink; ctx.globalAlpha = 0.14; ctx.fillRect(x0, 14, x1 - x0, H - 14); ctx.globalAlpha = 1;
    ctx.strokeStyle = colors.ink; ctx.lineWidth = 1.5; ctx.strokeRect(x0 + 0.75, 14.75, x1 - x0 - 1.5, H - 16);
  }

  // Big colored blocks behind the waveform, one per named section, with its name on top.
  function sectionBlocks(y, h) {
    const spans = HM.sheet && HM.sheet.spans ? HM.sheet.spans() : [];
    spans.forEach((sp) => {
      const x0 = xOf(sp.a), x1 = Math.max(x0 + 6, xOf(sp.b)), col = colors[`tone-${sp.tone}`];
      ctx.fillStyle = col; ctx.globalAlpha = 0.16; rr(x0, y, x1 - x0, h, 5); ctx.fill();
      ctx.globalAlpha = 0.9; rr(x0, y, x1 - x0, 13, 4); ctx.fill(); ctx.globalAlpha = 1;
      if (x1 - x0 > 28) { ctx.fillStyle = colors.surface; ctx.font = '700 10px -apple-system, system-ui, sans-serif'; ctx.textBaseline = 'middle'; ctx.fillText(sp.name, x0 + 6, y + 7); }
    });
  }

  function markers(y) {
    HM.sections.forEach((sec) => {
      const shown = HM.shownPass(sec);
      HM.visiblePasses(sec).forEach((p) => {
        const x0 = xOf(p.at), x1 = Math.max(x0 + 4, xOf(p.at + p.dur)), on = shown === p;
        ctx.fillStyle = colors[`tone-${sec.tone}`]; ctx.globalAlpha = on ? 1 : 0.42;
        rr(x0, y, x1 - x0, 12, 4); ctx.fill(); ctx.globalAlpha = 1;
        if (on) { ctx.strokeStyle = colors.ink; ctx.lineWidth = 1.2; rr(x0 - 1, y - 1, x1 - x0 + 2, 14, 5); ctx.stroke(); }
        if (x1 - x0 > 34) { ctx.fillStyle = colors.surface; ctx.font = '600 9px -apple-system, system-ui, sans-serif'; ctx.textBaseline = 'middle'; ctx.fillText(`${short(sec)} ${p.n}`, x0 + 4, y + 6.5); }
        hits.push({ x0, x1, y0: y, y1: y + 12, sec, p });
      });
    });
  }

  function lanes(y) {
    const placed = [];
    HM.sections.forEach((sec) => {
      const shown = HM.shownPass(sec);
      HM.visiblePasses(sec).forEach((p) => {
        let lane = 0; while (placed.some((q) => q.lane === lane && q.a < p.beatAt + p.dur - 0.01 && p.beatAt < q.b - 0.01)) lane++;
        placed.push({ lane, a: p.beatAt, b: p.beatAt + p.dur });
        const x0 = xOf(p.beatAt), x1 = xOf(p.beatAt + p.dur), yy = y + lane * 9, on = shown === p;
        ctx.fillStyle = colors[`tone-${sec.tone}`]; ctx.globalAlpha = on ? 1 : 0.38; rr(x0 + 1, yy, x1 - x0 - 2, 7, 3.5); ctx.fill(); ctx.globalAlpha = 1;
        if (on) { ctx.strokeStyle = colors.ink; ctx.lineWidth = 1; rr(x0, yy - 1, x1 - x0, 9, 4); ctx.stroke(); }
        hits.push({ x0, x1, y0: yy - 1, y1: yy + 8, sec, p });
      });
    });
  }
  const short = (sec) => ({ v1: 'V1', hook: 'Hook', v2: 'V2' }[sec.id] || sec.name);

  function local(e) { const r = canvas.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; }
  function hitAt(x, y) { return hits.find((h) => x >= h.x0 && x <= h.x1 && y >= h.y0 - 2 && y <= h.y1 + 2); }
  // What's under the pointer in beat mode: the brace's ends, its body, the empty loop row, or the beat.
  function zone(x, y) {
    if (!isBeat()) return { kind: 'none' };
    const L = HM.S.loop, x0 = xOf(L.a), x1 = xOf(L.b);
    if (y >= ROW.loop[0] - 2 && y <= ROW.loop[1] + 1) {
      if (Math.abs(x - x0) <= 7) return { kind: 'start' };
      if (Math.abs(x - x1) <= 7) return { kind: 'end' };
      if (x > x0 && x < x1) return { kind: 'move' };
      return { kind: 'draw' };
    }
    return { kind: y < ROW.loop[0] ? 'none' : 'beat' };
  }
  const CURSOR = { start: 'ew-resize', end: 'ew-resize', move: 'grab', draw: 'copy', beat: 'crosshair', none: 'default' };
  function down(e) {
    const [x, y] = local(e), z = zone(x, y);
    if (!isBeat()) { const h = hitAt(x, y); drag = { x, y, moved: false, kind: h && h.take ? 'take' : 'select', take: h && h.take, t: tOf(x) }; return; }
    drag = { x, y, moved: false, kind: z.kind, a: HM.S.loop.a, b: HM.S.loop.b, t: tOf(x) };
    if (z.kind === 'move') canvas.style.cursor = 'grabbing';
  }
  function move(e) {
    if (!canvas) return;
    const [x, y] = local(e);
    if (drag && !isBeat() && (drag.moved || Math.abs(x - drag.x) > 3)) {
      drag.moved = true; const t = tOf(x);
      HM.S.sel = { a: Math.max(0, Math.min(drag.t, t)), b: Math.min(HM.totalLen(), Math.max(drag.t, t)) };
      tip.hidden = true; draw(); return;
    }
    if (drag && isBeat() && (drag.moved || Math.abs(x - drag.x) > 3)) {
      drag.moved = true;
      const S = HM.S, L = S.loop, t = tOf(x), min = e.altKey ? HM.BEAT : HM.S.snap ? HM.BAR : HM.BEAT;
      if (drag.kind === 'move') {
        const len = drag.b - drag.a, a = Math.max(0, Math.min(HM.beat.len - len, snapT(drag.a + (t - drag.t), e)));
        S.loop = { ...L, a, b: a + len };
      } else if (drag.kind === 'start') S.loop = { ...L, a: Math.min(snapT(t, e), L.b - min) };
      else if (drag.kind === 'end') S.loop = { ...L, b: Math.max(snapT(t, e), L.a + min) };
      else if (drag.kind === 'draw' || drag.kind === 'beat') {
        let a = snapT(Math.min(drag.t, t), e), b = snapT(Math.max(drag.t, t), e);
        if (b - a < min) b = a + min;
        S.loop = { a, b: Math.min(HM.beat.len, b), on: true };
      }
      tip.hidden = true; draw(); return;
    }
    if (e.target !== canvas) return;
    const h = hitAt(x, y), z = zone(x, y);
    const nh = (!h && (!isBeat() || z.kind === 'beat' || z.kind === 'none')) ? xOf(snapClick(tOf(x), e)) : null;
    if (nh !== hoverX) { hoverX = nh; draw(); }
    canvas.style.cursor = drag && drag.kind === 'move' ? 'grabbing' : h ? 'pointer' : isBeat() ? CURSOR[z.kind] : 'text';
    if (h) {
      const words = h.p.lines.map((l) => l.text.split(' ').slice(0, 4).join(' ')).slice(0, 1)[0];
      tip.innerHTML = `<b>${HM.ui.esc(h.sec.name)} · Pass ${h.p.n}</b><span>${fmt(h.p.at)} into the session · ${Math.round(h.p.score.total * 100)}%</span><i>“${HM.ui.esc(words)}…”</i>`;
      tip.hidden = false; tip.style.left = `${Math.min(W - 200, Math.max(0, x - 20))}px`;
    } else tip.hidden = true;
  }
  function up(e) {
    if (!drag) return;
    const d = drag; drag = null;
    if (!isBeat()) {
      if (d.moved) return;                                   // a range is selected
      if (d.take) { HM.S.sel = { a: d.take.a, b: d.take.b }; draw(); return; }
      if (HM.S.sel) { HM.S.sel = null; draw(); }
    }
    if (d.moved) { HM.set({ loop: HM.S.loop, loopPass: 1 }); return; }
    if (e.target !== canvas) return;
    if (['start', 'end', 'move', 'draw'].includes(d.kind)) { HM.seek(d.kind === 'end' ? HM.S.loop.b - HM.BAR : HM.S.loop.a, HM.S.playing); return; }
    const h = hitAt(d.x, d.y);
    if (h) { HM.pickPass(h.sec, h.p); HM.seek(HM.timeOf(h.p), true); return; }
    HM.seek(snapClick(tOf(d.x), e), HM.S.playing);
  }

  // ---------- transport ----------
  let last = 0, raf = 0;
  function tick(now) {
    const S = HM.S, dt = Math.min(0.1, (now - last) / 1000); last = now;
    if (S.growing && HM.host) {
      S.elapsed += dt;                                // smooth between the app's 20/s clock reports
      const live = head.querySelector('[data-live]'); if (live) live.textContent = `${fmt(S.elapsed)} · ${HM.countTakes()} takes`;
      const ck = head.querySelector('[data-clock]'); if (ck && !isBeat()) ck.textContent = `${fmt(S.elapsed)}`;
    } else if (S.growing) {
      if (!S.sim && !S.micLive) S.elapsed = Math.min(HM.sessionLen, S.elapsed + dt * 20);
      const n = HM.countTakes();
      if (n !== S._takes) { S._takes = n; HM.renderNotes(); }
      const live = head.querySelector('[data-live]'); if (live) live.textContent = `${fmt(S.elapsed)} · ${n} takes`;
      const ck = head.querySelector('[data-clock]'); if (ck && !isBeat()) ck.textContent = `${fmt(S.elapsed)}`;
      if (S.elapsed >= HM.sessionLen) { S.growing = false; S.playing = false; HM.audio.stop(); HM.render(); }
    }
    if (S.playing) {
      const was = S.t, clock = isBeat() && HM.audio.beatClock ? HM.audio.beatClock() : null;
      S.t = clock ?? S.t + dt;
      // The loop wraps: on the beat's own clock, or (no beat loaded) whenever the playhead reaches its end.
      const wrapped = clock !== null ? S.t < was - 0.05 : isBeat() && S.loop.on && S.t >= S.loop.b && was < S.loop.b + 0.05;
      if (clock === null && wrapped) S.t = S.loop.a + (S.t - S.loop.b);
      if (!isBeat()) { const r = HM.hiddenRanges().find((h) => S.t >= h.a && S.t < h.b); if (r) S.t = r.b; }   // deleted stretches are skipped
      if (wrapped) { S.loopPass += 1; const lp = head.querySelector('[data-pass]'); if (lp) lp.textContent = S.loopPass; }
      if (S.t >= HM.totalLen()) { S.t = S.returnMode ? S.cue || 0 : 0; S.playing = false; HM.audio.stop(); HM.strip.head(); }
      else HM.audio.pump();
      const c = head.querySelector('[data-clock]'); if (c) c.textContent = `${fmt(S.t)} / ${fmt(HM.totalLen())}`;
      HM.highlight();
    }
    draw();
    raf = S.playing || S.growing ? requestAnimationFrame(tick) : 0;
  }
  HM.record = () => {
    const S = HM.S;
    if (HM.host) { HM.host.post({ cmd: 'record', on: !S.growing, mode: S.mode }); return; }
    if (S.growing) { S.growing = false; S.playing = false; HM.audio.stop(); HM.render(); return; }
    if (S.elapsed >= HM.sessionLen - 1) HM.newSession();
    S.growing = true; S.editing = false;
    if (isBeat()) { S.t = S.loop.on ? S.loop.a : S.cue || 0; S.playing = true; HM.audio.start(); }
    HM.render(); HM.kick();
  };
  // Ableton transport: play always starts from the marker (restarts if already playing);
  // stop stops and returns to the marker; stop again sends the marker back to the beginning.
  HM.play = () => { const S = HM.S; if (S.playing && S.returnMode) { S.playing = false; HM.audio.stop(); } HM.toggle(); };
  HM.stop = () => {
    const S = HM.S;
    if (S.growing) { HM.record(); return; }
    if (S.playing) { S.playing = false; HM.audio.stop(); S.t = Math.min(S.cue || 0, HM.totalLen()); HM.strip.head(); draw(); HM.highlight(); return; }
    S.cue = 0; S.t = 0; S.loopPass = 1; HM.strip.head(); draw(); HM.highlight();
  };
  HM.kick = () => { if (!raf) { last = performance.now(); raf = requestAnimationFrame(tick); } };
  HM.toggle = () => {
    const S = HM.S; S.playing = !S.playing;
    // Return (Ableton): always start from the marker, pausing jumps back to it.
    // Resume (default, like a video): pause holds the spot, play carries on from it.
    if (S.returnMode) S.t = Math.min(S.cue || 0, HM.totalLen());
    else if (S.playing && S.t >= HM.totalLen() - 0.05) S.t = 0;
    if (S.playing && isBeat() && S.loop.on && (S.t < S.loop.a || S.t >= S.loop.b)) { S.t = S.loop.a; S.loopPass = 1; }
    if (!S.playing) draw();
    if (HM.S.playing) HM.audio.start(); else HM.audio.stop();
    HM.strip.head(); HM.kick(); HM.highlight();
  };
  HM.seek = (t, play) => {
    HM.S.t = Math.max(0, Math.min(HM.totalLen(), t)); HM.S.cue = HM.S.t;
    if (play !== undefined) HM.S.playing = !!play;
    HM.audio.stop();                                   // the old spot stops, always
    if (HM.S.playing) HM.audio.start();
    HM.strip.head(); draw(); HM.highlight(); HM.kick();
  };
})(window.HM);
