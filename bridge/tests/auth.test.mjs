import test from 'node:test';
import assert from 'node:assert/strict';
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

test('Fehlschläge des Backends werden nicht gecacht', async () => {
  let down = true;
  const auth = check(async () => { if (down) throw new Error('aus'); return new Response(JSON.stringify({ user: { id: 'a', name: 'A' } })); });
  await assert.rejects(auth.verify(TOKEN), e => e.status === 503);
  down = false;
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
  assert.equal(calls, 2, 'auch negative Antworten gelten eine Minute');
  for (const token of ['b', 'c', 'd', 'e']) await assert.rejects(auth.verify(token.repeat(64)));
  assert.equal(auth.cache.size, 2);
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
