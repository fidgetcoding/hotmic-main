/* Hot Mic window: the line judge. Lines judged talk leave the notepad and wait in a quiet list above it; one
   click brings a line back, one click sends a line there, and every click teaches the learner (on this Mac).
   Only ever sorts and hides: words are never changed or suggested. */
(function (HM) {
  const post = (msg) => { if (HM.host) HM.host.post(msg); };
  const J = HM.judge = {
    aside: [], model: null, open: false,
    state: { modelOn: true, learnerOn: true, corrections: 0, modelAvailable: false },

    load(d) { J.aside = (d.judge && d.judge.aside) || []; J.model = (d.judge && d.judge.model) || null; if (!J.aside.length) J.open = false; },

    // Sung lines only: not typed lines, hums, chord rows, or a line the app hasn't saved yet.
    markable: (id, takeID) => !!id && takeID !== 'typed' && !/^(hum-|beat-|chords-|pending-)/.test(id),

    count: () => { const n = J.aside.length; return n ? `${n} line${n === 1 ? '' : 's'} of talk set aside` : ''; },

    correct(id, verdict) {
      if (verdict === 'writing') { J.aside = J.aside.filter((l) => l.id !== id); if (!J.aside.length) J.open = false; }
      post({ cmd: 'judgeCorrect', id, verdict });
    },
    signal(kind, id) { if (id && J.markable(id)) post({ cmd: 'judgeSignal', kind, id }); },

    // The toolbar's quiet count; opens the list.
    bar(h) {
      const text = J.count(); if (!text) return null;
      const b = h(`<button class="np-aside${J.open ? ' on' : ''}" title="Hot Mic judged these lines as talk${J.model ? ' with the on-device model' : ''}. Nothing is deleted.">${text}</button>`);
      b.addEventListener('click', (e) => { e.stopPropagation(); J.open = !J.open; HM.renderNotes(); });
      return b;
    },

    list(h, esc) {
      if (!J.open || !J.aside.length) return null;
      const box = h('<div class="aside-list"></div>');
      J.aside.forEach((l) => {
        const row = h(`<div class="aside-row"><span class="aside-text" title="Play it">${esc(l.text)}</span><button class="aside-keep" title="It's a lyric: bring it back and teach Hot Mic">Lyric</button></div>`);
        row.querySelector('.aside-text').addEventListener('click', () => HM.seek(l.at, true));
        row.querySelector('.aside-keep').addEventListener('click', (e) => { e.stopPropagation(); J.correct(l.id, 'writing'); });
        box.appendChild(row);
      });
      return box;
    },

    // Picks, edits and breaks saved before lines had stable ids ("s3:0", take "s3p2") move to their lines once.
    migrate(S, sections) {
      const to = (id) => { const m = /^s(\d+)$/.exec(id); return m && sections[+m[1]] ? sections[+m[1]].id : id; };
      const moved = (obj, value) => Object.fromEntries(Object.entries(obj || {}).map(([k, v]) => {
        const [id, rest] = k.split(':');
        return [rest === undefined ? to(id) : `${to(id)}:${rest}`, value ? value(v) : v];
      }));
      S.picks = moved(S.picks, (p) => String(p).replace(/^(s\d+)(p\d+)$/, (_, a, b) => to(a) + b));
      S.linePicks = moved(S.linePicks); S.edits = moved(S.edits);
      if (S.breaks) S.breaks = { solo: moved(S.breaks.solo), beat: S.breaks.beat ? moved(S.breaks.beat) : S.breaks.beat };
    },

    // Beside a lyric: one click says it's talk.
    rowButton(h, id, takeID) {
      if (!HM.host || !J.markable(id, takeID)) return null;
      const b = h('<button class="row-talk" title="That\'s talk: set it aside and teach Hot Mic">Talk</button>');
      b.addEventListener('click', (e) => { e.stopPropagation(); J.correct(id, 'talk'); });
      return b;
    },

    settings(S) {
      const s = J.state;
      return `<div class="set-sec"><div class="set-h">Sorting talk from lyrics</div>
        <label class="set-row"><span>On-device model after Stop${s.modelAvailable ? '' : ' <em>needs Apple Intelligence</em>'}</span><input type="checkbox" data-judge="modelOn"${s.modelOn ? ' checked' : ''}${s.modelAvailable ? '' : ' disabled'}></label>
        <label class="set-row"><span>Learn from what I fix</span><input type="checkbox" data-judge="learnerOn"${s.learnerOn ? ' checked' : ''}></label>
        <div class="set-row"><span>Learned from ${s.corrections} correction${s.corrections === 1 ? '' : 's'}</span><button class="set-btn" data-judge-reset${s.corrections ? '' : ' disabled'}>Reset</button></div>
        <div class="set-note">Hot Mic learns from your clicks, stars, edits and deletions. It stays on this Mac.</div></div>`;
    },
    wireSettings(pop, redraw) {
      pop.querySelectorAll('[data-judge]').forEach((c) => { c.onchange = () => { J.state[c.dataset.judge] = c.checked; post({ cmd: 'judgeSettings', [c.dataset.judge]: c.checked }); }; });
      const r = pop.querySelector('[data-judge-reset]');
      if (r) r.onclick = () => { J.state.corrections = 0; post({ cmd: 'judgeSettings', reset: true }); redraw(); };
    },
  };
})(window.HM);
