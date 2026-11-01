/* Hot Mic design lab: real sessions. One converter for both paths:
   - the lab: `swift run hotmic-export <folder> lab/sessions/<name>.js`, then open index.html#session=<name>
   - the app: the window (host.js) pushes the same JSON through HM.host.load().
   Each sung line becomes its own one-line section, so versions, "trying", picks and word swaps
   all run on what you actually sang. */
(function (HM) {
  const tones = ['a', 'b', 'c'];
  // In the app the page can only read its own files; library audio comes through hotmic-media:// (MediaScheme).
  const fileURL = (p) => (!p ? null : window.HM_HOST ? `hotmic-media://library${p.split('/').map(encodeURIComponent).join('/')}` : `file://${encodeURI(p)}`);

  HM.realConvert = (d) => {
    const seen = {};
    HM.sections = d.slots.map((versions, i) => {
      // Named from the line's first version, not its place: picks and edits stay on their line when the judge takes a line above it away.
      const base = String((versions[0] && versions[0].id) || `s${i}`).replace(/[^\w-]/g, '_');
      seen[base] = (seen[base] || 0) + 1;
      const id = seen[base] > 1 ? `${base}_${seen[base]}` : base;
      const passes = versions.map((v, k) => {
        const line = {
          text: v.text, flow: 'on the beat', chords: v.chords || [], sung: v.notes || [], key: `${v.text}|on the beat`,
          words: v.words.map((w, j) => ({ w: w.w, off: w.start, dur: Math.max(0.12, w.end - w.start), note: 60 + ((j * 5) % 7) })),
        };
        return {
          id: `${id}p${k + 1}`, n: k + 1, at: v.at, beatAt: v.at, dur: Math.max(0.8, v.end - v.start),
          score: { whole: 1, pitch: 1, timing: 1, total: v.keeper ? 1 : 0.5 }, note: '', lines: [line], wording: line.key,
          real: { id: v.id, takeID: v.takeID, start: v.start, end: v.end, voice: fileURL((d.takes.find((t) => t.id === v.takeID) || {}).voice) },
        };
      });
      return { id, name: `Line ${i + 1}`, tone: tones[i % 3], slots: 1, passes, keeper: versions.findIndex((v) => v.keeper) };
    });
    // Recording: the length comes from the app's clock (HM.host.level) and only ever grows.
    HM.sessionLen = HM.S && HM.S.growing ? Math.max(HM.sessionLen, Math.ceil(d.length || 0)) : Math.ceil(d.length || 0);
    HM.real.beatRuns = d.beatRuns || [];
    HM.real.takes = d.takes || [];
    HM.real.hidden = d.hidden || [];
    HM.real.audio = { files: (d.sessionAudio || []).map(fileURL), mix: (d.sessionMix || []).map(fileURL), seg: d.segmentSeconds || 300 };
    HM.real = Object.assign(HM.real || {}, { name: d.name, id: d.id });
    const k = (d.takes.find((t) => t.key) || {}).key; if (k) HM.KEY = k;

    // Waveform for the strip: the real recording's levels when the app sends them.
    const growing = HM.S && HM.S.growing;
    if (d.env && d.env.length) {
      const sRate = d.envRate || 20, live = growing ? HM.envelopes.session : null;
      // Recording into a session with earlier recordings: the file gives the earlier part, the live
      // levels give the part being recorded. Neither wipes the other, and the length never jumps.
      const len = growing ? HM.sessionLen : Math.max(HM.sessionLen, Math.ceil(d.env.length / sRate));
      const env = new Float32Array(Math.max(len * sRate, d.env.length, live ? live.length : 0)).fill(0.03);
      if (live) env.set(live);
      for (let i = 0; i < d.env.length; i++) env[i] = Math.max(0.03, d.env[i] / 255);
      if (!growing) HM.sessionLen = len;
      HM.envelopes.session = env; HM.envelopes.sRate = sRate;
      return;
    }
    // Recording right now: the strip already has the live levels; keep them (the live buffer carries
    // a minute of headroom, so its length says nothing about the session's).
    if (growing && HM.envelopes.session && HM.envelopes.session.length) return;
    // No recording to read (the lab's exported fixtures): drawn from the sung words.
    const sRate = 20, env = new Float32Array(Math.max(1, HM.sessionLen) * sRate).fill(0.03);
    HM.sections.forEach((sec) => sec.passes.forEach((p) => p.lines[0].words.forEach((w) => {
      const a = Math.floor((p.at + w.off) * sRate), b = Math.floor((p.at + w.off + w.dur) * sRate);
      for (let i = a; i < b && i < env.length; i++) env[i] = Math.max(env[i], 0.55 + 0.35 * Math.sin(i));
    })));
    HM.envelopes.session = env; HM.envelopes.sRate = sRate;
  };

  // The keeper you picked in the app becomes your pick here (only where you haven't picked yet).
  HM.realApplyKeepers = () => {
    if (!HM.S) return;
    HM.sections.forEach((sec) => {
      if (sec.keeper < 0) return;
      const key = `${sec.id}:0`;
      if (!HM.S.linePicks[key]) HM.S.linePicks[key] = sec.passes[sec.keeper].lines[0].key;
    });
  };

  // Real playback. With the whole recording: one player, started where you are and moved when you
  // jump (clicking a word, the strip, a line). Without it (lab fixtures): each line from its take file.
  const playing = [], timers = [];
  let el = null, elSeg = -1;
  HM.real = HM.real || {};
  // Beat mode plays the mix (your rap with the beat as it played); Freestyle plays your voice.
  let voiceOnly = false;   // looped Beat playback: the beat plays live, so only your voice comes from the recording
  const filesFor = (A) => (!voiceOnly && HM.S.mode === 'beat' && A.mix && A.mix.length ? A.mix : A.files);
  function wholePlay(now, voice = false) {
    const A0 = HM.real.audio; if (!A0 || !A0.files.length) return false;
    voiceOnly = voice;
    const A = { files: filesFor(A0), seg: A0.seg };
    const seg = Math.min(A.files.length - 1, Math.floor(now / A.seg)), local = now - seg * A.seg;
    if (!el) {
      el = new Audio();
      el.addEventListener('ended', () => {     // next 5-minute file
        const list = filesFor(HM.real.audio);
        if (!HM.S.playing || elSeg + 1 >= list.length) return;
        elSeg += 1; el.src = list[elSeg]; el.currentTime = 0; el.play().catch(() => {});
      });
    }
    const playingAt = elSeg * A.seg + el.currentTime;
    if (elSeg !== seg || !el.src.endsWith(A.files[seg].split('/').pop())) { elSeg = seg; el.src = A.files[seg]; el.currentTime = local; el.play().catch(() => {}); }
    else if (el.paused || Math.abs(playingAt - now) > 0.35) { el.currentTime = local; el.play().catch(() => {}); }
    return true;
  }
  HM.real.play = (t0, t1, now) => {
    if (wholePlay(now)) return;
    HM.sections.forEach((sec) => HM.visiblePasses(sec).forEach((p) => {
      if (!p.real || !p.real.voice || p.at < t0 || p.at >= t1) return;
      const a = new Audio(p.real.voice), delay = Math.max(0, (p.at - now) * 1000);
      a.currentTime = p.real.start;
      timers.push(setTimeout(() => { if (!HM.S.playing) return; a.play().catch(() => {}); playing.push(a); timers.push(setTimeout(() => a.pause(), p.dur * 1000 + 150)); }, delay));
    }));
  };
  HM.real.playVoice = (now) => wholePlay(now, true);
  HM.real.stopAll = () => {
    while (timers.length) clearTimeout(timers.pop());
    while (playing.length) playing.pop().pause();
    if (el) el.pause();
  };

  // Lab path: a session file was loaded by index.html (#session=<name>).
  const d = window.HM_SESSION;
  if (d && !window.HM_HOST) {
    HM.realConvert(d);
    HM.sessions = [{ name: d.name, day: 'Real session', time: '', len: `${Math.round(d.length)}s`, key: '—', bpm: '—', takes: d.takes.length, kind: 'solo', current: true, seed: 7 },
      ...HM.sessions.map((s) => ({ ...s, current: false }))];
    window.addEventListener('DOMContentLoaded', () => HM.realApplyKeepers());
  } else if (!window.HM_HOST) {
    HM.real = null; // demo mode: synthesized audio
  }
})(window.HM);
