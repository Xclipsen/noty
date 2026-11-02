import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { SessionAuth, bearerToken } from '../server/auth.mjs';
import { startAccountBackend } from './fake-account-backend.mjs';
import { TOKEN, TOKEN_B } from './helpers.mjs';

const respond = (body, status = 200) => async () => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status });
const check = (fetcher, options = {}) => new SessionAuth({ accountUrl: 'http://127.0.0.1:1/', fetcher, ...options });

test('Gültige Sitzung liefert nur id und name; URL und Header stimmen', async t => {
  const backend = await startAccountBackend(new Map([[TOKEN, { id: 'konto-a', name: 'Anna', email: 'privat@example.invalid' }]]));
  t.after(() => backend.close());
  const auth = new SessionAuth({ accountUrl: backend.url + '/' });
  assert.deepEqual(await auth.verify(TOKEN), { id: 'konto-a', name: 'Anna' });
  assert.deepEqual(backend.seen, [`Bearer ${TOKEN}`]);
  await assert.rejects(auth.verify(TOKEN_B), e => e.status === 401);
});

test('Ungültige Formen fragen das Backend gar nicht', async () => {
  let calls = 0;
  const auth = check(async () => { calls++; return new Response('{}'); });
  for (const token of [null, undefined, '', 'kurz', 'A'.repeat(64), 'a'.repeat(63), 'a'.repeat(65), 7]) await assert.rejects(auth.verify(token), e => e.status === 401);
  assert.equal(calls, 0);
  assert.equal(bearerToken(`Bearer ${TOKEN}`), TOKEN);
  for (const header of [undefined, TOKEN, `bearer ${TOKEN}`, `Bearer  ${TOKEN}`, `Bearer ${TOKEN} x`, 'Basic abc']) assert.equal(bearerToken(header), null);
});

test('Niemals fail-open: jede unklare Antwort ist 503', async () => {
  for (const fetcher of [
    async () => { throw new Error('ECONNREFUSED'); },
    respond({ user: { id: 'x', name: 'y' } }, 500), respond({ user: { id: 'x', name: 'y' } }, 404), respond({ user: { id: 'x', name: 'y' } }, 302), respond({ user: null }, 401),
    respond('kein json'), respond({}), respond([]), respond('null'), respond({ user: {} }), respond({ user: 'x' }), respond({ user: { id: '', name: 'y' } }), respond({ user: { id: 7, name: 'y' } }), respond({ user: { id: 'x' } }), respond({ user: true }), respond({ user: { id: 'x'.repeat(201), name: 'y' } })
  ]) await assert.rejects(check(fetcher).verify(TOKEN), e => e.status === 503 && /nicht erreichbar/.test(e.message));
});

test('Fehlschläge des Backends gelten nur Sekunden', async () => {
  let down = true; let now = 0;
  const auth = check(async () => { if (down) throw new Error('aus'); return new Response(JSON.stringify({ user: { id: 'a', name: 'A' } })); }, { now: () => now });
  await assert.rejects(auth.verify(TOKEN), e => e.status === 503);
  down = false;
  now = 3000;
  assert.equal((await auth.verify(TOKEN)).id, 'a');
});

test('Hängendes Backend läuft in eine Frist', async () => {
  const fetcher = (url, { signal }) => new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(signal.reason)));
  const keepAlive = setTimeout(() => {}, 200); // AbortSignal.timeout hält die Ereignisschleife nicht offen.
  await assert.rejects(check(fetcher, { timeoutMs: 20 }).verify(TOKEN), e => e.status === 503);
  clearTimeout(keepAlive);
});

test('Cache: 60 Sekunden, nur Hash als Schlüssel, Entzug und Größe', async () => {
  let now = 0; let calls = 0; let user = { id: 'a', name: 'A' };
  const auth = check(async () => { calls++; return new Response(JSON.stringify({ user })); }, { now: () => now, maxEntries: 2 });
  await auth.verify(TOKEN);
  now = 59_999;
  await auth.verify(TOKEN);
  assert.equal(calls, 1);
  assert.ok(![...auth.cache.keys()].includes(TOKEN));
  assert.ok(!JSON.stringify([...auth.cache]).includes(TOKEN));
  assert.match([...auth.cache.keys()][0], /^[a-f0-9]{64}$/);
  now = 60_000;
  user = null;
  await assert.rejects(auth.verify(TOKEN), e => e.status === 401);
  assert.equal(calls, 2);
  await assert.rejects(auth.verify(TOKEN), e => e.status === 401);
  assert.equal(calls, 2, 'auch negative Antworten werden gemerkt');
  assert.equal(auth.cache.size, 0, 'Entzug entfernt den Eintrag');
  for (const token of ['b', 'c', 'd', 'e']) await assert.rejects(auth.verify(token.repeat(64)));
  assert.equal(auth.negative.size, 2);
});

test('Weiterleitungen werden nicht verfolgt', async () => {
  let options;
  await check(async (url, given) => { options = given; return new Response(JSON.stringify({ user: null })); }).verify(TOKEN).catch(() => {});
  assert.equal(options.redirect, 'error');
});

test('Kein Schlüssel wird geschrieben oder geloggt', async () => {
  const source = await readFile(new URL('../server/auth.mjs', import.meta.url), 'utf8');
  assert.ok(!/console\.|writeFile|writeAtomic/.test(source));
});

const randomToken = () => randomBytes(32).toString('hex');
const nobody = () => { const fetcher = async () => { fetcher.calls++; return new Response('{"user":null}'); }; fetcher.calls = 0; return fetcher; };
const VALID = { id: 'konto-a', name: 'Anna' };

test('Befund 2: Flut zufälliger Tokens bleibt unter dem Backend-Limit, nie Zugriff', async () => {
  const fetcher = nobody();
  const auth = check(fetcher);
  const statuses = new Set();
  for (let i = 0; i < 3000; i++) await auth.verify(randomToken(), `198.51.100.${i % 200}`).then(() => assert.fail('Zugriff'), e => statuses.add(e.status));
  assert.ok(fetcher.calls <= 300, `${fetcher.calls} Abfragen`);
  assert.deepEqual([...statuses].sort(), [401, 429]);
});

test('Befund 2: bekannte gültige Tokens laufen trotz Flut weiter, auch nach Ablauf des Cache', async () => {
  let now = 1_000_000;
  let lookups = 0;
  const fetcher = async (url, { headers }) => { lookups++; return new Response(JSON.stringify({ user: headers.authorization.endsWith(TOKEN) ? VALID : null })); };
  const auth = check(fetcher, { now: () => now });
  assert.deepEqual(await auth.verify(TOKEN), VALID);
  for (let i = 0; i < 2000; i++) await auth.verify(randomToken(), `198.51.100.${i % 200}`).catch(() => {});
  assert.deepEqual(await auth.verify(TOKEN), VALID, 'Cache');
  now += 61_000;
  assert.deepEqual(await auth.verify(TOKEN), VALID, 'erneute Prüfung aus dem reservierten Anteil');
  await assert.rejects(auth.verify(TOKEN_B, '203.0.113.9'), e => e.status === 429);
  assert.ok(lookups <= 302, `${lookups} Abfragen`);
});

test('Befund 2: Flut verdrängt keine gültigen Einträge aus dem Cache', async () => {
  let lookups = 0;
  const fetcher = async (url, { headers }) => { lookups++; return new Response(JSON.stringify({ user: headers.authorization.endsWith(TOKEN) ? VALID : null })); };
  const auth = check(fetcher, { maxEntries: 5, maxUnknownLookups: 1000, maxLookups: 1000, maxClientLookups: 1000 });
  await auth.verify(TOKEN);
  for (let i = 0; i < 50; i++) await auth.verify(randomToken()).catch(() => {});
  const before = lookups;
  await auth.verify(TOKEN);
  assert.equal(lookups, before);
});

test('Befund 2: Fehlschlag wird kurz, gehasht und begrenzt gemerkt', async () => {
  let now = 1000;
  const fetcher = nobody();
  const auth = check(fetcher, { now: () => now, negativeTtlMs: 30_000, maxEntries: 4 });
  for (let i = 0; i < 5; i++) await assert.rejects(auth.verify(TOKEN_B), e => e.status === 401);
  assert.equal(fetcher.calls, 1);
  assert.ok(![...auth.negative.keys()].includes(TOKEN_B));
  now += 30_001;
  await assert.rejects(auth.verify(TOKEN_B), e => e.status === 401);
  assert.equal(fetcher.calls, 2);
  for (let i = 0; i < 20; i++) await auth.verify(randomToken()).catch(() => {});
  assert.ok(auth.negative.size <= 4);
});

test('Befund 2: Ausfälle des Backends werden nur kurz gemerkt', async () => {
  let now = 1000; let calls = 0; let down = true;
  const auth = check(async () => { calls++; if (down) throw new Error('weg'); return new Response(JSON.stringify({ user: VALID })); }, { now: () => now, failureTtlMs: 3000 });
  for (let i = 0; i < 3; i++) await assert.rejects(auth.verify(TOKEN), e => e.status === 503);
  assert.equal(calls, 1);
  down = false;
  now += 3001;
  assert.deepEqual(await auth.verify(TOKEN), VALID);
});

test('Befund 2: gleichzeitige Abfragen sind gedeckelt, Überschuss ist 503 und gibt nichts frei', async () => {
  const release = []; let active = 0; let peak = 0; let held = true;
  const fetcher = () => new Promise(resolve => {
    if (!held) { resolve(new Response('{"user":null}')); return; }
    active++; peak = Math.max(peak, active); release.push(() => { active--; resolve(new Response('{"user":null}')); });
  });
  const auth = check(fetcher, { maxUnknownConcurrent: 3, maxConcurrent: 5 });
  const results = Array.from({ length: 12 }, () => auth.verify(randomToken()).catch(e => e.status));
  await new Promise(setImmediate);
  assert.equal(peak, 3);
  held = false;
  while (release.length) release.shift()();
  const statuses = await Promise.all(results);
  assert.equal(statuses.filter(status => status === 401).length, 3);
  assert.equal(statuses.filter(status => status === 503).length, 9);
  await assert.rejects(auth.verify(randomToken()), e => e.status === 401);
});

test('Befund 2: Drossel je Client trifft nur diesen Client', async () => {
  const fetcher = nobody();
  const auth = check(fetcher, { maxClientLookups: 3 });
  for (let i = 0; i < 3; i++) await assert.rejects(auth.verify(randomToken(), '198.51.100.7'), e => e.status === 401);
  await assert.rejects(auth.verify(randomToken(), '198.51.100.7'), e => e.status === 429 && e.retryAfter > 0);
  await assert.rejects(auth.verify(randomToken(), '198.51.100.8'), e => e.status === 401);
});

test('Befund 2: 429 vom Backend pausiert alle Abfragen, gültiger Cache läuft weiter', async () => {
  let now = 1000; let calls = 0; let limited = false;
  const fetcher = async (url, { headers }) => {
    calls++;
    if (limited) return new Response('{}', { status: 429, headers: { 'retry-after': '60' } });
    return new Response(JSON.stringify({ user: headers.authorization.endsWith(TOKEN) ? VALID : null }));
  };
  const auth = check(fetcher, { now: () => now });
  await auth.verify(TOKEN);
  limited = true;
  await assert.rejects(auth.verify(TOKEN_B), e => e.status === 503);
  const before = calls;
  await assert.rejects(auth.verify(randomToken()), e => e.status === 503);
  assert.equal(calls, before);
  assert.deepEqual(await auth.verify(TOKEN), VALID);
  limited = false;
  now += 60_001;
  await assert.rejects(auth.verify(randomToken()), e => e.status === 401);
});

test('Befund 8: gekürzter Kontoname bleibt wohlgeformt', async () => {
  const auth = check(respond({ user: { id: 'konto-a', name: `${'a'.repeat(199)}😀` } }));
  const { name } = await auth.verify(TOKEN);
  assert.ok(name.isWellFormed());
});
