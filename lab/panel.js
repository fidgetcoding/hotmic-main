/* Hot Mic design lab: the control panel (variants, stars, rules, simulation, copy picks). */
(function (HM) {
  const DIMS = [
    { key: 'style', short: 'Style', name: 'Style', opts: [['vintage', 'Vintage'], ['modern', 'Modern'], ['notebook', 'Notebook']] },
    { key: 'accent', short: 'Accent', name: 'Accent color', opts: [['ice', 'Ice'], ['violet', 'Violet'], ['aurora', 'Aurora · ice + violet takes'], ['dusk', 'Dusk · violet + ice takes'], ['lilac', 'Lilac ice'], ['periwinkle', 'Periwinkle'], ['frost', 'Frost violet'], ['oxblood', 'Oxblood'], ['ox-ice', 'Oxblood + ice'], ['ox-violet', 'Oxblood + violet']] },
    { key: 'secMark', short: 'Sections', name: 'Section marking', opts: [['rail', 'Color rail'], ['band', 'Rail + tint'], ['rim', 'Rimmed card'], ['bracket', 'Bracket'], ['none', 'None (before)']] },
  ];
  const RULES = [
  ];
  const num = (i) => String(i + 1).padStart(2, '0');
  let el;

  function seg(rule) {
    return `<div class="lab-rule"><span>${rule.name}</span><div class="lab-seg">${rule.opts.map(([v, nm]) => `<button data-rule="${rule.key}" data-v="${v}" class="${HM.S[rule.key] === v ? 'on' : ''}">${nm}</button>`).join('')}</div></div>`;
  }

  function favorites() {
    const S = HM.S, label = (d, v) => { const i = d.opts.findIndex(([x]) => x === v); return i < 0 ? v : d.opts[i][1]; };
    const favs = DIMS.flatMap((d) => (S.stars[d.key] || []).map((v) => ({ d, v })));
    const body = favs.length
      ? `<div class="fav-list">${favs.map(({ d, v }) => `<span class="fav${S[d.key] === v ? ' on' : ''}"><button data-dim="${d.key}" data-v="${v}"><em>${d.short}</em>${label(d, v)}</button><button class="fav-x" data-star="${d.key}" data-v="${v}" title="Remove from favorites">×</button></span>`).join('')}</div>`
      : '<p class="lab-tip">Tap the ☆ next to any option below and it lands here.</p>';
    return `<div class="lab-group lab-favs"><h4><svg class="i"><use href="#i-star"/></svg>Your favorites</h4>${body}</div>`;
  }

  function render() {
    el = el || document.getElementById('lab');
    const S = HM.S;
    document.body.classList.toggle('lab-closed', !S.panel);
    document.getElementById('labFab').hidden = S.panel;
    if (!S.panel) { el.innerHTML = ''; return; }
    const pct = Math.round((S.elapsed / HM.sessionLen) * 100);
    el.innerHTML = `
      <div class="lab-head"><div><b>Hot Mic</b><span>design lab</span><small>Click to try it · ☆ to favorite · Copy picks to send me</small></div><div class="lab-actions">
        <button class="lab-btn primary" data-do="copy"><svg class="i"><use href="#i-copy"/></svg>Copy picks</button>
        <button class="lab-btn" data-do="hide" title="Hide (P)">Hide</button></div></div>
      ${favorites()}
      <div class="lab-group"><h4>Try it</h4>
        <div class="lab-rule"><span>Session so far <b data-el="pct">${pct}%</b></span><input type="range" min="0" max="${HM.sessionLen}" value="${Math.round(S.elapsed)}" data-do="elapsed"></div>
        <div class="lab-row"><button class="lab-btn primary" data-do="mic"><svg class="i"><use href="#i-mic"/></svg>Use my mic</button><button class="lab-btn" data-do="micstop">Stop</button></div>
        <div class="lab-row"><button class="lab-btn" data-do="sim1"><svg class="i"><use href="#i-play"/></svg>Simulate a freestyle</button><button class="lab-btn" data-do="sim2">2×</button><button class="lab-btn" data-do="sim4">4×</button></div>
        <div class="lab-row"><button class="lab-btn" data-do="grow">New empty session</button><button class="lab-btn" data-do="demo">Load the demo session</button><button class="lab-btn" data-do="clear">Clear my picks</button><a class="lab-btn primary" href="accents.html" target="_blank" rel="noopener">Compare accents →</a></div>
        <p class="lab-tip">Click a word to hear that spot. Double-click a line to edit it. In beat mode, drag across the beat to make a loop. R records, Space plays. M flips modes. L turns the loop on and off. P hides this panel.</p>
      </div>
      ${RULES.length ? `<div class="lab-group"><h4>Rules</h4>${RULES.map(seg).join('')}</div>` : ''}
      ${DIMS.map((d) => {
        const stars = S.stars[d.key] || [];
        return `<div class="lab-group"><h4>${d.name}</h4><div class="lab-opts">${d.opts.map(([v, nm], i) => `
          <div class="lab-opt${S[d.key] === v ? ' on' : ''}"><button class="lab-pick" data-dim="${d.key}" data-v="${v}"><em>${num(i)}</em>${nm}</button><button class="lab-star${stars.includes(v) ? ' on' : ''}" data-star="${d.key}" data-v="${v}" title="${stars.includes(v) ? 'Remove from favorites' : 'Add to favorites'}"><svg class="i"><use href="#i-star"/></svg></button></div>`).join('')}</div></div>`;
      }).join('')}
      <div class="lab-foot"><button class="lab-btn" data-do="reset">Reset the lab</button><span>Saved in this browser</span></div>`;
    el.querySelectorAll('[data-dim]').forEach((b) => b.addEventListener('click', () => HM.set({ [b.dataset.dim]: b.dataset.v, focus: b.dataset.dim === 'flip' && b.dataset.v === 'keys' ? HM.S.focus || 'v1:0' : HM.S.focus })));
    el.querySelectorAll('[data-star]').forEach((b) => b.addEventListener('click', () => {
      const k = b.dataset.star, list = new Set(S.stars[k] || []);
      list.has(b.dataset.v) ? list.delete(b.dataset.v) : list.add(b.dataset.v);
      S.stars[k] = [...list]; HM.save(); render();
    }));
    el.querySelectorAll('[data-rule]').forEach((b) => b.addEventListener('click', () => {
      const v = b.dataset.v === 'true' ? true : b.dataset.v === 'false' ? false : b.dataset.v, k = b.dataset.rule;
      // Make the pick rules visible: show which lines (and takes) they changed.
      const snap = () => { const m = {}; HM.sections.forEach((sec) => { if (!HM.visiblePasses(sec).length) return; for (let i = 0; i < sec.slots; i++) { const sh = HM.shown(sec, i); m[`${sec.id}:${i}`] = `${sh.version.key}|${sh.pass.id}`; } }); return m; };
      const before = ['pickBy', 'sectionDefault'].includes(k) ? snap() : null;
      HM.set({ [k]: v });
      if (before) {
        const after = snap(), changed = Object.keys(after).filter((x) => after[x] !== before[x]);
        changed.forEach((key) => { const r = document.querySelector(`.row[data-key="${key}"]`); if (r) { r.classList.remove('flash'); void r.offsetWidth; r.classList.add('flash'); } });
        if (changed.length) document.querySelector(`.row[data-key="${changed[0]}"]`)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
        toast(changed.length ? `${changed.length} line${changed.length > 1 ? 's' : ''} switched to a different take` : 'Same lines either way in this session');
      }
    }));
    const range = el.querySelector('[data-do="elapsed"]');
    range.addEventListener('input', () => {
      S.elapsed = +range.value; S.growing = false; S.t = Math.min(S.t, S.elapsed);
      el.querySelector('[data-el="pct"]').textContent = `${Math.round((S.elapsed / HM.sessionLen) * 100)}%`;
      HM.strip.head(); HM.strip.draw(); HM.renderNotes();
    });
    el.querySelector('[data-do="grow"]').addEventListener('click', () => HM.newSession());
    el.querySelector('[data-do="mic"]').addEventListener('click', () => HM.mic.start());
    el.querySelector('[data-do="micstop"]').addEventListener('click', () => HM.mic.stop());
    [1, 2, 4].forEach((n) => el.querySelector(`[data-do="sim${n}"]`).addEventListener('click', () => HM.sim.start(n)));
    el.querySelector('[data-do="demo"]').addEventListener('click', () => HM.demoSession());
    el.querySelector('[data-do="clear"]').addEventListener('click', () => HM.set({ picks: {}, linePicks: {}, edits: {}, open: {} }));
    el.querySelector('[data-do="hide"]').addEventListener('click', () => HM.set({ panel: false }));
    el.querySelector('[data-do="reset"]').addEventListener('click', () => HM.reset());
    el.querySelector('[data-do="copy"]').addEventListener('click', copy);
  }

  function summary() {
    const S = HM.S, label = (d, v) => { const i = d.opts.findIndex(([x]) => x === v); return i < 0 ? v : `${num(i)} ${d.opts[i][1]}`; };
    const now = new Date(), p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit', hour: 'numeric', minute: '2-digit' }).formatToParts(now).map((x) => [x.type, x.value]));
    const lines = [`Hot Mic lab picks (${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute} ${p.dayPeriod} ET)`, '', 'Showing now:'];
    DIMS.forEach((d) => lines.push(`- ${d.name}: ${label(d, S[d.key])}`));
    lines.push('', 'Starred:');
    const starred = DIMS.filter((d) => (S.stars[d.key] || []).length);
    if (!starred.length) lines.push('- nothing yet');
    starred.forEach((d) => lines.push(`- ${d.name}: ${S.stars[d.key].map((v) => label(d, v)).join(', ')}`));
    lines.push('', `Chord shapes under lines: ${S.shapes || 'off'}`);
    lines.push('', `Rules: picks by ${S.pickBy === 'section' ? 'whole section' : 'line'} · default ${S.sectionDefault === 'best' ? 'best take' : 'most recent'} · zoom ${S.zoom} · snap ${S.snap ? 'on' : 'off'}`);
    const edits = Object.entries(S.edits);
    if (edits.length) { lines.push('', 'Lines I typed:'); edits.forEach(([k, v]) => { const [id, slot] = k.split(':'); lines.push(`- ${HM.sec(id).name}, line ${+slot + 1}: ${v}`); }); }
    return lines.join('\n');
  }
  function toast(msg) {
    const t = document.createElement('div'); t.className = 'toast'; t.textContent = msg; document.body.appendChild(t);
    setTimeout(() => t.remove(), 2400);
  }
  async function copy() {
    const text = summary();
    try { await navigator.clipboard.writeText(text); toast('Copied. Paste it to Claude.'); return; } catch (e) { /* fall through */ }
    const ta = document.createElement('textarea'); ta.value = text; document.body.appendChild(ta); ta.select();
    const ok = document.execCommand && document.execCommand('copy'); ta.remove();
    toast(ok ? 'Copied. Paste it to Claude.' : 'Copy blocked. Picks are in the console.');
    if (!ok) console.log(text);
  }

  HM.panel = { render };
  window.addEventListener('DOMContentLoaded', () => {
    document.getElementById('labFab').addEventListener('click', () => HM.set({ panel: true }));
  });
})(window.HM);
