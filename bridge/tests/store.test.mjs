import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, readFile, readdir, rename, rm, stat, utimes, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { LatestWriter, Store, DAY_MS, writeAtomic } from '../server/store.mjs';
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
  await utimes(`${store.file(id)}.corrupt`, past, past);
  await new Store({ root }).init();
  await assert.rejects(stat(`${store.file(id)}.corrupt`));
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

const ID = '00000000-0000-4000-8000-000000000001';
const VALID = (extra = {}) => ({ id: ID, userId: USER, documentId: null, title: 'Titel', status: 'idle', revision: 3, updatedAt: Date.now(), messages: [{ id: 'm1', role: 'user', text: 'Frage' }], requests: ['anfrage-0001'], ...extra });
const quiet = t => t.mock.method(console, 'error', () => {});

test('Befund 9: jede ungültige Datei wird zu .corrupt und blockiert nichts', async t => {
  quiet(t);
  for (const [label, content] of [
    ['kein JSON', '{kaputt'], ['Zahl', '5'], ['Liste', '[]'], ['null', 'null'],
    ['id fremd', JSON.stringify(VALID({ id: '00000000-0000-4000-8000-000000000002' }))],
    ['userId fehlt', JSON.stringify(VALID({ userId: undefined }))], ['userId Zahl', JSON.stringify(VALID({ userId: 5 }))], ['userId leer', JSON.stringify(VALID({ userId: '' }))],
    ['documentId Zahl', JSON.stringify(VALID({ documentId: 5 }))], ['title Zahl', JSON.stringify(VALID({ title: 5 }))],
    ['status unbekannt', JSON.stringify(VALID({ status: 'kaputt' }))], ['status fehlt', JSON.stringify(VALID({ status: undefined }))],
    ['revision Text', JSON.stringify(VALID({ revision: '3' }))], ['revision negativ', JSON.stringify(VALID({ revision: -1 }))], ['revision Bruch', JSON.stringify(VALID({ revision: 1.5 }))],
    ['updatedAt Text', JSON.stringify(VALID({ updatedAt: 'gestern' }))], ['updatedAt fehlt', JSON.stringify(VALID({ updatedAt: undefined }))],
    ['requests fehlt', JSON.stringify(VALID({ requests: undefined }))], ['requests Zahlen', JSON.stringify(VALID({ requests: [5] }))],
    ['messages Objekt', JSON.stringify(VALID({ messages: {} }))], ['Nachricht null', JSON.stringify(VALID({ messages: [null] }))],
    ['Nachricht ohne Text', JSON.stringify(VALID({ messages: [{ id: 'm', role: 'user' }] }))], ['Text Zahl', JSON.stringify(VALID({ messages: [{ id: 'm', role: 'user', text: 5 }] }))],
    ['Rolle unbekannt', JSON.stringify(VALID({ messages: [{ id: 'm', role: 'root', text: 'x' }] }))], ['id fehlt', JSON.stringify(VALID({ messages: [{ role: 'user', text: 'x' }] }))],
    ['contextLabel Zahl', JSON.stringify(VALID({ messages: [{ id: 'm', role: 'user', text: 'x', contextLabel: 5 }] }))], ['imageCount Text', JSON.stringify(VALID({ messages: [{ id: 'm', role: 'user', text: 'x', imageCount: 'zwei' }] }))]
  ]) {
    const root = await tempDir(t);
    const seed = await new Store({ root }).init();
    await writeFile(seed.file(ID), content);
    const store = await new Store({ root }).init();
    assert.equal(store.sessions.size, 0, label);
    assert.deepEqual(await readdir(store.sessionsDir), [`${ID}.json.corrupt`], label);
    assert.equal(await readFile(`${store.file(ID)}.corrupt`, 'utf8'), content, label);
  }
});

test('Befund 9: gültige Dateien laden unverändert, Ordner an Dateistelle stört nicht', async t => {
  quiet(t);
  const root = await tempDir(t);
  const seed = await new Store({ root }).init();
  await writeFile(seed.file(ID), JSON.stringify(VALID()));
  await mkdir(seed.file('00000000-0000-4000-8000-000000000002'));
  const store = await new Store({ root }).init();
  assert.deepEqual(store.get(ID, USER), VALID({ updatedAt: store.get(ID, USER).updatedAt }));
});

test('Befund 9: .corrupt altert aus, auch im laufenden Betrieb', async t => {
  quiet(t);
  const root = await tempDir(t);
  const seed = await new Store({ root }).init();
  await writeFile(seed.file(ID), '{kaputt');
  const store = await new Store({ root }).init();
  const file = `${store.file(ID)}.corrupt`;
  await store.purge();
  assert.ok((await stat(file)).isFile());
  const past = new Date(Date.now() - 40 * DAY_MS);
  await utimes(file, past, past);
  await store.purge();
  await assert.rejects(stat(file));
});

test('Befund 9: nicht löschbare abgelaufene Dateien verhindern den Start nicht und bleiben unsichtbar', async t => {
  quiet(t);
  const root = await tempDir(t);
  const seed = await new Store({ root }).init();
  await writeFile(seed.file(ID), JSON.stringify(VALID({ updatedAt: Date.now() - 40 * DAY_MS })));
  const store = new Store({ root });
  store.unlinkFile = async () => { throw Object.assign(new Error('EACCES'), { code: 'EACCES' }); };
  await store.init();
  assert.equal(store.sessions.size, 0);
  assert.throws(() => store.get(ID, USER), e => e.status === 404);
});

test('Befund 9: scheiternde Aufbewahrung im Betrieb bricht weder Start noch übrige Löschungen ab', async t => {
  quiet(t);
  let now = Date.now();
  const { hub, store, metering } = await setup(t, { store: { now: () => now } });
  const a = await store.create(OWNER);
  const b = await store.create(OWNER);
  now += 40 * DAY_MS;
  const { unlinkFile } = store;
  store.unlinkFile = async file => { if (file === store.file(a.id)) throw Object.assign(new Error('EACCES'), { code: 'EACCES' }); return unlinkFile(file); };
  metering.save = () => Promise.reject(new Error('Platte voll'));
  metering.days.set('2000-01-01', new Map());
  await hub.startRetention();
  assert.deepEqual([...store.sessions.keys()], [a.id]);
  await assert.rejects(stat(store.file(b.id)));
});

test('Befund 9: abgelaufene Sitzungen sind sofort beim Lesen weg', async t => {
  let now = Date.now();
  const store = await new Store({ root: await tempDir(t), now: () => now, retentionDays: 30 }).init();
  const s = await store.create(OWNER);
  assert.equal(store.get(s.id, USER), s);
  now += 31 * DAY_MS;
  assert.throws(() => store.get(s.id, USER), e => e.status === 404);
  assert.deepEqual(store.list(USER), []);
});

test('Befund 9: .tmp-Reste im Wurzelordner verschwinden beim Start, Daten bleiben', async t => {
  const root = await tempDir(t);
  await writeFile(path.join(root, 'accounts.json'), '[]');
  await writeFile(path.join(root, 'accounts.json.0000.tmp'), 'Rest');
  await writeFile(path.join(root, 'metering.json.1111.tmp'), 'Rest');
  await writeFile(path.join(root, 'tool-free-catalog.json.2222.tmp'), 'Rest');
  await new Store({ root }).init();
  assert.deepEqual((await readdir(root)).sort(), ['accounts.json', 'sessions']);
});

test('Befund 9: Speicherfehler beim Neustart blockiert den Start nicht', async t => {
  quiet(t);
  const root = await tempDir(t);
  const seed = await new Store({ root }).init();
  await writeFile(seed.file(ID), JSON.stringify(VALID({ status: 'running' })));
  const store = new Store({ root });
  store.persist = () => Promise.reject(new Error('Platte voll'));
  await store.init();
  assert.equal(store.get(ID, USER).status, 'error');
});

test('Befund 8: bestehende Sitzung mit einzelnen Surrogaten wird beim Laden repariert', async t => {
  const root = await tempDir(t);
  const seed = await new Store({ root }).init();
  const before = VALID({ title: 'Titel \ud83d', messages: [{ id: 'm1', role: 'user', text: 'Frage \ude00', contextLabel: 'Heft \ud83d' }] });
  await writeFile(seed.file(ID), JSON.stringify(before));
  const store = await new Store({ root }).init();
  const s = store.get(ID, USER);
  assert.equal(s.title, 'Titel �');
  assert.equal(s.messages[0].text, 'Frage �');
  assert.equal(s.messages[0].contextLabel, 'Heft �');
  assert.ok(s.revision > before.revision, 'Client holt den reparierten Stand');
  assert.ok(!/\\ud[89a-f]/i.test(JSON.stringify(store.list(USER))));
  assert.ok(!/\\ud[89a-f]/i.test(await readFile(store.file(ID), 'utf8')));
});

test('Befund 10: LatestWriter holt Fehlschläge mit Backoff nach und endet mit dem Erfolg', async t => {
  const root = await tempDir(t);
  let attempts = 0; let value = 'erster Stand';
  const writer = new LatestWriter(path.join(root, 'fehlt', 'x.json'), () => { attempts++; return value; }, { retryMs: 5, maxRetryMs: 20 });
  await assert.rejects(writer.save());
  value = 'neuester Stand';
  await new Promise(resolve => setTimeout(resolve, 40));
  assert.ok(attempts >= 3, String(attempts));
  assert.ok(attempts <= 12, String(attempts));
  await mkdir(path.join(root, 'fehlt'));
  for (let i = 0; i < 100 && !(await readFile(writer.file, 'utf8').catch(() => '')); i++) await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(await readFile(writer.file, 'utf8'), 'neuester Stand');
  const done = attempts;
  await new Promise(resolve => setTimeout(resolve, 40));
  assert.equal(attempts, done);
});

test('Befund 10: abgebrochener Writer wiederholt nichts mehr', async t => {
  const root = await tempDir(t);
  let attempts = 0;
  const writer = new LatestWriter(path.join(root, 'fehlt', 'x.json'), () => { attempts++; return 'x'; }, { retryMs: 5 });
  await assert.rejects(writer.save());
  writer.cancel();
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal(attempts, 1);
});

test('Befund 10: flush versucht es sofort noch einmal, close beendet die Wiederholung', async t => {
  const root = await tempDir(t);
  await mkdir(path.join(root, 'ordner'));
  const writer = new LatestWriter(path.join(root, 'ordner'), () => 'x', { retryMs: 60_000 });
  await assert.rejects(writer.save());
  await rm(path.join(root, 'ordner'), { recursive: true });
  await writer.flush();
  assert.equal(await readFile(writer.file, 'utf8'), 'x');
  await rm(writer.file); await mkdir(writer.file);
  await assert.rejects(writer.save());
  await writer.close();
  assert.equal(writer.timer, null);
});

test('Befund 10: POST-Fehler rollt die Sitzung zurück und ist 503', async t => {
  const store = await new Store({ root: await tempDir(t), retryMs: 5 }).init();
  await rename(store.sessionsDir, `${store.sessionsDir}.weg`);
  await assert.rejects(store.create(OWNER), e => e.status === 503 && /gespeichert/.test(e.message));
  assert.equal(store.sessions.size, 0);
  assert.equal(store.writes.size, 0);
  await rename(`${store.sessionsDir}.weg`, store.sessionsDir);
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.deepEqual(await readdir(store.sessionsDir), []);
});

test('Befund 10: spätes Schreiben legt eine gelöschte Sitzung nie wieder an', async t => {
  const store = await new Store({ root: await tempDir(t), retryMs: 5 }).init();
  const s = await store.create(OWNER);
  await rename(store.sessionsDir, `${store.sessionsDir}.weg`);
  await store.save(s).catch(() => {});
  await rename(`${store.sessionsDir}.weg`, store.sessionsDir);
  await store.remove(s.id);
  await new Promise(resolve => setTimeout(resolve, 25));
  assert.deepEqual(await readdir(store.sessionsDir), []);
});

test('Befund 10: Schreiben während des Löschens legt keine Datei an, auch ohne bestehenden Writer', async t => {
  const root = await tempDir(t);
  const first = await new Store({ root }).init();
  const s = await first.create(OWNER);
  await first.flush();
  const store = await new Store({ root }).init();
  const loaded = store.get(s.id, USER);
  const { unlinkFile } = store;
  store.unlinkFile = async file => { await unlinkFile(file); store.touch(loaded); await store.flush(); };
  await store.remove(s.id);
  assert.deepEqual(await readdir(store.sessionsDir), []);
});
