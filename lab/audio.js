/* Hot Mic design lab: demo sound. A synthesized beat (drums, strummed chords, bass) and a hummed
   guide voice that sings each take's melody and rhythm, so flipping takes is something you hear. */
(function (HM) {
  const LOOK = 0.15;
  const OPEN = [40, 45, 50, 55, 59, 64];
  let ctx, master, bus, noise, horizon = 0;
  HM.audio = { on: true };

  function ensure() {
    if (!ctx) {
      ctx = new (window.AudioContext || window.webkitAudioContext)();
      master = ctx.createGain(); master.gain.value = 0.9;
      const comp = ctx.createDynamicsCompressor(); comp.threshold.value = -14; comp.ratio.value = 4;
      master.connect(comp); comp.connect(ctx.destination);
      noise = ctx.createBuffer(1, ctx.sampleRate, ctx.sampleRate);
      const d = noise.getChannelData(0); for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    }
    if (ctx.state === 'suspended') ctx.resume();
  }
  function freshBus() {
    if (!ctx) return;
    if (bus) { const old = bus; old.gain.setTargetAtTime(0, ctx.currentTime, 0.015); setTimeout(() => old.disconnect(), 400); }
    bus = ctx.createGain(); bus.connect(master);
  }

  // ---------- instruments ----------
  const hz = (m) => 440 * 2 ** ((m - 69) / 12);
  function env(g, t, peak, a, hold, rel) {
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(peak, t + a);
    g.gain.setValueAtTime(peak, t + a + hold); g.gain.exponentialRampToValueAtTime(0.0001, t + a + hold + rel);
  }
  function voice(midi, t, dur) {
    const f = hz(midi), o1 = ctx.createOscillator(), o2 = ctx.createOscillator(), vib = ctx.createOscillator(), vg = ctx.createGain();
    o1.type = 'sawtooth'; o2.type = 'triangle'; o1.frequency.value = f; o2.frequency.value = f * 1.004;
    vib.frequency.value = 5.3; vg.gain.value = f * 0.011; vib.connect(vg); vg.connect(o1.frequency); vg.connect(o2.frequency);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 1500;
    const form = ctx.createBiquadFilter(); form.type = 'peaking'; form.frequency.value = 820; form.Q.value = 1.4; form.gain.value = 7;
    const g = ctx.createGain(); env(g, t, 0.16, 0.035, Math.max(0.02, dur - 0.06), 0.12);
    o1.connect(lp); o2.connect(lp); lp.connect(form); form.connect(g); g.connect(bus);
    [o1, o2, vib].forEach((o) => { o.start(t); o.stop(t + dur + 0.25); });
  }
  function pluck(midi, t, vel) {
    const o = ctx.createOscillator(), lp = ctx.createBiquadFilter(), g = ctx.createGain();
    o.type = 'triangle'; o.frequency.value = hz(midi); lp.type = 'lowpass'; lp.frequency.setValueAtTime(3200, t); lp.frequency.exponentialRampToValueAtTime(700, t + 0.9);
    env(g, t, vel, 0.004, 0.02, 1.3); o.connect(lp); lp.connect(g); g.connect(bus); o.start(t); o.stop(t + 1.5);
  }
  function bass(midi, t, dur) {
    const o = ctx.createOscillator(), lp = ctx.createBiquadFilter(), g = ctx.createGain();
    o.type = 'triangle'; o.frequency.value = hz(midi); lp.type = 'lowpass'; lp.frequency.value = 520;
    env(g, t, 0.34, 0.01, dur * 0.5, dur * 0.5); o.connect(lp); lp.connect(g); g.connect(bus); o.start(t); o.stop(t + dur + 0.1);
  }
  function kick(t, v = 1) {
    const o = ctx.createOscillator(), g = ctx.createGain();
    o.frequency.setValueAtTime(150, t); o.frequency.exponentialRampToValueAtTime(42, t + 0.13);
    env(g, t, 0.95 * v, 0.003, 0.02, 0.26); o.connect(g); g.connect(bus); o.start(t); o.stop(t + 0.35);
  }
  function hiss(t, hp, peak, rel, bp) {
    const s = ctx.createBufferSource(), f = ctx.createBiquadFilter(), g = ctx.createGain();
    s.buffer = noise; f.type = bp ? 'bandpass' : 'highpass'; f.frequency.value = hp; if (bp) f.Q.value = 0.8;
    env(g, t, peak, 0.002, 0.005, rel); s.connect(f); f.connect(g); g.connect(bus); s.start(t, Math.random() * 0.5); s.stop(t + rel + 0.05);
  }
  const snare = (t, v = 1) => { hiss(t, 1800, 0.42 * v, 0.16, true); const o = ctx.createOscillator(), g = ctx.createGain(); o.frequency.value = 190; env(g, t, 0.25 * v, 0.002, 0.01, 0.08); o.connect(g); g.connect(bus); o.start(t); o.stop(t + 0.12); };
  const hat = (t, v = 1) => hiss(t, 7500, 0.11 * v, 0.045);

  // ---------- what plays when ----------
  HM.chordNotes = (name) => (HM.SHAPES[name] || HM.SHAPES.Am).map((f, s) => (f < 0 ? null : OPEN[s] + f)).filter((n) => n !== null);
  const PART_SEC = { 4: 'v1', 12: 'hook', 20: 'v2', 28: 'hook', 40: 'hook' };
  const FILL = { Intro: ['Am7', 'Fmaj7'], Bridge: ['Dm7', 'Esus4'], Outro: ['Am7', 'Fmaj7'] };
  function partAt(bar) { return HM.beat.parts.find(([, a, b]) => bar >= a && bar < b) || HM.beat.parts[HM.beat.parts.length - 1]; }
  function chordAt(bar) {
    const [name, a] = partAt(bar), id = PART_SEC[a], k = bar - a;
    if (!id) return FILL[name][k % 2];
    const sec = HM.sec(id), slot = Math.floor(k / 2) % sec.slots;
    const line = HM.visiblePasses(sec).length ? HM.shown(sec, slot).line : sec.passes[0].lines[slot];
    return line.chords[k % 2] || line.chords[0];
  }
  const ENERGY = { Intro: 0.5, Verse: 0.8, Hook: 1, Bridge: 0.55, Outro: 0.45 };

  function schedule(t0, t1, now) {
    const at = (e) => ctx.currentTime + 0.03 + Math.max(0, e - now), S = HM.S, half = HM.BEAT / 2;
    if (S.mode === 'beat' && !HM.beat.buffer) {
      for (let k = Math.ceil(t0 / half - 1e-6); k * half < t1; k++) {
        const t = k * half, bar = Math.floor(t / HM.BAR), inBar = k % 8, [part] = partAt(bar), e = ENERGY[part];
        if (bar >= HM.beat.bars) break;
        const when = at(t);
        if (part !== 'Intro' && part !== 'Bridge' && (inBar === 0 || inBar === 5)) kick(when, e);
        if (part === 'Bridge' && inBar === 0) kick(when, 0.6);
        if (part !== 'Intro' && (inBar === 2 || inBar === 6)) snare(when, e);
        hat(when, inBar % 2 ? 0.6 : 1);
        if (inBar === 0 || inBar === 4) {
          const notes = HM.chordNotes(chordAt(bar));
          notes.forEach((n, i) => pluck(n, when + i * 0.014, (inBar ? 0.05 : 0.075) * e));
          bass(notes[0] < 45 ? notes[0] : notes[0] - 12, when, HM.BEAT * 1.8);
        }
      }
      HM.sections.forEach((sec) => { const p = HM.shownPass(sec); if (p) sing(sec, p, p.beatAt, t0, t1, at); });
    } else if (S.mode === 'beat') {
      // A real session: your recording (with the beat in it). The demo song: the synth guide voice.
      if (hasRecording()) { if (!S.growing) HM.real.play(t0, t1, now); }
      else HM.sections.forEach((sec) => { const p = HM.shownPass(sec); if (p) sing(sec, p, p.beatAt, t0, t1, at); });
    } else {
      if (HM.real && HM.real.play) HM.real.play(t0, t1, now);
      else HM.sections.forEach((sec) => HM.visiblePasses(sec).forEach((p) => sing(sec, p, p.at, t0, t1, at)));
    }
  }
  function sing(sec, p, base, t0, t1, at) {
    if (base + p.dur < t0 || base > t1) return;
    const beat = HM.S.mode === 'beat';
    p.lines.forEach((_, slot) => {
      const line = beat ? HM.shown(sec, slot).line : p.lines[slot];
      line.words.forEach((w) => { const t = base + w.off; if (t >= t0 && t < t1) voice(w.note, at(t), w.dur); });
    });
  }

  // ---------- transport hooks ----------
  // Beat mode loops on the audio clock (Nate 2026-10-13: "the loop wasn't working properly"). The beat is one
  // AudioBufferSource with native loopStart/loopEnd, so it wraps sample-exact and never restarts; the playhead
  // follows the audio clock (beatClock) instead of animation frames, so picture and sound can't drift apart.
  let src = null, clockAt = 0, clockT = 0;
  const hasRecording = () => !!(HM.real && HM.real.audio && HM.real.audio.files && HM.real.audio.files.length && HM.real.play);
  // Listening back to a real session plays the recording (it has the beat in it), except with the loop on:
  // the loop is for going over a stretch of the beat, so it plays the beat itself.
  const runs = () => (HM.real && HM.real.beatRuns) || [];
  const beatPlays = () => HM.beat.buffer && HM.S.mode === 'beat' && (HM.S.growing || HM.S.loop.on || !hasRecording() || runs().length > 0);
  /** Session time of your recording at beat position `t`, from the run it was recorded in (null: no run covers it). */
  HM.audio.sessionFor = (t, list = runs()) => {
    const L = HM.S.loop;
    const inLoop = (r) => r.loopOn && t >= r.loopA - 0.01 && t < r.loopB + 0.01;
    const r = [...list].reverse().find((x) => inLoop(x) && Math.abs(x.loopA - L.a) < 0.05 && Math.abs(x.loopB - L.b) < 0.05)
      || [...list].reverse().find(inLoop) || [...list].reverse().find((x) => !x.loopOn && x.beat <= t);
    if (!r) return null;
    if (!r.loopOn || t >= r.beat) return r.at + (t - r.beat);
    return r.at + (r.loopB - r.beat) + (t - r.loopA);     // before where it started: the second time round
  };
  let voiceRun = null;    // { sess, ctxAt }: your recording, running alongside the beat
  function setLoop() {
    if (!src) return;
    const L = HM.S.loop, d = HM.beat.buffer.duration;
    src.loop = !!L.on; src.loopStart = Math.max(0, Math.min(L.a, d)); src.loopEnd = Math.max(src.loopStart + 0.05, Math.min(L.b, d));
  }
  function playBeatFrom(t) {
    src = null;
    if (!bus || !beatPlays()) return;
    src = ctx.createBufferSource(); src.buffer = HM.beat.buffer; setLoop();
    const g = ctx.createGain(); g.gain.value = 0.9; src.connect(g); g.connect(bus);
    clockAt = ctx.currentTime + 0.03; clockT = t;
    const sess = !HM.S.growing && hasRecording() ? HM.audio.sessionFor(t) : null;
    voiceRun = sess === null ? null : { sess, ctxAt: clockAt };
    src.start(clockAt, Math.max(0, Math.min(t, HM.beat.buffer.duration - 0.01)));
  }
  /** Where the beat is right now (seconds into the beat), wrapped by the loop; null when no beat is playing. */
  HM.audio.beatClock = () => {
    if (!src || !ctx || !HM.S.playing) return null;
    const now = ctx.currentTime, L = HM.S.loop;
    let t = clockT + Math.max(0, now - clockAt);
    if (L.on && t >= L.b && L.b > L.a) t = L.a + ((t - L.b) % (L.b - L.a));
    // Re-anchor every call so a loop dragged mid-play wraps from where the beat is now.
    clockAt = Math.max(clockAt, now); clockT = t; setLoop();
    return t;
  };
  HM.audio.decode = (arr) => { ensure(); return ctx.decodeAudioData(arr); };
  HM.audio.start = () => { if (!HM.audio.on) return; ensure(); freshBus(); horizon = HM.S.t; playBeatFrom(HM.S.t); };
  HM.audio.stop = () => { freshBus(); src = null; voiceRun = null; if (HM.real && HM.real.stopAll) HM.real.stopAll(); };
  HM.audio.pump = () => {
    if (!ctx || !bus || !HM.S.playing || !HM.audio.on) return;
    const S = HM.S, now = S.t;
    let until = now + LOOK;
    if (S.mode === 'beat' && S.loop.on && now < S.loop.b) until = Math.min(until, S.loop.b);
    // A jump (seek, or the loop wrapping): the looping beat carries on by itself; everything else restarts here.
    if (horizon < now - 0.05 || horizon > now + LOOK + 0.05) {
      horizon = now;
      if (!(src && src.loop)) { freshBus(); playBeatFrom(now); }
    }
    if (horizon >= until) return;
    if (S.mode === 'beat' && src && hasRecording()) { if (voiceRun) HM.real.playVoice(voiceRun.sess + Math.max(0, ctx.currentTime - voiceRun.ctxAt)); }
    else schedule(horizon, until, now);
    horizon = until;
  };
  HM.audio.toggle = () => { HM.audio.on = !HM.audio.on; if (!HM.audio.on) freshBus(); else if (HM.S.playing) HM.audio.start(); };
  // A single note when you click a word while stopped is handled by seek(), which starts playback.
})(window.HM);
