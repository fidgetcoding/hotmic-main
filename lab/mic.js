/* Hot Mic design lab: "Use my mic". Listens to your real voice: the strip draws your level, a take
   starts when you sing and ends after a pause, live words come from the browser's speech recognition,
   and each take's lines land in the sheet, grouped with earlier lines you sang the same way.
   Clicking a word plays your actual recording back. (The app does this with its own engine.) */
(function (HM) {
  if (window.HM_HOST) return;
  const RATE = 20, ON = 0.035, OFF_AFTER = 1.4;
  let stream, actx, an, buf, rec, mr, chunks = [], raf = 0, last = 0;
  let voiced = false, takeStart = 0, quietSince = 0, finals = [], interim = '', takeFinals = 0, takeN = 0, note = '';
  const S = () => HM.S;

  const tokens = (s) => s.toLowerCase().replace(/[^a-z' ]/g, ' ').split(/\s+/).filter(Boolean);
  function similar(a, b) {
    const A = tokens(a), B = tokens(b); if (!A.length || !B.length) return 0;
    const pool = [...B]; let hit = 0;
    A.forEach((w) => { const i = pool.indexOf(w); if (i >= 0) { hit++; pool.splice(i, 1); } });
    return (2 * hit) / (A.length + B.length);
  }

  // Put one sung line into the sheet: a new version of a line you've sung before, or a new line.
  function addLine(text, at, dur, url, offset) {
    let sec = HM.sections.find((s) => s.passes.some((p) => similar(p.lines[0].text, text) >= 0.5));
    if (!sec) { const i = HM.sections.length; sec = { id: `m${i}`, name: `Line ${i + 1}`, tone: ['a', 'b', 'c'][i % 3], slots: 1, passes: [] }; HM.sections.push(sec); }
    const ws = text.split(/\s+/), step = dur / Math.max(1, ws.length);
    const line = { text, flow: 'on the beat', chords: [], key: `${text}|on the beat`,
      words: ws.map((w, j) => ({ w, off: j * step, dur: step * 0.85, note: 60 + ((j * 5) % 7) })) };
    const n = sec.passes.length + 1;
    sec.passes.push({ id: `${sec.id}p${n}`, n, at, beatAt: at, dur, score: { whole: 1, pitch: 1, timing: 1, total: 0.5 }, note: '',
      lines: [line], wording: line.key, real: { takeID: `take${takeN}`, start: offset, end: offset + dur, voice: url } });
  }

  function endTake() {
    voiced = false;
    const s = S(), end = s.elapsed, start = takeStart, mine = finals.slice(takeFinals).map((t) => t.trim()).filter(Boolean);
    if (!mine.length && interim.trim()) mine.push(interim.trim());
    interim = '';
    const finish = (url) => {
      // spread the take's lines across the time you were singing
      const total = Math.max(0.8, end - start - OFF_AFTER), per = total / Math.max(1, mine.length);
      mine.forEach((t, i) => addLine(t, start + i * per, per, url, i * per));
      HM.renderNotes(); HM.strip.head(); HM.strip.draw();
    };
    if (mr && mr.state === 'recording') { mr.onstop = () => finish(URL.createObjectURL(new Blob(chunks, { type: mr.mimeType || 'audio/webm' }))); mr.stop(); }
    else finish(null);
  }

  function draw() {
    const notes = document.getElementById('notes'); if (!notes) return;
    let el = notes.querySelector('.live-line');
    const lines = voiced ? [...finals.slice(takeFinals), interim].map((t) => t.trim()).filter(Boolean) : [];
    if (!lines.length && !note) { if (el) el.remove(); return; }
    if (lines.length) notes.querySelector('.empty')?.remove();
    if (!el) { el = document.createElement('div'); el.className = 'live-line'; notes.appendChild(el); }
    el.innerHTML = '';
    lines.forEach((ln, i) => {
      const row = document.createElement('div'); row.className = 'live-row';
      const sp = document.createElement('span'); sp.className = 'live-text'; sp.textContent = ln; row.appendChild(sp);
      if (i === lines.length - 1) { const c = document.createElement('i'); c.className = 'live-caret'; row.appendChild(c); }
      el.appendChild(row);
    });
    if (note) { const n = document.createElement('div'); n.className = 'live-notice'; n.textContent = note; el.appendChild(n); }
    el.scrollIntoView({ block: 'end', behavior: 'smooth' });
  }

  function tick(now) {
    const s = S(); if (!s.micLive) { raf = 0; return; }
    const dt = Math.min(0.1, (now - last) / 1000); last = now;
    s.elapsed += dt; s.t = s.elapsed;
    an.getFloatTimeDomainData(buf);
    let sum = 0; for (let i = 0; i < buf.length; i++) sum += buf[i] * buf[i];
    const level = Math.sqrt(sum / buf.length), idx = Math.floor(s.elapsed * RATE);
    const env = HM.envelopes.session; if (idx < env.length) env[idx] = Math.max(0.03, Math.min(1, level * 9));
    if (level > ON) {
      quietSince = 0;
      if (!voiced) { voiced = true; takeStart = s.elapsed; takeFinals = finals.length; takeN += 1; chunks = []; try { mr.start(); } catch (e) { /* not ready */ } }
    } else if (voiced) {
      if (!quietSince) quietSince = s.elapsed;
      else if (s.elapsed - quietSince > OFF_AFTER) endTake();
    }
    const live = document.querySelector('[data-live]'); if (live) live.textContent = `${HM.fmt(s.elapsed)} · ${HM.countTakes()} takes`;
    draw();
    raf = requestAnimationFrame(tick);
  }

  async function start() {
    if (S().micLive) return;
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } }); }
    catch (e) { alert('Hot Mic needs the microphone. Allow it in the browser (and System Settings → Privacy → Microphone for your browser), then try again.'); return; }
    actx = new (window.AudioContext || window.webkitAudioContext)();
    an = actx.createAnalyser(); an.fftSize = 1024; buf = new Float32Array(an.fftSize);
    actx.createMediaStreamSource(stream).connect(an);
    mr = new MediaRecorder(stream); mr.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
    // empty live session
    HM.sections = []; HM.sessionLen = 3600; HM.envelopes.session = new Float32Array(HM.sessionLen * RATE).fill(0.03); HM.envelopes.sRate = RATE;
    HM.real = { name: 'Live mic', play, stopAll };
    finals = []; interim = ''; takeN = 0; note = '';
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (SR) {
      rec = new SR(); rec.continuous = true; rec.interimResults = true; rec.lang = 'en-US';
      rec.onresult = (e) => {
        interim = '';
        for (let i = e.resultIndex; i < e.results.length; i++) {
          const t = e.results[i][0].transcript;
          if (e.results[i].isFinal) finals.push(t); else interim += t;
        }
      };
      rec.onerror = (e) => { if (e.error === 'not-allowed') note = 'Speech recognition is blocked in this browser, so takes will land without words.'; };
      rec.onend = () => { if (S().micLive) try { rec.start(); } catch (e) { /* already running */ } };
      try { rec.start(); } catch (e) { /* ignore */ }
    } else note = 'This browser has no speech recognition, so takes will land without words.';
    HM.newSession();
    Object.assign(S(), { mode: 'solo', micLive: 1, growing: true, playing: false, elapsed: 0, t: 0, fresh: false });
    HM.render();
    last = performance.now(); if (!raf) raf = requestAnimationFrame(tick);
  }

  function stop() {
    const s = S(); if (!s.micLive) return;
    if (voiced) endTake();
    s.micLive = 0; s.growing = false; HM.sessionLen = Math.max(10, Math.ceil(s.elapsed)); s.elapsed = HM.sessionLen;
    try { rec && rec.stop(); } catch (e) { /* ignore */ }
    setTimeout(() => { stream && stream.getTracks().forEach((t) => t.stop()); }, 400);
    note = ''; draw(); HM.render();
  }

  // play your takes back
  const playing = [];
  function play(t0, t1, nowT) {
    HM.sections.forEach((sec) => HM.visiblePasses(sec).forEach((p) => {
      if (!p.real.voice || p.at < t0 || p.at >= t1) return;
      const a = new Audio(p.real.voice), delay = Math.max(0, (p.at - nowT) * 1000);
      setTimeout(() => { if (!S().playing) return; a.currentTime = p.real.start; a.play().catch(() => {}); playing.push(a); setTimeout(() => a.pause(), p.dur * 1000 + 150); }, delay);
    }));
  }
  function stopAll() { while (playing.length) playing.pop().pause(); }

  HM.mic = { start, stop };
  // the record button / R toggle the mic session while it's the live mode
  window.addEventListener('DOMContentLoaded', () => {
    const rec0 = HM.record; HM.record = (...a) => (S().micLive ? stop() : rec0(...a));
    const orig = HM.renderNotes; HM.renderNotes = (...a) => { const r = orig(...a); if (S().micLive) draw(); return r; };
  });
})(window.HM);
