/* Hot Mic design lab: state, picks, window chrome, sessions panel. */
(function (HM) {
  const STORE = 'hotmicLab2';
  const DEFAULTS = {
    mode: 'solo', style: 'vintage', look: 'tube', texture: 'felt-charcoal', accent: 'lilac', flip: 'diff', music: 'over', shapes: 'off', wave: 'bars', tune: 'chips', names: 'solo', side: 'list', font: 'geist', secMark: 'rail', chords: 'on',
    sidebar: true, panel: true, pickBy: 'section', sectionDefault: 'best', zoom: 'continuous', snap: true,
    key: null, bySession: {}, picks: {}, linePicks: {}, edits: {}, open: {}, focus: null, stars: { flip: ['diff'], music: ['over'] }, breaks: { solo: {}, beat: null }, returnMode: false, mic: 'apollo',
  };
  const TRANSIENT = { t: 0, playing: false, growing: false, elapsed: HM.sessionLen, loop: { a: 4 * HM.BAR, b: 12 * HM.BAR, on: false }, loopPass: 1, editing: false, cue: 0 };

  function load() {
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem(STORE) || '{}'); } catch (e) { saved = {}; }
    const S = { ...DEFAULTS, ...saved, ...TRANSIENT };
    S.returnMode = false;      // Replay retired (Nate 2026-10-12): play/pause always carry on like a video
    // Old looks/fonts were retired on 2026-10-12; map any saved pick onto the new defaults.
    // Nate's settled picks (2026-10-12): stick with them.
    Object.assign(S, { flip: 'diff', music: 'over', side: 'list', font: 'grotesk', pickBy: 'section', sectionDefault: 'recent', zoom: 'continuous', wave: 'bars' });
    if (!S.accent || ['amber', 'ice'].includes(S.accent)) S.accent = 'lilac';
    const LOOKS = ['tube', 'tube-light'], FONTS = ['geist', 'grotesk', 'serif', 'mono'];
    if (!LOOKS.includes(S.look)) S.look = 'tube';
    if (!['vintage', 'modern', 'notebook'].includes(S.style)) S.style = 'vintage';
    if (!FONTS.includes(S.font)) S.font = 'geist';
    if (S.stars.look) S.stars.look = S.stars.look.filter((v) => LOOKS.includes(v));
    if (S.stars.font) S.stars.font = S.stars.font.filter((v) => FONTS.includes(v));
    // #look=night&flip=lanes&mode=beat&elapsed=400 overrides for screenshots and sharing.
    new URLSearchParams(location.hash.slice(1)).forEach((v, k) => {
      if (k === 'elapsed' || k === 't') S[k] = +v;
      else if (k === 'open') S.open = { [v]: true };
      else if (k === 'loop') S.loop = { ...S.loop, on: v !== '0' };
      else if (k === 'only') document.documentElement.classList.add(`only-${v}`);
      else if (k === 'star') { const [dk, dv] = v.split(':'); if (dk && dv) { S.stars = { ...S.stars, [dk]: [...new Set([...(S.stars[dk] || []), dv])] }; S._starFromHash = true; } }
      else if (['sidebar', 'panel', 'snap'].includes(k)) S[k] = v !== '0';
      else S[k] = v;
    });
    return S;
  }
  HM.S = load();
  HM.save = () => {
    const out = {};
    Object.keys(DEFAULTS).forEach((k) => { out[k] = HM.S[k]; });
    try { localStorage.setItem(STORE, JSON.stringify(out)); } catch (e) { /* private window: picks just won't stick */ }
  };
  // Another tab (the accent gallery) changed stars or the accent: pick it up live.
  window.addEventListener('storage', (e) => {
    if (e.key !== STORE || !e.newValue || document.documentElement.classList.contains('only-strip')) return;
    try { const d = JSON.parse(e.newValue); if (d.stars) HM.S.stars = d.stars; if (d.accent) HM.S.accent = d.accent; if (d.look) HM.S.look = d.look; HM.render(); } catch (err) { /* ignore */ }
  });
  HM.set = (patch) => { Object.assign(HM.S, patch); HM.save(); HM.render(); };
  HM.newSession = () => HM.set({ fresh: true, elapsed: 0, t: 0, cue: 0, growing: false, playing: false, picks: {}, linePicks: {}, edits: {}, open: {}, breaks: { solo: {}, beat: null }, key: null });
  HM.demoSession = () => HM.set({ fresh: false, elapsed: HM.sessionLen, growing: false, playing: false, t: 0, cue: 0 });
  HM.reset = () => { try { localStorage.removeItem(STORE); } catch (e) { /* ignore */ } location.hash = ''; location.reload(); };

  // ---------- picks ----------
  // Ranges you deleted from the session (hidden, never erased: the audio stays). From the app, or kept here in the lab.
  HM.hiddenRanges = () => [...((HM.real && HM.real.hidden) || []), ...(HM.S.hiddenLocal || [])];
  HM.isHidden = (a, b) => HM.hiddenRanges().some((r) => (a + b) / 2 >= r.a && (a + b) / 2 <= r.b);
  HM.visiblePasses = (sec) => (HM.host ? sec.passes : sec.passes.filter((p) => p.at + p.dur <= HM.S.elapsed + 0.01)).filter((p) => !HM.isHidden(p.at, p.at + p.dur));
  HM.countTakes = () => (HM.real ? new Set(HM.sections.flatMap((s) => HM.visiblePasses(s).map((p) => p.real.takeID).filter((id) => id && id !== 'typed'))).size : HM.sections.reduce((n, s) => n + HM.visiblePasses(s).length, 0));
  HM.shownPass = (sec) => {
    const ps = HM.visiblePasses(sec); if (!ps.length) return null;
    return ps.find((p) => p.id === HM.S.picks[sec.id]) || HM.suggestPass(sec, ps, HM.S.sectionDefault);
  };
  HM.shown = (sec, slot) => {
    const S = HM.S, passes = HM.visiblePasses(sec), versions = HM.versions(sec, slot, passes), k = `${sec.id}:${slot}`;
    const sp = HM.shownPass(sec), picked = versions.find((v) => v.key === S.linePicks[k]);
    let version, pass, source;
    if (picked) { version = picked; pass = picked.passes.includes(sp) ? sp : picked.best; source = 'pick'; }
    else if (S.pickBy === 'line' && !S.picks[sec.id]) {
      const sug = HM.suggestVersion(sec, slot, passes, S.sectionDefault);
      version = versions.find((v) => v.key === sug.key);
      pass = version.passes.includes(sp) ? sp : S.sectionDefault === 'recent' ? version.latest : version.best; source = 'suggested';
    } else { pass = sp; version = versions.find((v) => v.key === sp.lines[slot].key); source = S.picks[sec.id] ? 'section' : 'suggested'; }
    return { version, pass, line: pass.lines[slot], versions, passes, source, edited: S.edits[k] };
  };
  const clearLines = (sec) => Object.keys(HM.S.linePicks).forEach((k) => { if (k.startsWith(`${sec.id}:`)) delete HM.S.linePicks[k]; });
  HM.pickPass = (sec, p) => { HM.S.picks[sec.id] = p.id; clearLines(sec); HM.save(); HM.render(); };
  HM.clearPass = (sec) => { delete HM.S.picks[sec.id]; clearLines(sec); HM.save(); HM.render(); };
  HM.pickLine = (sec, slot, key) => {
    HM.S.linePicks[`${sec.id}:${slot}`] = key; HM.save();
    // Picking a version of a line says it's a lyric: the judge learns from it.
    const picked = HM.judge && sec.passes.find((p) => p.lines[slot] && p.lines[slot].key === key);
    if (picked && picked.real) HM.judge.signal('starred', picked.real.id);
    HM.render();
  };
  HM.clearLine = (sec, slot) => { delete HM.S.linePicks[`${sec.id}:${slot}`]; HM.save(); HM.render(); };

  // ---------- menus ----------
  const menu = document.createElement('div'); menu.className = 'menu'; menu.hidden = true;
  document.addEventListener('mousedown', (e) => { if (!menu.hidden && !menu.contains(e.target) && !e.target.closest('[data-menu]')) menu.hidden = true; });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') menu.hidden = true; });
  HM.menu = (anchor, html, bind) => {
    if (!menu.isConnected) document.body.appendChild(menu);
    if (!menu.hidden && menu._anchor === anchor) { menu.hidden = true; return; }
    menu.innerHTML = html; menu.hidden = false; menu._anchor = anchor;
    const r = anchor.getBoundingClientRect();
    menu.style.left = `${Math.min(window.innerWidth - menu.offsetWidth - 8, r.left)}px`; menu.style.top = `${r.bottom + 6}px`;
    bind(menu, () => { menu.hidden = true; });
  };

  // ---------- chrome ----------
  HM.ACCENTS = ['amber', 'orange', 'cream', 'gold', 'crimson', 'magenta', 'violet', 'cobalt', 'ice', 'teal', 'mint', 'lime', 'aurora', 'dusk', 'lilac', 'periwinkle', 'frost', 'oxblood', 'ox-ice', 'ox-violet'];
  HM.NAMES = { solo: ['Solo', 'Beat'], free: ['Freestyle', 'Over a beat'], booth: ['Open mic', 'Booth'], jam: ['Jam', 'Beat'], acap: ['A cappella', 'Instrumental'] };
  const MICS = [['interface', 'Audio Interface · In 1', 'XLR'], ['builtin', 'MacBook Pro Microphone', 'Built-in'], ['airpods', 'AirPods Pro', 'Bluetooth'], ['system', 'Whatever macOS picks', 'System default']];

  // Recording whenever the session is live (playing the beat or freestyling); otherwise not.
  HM.recPill = () => {
    const on = HM.S.growing, el = document.getElementById('recPill');
    if (!el) return;                      // retired 2026-10-12: the strip already shows Recording
    el.classList.toggle('off', !on);
    el.innerHTML = on ? '<span class="rec-dot"></span>Recording' : 'Not recording';
  };
  function chrome() {
    const S = HM.S, [a, b] = ['Freestyle', 'Beat'];
    const seg = document.getElementById('modeSeg');
    seg.innerHTML = `<button class="${S.mode === 'solo' ? 'on' : ''}" data-mode="solo"><svg class="i"><use href="#i-mic"/></svg>${a}</button><button class="${S.mode === 'beat' ? 'on' : ''}" data-mode="beat"><svg class="i"><use href="#i-beat"/></svg>${b}</button>`;
    seg.querySelectorAll('[data-mode]').forEach((btn) => btn.addEventListener('click', () => {
      if (btn.dataset.mode === S.mode) return;
      HM.set({ mode: btn.dataset.mode, t: 0, cue: 0, playing: false, loopPass: 1 });
    }));
    const mic = document.getElementById('mic');
    const hm = HM.hostMics, mics = hm ? hm.items.map((m) => [String(m.id), m.name, '']) : MICS, sel = hm ? String(hm.selected) : S.mic;
    mic.innerHTML = `<svg class="i"><use href="#i-mic"/></svg><select aria-label="Microphone">${mics.map(([id, nm, sub]) => `<option value="${HM.ui.esc(id)}" title="${HM.ui.esc(sub)}"${sel === id ? ' selected' : ''}>${HM.ui.esc(nm)}</option>`).join('')}</select><span class="meter"><i></i><i></i><i></i><i></i><i></i></span>`;
    mic.querySelector('select').addEventListener('change', (e) => (HM.host ? HM.host.post({ cmd: 'setMic', id: e.target.value }) : HM.set({ mic: e.target.value })));
    const win = document.getElementById('win');
    win.classList.toggle('side-open', S.sidebar);
    win.classList.toggle('is-live', S.playing || S.growing);
    win.classList.toggle('is-recording', S.growing);
    HM.recPill();
    const tg = document.getElementById('themeToggle');
    if (tg) { const light = S.look === 'tube-light'; tg.classList.toggle('light', light); tg.title = light ? 'Switch to dark' : 'Switch to light'; tg.setAttribute('aria-pressed', String(light)); }
  }
  document.addEventListener('click', (e) => { if (e.target.closest('#themeToggle')) HM.set({ look: HM.S.look === 'tube-light' ? 'tube' : 'tube-light' }); });

  function miniWave(seed, n = 34) {
    const r = HM.rng(seed); let out = '';
    for (let i = 0; i < n; i++) { const v = 0.15 + Math.pow(r(), 1.6) * 0.85; out += `<i style="height:${Math.round(v * 100)}%"></i>`; }
    return `<span class="mini-wave">${out}</span>`;
  }
  function sidebar() {
    const S = HM.S, el = document.getElementById('side');
    const icon = (s) => `<svg class="i"><use href="#i-${s.kind === 'beat' ? 'beat' : 'mic'}"/></svg>`;
    const e = (v) => HM.ui.esc(String(v));   // names come from file names: never markup
    const row = (s) => {
      if (S.side === 'cards') return `<button class="s-card${s.current ? ' on' : ''}"${s.id ? ` data-session="${e(s.id)}"` : ''}><span class="s-top">${icon(s)}<b>${e(s.name)}</b></span>${miniWave(s.seed)}<span class="s-sub">${e(s.day)} · ${e(s.len)} · ${e(s.takes)} takes</span></button>`;
      if (S.side === 'days') return `<button class="s-row compact${s.current ? ' on' : ''}">${icon(s)}<span class="s-main"><span class="s-line"><b>${e(s.name)}</b><span class="s-time">${e(s.time)}</span></span><span class="s-chips"><em>${e(s.key)}</em><em>${e(s.bpm)} BPM</em><em>${e(s.takes)} takes</em></span></span></button>`;
      return `<button class="s-row${s.current ? ' on' : ''}"${s.id ? ` data-session="${e(s.id)}"` : ''}>${icon(s)}<span class="s-main"><b>${e(s.name)}${s.judged ? '<i class="s-judged" title="Talk sorted by the on-device model"></i>' : ''}</b><span>${e(s.day)} · ${e(s.time)} · ${e(s.len)}</span></span></button>`;
    };
    // A session being recorded keeps its row (the app lists the folder only once it exists on disk).
    const unlisted = HM.S.growing && !HM.sessions.some((x) => x.current);
    const cur = HM.S.fresh || unlisted ? { name: 'New session', day: 'Now', time: '', len: HM.fmt(HM.S.elapsed), key: '—', bpm: '—', takes: 0, kind: HM.S.mode === 'beat' ? 'beat' : 'solo', current: true, seed: 1 } : null;
    const sessions = cur ? [cur, ...HM.sessions.map((x) => ({ ...x, current: false }))] : HM.sessions;
    let list = '';
    if (S.side === 'days') {
      const days = [...new Set(sessions.map((s) => s.day))];
      list = days.map((d) => `<div class="s-day">${e(d)}</div>${sessions.filter((s) => s.day === d).map(row).join('')}`).join('');
    } else list = sessions.map(row).join('');
    el.className = `side side-${S.side}`;
    el.innerHTML = `<div class="side-head"><b>Sessions</b><button class="icon-btn" data-new title="New session"><svg class="i"><use href="#i-plus"/></svg></button></div>
      <label class="search"><svg class="i"><use href="#i-search"/></svg><input placeholder="Search lyrics, keys, beats"></label><div class="side-list">${list}</div>`;
  }

  document.addEventListener('click', (e) => { if (e.target.closest('[data-new]')) HM.newSession(); });
  HM.render = () => {
    // Style = the overall look (Vintage is the Tube Amp); look = dark/light within it.
    const st = HM.S.style || 'vintage', light = HM.S.look === 'tube-light';
    document.documentElement.dataset.style = st;
    document.documentElement.dataset.look = st === 'vintage' ? HM.S.look : `${st}${light ? '-light' : ''}`;
    // Locked materials (Nate 2026-10-12): rosewood cabinet (built into the Tube looks) + charcoal felt. Vintage only.
    document.documentElement.dataset.texture = st === 'vintage' ? 'felt-charcoal' : 'none';
    document.documentElement.dataset.accent = HM.ACCENTS.includes(HM.S.accent) ? HM.S.accent : 'amber';
    chrome(); sidebar();
    HM.renderTune(document.getElementById('tune'));
    HM.strip.refresh();
    HM.renderNotes();
    if (HM.panel) HM.panel.render();
    if (!HM.S.playing && HM.audio) HM.audio.stop();
  };

  // Delete a take or a stretch of the session: hidden from the session (lines included), audio kept, ⌘Z brings it back.
  HM.hideRange = (a, b) => {
    if (!(b > a)) return;
    HM.S.sel = null;
    if (HM.host) HM.host.post({ cmd: 'hideRange', a, b });
    else { HM.S.hiddenLocal = [...(HM.S.hiddenLocal || []), { a, b }]; HM.render(); }
    if (HM.toast) HM.toast('Deleted from the session · ⌘Z to undo');
  };
  HM.unhideLast = () => {
    if (HM.host) { HM.host.post({ cmd: 'unhideRange' }); return; }
    if ((HM.S.hiddenLocal || []).length) { HM.S.hiddenLocal = HM.S.hiddenLocal.slice(0, -1); HM.render(); }
  };
  document.addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'z' && !e.shiftKey && !(e.target.isContentEditable || /INPUT|TEXTAREA/.test(e.target.tagName)) && HM.hiddenRanges().length) { e.preventDefault(); HM.unhideLast(); }
  });
  document.addEventListener('keydown', (e) => {
    if (e.target.isContentEditable || /INPUT|TEXTAREA|SELECT/.test(e.target.tagName) || e.metaKey || e.ctrlKey) return;
    if (e.code === 'Space') { e.preventDefault(); HM.toggle(); }
    else if (e.key === 'r') HM.record();
    else if (e.key === 's') HM.set({ sidebar: !HM.S.sidebar });
    else if (e.key === 'p') HM.set({ panel: !HM.S.panel });
    else if (e.key === 'l' && HM.S.mode === 'beat') HM.set({ loop: { ...HM.S.loop, on: !HM.S.loop.on }, loopPass: 1 });
    else if ((e.key === 'Backspace' || e.key === 'Delete') && HM.S.sel && !document.activeElement.closest('.sidebar, .sessions')) { e.preventDefault(); HM.hideRange(HM.S.sel.a, HM.S.sel.b); }
    else if (e.key === 'm') HM.set({ mode: HM.S.mode === 'solo' ? 'beat' : 'solo', t: 0, cue: 0, playing: false });
  });
  document.addEventListener('click', (e) => {
    const t = e.target.closest('[data-act="sidebar"]'); if (t) HM.set({ sidebar: !HM.S.sidebar });
  });

  window.addEventListener('DOMContentLoaded', () => {
    if (HM.S._starFromHash) { delete HM.S._starFromHash; HM.save(); }
    HM.strip.init(document.getElementById('strip'));
    HM.render();
    if (location.hash.includes('grow=1')) { HM.S.elapsed = 0; HM.S.growing = true; HM.render(); HM.kick(); }
  });
})(window.HM);
