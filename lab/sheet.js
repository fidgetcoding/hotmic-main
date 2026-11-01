/* Hot Mic design lab: the lyric sheet. Sections only exist once you add them (beat mode can label
   them from the beat). Double-click anywhere = edit every line. */
(function (HM) {
  const S = () => HM.S;
  let host;
  const h = (html) => HM.ui.h(html), esc = (s) => HM.ui.esc(s);

  // Every line you've sung, in song order, whatever section Hot Mic filed it under.
  function lines() {
    const out = [];
    HM.sections.filter((s) => HM.visiblePasses(s).length).forEach((sec) => { for (let slot = 0; slot < sec.slots; slot++) out.push({ sec, slot, key: `${sec.id}:${slot}` }); });
    return out;
  }

  // Section breaks, per mode: { 'hook:0': 'Hook' }. Beat mode starts from the beat's own sections.
  function breaks() {
    const s = S(); s.breaks = s.breaks || { solo: {}, beat: null };
    if (s.mode === 'beat' && !s.breaks.beat) return Object.fromEntries(HM.sections.map((sec) => [`${sec.id}:0`, sec.name]));
    return s.breaks[s.mode] || {};
  }
  function own() { const s = S(); s.breaks = s.breaks || { solo: {}, beat: null }; if (!s.breaks[s.mode]) s.breaks[s.mode] = { ...breaks() }; return s.breaks[s.mode]; }
  HM.sheet = {
    addBreak(key) {
      const b = own(), [id, slot] = key.split(':'), sec = HM.sec(id);
      const taken = new Set(Object.values(b));
      let name = +slot === 0 && !taken.has(sec.name) ? sec.name : '';
      for (let n = Object.keys(b).length + 1; !name; n++) if (!taken.has(`Section ${n}`)) name = `Section ${n}`;
      b[key] = name; S()._rename = key; HM.save(); HM.renderNotes();
    },
    removeBreak(key) { delete own()[key]; HM.save(); HM.renderNotes(); },
    rename(key, name) { own()[key] = name.trim() || 'Section'; HM.save(); },
    wireName(el, g) {
      const nm = el.querySelector('.sec-name');
      if (g.typed) { nm.title = ''; return; }          // a header you typed: edit it like any line
      if (S().editing && !g.typed) {
        nm.contentEditable = 'plaintext-only'; nm.spellcheck = false;
        nm.addEventListener('input', () => { const t = nm.textContent.trim(); if (t) { own()[g.key] = t; HM.save(); } });
        nm.addEventListener('blur', () => { if (!nm.textContent.trim()) HM.sheet.removeBreak(g.key); });
        nm.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); nm.blur(); } else if ((e.key === 'Backspace' || e.key === 'Delete') && !nm.textContent.trim()) { e.preventDefault(); HM.sheet.removeBreak(g.key); } });
        return;
      }
      nm.addEventListener('click', (e) => { e.stopPropagation(); startRename(nm, g.key); });
      const x = h('<button class="sec-x" title="Remove this section break">×</button>');
      x.addEventListener('click', (e) => { e.stopPropagation(); HM.sheet.removeBreak(g.key); });
      el.querySelector('.sec-title').appendChild(x);
      if (S()._rename === g.key) { S()._rename = null; requestAnimationFrame(() => startRename(nm, g.key)); }
    },
  };
  function startRename(nm, key) {
    nm.contentEditable = 'plaintext-only'; nm.classList.add('renaming'); nm.focus();
    const sel = window.getSelection(); sel.selectAllChildren(nm);
    const done = () => { nm.removeEventListener('blur', done); nm.contentEditable = 'false'; HM.sheet.rename(key, nm.textContent); HM.renderNotes(); };
    nm.addEventListener('blur', done);
    nm.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === 'Escape') { e.preventDefault(); nm.blur(); } });
  }

  // Notes-style sections (Nate 2026-10-14): a line that is just a header — "Verse", "Hook", "[Chorus]",
  // "Bridge 2", "Verse:" — starts a section named that. Delete the line and the section is gone.
  const HEADER = /^\s*\[?\s*((?:intro|verse|hook|chorus|pre[- ]?chorus|post[- ]?chorus|bridge|outro|refrain|breakdown|drop|interlude|break|section|tag|coda)(?:\s*\d+)?)\s*\]?\s*:?\s*$/i;
  HM.sheet.headerName = (text) => { const m = HEADER.exec(text || ''); return m ? m[1].replace(/\s+/g, ' ').replace(/^./, (c) => c.toUpperCase()) : null; };
  const textOfLine = (ln) => { const e = S().edits[ln.key]; return e !== undefined ? e : HM.shown(ln.sec, ln.slot).version.text; };
  function groups(all) {
    const b = breaks(), out = [{ name: null, key: null, lines: [] }];
    all.forEach((ln) => {
      const t = textOfLine(ln);
      if (!S().editing) {
        if (t.trim() === '') return;                                  // a line you deleted
        const name = HM.sheet.headerName(t);
        if (name) { out.push({ name, key: ln.key, lines: [], typed: true }); return; }
      }
      if (b[ln.key] !== undefined) out.push({ name: b[ln.key], key: ln.key, lines: [] });
      out[out.length - 1].lines.push(ln);
    });
    return out.filter((g) => g.lines.length || g.typed);
  }
  // Named sections as time spans for the strip's big colored blocks (verse and hook
  // at a glance, like a DAW's markers). Same color as the section in the notepad.
  HM.sheet.spans = () => {
    let named = 0;
    return groups(lines()).filter((g) => g.name !== null).map((g) => {
      const tone = whole(g) ? g.lines[0].sec.tone : ['a', 'b', 'c'][named % 3]; named++;
      const times = g.lines.flatMap((ln) => { const p = HM.shownPass(ln.sec) || HM.visiblePasses(ln.sec)[0]; if (!p) return []; const t0 = HM.timeOf(p) + ln.slot * HM.LINE_DUR; return [t0, Math.min(t0 + HM.LINE_DUR, HM.timeOf(p) + p.dur)]; });
      return times.length ? { name: g.name, tone, a: Math.min(...times), b: Math.max(...times) } : null;
    }).filter(Boolean).map((sp, i, all) => ({ ...sp, b: Math.max(sp.b, i + 1 < all.length ? Math.min(all[i + 1].a, sp.b + 4) : sp.b) }));
  };
  // A section gets take-flipping when its lines are exactly one of the passes Hot Mic heard.
  const whole = (g) => g.lines.length > 0 && !g.typed && g.lines.length === g.lines[0].sec.slots && g.lines[0].slot === 0 && g.lines.every((l) => l.sec === g.lines[0].sec);

  function gap() { return document.createElement('span'); }
  function gapOld(ln, suggest) {
    const b = h(`<button class="add-break${suggest ? ' suggest' : ''}" title="Start a new section here">＋ Section${suggest ? ' <em>new part?</em>' : ''}</button>`);
    b.addEventListener('click', (e) => { e.stopPropagation(); HM.sheet.addBreak(ln.key); });
    const wrap = h('<div class="gap"></div>'); wrap.appendChild(b); return wrap;
  }

  // ---------- edit mode: the same rows, typed into in place ----------
  const textOf = (el) => { const c = el.cloneNode(true); c.querySelectorAll('.ch, .tag, .sung, .count, .count-tag').forEach((n) => n.remove()); return c.textContent.replace(/\s+/g, ' ').trim(); };
  HM.sheet.makeEditable = () => {
    host.querySelectorAll('.row[data-key] .lyric').forEach((ed) => {
      const key = ed.closest('.row').dataset.key, [id, slot] = key.split(':'), sec = HM.sec(id), sh = HM.shown(sec, +slot);
      ed.contentEditable = 'plaintext-only'; ed.spellcheck = false;
      ed.querySelectorAll('.ch, .tag, .count, .count-tag').forEach((n) => { n.contentEditable = 'false'; });
      ed.oninput = () => { const t = textOf(ed); if (t !== sh.version.text) S().edits[key] = t; else delete S().edits[key]; HM.save(); };
      ed.onfocus = () => { S()._caretKey = key; };
      ed.onkeydown = (e) => {
        const all = [...host.querySelectorAll('.row[data-key] .lyric')], i = all.indexOf(ed);
        if (e.key === 'Enter') {
          e.preventDefault();
          // "Hook⏎" typed at the start of a line: the header becomes a section above it, the line stays as it was.
          const sel = window.getSelection(), pre = document.createRange(); pre.selectNodeContents(ed);
          if (sel.rangeCount) pre.setEnd(sel.getRangeAt(0).startContainer, sel.getRangeAt(0).startOffset);
          const frag = document.createElement('div'); frag.appendChild(pre.cloneContents()); frag.querySelectorAll('.ch, .tag, .sung, .count, .count-tag').forEach((n) => n.remove());
          const name = HM.sheet.headerName(frag.textContent);
          if (name) { own()[key] = name; delete S().edits[key]; HM.save(); HM.renderNotes(); return; }
          if (all[i + 1]) caretEnd(all[i + 1]);
        }
        else if (e.key === 'End' || (e.metaKey && e.key === 'ArrowRight')) { e.preventDefault(); caretEnd(ed); }
        else if (e.key === 'Home' || (e.metaKey && e.key === 'ArrowLeft')) { e.preventDefault(); caretStart(ed); }
        else if (e.key === 'ArrowUp' && i > 0 && caretAtEdge(ed, 'start')) { e.preventDefault(); caretEnd(all[i - 1]); }
        else if (e.key === 'ArrowDown' && i < all.length - 1 && caretAtEdge(ed, 'end')) { e.preventDefault(); caretEnd(all[i + 1]); }
        else if (e.key === 'Escape') { e.preventDefault(); HM.sheet.stopEditing(); }
      };
    });
  };
  function caretAtEdge(el, edge) {
    const s = window.getSelection(); if (!s.rangeCount) return true;
    const r = s.getRangeAt(0).cloneRange(), all = document.createRange(); all.selectNodeContents(el);
    if (edge === 'start') { all.setEnd(r.startContainer, r.startOffset); return all.toString().trim() === ''; }
    all.setStart(r.endContainer, r.endOffset); return textOf(Object.assign(document.createElement('div'), { textContent: all.toString() })) === '';
  }
  function caretStart(el) { el.focus(); const w = el.querySelector('.w'); const r = document.createRange(); if (w) { const t = [...w.childNodes].find((n) => n.nodeType === 3); r.setStart(t || w, 0); } else r.setStart(el, 0); r.collapse(true); const s = window.getSelection(); s.removeAllRanges(); s.addRange(r); }
  function caretEnd(el) { el.focus(); const ws = el.querySelectorAll('.w'), w = ws[ws.length - 1], r = document.createRange(); if (w) { const t = [...w.childNodes].filter((n) => n.nodeType === 3).pop(); if (t) r.setStart(t, t.length); else r.setStartAfter(w); } else { r.selectNodeContents(el); r.collapse(false); } r.collapse(true); const s = window.getSelection(); s.removeAllRanges(); s.addRange(r); }

  HM.sheet.startEditing = (key, x, y) => {
    const s = S();
    // Editing pauses the music, unless you're looping a part on purpose.
    if (s.playing && !(s.mode === 'beat' && s.loop.on)) { s.playing = false; HM.audio.stop(); HM.strip.head(); }
    s._editsBefore = { ...s.edits };
    s.editing = true; HM.renderNotes();
    const target = (key && host.querySelector(`.row[data-key="${key}"] .lyric`)) || host.querySelector('.row[data-key] .lyric');
    if (!target) return;
    target.focus();
    const r = x != null && document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
    if (r && target.contains(r.startContainer)) { const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r); } else caretEnd(target);
  };
  HM.sheet.stopEditing = () => {
    const s = S();
    // A line whose words you fixed is a lyric: the judge learns from it.
    if (HM.judge) Object.keys(s.edits).forEach((k) => {
      if (s.edits[k] === (s._editsBefore || {})[k] || !s.edits[k]) return;
      const [id, slot] = k.split(':'), sec = HM.sec(id), pass = sec && HM.shown(sec, +slot).pass;
      if (pass && pass.real) HM.judge.signal('edited', pass.real.id);
    });
    s.editing = false; HM.renderNotes();
  };

  function toolbar(n) {
    const ed = S().editing;
    const count = S().growing ? `${n} line${n === 1 ? '' : 's'} so far` : `${n} lines · double-click anywhere to edit`;
    const bar = h(`<div class="np-bar"><div class="np-left"><b>${ed ? 'Editing lyrics' : 'Lyrics'}</b><span>${ed ? 'Type Verse, Hook, [Chorus]… then Enter for a section · Esc = done' : count}</span></div><div class="np-right"></div></div>`);
    const btn = h(`<button class="np-btn${ed ? ' primary' : ''}">${ed ? 'Done' : '✎ Edit'}</button>`);
    btn.addEventListener('click', () => (ed ? HM.sheet.stopEditing() : HM.sheet.startEditing()));
    if (ed) {
      const sec = h('<button class="np-btn" title="Puts a header line above the line you\'re on. Or just type Verse, Hook, [Chorus]… on a line.">＋ Section</button>');
      sec.addEventListener('mousedown', (e) => e.preventDefault());
      sec.addEventListener('click', () => { const k = S()._caretKey || (host.querySelector('.row[data-key]') || {}).dataset?.key; if (k) HM.sheet.addBreak(k); });
      bar.querySelector('.np-right').appendChild(sec);
    }
    const aside = !ed && HM.judge ? HM.judge.bar(h) : null;
    if (aside) bar.querySelector('.np-left').appendChild(aside);
    bar.querySelector('.np-right').appendChild(btn);
    return bar;
  }

  // ---------- typing new lines (type straight into the sheet and build the song live) ----------
  // A box at the end of the notepad: Enter adds the line, a multi-line paste adds every line. While you're
  // recording the lines land at the moment you typed them; otherwise after the last line.
  HM.typeLines = (text) => {
    const rows = text.split(/\r?\n/).map((r) => r.trim()).filter(Boolean);
    if (!rows.length) return;
    const S0 = S(), lastEnd = Math.max(0, ...(HM.sections || []).flatMap((sec) => sec.passes.map((p) => (p.at || 0) + (p.dur || 0))), ...(HM.liveDone || []).map((l) => l.end || 0));
    const at = S0.growing ? S0.elapsed : lastEnd + 0.1;
    if (HM.host) { HM.host.post({ cmd: 'typeLines', text: rows.join('\n'), at }); return; }
    HM.labTyped = (HM.labTyped || []).concat(rows); HM.renderNotes();   // the lab has no session files: kept on the page
  };
  HM.sheet.compose = () => {
    host = host || document.getElementById('notes'); S()._composing = true;
    let box = host.querySelector('.composer');
    if (!box) {
      box = h('<div class="composer"><textarea rows="1" placeholder="Type a line, Enter to add it. Paste a whole verse to add every line."></textarea><button class="np-btn primary">Add</button></div>');
      const ta = box.querySelector('textarea');
      const add = () => { const v = ta.value; ta.value = ''; ta.rows = 1; HM.typeLines(v); setTimeout(() => HM.sheet.compose(), 0); };
      ta.addEventListener('keydown', (e) => { e.stopPropagation(); if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); add(); } else if (e.key === 'Escape') { S()._composing = false; box.remove(); } });
      ta.addEventListener('paste', (e) => { const t = (e.clipboardData || window.clipboardData).getData('text'); if (/\n/.test(t)) { e.preventDefault(); HM.typeLines(ta.value + t); ta.value = ''; setTimeout(() => HM.sheet.compose(), 0); } });
      box.querySelector('button').addEventListener('click', add);
      host.appendChild(box);
    }
    const ta = box.querySelector('textarea'); ta.focus(); box.scrollIntoView({ block: 'nearest' });
  };

  HM.renderNotes = () => {
    host = host || document.getElementById('notes');
    if (!host._wired) {
      host._wired = true;
      host.addEventListener('click', (e) => {
        if (S().editing || e.target.closest('.row, .sec-head, .np-bar, button, .type-line, .pop')) return;
        const tl = host.querySelector('.type-line'); if (tl) { tl.focus(); const r = document.createRange(); r.selectNodeContents(tl); r.collapse(false); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r); }
      });
      host.addEventListener('dblclick', (e) => {
        if (S().editing || e.target.closest('.sec-head, .np-bar, .add-break, .pop, button')) return;
        const row = e.target.closest('.row[data-key]') || nearestRow(e.clientY);
        HM.sheet.startEditing(row && row.dataset.key, e.clientX, e.clientY);
      });
    }
    const keepScroll = host.scrollTop;          // a reload while recording must not bounce the sheet
    HM.ui.resetRefs(); host.innerHTML = '';
    const s = S(), flip = HM.ui.ROWS[s.flip] ? s.flip : 'diff';
    host.className = `notes flip-${flip} mus-${s.music} font-${s.font} sec-${s.secMark || 'rail'}${s.chords === 'off' ? ' no-chords' : ''}${s.editing ? ' is-editing' : ''}`;
    const all = lines();
    // Recording and already singing: the sheet is live (toolbar + rows) from the first word.
    const singing = s.growing && !!HM.liveText;
    // The board is only lyrics, and always typeable (Nate 2026-10-14): an empty session is just a blank page.
    if (!all.length && !singing && !(HM.labTyped || []).length) { finish(); return; }
    host.appendChild(toolbar(all.length));
    const asideList = HM.judge ? HM.judge.list(h, esc) : null;
    if (asideList) host.appendChild(asideList);
    if (!all.length && !(HM.labTyped || []).length) { finish(); host.scrollTop = keepScroll; return; }
    const b = breaks();
    let named = 0;
    groups(all).forEach((g) => {
      const sec = g.lines.length ? g.lines[0].sec : null, match = g.name !== null && whole(g);
      // Every named section gets a color: its own (the same as its bar on the strip), else the next in turn.
      const tone = g.name === null ? '' : match ? sec.tone : ['a', 'b', 'c'][named % 3];
      if (g.name !== null) named++;
      const box = h(`<section class="sec${g.name === null ? ' unnamed' : ''}${tone ? ` tone-${tone}` : ''}"></section>`);
      if (g.name !== null) {
        if (match && !s.editing) {
          const head = HM.ui.HEADS[flip](sec);
          box.appendChild(HM.ui.header(sec, head.tools || null, g));
          if (head.after) box.appendChild(head.after);
        } else {
          const el = h(`<header class="sec-head plain"><div class="sec-title"><span class="dot${tone ? ` tone-${tone}` : ''}"></span><h3 class="sec-name" title="Click to rename">${esc(g.name)}</h3><span class="dim">${g.lines.length} line${g.lines.length > 1 ? 's' : ''}</span></div><div class="sec-tools"></div></header>`);
          HM.sheet.wireName(el, g); box.appendChild(el);
        }
      }
      g.lines.forEach((ln, i) => {
        if (!(i === 0 && g.name !== null)) box.appendChild(gap(ln, !HM.real && ln.slot === 0 && b[ln.key] === undefined && i > 0));
        box.appendChild(HM.ui.ROWS[flip](ln.sec, ln.slot));
      });
      host.appendChild(box);
    });
    finish();
    host.scrollTop = keepScroll;
  };
  function nearestRow(y) {
    let best = null, d = Infinity;
    host.querySelectorAll('.row[data-key]').forEach((r) => { const b = r.getBoundingClientRect(), dd = Math.abs(y - (b.top + b.bottom) / 2); if (dd < d) { d = dd; best = r; } });
    return best;
  }
  function typeLine() {
    const empty = !host.querySelector('.row[data-key]') && !(HM.labTyped || []).length;
    // Built like a committed row (same section, row and lyric boxes) so the line you type sits exactly
    // where it lands on Enter (Nate 2026-10-14: it sat ~110 px right and jumped left).
    const wrap = h(`<section class="sec unnamed type-sec"><div class="row type-row"><div class="row-main"><div class="lyric type-line" contenteditable="plaintext-only" spellcheck="false" data-ph="${empty ? 'Sing, or start typing…' : ''}"></div></div></div></section>`);
    const el = wrap.querySelector('.type-line');
    el.textContent = S()._typeDraft || '';
    el.addEventListener('input', () => { S()._typeDraft = el.textContent; });
    el.addEventListener('focus', () => { S()._typing = true; HM.highlight(); });
    el.addEventListener('blur', () => { S()._typing = false; HM.highlight(); });
    el.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter') { e.preventDefault(); const t = el.textContent; S()._typeDraft = ''; el.textContent = ''; S()._refocus = true; HM.typeLines(t); }
      else if (e.key === 'Escape') el.blur();
    });
    el.addEventListener('paste', (e) => {
      const t = (e.clipboardData || window.clipboardData).getData('text');
      if (!/\n/.test(t)) return;
      e.preventDefault(); const all = el.textContent + t; S()._typeDraft = ''; el.textContent = ''; S()._refocus = true; HM.typeLines(all);
    });
    return wrap;
  }
  function labRows() {
    let sec = null;
    (HM.labTyped || []).forEach((t) => {
      const name = HM.sheet.headerName(t);
      if (name || !sec) { sec = h(`<section class="sec${name ? '' : ' unnamed'}"></section>`); host.appendChild(sec); }
      if (name) sec.appendChild(h(`<header class="sec-head plain"><div class="sec-title"><h3 class="sec-name">${esc(name)}</h3></div></header>`));
      else sec.appendChild(h(`<div class="row typed-row"><div class="row-main"><div class="lyric">${esc(t)}</div></div></div>`));
    });
  }
  function finish() {
    if (!S().editing) {
      labRows();
      const tlw = typeLine(), last = [...host.children].filter((c) => c.matches('section.sec')).pop();
      // Same section as the last line, so the gap above it is the gap between lines.
      if (last) { last.appendChild(tlw.querySelector('.row')); host.appendChild(h('<div class="type-spacer"></div>')); } else host.appendChild(tlw);
      const tl = host.querySelector('.type-line');
      if (S()._typing || S()._refocus) { S()._refocus = false; tl.focus(); const r = document.createRange(); r.selectNodeContents(tl); r.collapse(false); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r); }
    }
    if (S().editing) HM.sheet.makeEditable();
    const old = document.querySelector('.hud'); if (old) old.remove();
    const hd = HM.ui.hud(); if (hd) host.parentElement.appendChild(hd);
    HM.highlight();
    if (S()._composing && !host.querySelector('.composer')) { const f = document.activeElement; HM.sheet.compose(); if (f && f !== document.body && !f.closest('.composer')) f.focus(); }
    if (HM.strip && HM.strip.draw) HM.strip.draw();   // section blocks on the strip follow the notepad
  }
})(window.HM);
