/* Hot Mic: Settings. The look is chosen here (gear in the title bar, or Settings… / ⌘, in the app menu),
   not in the window itself. Light/dark stays one click away in the title bar. */
(function (HM) {
  const STYLES = [
    ['vintage', 'Vintage', 'Tube amp hardware: rosewood, felt, glowing screen'],
    ['modern', 'Modern', 'Clean and flat, soft depth, no hardware'],
    ['notebook', 'Notebook', 'Your lyrics on real paper'],
  ];
  const ACCENTS = [['lilac', 'Lilac ice', '#b4c4ff'], ['ice', 'Ice', '#8fe2ff'], ['violet', 'Violet', '#a77bff'], ['periwinkle', 'Periwinkle', '#8f9cff'],
    ['frost', 'Frost violet', '#c9b8ff'], ['aurora', 'Aurora', '#8fe2ff'], ['dusk', 'Dusk', '#a77bff'], ['oxblood', 'Oxblood', '#c73b52'],
    ['ox-ice', 'Oxblood + ice', '#c73b52'], ['ox-violet', 'Oxblood + violet', '#b8405e']];
  // tiny swatches that hint at each style's surface
  const SWATCH = {
    vintage: 'linear-gradient(90deg, #4a2318 0 14%, #1d1a17 14% 86%, #4a2318 86%)',
    modern: 'linear-gradient(180deg, #23222a, #17161c)',
    notebook: 'repeating-linear-gradient(180deg, #fbf8f1 0 9px, #d6dcf3 9px 10px)',
  };
  let pop;

  function render() {
    const S = HM.S, st = S.style || 'vintage', ac = S.accent || 'lilac';
    pop.innerHTML = `
      <div class="set-head"><b>Settings</b><button class="set-x" aria-label="Close">×</button></div>
      <div class="set-sec"><div class="set-h">Style</div><div class="set-styles">${STYLES.map(([id, nm, d]) => `
        <button class="set-style${st === id ? ' on' : ''}" data-style-pick="${id}"><span class="set-sw" style="background:${SWATCH[id]}"></span><b>${nm}</b><span>${d}</span></button>`).join('')}</div></div>
      <div class="set-sec"><div class="set-h">Accent</div><div class="set-accents">${ACCENTS.map(([id, nm, c]) => `
        <button class="set-acc${ac === id ? ' on' : ''}" data-accent-pick="${id}" title="${nm}"><i style="background:${c}"></i><span>${nm}</span></button>`).join('')}</div></div>
      <div class="set-sec"><div class="set-h">Appearance</div><div class="set-row"><span>Light or dark</span><button class="set-btn" data-theme-flip>${S.look === 'tube-light' ? 'Switch to dark' : 'Switch to light'}</button></div></div>
      ${window.HM_HOST ? HM.judge.settings(S) : ''}
      <div class="set-foot">More settings land here.</div>`;
    pop.querySelector('.set-x').onclick = close;
    pop.querySelectorAll('[data-style-pick]').forEach((b) => (b.onclick = () => { HM.set({ style: b.dataset.stylePick }); render(); }));
    pop.querySelectorAll('[data-accent-pick]').forEach((b) => (b.onclick = () => { HM.set({ accent: b.dataset.accentPick }); render(); }));
    if (window.HM_HOST) HM.judge.wireSettings(pop, render);
    pop.querySelector('[data-theme-flip]').onclick = () => { HM.set({ look: HM.S.look === 'tube-light' ? 'tube' : 'tube-light' }); render(); };
  }
  function open() {
    if (!pop) { pop = document.createElement('div'); pop.className = 'settings-pop'; pop.setAttribute('role', 'dialog'); document.body.appendChild(pop); }
    render(); pop.hidden = false;
    const g = document.getElementById('settingsBtn');
    if (g) { const r = g.getBoundingClientRect(); pop.style.top = `${r.bottom + 8}px`; pop.style.right = `${Math.max(12, window.innerWidth - r.right)}px`; }
    else { pop.style.top = '64px'; pop.style.right = '24px'; }
  }
  function close() { if (pop) pop.hidden = true; }
  HM.openSettings = () => (pop && !pop.hidden ? close() : open());
  HM.closeSettings = close;

  document.addEventListener('click', (e) => {
    if (e.target.closest('#settingsBtn')) { HM.openSettings(); return; }
    if (pop && !pop.hidden && !pop.contains(e.target)) close();
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') close();
    // ⌘, in the lab (the app's menu item sends HM.openSettings() itself)
    if ((e.metaKey || e.ctrlKey) && e.key === ',' && !window.HM_HOST) { e.preventDefault(); HM.openSettings(); }
  });
})(window.HM);
