/* Hot Mic design lab: a simulated freestyle, so you can watch a session fill in from empty.
   Runs in real time (or 2× / 4×), skips the silent gaps between takes, types live words with the
   kind of slips on-device recognition makes, then swaps in the corrected line when each take ends. */
(function (HM) {
  if (window.HM_HOST) return; // the app has the real thing
  // Live recognition slips → what Whisper gets right after the take.
  const SLIPS = { Streetlights: 'Street lights', humming: 'hummin', answering: 'answer in', Rewinding: 'rewind in', swore: 'sword', "I'd": 'I', "I'll": 'aisle', Ceiling: 'sealing', Coffee: 'coffee', 'cold': 'called' };
  let raf = 0, last = 0, note = '';
  const S = () => HM.S;
  const allPasses = () => HM.sections.flatMap((sec) => sec.passes).sort((a, b) => a.at - b.at);

  function liveFor(t) {
    const p = allPasses().find((q) => t >= q.at && t < q.at + q.dur);
    if (!p) return '';
    // one live line per sung line; slips on roughly every other take so you can see the correction land
    return p.lines.map((ln) => ln.words.filter((w) => p.at + w.off <= t)
      .map((w, i) => (p.n % 2 && SLIPS[w.w] && i % 2 === 0 ? SLIPS[w.w] : w.w)).join(' ')).filter(Boolean).join('\n');
  }

  function draw(text) {
    const notes = document.getElementById('notes'); if (!notes) return;
    let el = notes.querySelector('.live-line');
    if (!text && !note) { if (el) el.remove(); return; }
    if (text) notes.querySelector('.empty')?.remove();
    if (!el) { el = document.createElement('div'); el.className = 'live-line'; notes.appendChild(el); }
    el.innerHTML = '';
    if (text) {
      const ls = text.split('\n');
      ls.forEach((ln, i) => {
        const row = document.createElement('div'); row.className = 'live-row';
        const sp = document.createElement('span'); sp.className = 'live-text'; sp.textContent = ln; row.appendChild(sp);
        if (i === ls.length - 1) { const c = document.createElement('i'); c.className = 'live-caret'; row.appendChild(c); }
        el.appendChild(row);
      });
    }
    if (note) { const n = document.createElement('div'); n.className = 'live-notice'; n.textContent = note; el.appendChild(n); }
    el.scrollIntoView({ block: 'end', behavior: 'smooth' });
  }

  function tick(now) {
    const s = S(); if (!s.sim) { raf = 0; return; }
    const dt = Math.min(0.1, (now - last) / 1000); last = now;
    let t = s.elapsed + dt * s.sim;
    // between takes: fast-forward the silence so you're not waiting on talking/breaths
    const next = allPasses().find((p) => p.at + p.dur > t);
    if (next && t < next.at - 1.2) { t = next.at - 1.2; note = '⏩ skipping the quiet part'; } else note = '';
    if (!next) { stop(); return; }
    s.elapsed = Math.min(HM.sessionLen, t); s.t = s.elapsed;
    const n = HM.countTakes();
    if (n !== s._simTakes) { s._simTakes = n; HM.renderNotes(); HM.strip.head(); }
    const live = HM.strip && document.querySelector('[data-live]'); if (live) live.textContent = `${HM.fmt(s.elapsed)} · ${n} takes`;
    draw(liveFor(s.elapsed));
    raf = requestAnimationFrame(tick);
  }

  function start(speed = 1) {
    HM.newSession();
    const s = S();
    Object.assign(s, { mode: 'solo', sim: speed, growing: true, growRate: 0, playing: true, elapsed: 0, t: 0, _simTakes: 0 });
    HM.audio.start(); HM.render(); HM.kick();
    last = performance.now(); if (!raf) raf = requestAnimationFrame(tick);
  }
  function stop() {
    const s = S(); s.sim = 0; s.growing = false; s.playing = false; s.growRate = undefined; note = '';
    HM.audio.stop(); draw(''); HM.render();
  }
  HM.sim = { start, stop, speed: (v) => { S().sim = v; } };

  // keep the live line on screen when the sheet re-renders
  window.addEventListener('DOMContentLoaded', () => {
    const orig = HM.renderNotes; HM.renderNotes = (...a) => { const r = orig(...a); if (S().sim) draw(liveFor(S().elapsed)); return r; };
    if (/sim=1/.test(location.hash)) setTimeout(() => start(+((location.hash.match(/speed=(\d)/) || [])[1] || 1)), 300);
  });
})(window.HM);
