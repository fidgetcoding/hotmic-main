// The window's judge code, in Node with a tiny stand-in for the page. Run: node --test Tests/lab/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// Objects made inside the page's context have that context's prototypes.
const plain = (o) => JSON.parse(JSON.stringify(o));

function page() {
  const posted = [];
  const HM = { host: { post: (m) => posted.push(m) }, renderNotes() { HM.rendered = (HM.rendered || 0) + 1; }, seek() {} };
  vm.runInNewContext(readFileSync(new URL('../../lab/judge.js', import.meta.url), 'utf8'), { window: { HM } });
  const h = (html) => {
    const listeners = {};
    return { html, addEventListener: (k, f) => { listeners[k] = f; }, click: () => listeners.click({ stopPropagation() {} }),
      querySelector: () => ({ addEventListener() {} }), appendChild() {} };
  };
  return { HM, J: HM.judge, posted, h };
}

test('sung lines can be marked; typed lines, hums and unsaved lines cannot', () => {
  const { J } = page();
  assert.equal(J.markable('t#3', 't'), true);
  assert.equal(J.markable('live-4', ''), true);
  assert.equal(J.markable('live-4', 'typed'), false);
  for (const id of ['hum-t', 'beat-t', 'chords-t-10', 'pending-0-1.5', '']) assert.equal(J.markable(id, 't'), false, id);
});

test('a session with nothing set aside shows nothing', () => {
  const { J, h } = page();
  J.load({ slots: [] });
  assert.equal(J.count(), '');
  assert.equal(J.bar(h), null);
  assert.equal(J.list(h, (s) => s), null);
});

test('the count opens the list, and a kept line leaves it and tells the app', () => {
  const { HM, J, posted, h } = page();
  J.load({ judge: { model: 'apple-foundation', aside: [{ id: 'a', text: 'one', at: 1 }, { id: 'b', text: 'two', at: 2 }] } });
  assert.equal(J.count(), '2 lines of talk set aside');
  J.bar(h).click();
  assert.equal(J.open, true);
  assert.equal(HM.rendered, 1);
  J.correct('a', 'writing');
  assert.deepEqual(plain(posted.at(-1)), { cmd: 'judgeCorrect', id: 'a', verdict: 'writing' });
  assert.equal(J.count(), '1 line of talk set aside');
  J.correct('b', 'writing');
  assert.equal(J.open, false, 'nothing left: the list closes');
});

test('the row button says talk, and only on a line it can mark', () => {
  const { J, posted, h } = page();
  assert.equal(J.rowButton(h, 'chords-t-1', 't'), null);
  J.rowButton(h, 't#1', 't').click();
  assert.deepEqual(plain(posted.at(-1)), { cmd: 'judgeCorrect', id: 't#1', verdict: 'talk' });
});

test('stars and edits teach only on lines it can mark', () => {
  const { J, posted } = page();
  J.signal('starred', 'pending-0-1');
  assert.equal(posted.length, 0);
  J.signal('edited', 't#2');
  assert.deepEqual(plain(posted.at(-1)), { cmd: 'judgeSignal', kind: 'edited', id: 't#2' });
});

test('picks and edits saved under the old line numbers move to their lines', () => {
  const { J } = page();
  const S = { picks: { s1: 's1p2' }, linePicks: { 's0:0': 'words|on the beat' }, edits: { 's1:0': 'my fix', 'kept:0': 'already moved' }, breaks: { solo: { 's0:0': 'Hook' }, beat: null } };
  J.migrate(S, [{ id: 'take_0' }, { id: 'take_1' }]);
  assert.deepEqual(plain(S), { picks: { take_1: 'take_1p2' }, linePicks: { 'take_0:0': 'words|on the beat' }, edits: { 'take_1:0': 'my fix', 'kept:0': 'already moved' }, breaks: { solo: { 'take_0:0': 'Hook' }, beat: null } });
});

test('settings say when the model is not there', () => {
  const { J } = page();
  assert.match(J.settings(), /needs Apple Intelligence/);
  assert.match(J.settings(), /stays on this Mac/);
  J.state.modelAvailable = true; J.state.corrections = 1;
  assert.doesNotMatch(J.settings(), /needs Apple Intelligence/);
  assert.match(J.settings(), /Learned from 1 correction</);
});
