// The window's behaviour, on the real page code in jsdom. Most of this was only ever checked by eye.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openWindow, session, version, rows } from './window.mjs';

const plain = (o) => JSON.parse(JSON.stringify(o));
const click = (w, el) => el.dispatchEvent(new w.window.MouseEvent('click', { bubbles: true }));
const key = (w, el, k, extra = {}) => el.dispatchEvent(new w.window.KeyboardEvent('keydown', { key: k, bubbles: true, ...extra }));

function loaded(slots = [[version('t1#0', 'moonlight on my new song', 1)], [version('t1#1', 'velvet rain on the window', 4)]], extra = {}) {
  const w = openWindow();
  w.HM.host.load(session(slots, extra));
  return w;
}

test('the page loads with no errors and starts empty, never on the demo song', () => {
  const w = openWindow();
  assert.deepEqual(w.errors, []);
  assert.equal(w.HM.sections.length, 0);
  assert.ok(w.posted('ready').length, 'it tells the app it is ready');
  assert.equal(w.log.contexts.length, 0, 'no audio context before anything plays');
});

test('a session shows its lines in order', () => {
  const w = loaded();
  assert.deepEqual(rows(w.document), ['moonlight on my new song', 'velvet rain on the window']);
});

// ---------- 10-14: notes-style sections ----------
test('a line that is just a header starts a section; deleting it removes the section', () => {
  const slots = [[version('a', 'Verse', 1)], [version('b', 'moonlight on my new song', 2)], [version('c', '[Chorus]', 4)], [version('d', 'velvet rain', 5)], [version('e', 'Bridge 2:', 7)], [version('f', 'silver crown', 8)]];
  const w = loaded(slots);
  const names = () => [...w.document.querySelectorAll('.sec-name')].map((e) => e.textContent);
  assert.deepEqual(names(), ['Verse', 'Chorus', 'Bridge 2']);
  assert.deepEqual(rows(w.document), ['moonlight on my new song', 'velvet rain', 'silver crown']);
  // Deleting the header line (an empty edit) removes that section; its line stays.
  const key0 = `${w.HM.sections[2].id}:0`;
  w.HM.S.edits[key0] = '';
  w.HM.renderNotes();
  assert.deepEqual(names(), ['Verse', 'Bridge 2']);
  assert.deepEqual(rows(w.document), ['moonlight on my new song', 'velvet rain', 'silver crown']);
});

test('only whole-line headers count as sections', () => {
  const { HM } = openWindow();
  for (const [text, name] of [['Verse', 'Verse'], ['hook', 'Hook'], ['[Chorus]', 'Chorus'], ['Bridge 2', 'Bridge 2'], ['Verse:', 'Verse'], ['pre-chorus', 'Pre-chorus']]) assert.equal(HM.sheet.headerName(text), name, text);
  for (const text of ['verse one of my song', 'hook me up', 'the bridge', '', null]) assert.equal(HM.sheet.headerName(text), null, String(text));
});

test('named sections get blocks on the strip, in order', () => {
  const w = loaded([[version('a', 'Verse', 1)], [version('b', 'moonlight on my new song', 2)], [version('c', 'Hook', 10)], [version('d', 'velvet rain on the window', 11)]]);
  const spans = w.HM.sheet.spans();
  assert.deepEqual(plain(spans.map((s) => s.name)), ['Verse', 'Hook']);
  assert.ok(spans[0].a < spans[1].a);
});

// ---------- 10-14: the board is always typeable ----------
test('an empty session is a blank page you can type on', () => {
  const w = openWindow();
  w.HM.host.load(session([]));
  const line = w.document.querySelector('.type-line');
  assert.ok(line, 'a typing line');
  assert.match(line.dataset.ph, /start typing/);
  assert.equal(w.document.querySelector('.np-bar'), null, 'no toolbar on a blank page');
});

test('Enter sends a typed line to the app, after the last line when not recording', () => {
  const w = loaded();
  const line = w.document.querySelector('.type-line');
  line.textContent = 'a line I typed';
  key(w, line, 'Enter');
  const sent = w.posted('typeLines');
  assert.equal(sent.length, 1);
  assert.equal(sent[0].text, 'a line I typed');
  assert.ok(sent[0].at >= 4, `after the last line, got ${sent[0].at}`);
});

test('a pasted verse goes in line by line, and blank lines are dropped', () => {
  const w = openWindow();
  w.HM.typeLines('first line\n\n  second line  \nthird line\n');
  assert.equal(w.posted('typeLines')[0].text, 'first line\nsecond line\nthird line');
});

test('while recording, a typed line lands at the moment you typed it', () => {
  const w = loaded();
  w.HM.host.recording(true);
  w.HM.host.level(0.5, 42);
  w.HM.typeLines('typed mid-take');
  assert.equal(w.posted('typeLines')[0].at, 42);
});

// ---------- 10-14: live lines ----------
test('the line in progress sits above the typing row, where the next line lands', () => {
  const w = loaded();
  w.HM.host.recording(true);
  w.HM.host.live({ text: 'still singing this', final: false });
  const live = w.document.querySelector('.live-line');
  assert.ok(live, 'it shows');
  const typing = w.document.querySelector('.type-row');
  assert.ok(typing, 'the typing row is still there');
  assert.ok(live.compareDocumentPosition(typing) & w.window.Node.DOCUMENT_POSITION_FOLLOWING, 'the live line comes first');
  assert.equal(live.textContent.trim().replace(/\s+/g, ' '), 'still singing this');
});

test('a finished line becomes a row at once and does not double when its saved copy arrives', () => {
  const w = loaded();
  w.HM.host.recording(true);
  w.HM.host.level(0.5, 20);
  w.HM.host.live({ text: 'a brand new line', final: false });
  w.HM.host.lineDone({ text: 'a brand new line', at: 18, end: 20 });
  assert.deepEqual(rows(w.document).at(-1), 'a brand new line');
  assert.equal(w.document.querySelector('.live-line'), null, 'no longer the line in progress');
  w.HM.host.load(session([[version('t1#0', 'moonlight on my new song', 1)], [version('t1#1', 'velvet rain on the window', 4)], [version('live-0', 'a brand new line', 18, { takeID: '' })]]));
  assert.equal(rows(w.document).filter((r) => r === 'a brand new line').length, 1);
});

test('a reload while recording never moves the clock backwards', () => {
  const w = loaded();
  w.HM.host.recording(true);
  w.HM.host.level(0.5, 90);
  w.HM.host.load(session([[version('t1#0', 'moonlight on my new song', 1)]]));
  assert.equal(w.HM.S.elapsed, 90);
  assert.ok(w.HM.sessionLen >= 90);
});

test('the notice about live words shows without a recording', () => {
  const w = loaded();
  w.HM.host.liveNotice('Live words are off');
  assert.match(w.document.querySelector('.live-notice').textContent, /Live words are off/);
  w.HM.host.liveNotice(null);
  assert.equal(w.document.querySelector('.live-notice'), null);
});

// ---------- 10-14: deleting stretches ----------
test('deleting a stretch asks the app to hide it, and its lines leave once the app says so', () => {
  const w = loaded();
  w.HM.hideRange(3, 8);
  assert.deepEqual(plain(w.posted('hideRange')[0]), { cmd: 'hideRange', a: 3, b: 8 });
  w.HM.host.load(session([[version('t1#0', 'moonlight on my new song', 1)], [version('t1#1', 'velvet rain on the window', 4)]], { hidden: [{ a: 3, b: 8 }] }));
  assert.deepEqual(rows(w.document), ['moonlight on my new song']);
});

test('an empty stretch does nothing', () => {
  const w = loaded();
  w.HM.hideRange(5, 5);
  assert.equal(w.posted('hideRange').length, 0);
});

test('Cmd-Z brings the last stretch back, only when there is one', () => {
  const w = loaded();
  key(w, w.document.body, 'z', { metaKey: true });
  assert.equal(w.posted('unhideRange').length, 0);
  w.HM.host.load(session([[version('t1#0', 'moonlight', 1)]], { hidden: [{ a: 3, b: 8 }] }));
  key(w, w.document.body, 'z', { metaKey: true });
  assert.equal(w.posted('unhideRange').length, 1);
});

// ---------- 10-14: chords and notes ----------
test('sung notes show on sung lines, and the Chords switch hides them', () => {
  const w = loaded([[version('t1#0', 'moonlight on my new song', 1, { notes: ['A3', 'C4'] })], [version('t1#1', 'rapped line here', 4)]]);
  assert.equal(w.document.querySelectorAll('.sung').length, 1);
  assert.match(w.document.querySelector('.sung').textContent, /A3 C4/);
  w.HM.S.chords = 'off';
  w.HM.renderNotes();
  assert.equal(w.document.querySelectorAll('.sung').length, 0);
});

// ---------- 10-14: versions ----------
test('a line with versions flips with its arrows, and the choice sticks to that line', () => {
  const slots = [[version('t1#0', 'moonlight on my old song', 1), version('t1#5', 'moonlight on my new song', 9)], [version('t1#1', 'velvet rain', 4)]];
  const w = loaded(slots);
  assert.equal(rows(w.document)[0], 'moonlight on my new song', 'newest shows');
  const back = w.document.querySelector('.stepper button');
  back.disabled = false;
  click(w, back);
  assert.equal(rows(w.document)[0], 'moonlight on my old song');
  // A line above it leaves (the judge took it): the pick stays on its line.
  w.HM.host.load(session([[version('zz', 'a line above', 0.5)], ...slots]));
  assert.equal(rows(w.document)[1], 'moonlight on my old song');
});

// ---------- 10-14: playback ----------
const audioSession = { sessionAudio: ['/lib/Sessions/One Two/session__voice_001.m4a', '/lib/Sessions/One Two/session__voice_002.m4a'], sessionMix: ['/lib/Sessions/One Two/session__mix_001.m4a', '/lib/Sessions/One Two/session__mix_002.m4a'] };

test('library audio goes through the media scheme, with the path encoded', () => {
  const w = loaded(undefined, audioSession);
  assert.equal(w.HM.real.audio.files[0], 'hotmic-media://library/lib/Sessions/One%20Two/session__voice_001.m4a');
});

test('Freestyle plays one player on the voice file, and a jump moves it instead of starting another', async () => {
  const w = loaded(undefined, audioSession);
  w.HM.S.mode = 'solo';
  assert.equal(w.HM.real.playVoice(10), true);
  assert.equal(w.log.audio.length, 1);
  const el = w.log.audio[0];
  assert.match(el.src, /voice_001/);
  assert.equal(el.currentTime, 10);
  w.HM.real.play(0, 1, 100);
  assert.equal(w.log.audio.length, 1, 'still one player');
  assert.equal(el.currentTime, 100);
  w.HM.real.play(0, 1, 310);
  assert.match(el.src, /voice_002/, 'past 5:00 is the second file');
  assert.equal(el.currentTime, 10);
});

test('one file ending starts the next while playing', () => {
  const w = loaded(undefined, audioSession);
  w.HM.real.play(0, 1, 299);
  const el = w.log.audio[0];
  w.HM.S.playing = true;
  el.listeners.ended();
  assert.match(el.src, /voice_002/);
  assert.equal(el.currentTime, 0);
});

test('Beat mode plays the mix, Freestyle the voice', () => {
  const w = loaded(undefined, audioSession);
  w.HM.S.mode = 'beat';
  w.HM.real.play(0, 1, 5);
  assert.match(w.log.audio[0].src, /mix_001/);
});

// ---------- 10-14: beat runs: looped Beat playback stays in sync with your voice ----------
test('your recording lines up with the beat, whichever run and loop it was sung in', () => {
  const { HM } = openWindow();
  HM.S.loop = { a: 8, b: 16, on: true };
  const straight = [{ at: 100, beat: 4, loopA: 0, loopB: 0, loopOn: false }];
  assert.equal(HM.audio.sessionFor(10, straight), 106, 'beat second 10 was sung 6 s into the run');
  assert.equal(HM.audio.sessionFor(2, straight), null, 'before the run started');
  const looped = [{ at: 200, beat: 10, loopA: 8, loopB: 16, loopOn: true }];
  assert.equal(HM.audio.sessionFor(12, looped), 202, 'first time round');
  assert.equal(HM.audio.sessionFor(9, looped), 200 + 6 + 1, 'before where it started: the second time round');
  assert.equal(HM.audio.sessionFor(20, looped), null, 'outside the loop');
  const both = [{ at: 50, beat: 0, loopA: 0, loopB: 0, loopOn: false }, { at: 300, beat: 8, loopA: 0, loopB: 8, loopOn: true }, { at: 400, beat: 8, loopA: 8, loopB: 16, loopOn: true }];
  assert.equal(HM.audio.sessionFor(10, both), 402, 'the run with the same loop you have on now wins');
  assert.equal(HM.audio.sessionFor(100, both), 150, 'past every loop: the straight run');
  assert.equal(HM.audio.sessionFor(10, []), null, 'no runs');
});

test('Record in Beat mode reports where the beat started, for lining up later', () => {
  const w = loaded();
  w.HM.S.mode = 'beat';
  w.HM.beat.buffer = { duration: 100 };
  w.HM.beat.name = 'demo.wav';
  w.HM.S.loop = { a: 8, b: 16, on: true };
  w.HM.S.cue = 4;
  w.HM.host.recording(true);
  const run = w.posted('beatRun')[0];
  assert.equal(run.beat, 8, 'from the loop');
  assert.equal(run.loopOn, true);
  assert.equal(run.beatName, 'demo.wav');
  assert.equal(w.log.sources.length, 1, 'the beat starts');
  assert.equal(w.log.sources[0].loop, true);
  assert.equal(w.log.sources[0].loopStart, 8);
  assert.equal(w.log.sources[0].loopEnd, 16);
});

test('the beat clock wraps at the loop end, on the audio clock', () => {
  const w = loaded();
  w.HM.S.mode = 'beat';
  w.HM.beat.buffer = { duration: 100 };
  w.HM.S.loop = { a: 8, b: 16, on: true };
  w.HM.S.t = 8; w.HM.S.playing = true;
  w.HM.audio.on = true;
  w.HM.audio.start();
  const ctx = w.log.contexts[0];
  ctx.currentTime = 0.03 + 3;
  assert.ok(Math.abs(w.HM.audio.beatClock() - 11) < 1e-6);
  ctx.currentTime = 0.03 + 9;
  assert.ok(Math.abs(w.HM.audio.beatClock() - 9) < 1e-6, 'past the end by 1 s: 1 s into the loop');
});

// ---------- the line judge ----------
const judged = { judge: { model: 'apple-foundation', aside: [{ id: 't1#7', text: 'yo thanks for coming', at: 2, verdict: 'talk', source: 'model' }, { id: 't1#8', text: 'everybody vote', at: 3, verdict: 'talk', source: 'model' }] } };

test('talk set aside shows as a quiet count that opens a list', () => {
  const w = loaded(undefined, judged);
  const count = w.document.querySelector('.np-aside');
  assert.equal(count.textContent, '2 lines of talk set aside');
  assert.equal(w.document.querySelector('.aside-list'), null, 'closed at first');
  assert.deepEqual(rows(w.document), ['moonlight on my new song', 'velvet rain on the window'], 'not in the notepad');
  click(w, count);
  assert.equal(w.document.querySelectorAll('.aside-row').length, 2);
  assert.match(w.document.querySelector('.aside-text').textContent, /yo thanks/);
});

test('Lyric on a set-aside line tells the app and leaves the list', () => {
  const w = loaded(undefined, judged);
  click(w, w.document.querySelector('.np-aside'));
  click(w, w.document.querySelector('.aside-keep'));
  assert.deepEqual(plain(w.posted('judgeCorrect')[0]), { cmd: 'judgeCorrect', id: 't1#7', verdict: 'writing' });
  assert.equal(w.HM.judge.aside.length, 1);
});

test('clicking a set-aside line plays it', () => {
  const w = loaded(undefined, judged);
  let at = null;
  w.HM.seek = (t) => { at = t; };
  click(w, w.document.querySelector('.np-aside'));
  click(w, w.document.querySelector('.aside-text'));
  assert.equal(at, 2);
});

test('every sung row has a Talk button; typed lines and hums do not', () => {
  const w = loaded([[version('t1#0', 'moonlight on my new song', 1)], [version('live-1', 'typed here', 2, { takeID: 'typed' })], [version('hum-t1', 'hum · A3 C4', 3)]]);
  assert.equal(w.document.querySelectorAll('.row-talk').length, 1);
  click(w, w.document.querySelector('.row-talk'));
  assert.deepEqual(plain(w.posted('judgeCorrect')[0]), { cmd: 'judgeCorrect', id: 't1#0', verdict: 'talk' });
});

test('a session the model judged gets its dot in the sidebar; others do not', () => {
  const w = loaded();
  w.HM.S.side = 'list';
  w.HM.host.sessions([{ id: '/a', name: 'One', date: '2026-11-01T12:00:00Z', daw: 'Jam', takes: 3, length: 60, judged: true }, { id: '/b', name: 'Two', date: '2026-11-01T12:00:00Z', daw: 'Jam', takes: 3, length: 60 }]);
  w.HM.render();
  const dots = [...w.document.querySelectorAll('[data-session]')].map((r) => !!r.querySelector('.s-judged'));
  assert.deepEqual(dots, [true, false]);
});

test('picking a version teaches: the line is a lyric', () => {
  const slots = [[version('t1#0', 'moonlight on my old song', 1), version('t1#5', 'moonlight on my new song', 9)]];
  const w = loaded(slots);
  click(w, w.document.querySelector('.stepper button'));
  assert.deepEqual(plain(w.posted('judgeSignal')[0]), { cmd: 'judgeSignal', kind: 'starred', id: 't1#0' });
});

test('editing a line teaches once when you finish, and only for lines you changed', () => {
  const w = loaded();
  w.HM.sheet.startEditing();
  w.HM.S.edits[`${w.HM.sections[0].id}:0`] = 'moonlight on my newer song';
  w.HM.sheet.stopEditing();
  assert.deepEqual(plain(w.posted('judgeSignal')), [{ cmd: 'judgeSignal', kind: 'edited', id: 't1#0' }]);
  w.HM.sheet.startEditing();
  w.HM.sheet.stopEditing();
  assert.equal(w.posted('judgeSignal').length, 1, 'no change, nothing taught');
});

test('Settings shows the judge switches and sends them to the app', () => {
  const w = loaded();
  w.HM.host.judgeState({ modelOn: true, learnerOn: true, corrections: 3, modelAvailable: true });
  w.HM.openSettings();
  const pop = w.document.querySelector('.settings-pop');
  assert.match(pop.textContent, /Learned from 3 corrections/);
  const toggle = pop.querySelector('[data-judge="learnerOn"]');
  toggle.checked = false;
  toggle.dispatchEvent(new w.window.Event('change'));
  assert.deepEqual(plain(w.posted('judgeSettings')[0]), { cmd: 'judgeSettings', learnerOn: false });
  click(w, pop.querySelector('[data-judge-reset]'));
  assert.deepEqual(plain(w.posted('judgeSettings')[1]), { cmd: 'judgeSettings', reset: true });
  assert.match(pop.textContent, /Learned from 0 corrections/);
});

test('recording never creates an audio context by itself in Freestyle', () => {
  const w = loaded();
  w.HM.S.mode = 'solo';
  w.HM.host.recording(true);
  assert.equal(w.log.sources.length, 0);
});


test('repeated recording snapshots do not restart the beat or duplicate its run', () => {
  const w = loaded();
  try {
    w.HM.S.mode = 'beat';
    w.HM.beat = { buffer: { duration: 30 }, name: 'test beat' };
    w.HM.S.loop = { on: true, a: 2, b: 8 };
    let starts = 0, stops = 0;
    w.HM.audio.start = () => { starts++; };
    w.HM.audio.stop = () => { stops++; };
    w.HM.host.recording(true);
    w.HM.S.t = 6;
    w.HM.host.recording(true);
    assert.equal(starts, 1);
    assert.equal(w.posted('beatRun').length, 1);
    assert.equal(w.HM.S.t, 6);
    w.HM.host.recording(false);
    assert.ok(stops >= 1);
    const stopped = stops;
    // A routine stopped-state refresh must not interrupt playback started by the user.
    w.HM.S.playing = true;
    w.HM.host.recording(false);
    assert.equal(stops, stopped);
    assert.equal(w.HM.S.playing, true);
    w.HM.host.recording(true);
    assert.equal(starts, 2);
  } finally { w.close(); }
});


test('a failed paste save restores the words and keeps newer typing', () => {
  const w = loaded();
  try {
    const text = 'Café on the moon\n<script>keep as text</script>';
    w.HM.S._typeDraft = 'the next line';
    w.HM.host.typeFailed(text);
    assert.equal(w.HM.S._typeDraft, text + '\nthe next line');
    assert.equal(w.document.querySelector('.type-line').textContent, text + '\nthe next line');
    assert.equal(w.document.querySelector('.type-line script'), null);
    assert.equal(w.posted('typeLines').length, 0, 'no automatic retry or claim that these words saved');
  } finally { w.close(); }
});
