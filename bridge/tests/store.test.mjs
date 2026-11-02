import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, readFile, readdir, stat, utimes, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { Store, DAY_MS, writeAtomic } from '../server/store.mjs';
import { setup, tempDir, OWNER, USER } from './helpers.mjs';

test('Sitzungsdateien sind 600, der Ordner 700, keine tmp-Reste', async t => {
  const root = await tempDir(t);
  const store = await new Store({ root }).init();
  const s = await store.create(OWNER);
  await store.save(s);
  assert.equal((await stat(store.file(s.id))).mode & 0o777, 0o600);
  assert.equal((await stat(store.sessionsDir)).mode & 0o777, 0o700);
  assert.deepEqual(await readdir(store.sessionsDir), [s.id + '.json']);
});

test('Atomisch: scheiternder Schreibvorgang erhält den Altstand', async t => {
  const root = await tempDir(t);
  const file = path.join(root, 'x.json');
  await writeAtomic(file, 'alt');
  await assert.rejects(writeAtomic(path.join(root, 'fehlt', 'x.json'), 'neu'));
  await mkdir(path.join(root, 'ziel'));
  await assert.rejects(writeAtomic(path.join(root, 'ziel'), 'neu'));
  assert.equal(await readFile(file, 'utf8'), 'alt');
  assert.deepEqual((await readdir(root)).filter(name => name.endsWith('.tmp')), []);
});

test('Parallele Saves: seriell, Datei endet beim neuesten Stand', async t => {
  const root = await tempDir(t);
  const store = await new Store({ root }).init();
  const s = await store.create(OWNER);
  const saves = [];
  for (let i = 0; i < 50; i++) { s.title = 'Stand ' + i; saves.push(store.save(s)); }
  await Promise.all(saves);
  const saved = JSON.parse(await readFile(store.file(s.id), 'utf8'));
  assert.equal(saved.title, 'Stand 49');
  assert.equal(saved.revision, s.revision);
});

test('Neustart: running wird error mit system-Nachricht, Revision springt', async t => {
  const root = await tempDir(t);
  const first = await new Store({ root }).init();
  const s = await first.create(OWNER);
  s.status = 'running';
  await first.save(s);
  const second = await new Store({ root }).init();
  const loaded = second.get(s.id, USER);
  assert.equal(loaded.status, 'error');
  assert.equal(loaded.messages.at(-1).role, 'system');
  assert.match(loaded.messages.at(-1).text, /neu gestartet/);
  assert.ok(loaded.revision > s.revision + 100);
  assert.equal(JSON.parse(await readFile(second.file(s.id), 'utf8')).status, 'error');
});

test('Aufbewahrung beim Start: alte Sitzungen, auch laufende, und tmp-Reste weg', async t => {
  const root = await tempDir(t);
  let now = Date.now();
  const first = await new Store({ root, now: () => now }).init();
  const old = await first.create(OWNER);
  const oldRunning = await first.create(OWNER);
  oldRunning.status = 'running';
  await first.save(oldRunning);
  now += 31 * DAY_MS;
  const fresh = await first.create(OWNER);
  await writeFile(first.file(fresh.id) + '.abc.tmp', 'Rest');
  const second = await new Store({ root, now: () => now, retentionDays: 30 }).init();
  assert.deepEqual([...second.sessions.keys()], [fresh.id]);
  assert.deepEqual(await readdir(second.sessionsDir), [fresh.id + '.json']);
  assert.ok(old.id);
});

test('Aufbewahrung täglich: purge verschont aktive Läufe', async t => {
  const root = await tempDir(t);
  let now = Date.now();
  const store = await new Store({ root, now: () => now, retentionDays: 30 }).init();
  const a = await store.create(OWNER);
  const b = await store.create(OWNER);
  now += 31 * DAY_MS;
  await store.purge(id => id === b.id);
  assert.deepEqual([...store.sessions.keys()], [b.id]);
  await assert.rejects(stat(store.file(a.id)));
});

test('Kaputte Sitzungsdatei sperrt den Dienst nicht und altert aus', async t => {
  const root = await tempDir(t);
  const store = await new Store({ root }).init();
  const id = '00000000-0000-4000-8000-000000000000';
  await writeFile(store.file(id), '{kaputt');
  t.mock.method(console, 'error', () => {});
  assert.equal((await new Store({ root }).init()).sessions.size, 0);
  const past = new Date(Date.now() - 40 * DAY_MS);
  await utimes(store.file(id), past, past);
  await new Store({ root }).init();
  await assert.rejects(stat(store.file(id)));
});

test('Löschen während laufender Schreibvorgänge lässt keine Datei zurück', async t => {
  const { store, hub } = await setup(t);
  const s = await store.create(OWNER);
  for (let i = 0; i < 20; i++) store.touch(s);
  await hub.remove(USER, s.id);
  store.touch(s);
  await store.flush();
  await new Promise(resolve => setTimeout(resolve, 10));
  await assert.rejects(stat(store.file(s.id)));
  assert.throws(() => store.get(s.id, USER), /nicht gefunden/);
});

test('Sitzung gehört einem Konto: fremd und ohne Besitzer wie nicht vorhanden', async t => {
  const root = await tempDir(t);
  const store = await new Store({ root }).init();
  const s = await store.create(OWNER);
  assert.equal(store.get(s.id, USER), s);
  assert.throws(() => store.get(s.id, 'konto-b'), e => e.status === 404);
  assert.throws(() => store.get(s.id, undefined), e => e.status === 404);
  assert.deepEqual(store.list('konto-b'), []);
  assert.equal(store.list(USER).length, 1);
  assert.equal(JSON.parse(await readFile(store.file(s.id), 'utf8')).userId, USER);
  assert.ok(!('userId' in store.public(s)));
});
