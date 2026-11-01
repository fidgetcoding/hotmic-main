// The real window page (lab/index.html and every script it loads) in jsdom, as the app runs it: HM_HOST set,
// messages to Swift captured, session data pushed through HM.host.*. There is no audio anywhere: AudioContext and
// Audio are plain fakes that only record what they were told.
import { readFileSync } from 'node:fs';
import { JSDOM, VirtualConsole } from 'jsdom';

const LAB = new URL('../../lab/', import.meta.url);

class FakeParam { constructor() { this.value = 0; } setValueAtTime() {} linearRampToValueAtTime() {} exponentialRampToValueAtTime() {} cancelScheduledValues() {} }
// Any node: any property it's asked for is a parameter.
class FakeNode {
  constructor() { return new Proxy(this, { get: (t, k) => { if (!(k in t) && typeof k === 'string') t[k] = new FakeParam(); return t[k]; } }); }
  connect() { return this; } disconnect() {} start() {} stop() {} setPeriodicWave() {}
}

function fakes(window, log) {
  const makeSource = () => {
    const node = new FakeNode();
    node.loop = false; node.loopStart = 0; node.loopEnd = 0; node.buffer = null; node.playbackRate = new FakeParam();
    node.start = (when, offset) => { log.sources.push(node); node.startedAt = when; node.offset = offset; };
    node.stop = () => { node.stopped = true; };
    return node;
  };
  window.AudioContext = class {
    constructor() { this.currentTime = 0; this.destination = new FakeNode(); this.state = 'running'; log.contexts.push(this); }
    createGain() { return new FakeNode(); } createOscillator() { return new FakeNode(); } createBiquadFilter() { return new FakeNode(); }
    createDynamicsCompressor() { return new FakeNode(); } createStereoPanner() { return new FakeNode(); } createAnalyser() { return new FakeNode(); }
    createWaveShaper() { return new FakeNode(); } createDelay() { return new FakeNode(); } createConvolver() { return new FakeNode(); }
    createBuffer(c, n, r) { return { duration: n / r, length: n, sampleRate: r, getChannelData: () => new window.Float32Array(n) }; }
    createBufferSource() { return makeSource(); }
    resume() { return window.Promise.resolve(); } decodeAudioData() { return window.Promise.resolve(null); }
  };
  window.webkitAudioContext = window.AudioContext;
  window.Audio = class {
    constructor(src) { this.src = src || ''; this.paused = true; this.currentTime = 0; this.listeners = {}; log.audio.push(this); }
    addEventListener(k, f) { this.listeners[k] = f; }
    play() { this.paused = false; this.plays = (this.plays || 0) + 1; return window.Promise.resolve(); }
    pause() { this.paused = true; }
  };
  const drawing = new Proxy({}, { get: (t, k) => (k in t ? t[k] : k === 'measureText' ? () => ({ width: 10 }) : k === 'createLinearGradient' ? () => ({ addColorStop() {} }) : k === 'getImageData' ? () => ({ data: new window.Uint8ClampedArray(4), width: 1, height: 1 }) : () => {}), set: (t, k, v) => { t[k] = v; return true; } });
  window.HTMLCanvasElement.prototype.getContext = () => drawing;
  window.ResizeObserver = class { observe() {} disconnect() {} unobserve() {} };
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  window.requestAnimationFrame = () => 0;
  window.cancelAnimationFrame = () => {};
  window.scrollTo = () => {};
  window.Element.prototype.scrollIntoView = () => {};
  window.document.caretRangeFromPoint = () => null;
}

/** Loads the window. `host: false` gives the design lab instead of the app's page. */
export function openWindow({ host = true } = {}) {
  const html = readFileSync(new URL('index.html', LAB), 'utf8').replace(/<meta http-equiv="Content-Security-Policy"[^>]*>/, '').replace(/<link [^>]*>/g, '');
  const scripts = [...html.matchAll(/<script src="([^"]+)"><\/script>/g)].map((m) => m[1]);
  const errors = [];
  const console_ = new VirtualConsole();
  console_.on('jsdomError', (e) => errors.push(e));
  const dom = new JSDOM(html.replace(/<script src="[^"]+"><\/script>/g, ''), { runScripts: 'outside-only', url: 'file:///Hot%20Mic/ui/index.html', pretendToBeVisual: false, virtualConsole: console_ });
  const { window } = dom;
  const log = { contexts: [], sources: [], audio: [], posted: [] };
  fakes(window, log);
  if (host) {
    window.HM_HOST = true;
    window.webkit = { messageHandlers: { hotmic: { postMessage: (m) => log.posted.push(JSON.parse(JSON.stringify(m))) } } };
  }
  for (const name of scripts) window.eval(readFileSync(new URL(name, LAB), 'utf8') + `\n//# sourceURL=${name}`);
  window.document.dispatchEvent(new window.Event('DOMContentLoaded'));
  window.dispatchEvent(new window.Event('DOMContentLoaded'));
  const posted = (cmd) => log.posted.filter((m) => m.cmd === cmd);
  return { window, document: window.document, HM: window.HM, log, posted, errors, close: () => window.close() };
}

// ---------- sessions, as LabSessionExport writes them ----------
export function version(id, text, at, extra = {}) {
  const words = text.split(/\s+/).filter(Boolean);
  const dur = extra.dur ?? Math.max(0.5, words.length * 0.4);
  return { id, takeID: 'takeID' in extra ? extra.takeID : 't1', text, start: at, end: at + dur, at, chords: [], keeper: false, notes: [],
    words: words.map((w, i) => ({ w, start: (i * dur) / words.length, end: ((i + 1) * dur) / words.length })), ...extra };
}
export function session(slots, extra = {}) {
  const ats = slots.flat().map((v) => v.at + (v.end - v.start));
  return { id: '/lib/Sessions/one', name: '2026-11-01 120000 One', folder: '/lib/Sessions/one', length: Math.max(10, ...ats) + 5, takes: [{ id: 't1', at: 0, dur: 60, voice: '/lib/Sessions/one/t1__voice.m4a', mix: null, confidence: 1 }],
    slots, env: [], envRate: 20, sessionAudio: [], sessionMix: [], segmentSeconds: 300, beatRuns: [], hidden: [], ...extra };
}
export const rows = (doc) => [...doc.querySelectorAll('.row[data-key] .lyric')].map((e) => [...e.querySelectorAll('.w')].map((w) => w.textContent).join(' '));
