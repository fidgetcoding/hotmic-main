/* Hot Mic window bridge: when the page runs inside the app (window.HM_HOST, injected by the app at
   document start), real sessions, recording and the mic come from Swift through HM.host.*, and the
   page talks back with window.webkit.messageHandlers.hotmic.postMessage({cmd, ...}). */
(function (HM) {
  if (!window.HM_HOST) return;
  document.documentElement.classList.add('in-app');
  // Start empty, never on the demo song.
  HM.sections = []; HM.sessionLen = 0; HM.sessions = []; HM.real = HM.real || {};

  const post = (msg) => { try { window.webkit.messageHandlers.hotmic.postMessage(msg); } catch (e) { /* not in the app */ } };
  let list = [], current = null;
  const PER = ['picks', 'linePicks', 'edits', 'breaks'];

  function dayLabel(iso) {
    const d = new Date(iso), now = new Date(), y = new Date(now); y.setDate(now.getDate() - 1);
    if (d.toDateString() === now.toDateString()) return 'Today';
    if (d.toDateString() === y.toDateString()) return 'Yesterday';
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  }
  const fmt = (s) => { s = Math.max(0, Math.round(s)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };
  function mapSessions() {
    HM.sessions = list.map((s) => ({
      id: s.id, name: s.name.replace(/^\d{4}-\d{2}-\d{2} \d{6} /, ''), day: dayLabel(s.date),
      time: new Date(s.date).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }),
      len: fmt(s.length), key: '—', bpm: '—', takes: s.takes, kind: /jam/i.test(s.daw) || !s.daw ? 'solo' : 'beat',
      current: s.id === current, seed: s.takes * 7 + 3,
    }));
  }

  // Your picks, edits and section breaks are kept per session.
  function swapSession(id) {
    const S = HM.S; if (!S || (id === current && id)) return;
    S.bySession = S.bySession || {};
    if (current) S.bySession[current] = Object.fromEntries(PER.map((k) => [k, S[k]]));
    if (!id) { S.picks = {}; S.linePicks = {}; S.edits = {}; S.breaks = { solo: {}, beat: null }; return; }   // a clean slate
    const saved = S.bySession[id] || {};
    S.picks = saved.picks || {}; S.linePicks = saved.linePicks || {}; S.edits = saved.edits || {};
    S.breaks = saved.breaks || { solo: {}, beat: null };
  }

  // Lines you finished singing that the saved session hasn't caught up with yet (the app reads the
  // folder half a second after each line lands). They show as real rows right away, so a line never
  // vanishes and never jumps when its saved copy arrives.
  HM.liveDone = [];
  let lastLoad = null;
  const normText = (t) => (t || '').toLowerCase().replace(/[^a-z0-9' ]/g, '').replace(/\s+/g, ' ').trim();
  function withPending(d) {
    const pending = HM.liveDone;
    if (!pending.length) return d;
    const slots = d.slots.concat(pending.map((p, i) => {
      const dur = Math.max(0.3, p.end - p.at), ws = p.text.split(/\s+/).filter(Boolean), step = dur / Math.max(1, ws.length);
      return [{ id: `pending-${i}-${p.at}`, takeID: '', text: p.text, start: 0, end: dur, at: p.at, chords: [], keeper: false,
                words: ws.map((w, j) => ({ w, start: j * step, end: (j + 1) * step })) }];
    })).sort((a, b) => (a[0] ? a[0].at : 0) - (b[0] ? b[0].at : 0));
    return Object.assign({}, d, { slots });
  }
  // A pending line is in the saved copy when a saved line starts at its time, or spans it (a lone
  // word folded into the line before it), or when it's old enough that the save must have landed.
  function reconcile(d) {
    const S = HM.S, now = S ? S.elapsed : Infinity;
    HM.liveDone = HM.liveDone.filter((p) => {
      if (p.at < now - 12) return false;
      return !d.slots.some((slot) => slot.some((v) => Math.abs(v.at - p.at) < 0.5 || (p.at >= v.at - 0.5 && p.at <= v.at + (v.end - v.start) + 0.5)));
    });
  }

  HM.host = {
    post,
    load(d) {
      if (!d) return;
      swapSession(d.id);
      if (d.id !== current) HM.liveDone = [];
      current = d.id;
      lastLoad = d;
      reconcile(d);
      HM.realConvert(withPending(d));
      const S = HM.S;
      if (S) {
        // Recording: the clock comes from the app (HM.host.level); a mid-take reload never moves it.
        if (S.growing) HM.sessionLen = Math.max(HM.sessionLen, Math.ceil(S.elapsed)); else S.elapsed = HM.sessionLen;
        S.t = Math.min(S.t, HM.sessionLen); S.cue = Math.min(S.cue || 0, HM.sessionLen);
        S.fresh = !d.slots.length;
        HM.realApplyKeepers(); HM.save();
      }
      mapSessions();
      if (S) HM.render();
    },
    sessions(items) { list = items || []; mapSessions(); if (HM.S) HM.render(); },
    recording(on) {
      HM._lastLevelAt = undefined;
      const S = HM.S; if (!S) return;
      S.growing = !!on; if (on) { S.fresh = false; S.elapsed = Math.max(0, S.elapsed); }
      // Beat mode: Record plays the beat (from the loop or your marker), Stop stops it.
      if (S.mode === 'beat' && HM.beat && HM.beat.buffer) {
        if (on) {
          S.t = S.loop && S.loop.on ? S.loop.a : (S.cue || 0); S.playing = true; HM.audio.start();
          // Where the beat starts for this recording, so looped playback lines your voice back up with it.
          HM.host.post({ cmd: 'beatRun', at: S.elapsed || 0, beat: S.t, loopA: S.loop.a, loopB: S.loop.b, loopOn: !!S.loop.on, beatName: HM.beat.name });
        }
        else if (S.playing) { S.playing = false; HM.audio.stop(); }
      }
      HM.render(); HM.kick();
    },
    // The window opened: clean slate (the app then loads the empty session, or the one recording).
    fresh() {
      const S = HM.S; if (!S) return;
      HM.liveText = ''; HM.liveDone = []; S.editing = false; S.t = 0; S.cue = 0; S.playing = false; S.fresh = true;
      if (HM.audio) HM.audio.stop();
    },
    // Words as you sing them (the line in progress).
    live(m) {
      const next = m && m.text ? m.text : '';
      HM.liveText = next;
      drawLive();
    },
    // A line just finished (the app saved it): it becomes a row this instant, in place, and stays put
    // when the saved copy and then Whisper's correction arrive.
    lineDone(m) {
      if (!m || !m.text) return;
      HM.liveDone.push({ text: m.text, at: +m.at || 0, end: +m.end || 0 });
      if (normText(HM.liveText) === normText(m.text)) HM.liveText = '';
      if (lastLoad) { HM.realConvert(withPending(lastLoad)); HM.renderNotes(); if (HM.strip && HM.strip.draw) HM.strip.draw(); }
      drawLive();
    },
    liveNotice(text) { HM.liveNotice = text || ''; drawLive(); },
    // Live input level while recording: written into the strip's waveform at the current time.
    level(v, at) {
      const S = HM.S; if (!S || !S.growing) return;
      if (typeof at === 'number' && at >= 0) S.elapsed = at;      // the app's clock, not the page's guess
      const rate = HM.envelopes.sRate || 20;
      let env = HM.envelopes.session;
      const i = Math.floor(S.elapsed * rate);
      if (!env || i >= env.length) {
        const grown = new Float32Array(Math.max(i + 1, (env ? env.length : 0)) + 60 * rate).fill(0.03);
        if (env) grown.set(env);
        env = HM.envelopes.session = grown; HM.envelopes.sRate = rate;
      }
      const from = Math.max(0, Math.min(i, (HM._lastLevelAt ?? i)));
      for (let k = from; k <= i; k++) env[k] = Math.max(0.03, v);
      HM._lastLevelAt = i + 1;
      if (HM.sessionLen < S.elapsed + 1) HM.sessionLen = Math.ceil(S.elapsed) + 1;
      if (HM.strip && HM.strip.draw) HM.strip.draw();
    },
    mics(items, selected) { HM.hostMics = { items: items || [], selected }; if (HM.S) HM.render(); },
    // A recording dropped in Freestyle, being split into a session: one banner that updates in place.
    importing(m) {
      let el = document.querySelector('.import-banner');
      if (!el) { el = document.createElement('div'); el.className = 'import-banner'; document.body.appendChild(el); }
      clearTimeout(el._t);
      if (m.error) { el.className = 'import-banner err'; el.textContent = `Couldn't open ${m.name}: ${m.error}`; el._t = setTimeout(() => el.remove(), 6000); return; }
      if (m.done) {
        el.className = 'import-banner done';
        el.textContent = m.takes ? `${m.name} · ${m.takes} take${m.takes > 1 ? 's' : ''}` : `${m.name} · no singing found`;
        el._t = setTimeout(() => el.remove(), 4000); return;
      }
      el.className = 'import-banner';
      el.innerHTML = `<span>Splitting ${HM.ui.esc(m.name)}…</span><i style="width:${Math.round((m.progress || 0) * 100)}%"></i>`;
    },
  };

  // The line in progress, drawn as a row of the sheet (same type, same place) so nothing moves when
  // it becomes a saved line. The first words also bring in the sheet's toolbar, once, so the toolbar
  // never pops in above the first line later.
  function drawLive() {
    const notes = document.getElementById('notes'); if (!notes) return;
    let el = notes.querySelector('.live-line');
    const S = HM.S, growing = S && S.growing, show = (growing && HM.liveText) || HM.liveNotice;
    if (!show) { if (el) el.remove(); return; }
    if (growing && HM.liveText && notes.querySelector('.empty')) { HM.renderNotes(); return; }   // renderNotes ends by calling drawLive
    // The line you're singing goes where the next line lands: above the always-there typing row and its spacer
    // (appended after them it sat 40vh down, off screen: Nate 2026-10-14 "live lines didn't show").
    const typeRow = notes.querySelector('.type-row'), anchor = typeRow ? (typeRow.closest('.type-sec') || typeRow) : notes.querySelector('.type-spacer');
    if (!el) { el = document.createElement('section'); el.className = 'sec unnamed live-line'; }
    if (anchor && anchor.parentElement && el.nextSibling !== anchor) anchor.parentElement.insertBefore(el, anchor);
    else if (!anchor && el.parentElement !== notes) notes.appendChild(el);
    el.innerHTML = '';
    if (growing && HM.liveText) {
      const row = document.createElement('div'); row.className = 'row';
      const main = document.createElement('div'); main.className = 'row-main';
      const ly = document.createElement('div'); ly.className = 'lyric';
      HM.liveText.split(/\s+/).filter(Boolean).forEach((w) => { const s = document.createElement('span'); s.className = 'w'; s.textContent = w; ly.appendChild(s); ly.appendChild(document.createTextNode(' ')); });
      const c = document.createElement('i'); c.className = 'live-caret'; ly.appendChild(c);
      main.appendChild(ly); row.appendChild(main); el.appendChild(row);
    }
    if (HM.liveNotice) { const n = document.createElement('div'); n.className = 'live-notice'; n.textContent = HM.liveNotice; el.appendChild(n); }
    // Only scroll when the live line is actually below the fold (a smooth scroll on every word jittered).
    const r = el.getBoundingClientRect(), box = notes.getBoundingClientRect();
    if (r.bottom > box.bottom || r.top < box.top) el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }
  HM.hostDrawLive = drawLive;

  // Clicking a session in the sidebar opens it.
  document.addEventListener('click', (e) => {
    const row = e.target.closest('[data-session]');
    if (row) post({ cmd: 'openSession', id: row.dataset.session });
    // ＋ New session: the app forgets the open one, so record starts a fresh session.
    if (e.target.closest('[data-new]')) { current = null; post({ cmd: 'openSession', id: '' }); }
  });

  // Window dragging: the app drags the window from the title bar except where these controls are.
  function reportNoDrag() {
    const bar = document.querySelector('.titlebar'); if (!bar) return;
    const b = bar.getBoundingClientRect();
    const rects = [...bar.querySelectorAll('button, select, label, input, .mode-seg, .theme-toggle, .tb-gear, .rec-pill, .mic')]
      .map((el) => el.getBoundingClientRect()).filter((r) => r.width && r.height).map((r) => [r.left, r.top, r.width, r.height]);
    const l = bar.querySelector('.lights'), lr = l && l.getBoundingClientRect();
    post({ cmd: 'dragRegion', bar: [b.left, b.top, b.width, b.height], noDrag: rects, lights: lr ? [lr.left, lr.top, lr.width, lr.height] : null });
  }
  window.addEventListener('resize', reportNoDrag);
  const _render = () => setTimeout(reportNoDrag, 0);
  window.addEventListener('DOMContentLoaded', () => {
    let lastMode = null;
    const orig = HM.render; HM.render = (...a) => {
      const r = orig(...a); _render(); drawLive();
      if (HM.S && HM.S.mode !== lastMode) { lastMode = HM.S.mode; post({ cmd: 'mode', id: lastMode }); }
      return r;
    };
    const origNotes = HM.renderNotes; HM.renderNotes = (...a) => { const r = origNotes(...a); drawLive(); return r; };
    post({ cmd: 'ready' }); _render();
  });
})(window.HM);
