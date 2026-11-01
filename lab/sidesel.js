/* Hot Mic window: the Sessions sidebar works like Notes. Click opens; ⌘-click toggles; ⇧-click selects a
   range; ⌘A selects all (after clicking in the list); Delete/⌫ moves the selection (or the open session) to
   the Trash with Undo; right-click for Delete / Show in Finder. In the browser lab there's nothing to delete. */
(function (HM) {
  const sel = new Set();
  let anchor = null, listFocused = false, menu = null;
  const post = (m) => { try { window.webkit.messageHandlers.hotmic.postMessage(m); } catch (e) { /* not in the app */ } };
  const rows = () => [...document.querySelectorAll('#side [data-session]')];
  const ids = () => rows().map((r) => r.dataset.session);
  function paint() { rows().forEach((r) => r.classList.toggle('sel', sel.has(r.dataset.session))); }
  function closeMenu() { if (menu) { menu.remove(); menu = null; } }

  // Re-apply the selection whenever the sidebar redraws.
  const side = document.getElementById('side');
  if (side) new MutationObserver(paint).observe(side, { childList: true, subtree: true });

  document.addEventListener('click', (e) => {
    if (e.target.closest('.side-menu')) return;       // the menu handles its own clicks
    closeMenu();
    const row = e.target.closest('#side [data-session]');
    listFocused = !!e.target.closest('#side');
    if (!row) { if (!e.target.closest('#side')) { sel.clear(); paint(); } return; }
    const id = row.dataset.session;
    if (e.metaKey) {                                  // ⌘-click: add/remove, don't open
      e.stopImmediatePropagation(); e.preventDefault();
      sel.has(id) ? sel.delete(id) : sel.add(id); anchor = id; paint(); return;
    }
    if (e.shiftKey && anchor) {                       // ⇧-click: range from the last one, don't open
      e.stopImmediatePropagation(); e.preventDefault();
      const all = ids(), a = all.indexOf(anchor), b = all.indexOf(id);
      if (a >= 0 && b >= 0) { sel.clear(); all.slice(Math.min(a, b), Math.max(a, b) + 1).forEach((x) => sel.add(x)); }
      paint(); return;
    }
    sel.clear(); sel.add(id); anchor = id; paint();   // plain click: just this one (and it opens)
  }, true);

  function trash(list) {
    list = list.filter(Boolean);
    if (!list.length) return;
    post({ cmd: 'deleteSessions', ids: list });
    sel.clear(); paint();
  }
  function targets() {
    if (sel.size) return [...sel];
    const open = document.querySelector('#side .s-row.on[data-session], #side .s-card.on[data-session]');
    return open ? [open.dataset.session] : [];
  }

  document.addEventListener('keydown', (e) => {
    if (e.target.isContentEditable || /INPUT|TEXTAREA|SELECT/.test(e.target.tagName)) return;
    if ((e.key === 'Backspace' || e.key === 'Delete') && listFocused) { e.preventDefault(); trash(targets()); }
    else if (e.metaKey && e.key.toLowerCase() === 'a' && listFocused) { e.preventDefault(); ids().forEach((x) => sel.add(x)); paint(); }
    else if (e.key === 'Escape') { sel.clear(); paint(); closeMenu(); }
  });

  document.addEventListener('contextmenu', (e) => {
    const row = e.target.closest('#side [data-session]');
    closeMenu();
    if (!row) return;
    e.preventDefault();
    listFocused = true;
    if (!sel.has(row.dataset.session)) { sel.clear(); sel.add(row.dataset.session); anchor = row.dataset.session; paint(); }
    const n = sel.size;
    menu = document.createElement('div');
    menu.className = 'side-menu';
    menu.innerHTML = `<button data-m="delete">Delete${n > 1 ? ` ${n} sessions` : ''}</button>${n === 1 ? '<button data-m="finder">Show in Finder</button>' : ''}`;
    menu.style.left = `${e.clientX}px`; menu.style.top = `${e.clientY}px`;
    document.body.appendChild(menu);
    menu.addEventListener('click', (ev) => {
      const m = ev.target.closest('[data-m]'); if (!m) return;
      ev.stopPropagation();
      if (m.dataset.m === 'delete') trash([...sel]);
      if (m.dataset.m === 'finder') post({ cmd: 'revealSession', id: [...sel][0] });
      closeMenu();
    });
  });

  // The app's answer: "Moved N to the Trash · Undo".
  HM.sideDeleted = (n, failed) => {
    let el = document.querySelector('.side-toast');
    if (!el) { el = document.createElement('div'); el.className = 'side-toast'; document.body.appendChild(el); }
    clearTimeout(el._t);
    el.innerHTML = failed
      ? `<span>${failed}</span>`
      : `<span>Moved ${n} session${n > 1 ? 's' : ''} to the Trash</span><button data-undo>Undo</button>`;
    const u = el.querySelector('[data-undo]');
    if (u) u.onclick = () => { post({ cmd: 'undoDelete' }); el.remove(); };
    el._t = setTimeout(() => el.remove(), 7000);
  };
})(window.HM);
