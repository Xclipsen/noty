import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { Accounts, buildOverview } from '../server/accounts.mjs';
import { Metering, COUNTERS, emptyCounters } from '../server/metering.mjs';
import { DAY_MS } from '../server/store.mjs';
import { tempDir } from './helpers.mjs';

test('Neue Konten sind pending, Datei 600, Status überlebt Neustart', async t => {
  const root = await tempDir(t);
  const accounts = await new Accounts({ root }).init();
  const view = await accounts.seen({ id: 'a', name: 'Anna' });
  assert.deepEqual({ ...view, lastSeenAt: 0 }, { id: 'a', name: 'Anna', status: 'pending', role: 'user', dailyLimit: null, effectiveDailyLimit: 200, lastSeenAt: 0 });
  assert.equal((await stat(accounts.file)).mode & 0o777, 0o600);
  await accounts.update('a', { status: 'active', dailyLimit: 5 });
  const again = await new Accounts({ root }).init();
  assert.deepEqual([again.get('a').status, again.limitFor('a')], ['active', 5]);
  assert.equal(again.limitFor('unbekannt'), 200);
});

test('Name und lastSeenAt folgen dem Backend, Status bleibt', async t => {
  const root = await tempDir(t);
  let now = 1000;
  const accounts = await new Accounts({ root, now: () => now }).init();
  await accounts.seen({ id: 'a', name: 'Alt' });
  await accounts.update('a', { status: 'blocked' });
  now = 100_000;
  const view = await accounts.seen({ id: 'a', name: 'Neu' });
  assert.deepEqual([view.name, view.status, view.lastSeenAt], ['Neu', 'blocked', 100_000]);
  await accounts.flush();
  assert.equal(JSON.parse(await readFile(accounts.file, 'utf8'))[0].name, 'Neu');
});

test('Admins: immer active, Rolle admin, auch wenn gespeichert blocked', async t => {
  const root = await tempDir(t);
  const first = await new Accounts({ root }).init();
  await first.seen({ id: 'a', name: 'A' });
  await first.update('a', { status: 'blocked' });
  const accounts = await new Accounts({ root, adminIds: ['a'] }).init();
  assert.deepEqual([accounts.get('a').status, accounts.get('a').role], ['active', 'admin']);
  await assert.rejects(accounts.update('a', { status: 'blocked' }), e => e.status === 409 && /Admins/.test(e.message));
  assert.equal((await accounts.update('a', { dailyLimit: 3 })).dailyLimit, 3);
  assert.equal((await accounts.update('a', { status: 'active' })).status, 'active');
});

test('Kontoänderung prüft Eingaben und kennt null als Standard', async t => {
  const accounts = await new Accounts({ root: await tempDir(t), defaultDailyLimit: 7 }).init();
  await accounts.seen({ id: 'a', name: 'A' });
  await assert.rejects(accounts.update('fehlt', { status: 'active' }), e => e.status === 404);
  for (const status of ['aktiv', null, 1]) await assert.rejects(accounts.update('a', { status }), e => e.status === 400);
  for (const dailyLimit of [-1, 1.5, '3', 1_000_001]) await assert.rejects(accounts.update('a', { dailyLimit }), e => e.status === 400);
  assert.equal((await accounts.update('a', { dailyLimit: 0 })).effectiveDailyLimit, 0);
  const reset = await accounts.update('a', { dailyLimit: null });
  assert.deepEqual([reset.dailyLimit, reset.effectiveDailyLimit], [null, 7]);
  assert.equal((await accounts.update('a', { name: 'Hack', role: 'admin' })).name, 'A');
});

test('Scheitert das Speichern, bleibt die Änderung aus', async t => {
  const accounts = await new Accounts({ root: await tempDir(t) }).init();
  await accounts.seen({ id: 'a', name: 'A' });
  accounts.writer.save = () => Promise.reject(new Error('voll'));
  await assert.rejects(accounts.update('a', { status: 'active' }), e => e.status === 503);
  assert.equal(accounts.get('a').status, 'pending');
});

test('Kaputte Dateien stoppen den Start statt Limits oder Sperren zu verlieren', async t => {
  const root = await tempDir(t);
  await writeFile(path.join(root, 'accounts.json'), '{kaputt');
  await assert.rejects(new Accounts({ root }).init(), /unlesbar/);
  await writeFile(path.join(root, 'accounts.json'), '{}');
  await assert.rejects(new Accounts({ root }).init(), /unlesbar/);
  await writeFile(path.join(root, 'metering.json'), '{kaputt');
  await assert.rejects(new Metering({ root }).init(), /unlesbar/);
});

test('Zähler: je Konto und UTC-Tag, Datei 600, überleben Neustart', async t => {
  const root = await tempDir(t);
  let now = Date.parse('2026-03-01T23:59:00Z');
  const metering = await new Metering({ root, now: () => now }).init();
  metering.add('a', { turns: 1, images: 2, inputTokens: 5 });
  metering.add('b', { turns: 1 });
  await metering.save();
  assert.equal((await stat(metering.file)).mode & 0o777, 0o600);
  const again = await new Metering({ root, now: () => now }).init();
  assert.deepEqual(again.forToday('a'), { ...emptyCounters(), turns: 1, images: 2, inputTokens: 5 });
  now = Date.parse('2026-03-02T00:00:00Z');
  assert.equal(again.forToday('a').turns, 0);
  again.add('a', { turns: 2 });
  assert.equal(again.sum('a').turns, 3);
  assert.equal(again.sum('a', 1).turns, 2);
  assert.equal(again.sum('a', 2).turns, 3);
  assert.equal(again.todayTotal().turns, 2);
  assert.deepEqual(Object.keys(again.forToday('zzz')), COUNTERS);
});

test('Nur bekannte Zähler; Fremdfelder werden nicht gespeichert', async t => {
  const metering = await new Metering({ root: await tempDir(t) }).init();
  metering.add('a', { turns: 1, text: 'INHALT', inputTokens: 'viele', outputTokens: 1.5 });
  await metering.save();
  const raw = await readFile(metering.file, 'utf8');
  assert.ok(!raw.includes('INHALT'));
  assert.deepEqual(metering.forToday('a'), { ...emptyCounters(), turns: 1 });
  assert.deepEqual(Metering.tokens({ inputTokens: 1, cachedInputTokens: 2, outputTokens: 3, reasoningOutputTokens: 4, totalTokens: 10 }), { inputTokens: 1, cachedInputTokens: 2, outputTokens: 3, reasoningOutputTokens: 4 });
});

test('Tage älter als NOTY_AI_USAGE_DAYS werden gelöscht', async t => {
  const root = await tempDir(t);
  let now = Date.parse('2026-01-01T12:00:00Z');
  const metering = await new Metering({ root, now: () => now, usageDays: 400 }).init();
  metering.add('a', { turns: 1 });
  await metering.save();
  now += 400 * DAY_MS;
  await metering.prune();
  assert.equal(metering.sum('a').turns, 1);
  now += DAY_MS;
  await metering.prune();
  assert.equal(metering.sum('a').turns, 0);
  await metering.flush();
  assert.deepEqual(JSON.parse(await readFile(metering.file, 'utf8')), {});
});

test('Übersicht enthält alle Konten mit Zeiträumen', async t => {
  const root = await tempDir(t);
  let now = Date.parse('2026-03-20T12:00:00Z');
  const accounts = await new Accounts({ root, now: () => now, adminIds: ['b'] }).init();
  const metering = await new Metering({ root, now: () => now }).init();
  await accounts.seen({ id: 'a', name: 'A' });
  await accounts.seen({ id: 'b', name: 'B' });
  metering.add('a', { turns: 1 });
  now += 10 * DAY_MS;
  metering.add('a', { turns: 2 });
  metering.add('b', { turns: 4 });
  const overview = buildOverview({ accounts, metering, account: 'chatgpt', plan: { limits: [] }, running: 1 });
  assert.deepEqual([overview.account, overview.running, overview.today.turns], ['chatgpt', 1, 6]);
  const [a] = overview.users;
  assert.deepEqual([a.today.turns, a.last7.turns, a.last30.turns, a.total.turns], [2, 2, 3, 3]);
  assert.deepEqual(Object.keys(a).sort(), ['dailyLimit', 'effectiveDailyLimit', 'id', 'last30', 'last7', 'lastSeenAt', 'name', 'role', 'status', 'today', 'total']);
  assert.equal(overview.users[1].role, 'admin');
});
