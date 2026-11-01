/* Hot Mic design lab: bring your own beat. Drag a file anywhere onto the window, or pick one. */
(function (HM) {
  const input = Object.assign(document.createElement('input'), { type: 'file', accept: 'audio/*', hidden: true });
  input.addEventListener('change', () => { if (input.files[0]) load(input.files[0]); input.value = ''; });
  HM.pickBeat = () => { if (!input.isConnected) document.body.appendChild(input); input.click(); };

  // Tempo from the beat itself: onset strength, then the strongest repeat between 70 and 160 BPM.
  function tempo(buf) {
    const d = buf.getChannelData(0), hop = Math.floor(buf.sampleRate / 100), n = Math.floor(d.length / hop), e = new Float32Array(n);
    for (let i = 0; i < n; i++) { let s = 0; for (let j = 0; j < hop; j++) { const v = d[i * hop + j]; s += v * v; } e[i] = Math.sqrt(s / hop); }
    const on = new Float32Array(n); for (let i = 1; i < n; i++) on[i] = Math.max(0, e[i] - e[i - 1]);
    let best = 88, score = -1;
    for (let bpm = 70; bpm <= 160; bpm += 0.5) {
      const lag = 6000 / bpm; let s = 0;
      for (let i = 0; i + lag * 2 < n; i += 1) s += on[i] * (on[Math.round(i + lag)] + 0.5 * on[Math.round(i + lag * 2)]);
      if (bpm >= 80 && bpm <= 140) s *= 1.1;
      if (s > score) { score = s; best = bpm; }
    }
    return best;
  }
  function envelope(buf, rate) {
    const d = buf.getChannelData(0), step = Math.floor(buf.sampleRate / rate), n = Math.floor(d.length / step), out = new Float32Array(n);
    let peak = 1e-6;
    for (let i = 0; i < n; i++) { let s = 0; for (let j = 0; j < step; j += 4) { const v = d[i * step + j]; s += v * v; } out[i] = Math.sqrt(s / (step / 4)); peak = Math.max(peak, out[i]); }
    for (let i = 0; i < n; i++) out[i] = Math.min(1, out[i] / peak);
    return out;
  }

  async function load(file) {
    if (!/^audio\//.test(file.type) && !/\.(wav|mp3|aiff?|m4a|flac|ogg)$/i.test(file.name)) { toast('That isn\'t an audio file'); return; }
    toast(`Loading ${file.name}…`);
    let buf;
    try { buf = await HM.audio.decode(await file.arrayBuffer()); } catch (e) { toast('Couldn\'t read that file'); return; }
    const bpm = tempo(buf), oldBar = HM.BAR;
    HM.BPM = bpm; HM.BEAT = 60 / bpm; HM.BAR = HM.BEAT * 4;
    const bars = Math.max(1, Math.floor(buf.duration / HM.BAR));
    HM.beat = { name: file.name, custom: true, buffer: buf, len: buf.duration, bars, parts: [['Beat', 0, bars]] };
    HM.envelopes.beat = envelope(buf, HM.envelopes.bRate);
    HM.sections.forEach((s) => s.passes.forEach((p) => { p.beatAt = Math.min((p.beatAt / oldBar) * HM.BAR, Math.max(0, buf.duration - p.dur)); }));
    const L = HM.S.loop; HM.S.loop = { a: Math.min(L.a, HM.BAR * Math.max(0, bars - 4)), b: Math.min(HM.BAR * Math.min(bars, 4 + Math.round(L.a / HM.BAR)), buf.duration), on: L.on };
    if (HM.S.loop.b <= HM.S.loop.a) HM.S.loop = { a: 0, b: Math.min(bars, 4) * HM.BAR, on: L.on };
    HM.set({ mode: 'beat', t: 0, cue: 0, playing: false });
    toast(`${file.name} · ${Math.round(bpm)} BPM · ${bars} bars`);
  }
  HM.toast = (msg) => toast(msg);
  function toast(msg) {
    document.querySelectorAll('.toast').forEach((t) => t.remove());
    const t = document.createElement('div'); t.className = 'toast'; t.textContent = msg; document.body.appendChild(t); setTimeout(() => t.remove(), 2600);
  }

  // Freestyle: bring in a recording made outside Hot Mic (the app opens a file picker and splits it).
  HM.importRecording = () => {
    try { if (window.HM_HOST) { window.webkit.messageHandlers.hotmic.postMessage({ cmd: 'importPick' }); return; } } catch (e) { /* not in the app */ }
    toast('In the app this opens a file picker: pick a voice memo and it becomes a session');
  };
  document.addEventListener('click', (e) => { if (e.target.closest('[data-act-import]')) { e.preventDefault(); HM.importRecording(); } });

  // Drop anywhere on the app window.
  let depth = 0;
  const win = () => document.getElementById('win');
  const isFile = (e) => [...(e.dataTransfer?.types || [])].includes('Files');
  window.addEventListener('dragenter', (e) => { if (!isFile(e)) return; e.preventDefault(); depth++; win().classList.add('drop-on'); win().classList.toggle('drop-import', HM.S.mode === 'solo'); });
  window.addEventListener('dragover', (e) => { if (isFile(e)) e.preventDefault(); });
  window.addEventListener('dragleave', (e) => { if (!isFile(e)) return; depth = Math.max(0, depth - 1); if (!depth) win().classList.remove('drop-on'); });
  window.addEventListener('drop', (e) => {
    if (!isFile(e)) return; e.preventDefault(); depth = 0; win().classList.remove('drop-on');
    const f = e.dataTransfer.files[0]; if (!f) return;
    // Freestyle: the app splits a dropped recording into a session (it takes the drop before the page).
    if (HM.S.mode === 'solo') { toast(`In the app, ${f.name} becomes a session split into takes`); return; }
    load(f);
  });
})(window.HM);
