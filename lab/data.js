/* Hot Mic design lab: mock session. Every lyric, take and score here is made up. */
window.HM = window.HM || {};
(function (HM) {
  const BPM = 88, BEAT = 60 / BPM, BAR = BEAT * 4, LINE_BARS = 2;
  Object.assign(HM, { BPM, BEAT, BAR, KEY: 'A minor' });

  function rng(seed) {
    let s = seed >>> 0;
    return () => {
      s = (s + 0x6D2B79F5) >>> 0;
      let t = Math.imul(s ^ (s >>> 15), s | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function hash(str) { let h = 2166136261; for (const c of str) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619); } return h >>> 0; }
  HM.rng = rng; HM.hash = hash;

  // The song as it was sung: each pass = one time through a section.
  const V1 = [['Am7', 'Fmaj7'], ['C', 'G6'], ['Am7', 'Fmaj7'], ['C', 'G']];
  const HK = [['F', 'C/E'], ['Dm7', 'Esus4'], ['F', 'C/E'], ['Dm7', 'E']];
  const V2 = [['Am', 'F'], ['C', 'G'], ['Dm7', 'Am'], ['Fmaj7', 'Esus4']];
  const L = (text, flow = 'on the beat', chords = null) => ({ text, flow, chords });

  const RAW = [
    { id: 'v1', name: 'Verse 1', tone: 'a', beatBar: 4, chords: V1, passes: [
      { at: 52, bar: 4, score: [0.58, 0.78, 0.71], note: 'restarted line 3', lines: [
        L('Streetlights hum in a minor key'), L('I been counting all the cars that never stop for me'),
        L('Your voice still on the answering machine', 'laid back'), L('Playing back the parts I never meant to keep')] },
      { at: 130, bar: 4, score: [0.9, 0.83, 0.8], lines: [
        L('Streetlights humming in a minor key'), L('Counting every car that never stops for me', 'double-time'),
        L('Your voice still on the answering machine', 'laid back'), L('Playing back the parts I never meant to keep')] },
      { at: 211, bar: 4, score: [1, 0.88, 0.9], lines: [
        L('Streetlights hum in a minor key'), L('Counting every car that never stops for me', 'double-time'),
        L('Your voice still living on the answering machine', 'laid back'),
        L('Rewinding all the parts I swore I\'d never keep', 'on the beat', ['C', 'Esus4'])] },
      { at: 520, bar: 4, score: [1, 0.84, 0.86], lines: [
        L('Streetlights hum in a minor key'), L('Counting every car that never stops for me', 'double-time'),
        L('Your voice still living on the answering machine', 'laid back'),
        L('Rewinding all the parts I swore I\'d never keep', 'on the beat', ['C', 'Esus4'])] },
    ] },
    { id: 'hook', name: 'Hook', tone: 'b', beatBar: 12, chords: HK, passes: [
      { at: 300, bar: 12, score: [0.7, 0.75, 0.7], lines: [
        L('Leave the light on, leave the light on'), L('I\'ll be home before the morning comes'),
        L('Leave the light on, leave the light on'), L('Even if I\'m not the one')] },
      { at: 360, bar: 12, score: [0.95, 0.8, 0.78], lines: [
        L('Leave the light on, leave the light on'), L('I\'ll be home before the night is done'),
        L('Leave the light on, leave the light on'), L('Even if you\'re not the one')] },
      { at: 610, bar: 12, score: [0.92, 0.91, 0.85], lines: [
        L('Leave the light on, leave the light on', 'on the beat', ['Fadd9', 'C/E']), L('I\'ll be home before the morning comes'),
        L('Leave the light on, leave the light on'), L('Even if I\'m not the one')] },
      { at: 700, bar: 28, score: [1, 0.86, 0.9], lines: [
        L('Leave the light on, leave the light on', 'on the beat', ['Fadd9', 'C/E']), L('I\'ll be home before the morning comes'),
        L('Leave the light on, leave the light on'), L('Even if I\'m not the one')] },
      { at: 760, bar: 40, score: [0.8, 0.9, 0.88], lines: [
        L('Leave the light on, leave the light on', 'on the beat', ['Fadd9', 'C/E']), L('I\'ll be home before the morning breaks'),
        L('Leave the light on, leave the light on'), L('Even if I\'m not the one')] },
    ] },
    { id: 'v2', name: 'Verse 2', tone: 'c', beatBar: 20, chords: V2, passes: [
      { at: 830, bar: 20, score: [0.75, 0.82, 0.7], lines: [
        L('Coffee cold on the window sill'), L('Every letter that I write I never send, I never will', 'double-time'),
        L('Ceiling fan is spinning out of time', 'laid back'), L('Counting every second like it\'s mine')] },
      { at: 895, bar: 20, score: [0.88, 0.85, 0.8], lines: [
        L('Coffee going cold on the window sill'), L('Every letter that I write I never send, I never will', 'double-time'),
        L('Ceiling fan is spinning out of time', 'laid back'), L('Holding every second like it\'s mine')] },
    ] },
  ];

  const FLOW = { 'on the beat': [0.1, 6.4], 'laid back': [0.55, 6.2], 'double-time': [0.1, 4.2] };
  const PENTA = [57, 60, 62, 64, 67, 69, 72];

  function melodyFor(key, n) {
    const r = rng(hash(key)); let i = 2 + Math.floor(r() * 3); const out = [];
    for (let k = 0; k < n; k++) { i = Math.max(0, Math.min(PENTA.length - 1, i + Math.round((r() - 0.5) * 3))); out.push(PENTA[i]); }
    return out;
  }

  function timeLine(line, slot, passSeed) {
    const words = line.text.split(/\s+/);
    const [start, span] = FLOW[line.flow] || FLOW['on the beat'];
    const r = rng(passSeed + slot * 31), step = (span * BEAT) / words.length;
    const melody = melodyFor(line.text + '|' + line.flow, words.length);
    const lineOff = slot * LINE_BARS * BAR;
    return words.map((w, i) => {
      const off = lineOff + start * BEAT + i * step + (r() - 0.5) * step * 0.25;
      return { w, off, dur: step * 0.82, note: melody[i] };
    });
  }

  HM.sections = RAW.map((sec) => {
    const passes = sec.passes.map((p, pi) => {
      const total = p.score[0] * 0.5 + p.score[1] * 0.25 + p.score[2] * 0.25;
      const lines = p.lines.map((ln, slot) => ({
        ...ln, chords: ln.chords || sec.chords[slot], key: ln.text + '|' + ln.flow,
        words: timeLine(ln, slot, hash(sec.id + pi)),
      }));
      return {
        id: `${sec.id}p${pi + 1}`, n: pi + 1, at: p.at, beatAt: p.bar * BAR, dur: lines.length * LINE_BARS * BAR,
        score: { whole: p.score[0], pitch: p.score[1], timing: p.score[2], total }, note: p.note || '', lines,
        wording: lines.map((l) => l.key).join('\n'),
      };
    });
    return { id: sec.id, name: sec.name, tone: sec.tone, slots: sec.passes[0].lines.length, passes };
  });
  HM.sec = (id) => HM.sections.find((s) => s.id === id);
  HM.LINE_DUR = LINE_BARS * BAR;

  // Unique wordings (words + flow) for one line across the passes you can see.
  HM.versions = (sec, slot, passes) => {
    const map = new Map();
    passes.forEach((p) => {
      const line = p.lines[slot];
      if (!map.has(line.key)) map.set(line.key, { id: `${sec.id}:${slot}:${map.size}`, key: line.key, text: line.text, flow: line.flow, chords: line.chords, passes: [] });
      map.get(line.key).passes.push(p);
    });
    const list = [...map.values()];
    list.forEach((v, i) => {
      v.best = v.passes.reduce((a, b) => (b.score.total >= a.score.total ? b : a));
      v.latest = v.passes[v.passes.length - 1];
      v.index = i;
      const prev = list[i - 1];
      v.chordChanged = !!prev && prev.chords.join() !== v.chords.join();
    });
    return list;
  };

  // A wording is settled once you sing it on 2 passes in a row (latest such pair wins).
  function settledKey(keys) {
    for (let i = keys.length - 1; i > 0; i--) if (keys[i] === keys[i - 1]) return keys[i];
    return null;
  }
  HM.suggestPass = (sec, passes, rule) => {
    if (!passes.length) return null;
    if (rule === 'recent') return passes[passes.length - 1];
    const settled = settledKey(passes.map((p) => p.wording));
    const pool = settled ? passes.filter((p) => p.wording === settled) : passes;
    return pool.reduce((a, b) => (b.score.total >= a.score.total ? b : a));
  };
  HM.suggestVersion = (sec, slot, passes, rule) => {
    const vs = HM.versions(sec, slot, passes);
    if (!vs.length) return null;
    if (rule === 'recent') return vs.find((v) => v.key === passes[passes.length - 1].lines[slot].key);
    const settled = settledKey(passes.map((p) => p.lines[slot].key));
    if (settled) return vs.find((v) => v.key === settled);
    return vs.reduce((a, b) => (b.best.score.total >= a.best.score.total ? b : a));
  };
  // "Trying": only sung on the newest pass, and different from the pass before it.
  HM.isTrying = (v, passes) => {
    if (passes.length < 2 || v.passes.length !== 1) return false;
    return v.passes[0] === passes[passes.length - 1];
  };

  HM.sessions = [
    { name: 'Leave the Light On', day: 'Today', time: '11:52 PM', len: '16:20', key: 'A minor', bpm: 88, takes: 11, kind: 'solo', current: true, seed: 3 },
    { name: 'dusty_keys_88.wav', day: 'Today', time: '9:10 PM', len: '2:22', key: 'A minor', bpm: 88, takes: 6, kind: 'beat', seed: 8 },
    { name: 'Untitled jam', day: 'Yesterday', time: '1:14 AM', len: '42:08', key: 'E major', bpm: 96, takes: 23, kind: 'solo', seed: 12 },
    { name: 'Porch loop 74', day: 'Yesterday', time: '6:40 PM', len: '3:05', key: 'D major', bpm: 74, takes: 9, kind: 'beat', seed: 21 },
    { name: 'Coffee Cold (idea)', day: 'Oct 9', time: '10:02 PM', len: '7:44', key: 'A minor', bpm: 84, takes: 4, kind: 'solo', seed: 34 },
    { name: 'Hook ideas', day: 'Oct 9', time: '2:15 PM', len: '12:31', key: 'C major', bpm: 100, takes: 14, kind: 'solo', seed: 5 },
    { name: 'midnight_drive_92.wav', day: 'Oct 7', time: '12:48 AM', len: '2:51', key: 'F# minor', bpm: 92, takes: 12, kind: 'beat', seed: 55 },
    { name: 'Lullaby sketch', day: 'Oct 6', time: '8:20 PM', len: '5:09', key: 'G major', bpm: 70, takes: 3, kind: 'solo', seed: 89 },
  ];

  // Beat layout for beat mode (bars).
  HM.beat = { name: 'dusty_keys_88.wav', bars: 52, parts: [
    ['Intro', 0, 4], ['Verse', 4, 12], ['Hook', 12, 20], ['Verse', 20, 28], ['Hook', 28, 36], ['Bridge', 36, 40], ['Hook', 40, 48], ['Outro', 48, 52]] };
  HM.beat.len = HM.beat.bars * BAR;
  HM.sessionLen = 980;

  // Loudness envelopes for the strip.
  HM.envelopes = (() => {
    const sRate = 20, sN = HM.sessionLen * sRate, session = new Float32Array(sN), r = rng(7);
    for (let i = 0; i < sN; i++) session[i] = 0.025 + r() * 0.03;
    for (let k = 0; k < 70; k++) {
      const c = Math.floor(r() * sN), len = 10 + Math.floor(r() * 50), amp = 0.12 + r() * 0.2;
      for (let i = 0; i < len && c + i < sN; i++) session[c + i] = Math.max(session[c + i], amp * (0.5 + r() * 0.5));
    }
    HM.sections.forEach((sec) => sec.passes.forEach((p) => {
      const a0 = Math.floor(p.at * sRate), a1 = Math.floor((p.at + p.dur) * sRate);
      for (let i = a0; i < a1 && i < sN; i++) session[i] = 0.06 + r() * 0.06;
      p.lines.forEach((ln) => ln.words.forEach((w) => {
        const w0 = Math.floor((p.at + w.off) * sRate), w1 = Math.floor((p.at + w.off + w.dur) * sRate);
        const peak = 0.5 + r() * 0.42;
        for (let i = w0; i < w1 && i < sN; i++) session[i] = Math.max(session[i], peak * (1 - 0.5 * ((i - w0) / Math.max(1, w1 - w0))));
      }));
    }));
    const bRate = 60, bN = Math.floor(HM.beat.len * bRate), beat = new Float32Array(bN), rb = rng(11);
    const energy = (bar) => { const part = HM.beat.parts.find(([, a, b]) => bar >= a && bar < b); return { Intro: 0.38, Verse: 0.66, Hook: 1, Bridge: 0.45, Outro: 0.3 }[part ? part[0] : 'Outro']; };
    for (let i = 0; i < bN; i++) {
      const t = i / bRate, beatPos = t / BEAT, inBeat = beatPos % 1, bi = Math.floor(beatPos) % 4, e = energy(Math.floor(t / BAR));
      let v = 0.18 + 0.1 * Math.sin(t * 0.9) + rb() * 0.06;
      v += Math.exp(-inBeat * 9) * (bi === 1 || bi === 3 ? 0.55 : 0.7);
      v += Math.exp(-((inBeat + 0.5) % 1) * 14) * 0.18;
      beat[i] = Math.min(1, v * e);
    }
    return { session, sRate, beat, bRate };
  })();
})(window.HM);
