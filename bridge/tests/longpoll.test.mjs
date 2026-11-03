import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { Store } from '../server/store.mjs';
import { RevisionWaits } from '../server/waits.mjs';
import { boot } from '../server/main.mjs';
import { startAccountBackend } from './fake-account-backend.mjs';
import { serve, setup, settled, request, tempDir, until, OWNER, TOKEN, TOKEN_B, USER } from './helpers.mjs';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const fakeResponse = () => Object.assign(new EventEmitter(), { destroyed: false, writableEnded: false });

// MARK: Wartestellen

test('Long-Poll: Wartende enden mit Änderung, Ablauf, Abbruch oder Schließen, ohne Reste', async t => {
  // Die Timer der Wartestellen halten den Prozess bewusst nicht am Leben; im Dienst tut das der Listener.
  const alive = setInterval(() => {}, 1_000);
  t.after(() => clearInterval(alive));
  const waits = new RevisionWaits({ timeoutMs: 40 });
  const changed = waits.wait('a', 's1', fakeResponse());
  const other = waits.wait('a', 's2', fakeResponse());
  assert.equal(waits.size, 2);
  waits.notify('s1');
  assert.equal(await changed, 'changed');
  assert.equal(waits.size, 1, 'Nur die eigene Sitzung wird geweckt');
  assert.equal(await other, 'timeout');
  assert.equal(waits.size, 0);
  const res = fakeResponse();
  const gone = waits.wait('a', 's1', res);
  res.emit('close');
  assert.equal(await gone, 'closed');
  assert.deepEqual([waits.size, waits.sessions.size, waits.accounts.size, res.listenerCount('close')], [0, 0, 0, 0]);
  const pending = waits.wait('a', 's1', fakeResponse());
  waits.close();
  assert.equal(await pending, 'closed');
  assert.equal(await waits.wait('a', 's1', fakeResponse()), 'closed', 'Nach dem Schließen wartet niemand mehr');
  assert.equal(waits.size, 0);
});

test('Long-Poll: Grenzen je Konto und insgesamt ergeben 429 mit Retry-After', async () => {
  const waits = new RevisionWaits({ perAccount: 2, global: 3, timeoutMs: 5_000 });
  const held = [waits.wait('a', 's', fakeResponse()), waits.wait('a', 's', fakeResponse())];
  assert.throws(() => waits.wait('a', 's', fakeResponse()), e => e.status === 429 && e.retryAfter === 1 && e.code === 'too_many_waits');
  held.push(waits.wait('b', 't', fakeResponse()));
  assert.throws(() => waits.wait('c', 'u', fakeResponse()), e => e.status === 429, 'global');
  assert.equal(waits.size, 3);
  waits.close();
  assert.deepEqual(await Promise.all(held), ['closed', 'closed', 'closed']);
});

// MARK: Gedrosselte Revisionen

test('Deltas: Revision höchstens alle notifyMs, Platte höchstens alle persistMs, nichts geht verloren', async t => {
  const store = await new Store({ root: await tempDir(t), notifyMs: 40, persistMs: 400 }).init();
  const s = await store.create(OWNER);
  const start = s.revision;
  let writes = 0, notes = 0;
  const persist = store.persist.bind(store);
  store.persist = session => { writes++; return persist(session); };
  store.watch(id => { if (id === s.id) notes++; });
  for (let i = 0; i < 50; i++) store.touch(s);
  assert.equal(s.revision, start + 1, 'Das erste Delta wirkt sofort');
  assert.deepEqual([writes, notes], [1, 1]);
  await sleep(80);
  assert.equal(s.revision, start + 2, 'Der Rest gebündelt am Ende des Fensters');
  assert.equal(writes, 1, 'Platte noch nicht wieder');
  await sleep(400);
  assert.equal(writes, 2);
  assert.equal(notes, 2);
  assert.equal(JSON.parse(await readFile(store.file(s.id), 'utf8')).revision, s.revision);
  store.touch(s); store.touch(s);
  await store.flush();
  assert.equal(JSON.parse(await readFile(store.file(s.id), 'utf8')).revision, s.revision, 'flush wendet Ausstehendes an');
});

test('Deltas: gleichmäßige Revisionen, auch während das Schreiben auf die Platte noch wartet', async t => {
  const store = await new Store({ root: await tempDir(t), notifyMs: 50, persistMs: 2_000 }).init();
  const s = await store.create(OWNER);
  const start = s.revision;
  const times = [];
  store.watch(() => times.push(performance.now()));
  for (let i = 0; i < 20; i++) { store.touch(s); await sleep(20); }
  await sleep(60);
  const revisions = s.revision - start;
  assert.ok(revisions >= 6 && revisions <= 10, `Revisionen in 400 ms: ${revisions}`);
  const gaps = times.slice(1).map((time, i) => time - times[i]);
  assert.ok(Math.max(...gaps) < 150, `größter Abstand ${Math.round(Math.max(...gaps))} ms`);
  assert.ok(Math.min(...gaps) >= 45, `kleinster Abstand ${Math.round(Math.min(...gaps))} ms`);
  await store.flush();
});

test('Deltas: save übernimmt Ausstehendes, Löschen beendet den Takt und meldet sich', async t => {
  const store = await new Store({ root: await tempDir(t), notifyMs: 30, persistMs: 30 }).init();
  const s = await store.create(OWNER);
  store.touch(s); store.touch(s);
  await store.save(s);
  const saved = s.revision;
  await sleep(60);
  assert.equal(s.revision, saved, 'Kein später Nachzügler nach dem vollständigen Schreiben');
  assert.equal(store.streams.size, 0);
  const seen = [];
  store.watch(id => seen.push(id));
  store.touch(s); store.touch(s);
  await store.remove(s.id);
  assert.equal(store.streams.size, 0);
  assert.deepEqual(seen, [s.id, s.id], 'Delta und Löschen');
  await sleep(60);
  assert.equal(seen.length, 2);
});

// MARK: HTTP

const longPoll = (ctx, id, revision, init = {}) => fetch(`${ctx.base}/v1/sessions/${id}?after=${revision}&wait=1`, { headers: { authorization: `Bearer ${TOKEN}` }, ...init });

test('Long-Poll über HTTP: sofort bei neuerer Revision, wach bei Änderung, 204 nach Ablauf', async t => {
  const ctx = await serve(t, { waits: { timeoutMs: 120 } });
  const s = await ctx.store.create(OWNER);
  assert.equal((await longPoll(ctx, s.id, s.revision + 5)).status, 200, 'andere Revision: sofort');
  assert.equal((await ctx.call('GET', `/v1/sessions/${s.id}?after=${s.revision}`)).status, 204, 'ohne wait wie bisher');
  assert.equal((await ctx.call('GET', `/v1/sessions/${s.id}?after=${s.revision}&wait=0`)).status, 204);
  assert.equal((await ctx.call('GET', `/v1/sessions/${s.id}?after=${s.revision}&wait=ja`)).status, 400);
  const before = s.revision;
  const started = performance.now();
  const pending = longPoll(ctx, s.id, before);
  await until(() => ctx.waits.size === 1);
  s.title = 'Neu';
  await ctx.store.save(s);
  const res = await pending;
  const body = await res.json();
  assert.equal(res.status, 200);
  assert.equal(body.revision, before + 1);
  assert.equal(body.title, 'Neu');
  assert.ok(performance.now() - started < 100, 'nicht erst nach Ablauf');
  assert.equal(ctx.waits.size, 0);
  const waited = performance.now();
  assert.equal((await longPoll(ctx, s.id, s.revision)).status, 204);
  assert.ok(performance.now() - waited >= 100, 'wartet bis zum Ablauf');
  assert.equal(ctx.waits.size, 0);
});

test('Long-Poll über HTTP: Abbruch räumt sofort auf, Grenze je Konto, Löschen und Sperre beenden', async t => {
  const ctx = await serve(t, { waits: { timeoutMs: 10_000, perAccount: 2 } });
  const s = await ctx.store.create(OWNER);
  const abort = new AbortController();
  const gone = longPoll(ctx, s.id, s.revision, { signal: abort.signal }).catch(error => error.name);
  await until(() => ctx.waits.size === 1);
  abort.abort();
  assert.equal(await gone, 'AbortError');
  await until(() => ctx.waits.size === 0);
  assert.equal(ctx.waits.size, 0);

  const first = longPoll(ctx, s.id, s.revision), second = longPoll(ctx, s.id, s.revision);
  await until(() => ctx.waits.size === 2);
  const third = await longPoll(ctx, s.id, s.revision);
  assert.equal(third.status, 429);
  assert.equal(third.headers.get('retry-after'), '1');
  assert.equal((await third.json()).code, 'too_many_waits');
  const foreign = await ctx.store.create({ userId: 'konto-b' });
  const otherAccount = fetch(`${ctx.base}/v1/sessions/${foreign.id}?after=${foreign.revision}&wait=1`, { headers: { authorization: `Bearer ${TOKEN_B}` } });
  await until(() => ctx.waits.size === 3);
  await ctx.hub.remove(USER, s.id);
  assert.deepEqual([(await first).status, (await second).status], [404, 404], 'gelöscht: sofort 404');
  await ctx.accounts.update('konto-b', { status: 'blocked' });
  await ctx.store.save(foreign);
  assert.equal((await otherAccount).status, 403, 'Status nach dem Warten erneut geprüft');
  assert.equal(ctx.waits.size, 0);
});

test('Long-Poll über HTTP: laufende Antwort kommt in mehreren gedrosselten Schritten', async t => {
  const deltas = ['Eins ', 'zwei ', 'drei ', 'vier ', 'fünf ', 'sechs ', 'sieben ', 'acht'];
  const onTurn = async r => {
    r.emit('message', { method: 'turn/started', params: { threadId: r.threadId, turn: { id: r.turnId } } });
    for (const delta of deltas) {
      r.emit('message', { method: 'item/agentMessage/delta', params: { threadId: r.threadId, turnId: r.turnId, itemId: 'a', delta } });
      await sleep(25);
    }
    r.complete();
  };
  const ctx = await serve(t, { rpc: { onTurn }, store: { notifyMs: 50, persistMs: 1000 } });
  const s = await ctx.store.create(OWNER);
  let writes = 0;
  const persist = ctx.store.persist.bind(ctx.store);
  ctx.store.persist = session => { writes++; return persist(session); };
  const accepted = await (await ctx.call('POST', `/v1/sessions/${s.id}/turns`, request())).json();
  const seen = [];
  let revision = accepted.revision, status = accepted.status;
  while (status === 'running') {
    const res = await longPoll(ctx, s.id, revision);
    if (res.status === 204) continue;
    const next = await res.json();
    assert.ok(next.revision > revision);
    revision = next.revision; status = next.status;
    seen.push(next.messages.at(-1).text);
  }
  await settled(ctx.store, s.id);
  assert.equal(seen.at(-1), deltas.join(''));
  assert.ok(seen.length >= 3, `Zwischenstände: ${seen.length}`);
  assert.ok(seen.length < deltas.length + 2, 'gedrosselt, nicht je Delta');
  assert.ok(seen.every((text, i) => i === 0 || text.startsWith(seen[i - 1]) || seen[i - 1].startsWith(text)), 'wächst nur');
  assert.ok(writes <= 4, `Plattenschreiben während des Laufs: ${writes}`);
});

test('Herunterfahren beendet wartende Abfragen sofort', async t => {
  const backend = await startAccountBackend(new Map([[TOKEN, { id: 'konto-admin', name: 'Admin' }]]));
  t.after(() => backend.close());
  const root = await tempDir(t);
  const { close, address, api } = await boot({ STATE_DIR: path.join(root, 'state'), CODEX_HOME: root, NOTY_AI_ACCOUNT_URL: backend.url,
    NOTY_AI_ADMIN_IDS: 'konto-admin', CODEX_BIN: '/bin/false', PORT: '0', ADMIN_PORT: '0' });
  const base = `http://127.0.0.1:${address.port}`;
  const headers = { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' };
  const session = await (await fetch(`${base}/v1/sessions`, { method: 'POST', headers, body: '{}' })).json();
  const pending = fetch(`${base}/v1/sessions/${session.id}?after=${session.revision}&wait=1`, { headers }).then(res => res.status, () => 'getrennt');
  await until(() => api.waits.size === 1);
  const started = performance.now();
  const closed = once(api, 'close');
  await close();
  await closed;
  assert.ok(['getrennt', 204].includes(await pending));
  assert.ok(performance.now() - started < 2_000, 'kein Warten auf den Ablauf');
  assert.equal(api.waits.size, 0);
});

test('Hub: Deltas über setup ändern die Revision gedrosselt, das Ende sofort', async t => {
  const onTurn = async r => {
    r.emit('message', { method: 'turn/started', params: { threadId: r.threadId, turn: { id: r.turnId } } });
    for (let i = 0; i < 30; i++) r.emit('message', { method: 'item/agentMessage/delta', params: { threadId: r.threadId, turnId: r.turnId, itemId: 'a', delta: `w${i} ` } });
    await sleep(5);
    r.complete();
  };
  const { hub, store } = await setup(t, { rpc: { onTurn }, store: { notifyMs: 1_000, persistMs: 1_000 } });
  const s = await store.create(OWNER);
  const start = (await hub.turn(USER, s.id, request())).revision;
  const done = await settled(store, s.id);
  assert.ok(done.revision - start <= 3, `Revisionen: ${done.revision - start}`);
  assert.equal(done.messages.at(-1).text.trim().split(' ').length, 30);
  await until(() => hub.runs.size === 0);
  await store.flush();
  assert.equal(JSON.parse(await readFile(store.file(s.id), 'utf8')).messages.at(-1).text, done.messages.at(-1).text, 'Ende vollständig auf der Platte');
});
