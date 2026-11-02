import test from 'node:test';
import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import { readFile } from 'node:fs/promises';
import { MAX_BODY } from '../server/http.mjs';
import { serve, settled, request, until, TOKEN, TOKEN_B, USER, PNG } from './helpers.mjs';

const UUID_UPPER = 'E621E1F8-C36C-495A-93FC-0C247A3E6E5F';
const json = async (ctx, ...args) => { const res = await ctx.call(...args); return [res.status, res.status === 204 ? undefined : await res.json()]; };

function raw(port, { method = 'POST', path, headers, chunks = [] }) {
  return new Promise((resolve, reject) => {
    const req = httpRequest({ port, host: '127.0.0.1', method, path, headers }, res => {
      let body = ''; res.setEncoding('utf8'); res.on('data', d => { body += d; }); res.on('end', () => resolve({ status: res.statusCode, body, headers: res.headers }));
    });
    req.on('error', reject);
    for (const chunk of chunks) req.write(chunk);
    req.end();
  });
}

test('Jeder /v1-Pfad verlangt eine gültige Sitzung, Fehler sind deutsch, no-store überall', async t => {
  const ctx = await serve(t);
  for (const [method, path] of [['GET', '/v1/me'], ['GET', '/v1/info'], ['GET', '/v1/usage'], ['GET', '/v1/sessions'], ['POST', '/v1/sessions'], ['GET', `/v1/sessions/${UUID_UPPER}`], ['DELETE', `/v1/sessions/${UUID_UPPER}`], ['POST', `/v1/sessions/${UUID_UPPER}/turns`], ['POST', `/v1/sessions/${UUID_UPPER}/cancel`], ['GET', '/v1/pair'], ['POST', '/v1/pair'], ['GET', '/v1/unbekannt']]) {
    for (const headers of [{}, { authorization: `Bearer ${'c'.repeat(64)}` }, { authorization: TOKEN }, { authorization: `bearer ${TOKEN}` }, { authorization: 'Bearer kurz' }]) {
      const res = await ctx.call(method, path, undefined, headers);
      assert.equal(res.status, 401, `${method} ${path}`);
      assert.equal(res.headers.get('cache-control'), 'no-store');
      assert.match((await res.json()).error, /Anmeldung/);
    }
  }
  assert.equal(ctx.instances.length, 0);
});

test('Ohne gültige Sitzung wird ein großer Körper nicht ausgewertet', async t => {
  const ctx = await serve(t);
  const res = await raw(ctx.api.address().port, { path: '/v1/sessions', headers: { 'content-type': 'application/json', 'content-length': MAX_BODY * 2 } });
  assert.equal(res.status, 401);
});

test('Backend down: 503 für jeden /v1-Pfad, auch /v1/me', async t => {
  const ctx = await serve(t);
  ctx.backend.down = true;
  for (const path of ['/v1/me', '/v1/info', '/v1/sessions']) {
    const res = await ctx.call('GET', path);
    assert.equal(res.status, 503, path);
    assert.match((await res.json()).error, /nicht erreichbar/);
  }
  ctx.backend.down = false;
  assert.equal((await ctx.call('GET', '/v1/me')).status, 200);
});

test('Status: pending und blocked sehen nur /v1/me, active alles', async t => {
  const ctx = await serve(t, { activate: [] });
  const body = await ctx.call('GET', '/v1/me');
  assert.equal(body.status, 200);
  const me = await body.json();
  assert.deepEqual(Object.keys(me).sort(), ['dailyLimit', 'role', 'status', 'today', 'user']);
  assert.deepEqual([me.user, me.status, me.role, me.dailyLimit], [{ id: USER, name: 'Anna' }, 'pending', 'user', 200]);
  assert.deepEqual(Object.keys(me.today), ['turns', 'failedTurns', 'images', 'inputTokens', 'cachedInputTokens', 'outputTokens', 'reasoningOutputTokens']);
  for (const [status, code] of [['pending', /wartet/], ['blocked', /gesperrt/]]) {
    if (status === 'blocked') await ctx.accounts.update(USER, { status });
    assert.equal((await (await ctx.call('GET', '/v1/me')).json()).status, status);
    for (const [method, path] of [['GET', '/v1/info'], ['GET', '/v1/usage'], ['GET', '/v1/sessions'], ['POST', '/v1/sessions'], ['GET', `/v1/sessions/${UUID_UPPER}`], ['POST', `/v1/sessions/${UUID_UPPER}/turns`]]) {
      const res = await ctx.call(method, path);
      assert.equal(res.status, 403, path);
      const error = await res.json();
      assert.equal(error.code, status);
      assert.match(error.error, code);
    }
  }
  assert.equal(ctx.instances.length, 0);
  await ctx.accounts.update(USER, { status: 'active' });
  assert.equal((await ctx.call('GET', '/v1/sessions')).status, 200);
});

test('Admin aus der Liste ist immer active, ohne gesperrt werden zu können', async t => {
  const ctx = await serve(t, { activate: [], accounts: { adminIds: [USER] } });
  const me = await (await ctx.call('GET', '/v1/me')).json();
  assert.deepEqual([me.status, me.role], ['active', 'admin']);
  assert.equal((await ctx.call('GET', '/v1/sessions')).status, 200);
  await assert.rejects(ctx.accounts.update(USER, { status: 'blocked' }), e => e.status === 409);
  await assert.rejects(ctx.accounts.update(USER, { status: 'pending' }), e => e.status === 409);
  assert.equal((await ctx.call('GET', '/v1/sessions')).status, 200);
});

test('Sitzungsisolation zwischen zwei Konten', async t => {
  const ctx = await serve(t);
  const b = { authorization: `Bearer ${TOKEN_B}` };
  const [, session] = await json(ctx, 'POST', '/v1/sessions', { documentId: UUID_UPPER, title: 'Annas Heft' });
  const id = session.id;
  await ctx.call('POST', `/v1/sessions/${id}/turns`, request('anfrage-0001', { text: 'PRIVATE-FRAGE' }));
  await settled(ctx.store, id);
  await until(() => ctx.hub.runs.size === 0);
  assert.deepEqual((await json(ctx, 'GET', '/v1/sessions', undefined, b))[1], []);
  assert.deepEqual((await json(ctx, 'GET', `/v1/sessions?documentId=${UUID_UPPER}`, undefined, b))[1], []);
  for (const [method, path, body] of [['GET', `/v1/sessions/${id}`], ['GET', `/v1/sessions/${id}?after=0`], ['DELETE', `/v1/sessions/${id}`], ['POST', `/v1/sessions/${id}/turns`, request('anfrage-0002')], ['POST', `/v1/sessions/${id}/cancel`]]) {
    const res = await ctx.call(method, path, body, b);
    assert.equal(res.status, 404, `${method} ${path}`);
    assert.ok(!(await res.text()).includes('PRIVATE-FRAGE'));
  }
  assert.equal(ctx.instances.length, 1);
  assert.equal((await ctx.call('GET', `/v1/sessions/${id}`)).status, 200);
  assert.equal(ctx.metering.forToday('konto-b').turns, 0);
  assert.equal(ctx.metering.forToday(USER).turns, 1);
});

test('Laufplätze gelten über alle Konten, Limits je Konto', async t => {
  const ctx = await serve(t, { rpc: { onTurn: () => {} } });
  const b = { authorization: `Bearer ${TOKEN_B}` };
  const [, one] = await json(ctx, 'POST', '/v1/sessions', {});
  const [, two] = await json(ctx, 'POST', '/v1/sessions', {});
  const [, foreign] = await json(ctx, 'POST', '/v1/sessions', {}, b);
  assert.equal((await ctx.call('POST', `/v1/sessions/${one.id}/turns`, request())).status, 202);
  assert.equal((await ctx.call('POST', `/v1/sessions/${two.id}/turns`, request())).status, 202);
  assert.equal((await ctx.call('POST', `/v1/sessions/${foreign.id}/turns`, request(), b)).status, 429);
});

test('Limit 0 über HTTP: 429 mit deutscher Meldung, /v1/me zeigt 0', async t => {
  const ctx = await serve(t);
  await ctx.accounts.update(USER, { dailyLimit: 0 });
  const [, session] = await json(ctx, 'POST', '/v1/sessions', {});
  const res = await ctx.call('POST', `/v1/sessions/${session.id}/turns`, request());
  assert.equal(res.status, 429);
  assert.match((await res.json()).error, /keine Läufe/);
  assert.equal((await (await ctx.call('GET', '/v1/me')).json()).dailyLimit, 0);
  assert.equal(ctx.instances.length, 0);
});

test('Sitzungsprüfung läuft höchstens einmal je Minute je Schlüssel', async t => {
  let now = 1_000_000;
  const ctx = await serve(t, { auth: { now: () => now } });
  await Promise.all([ctx.call('GET', '/v1/me'), ctx.call('GET', '/v1/me')]);
  await ctx.call('GET', '/v1/me');
  assert.equal(ctx.backend.lookups, 1);
  now += 60_000;
  await ctx.call('GET', '/v1/me');
  assert.equal(ctx.backend.lookups, 2);
  ctx.backend.users.clear();
  now += 60_000;
  assert.equal((await ctx.call('GET', '/v1/me')).status, 401);
});

test('Einhängepunkt /admin: ohne Handler 404, mit Handler ohne /v1-Prüfung', async t => {
  const without = await serve(t);
  for (const path of ['/admin', '/admin/api/overview']) assert.equal((await without.call('GET', path, undefined, {})).status, 404);
  assert.equal(without.backend.lookups, 0);
  assert.equal((await without.call('GET', '/adminx', undefined, {})).status, 404);
  const seen = [];
  const withHandler = await serve(t, { admin: async (req, res, url) => { seen.push(url.pathname); res.writeHead(200); res.end('panel'); } });
  const res = await withHandler.call('GET', '/admin', undefined, {});
  assert.equal(await res.text(), 'panel');
  assert.deepEqual(seen, ['/admin']);
  const failing = await serve(t, { admin: async () => { throw new Error('intern'); } });
  assert.deepEqual(await (await failing.call('GET', '/admin/x', undefined, {})).json(), { error: 'Interner Fehler.' });
});

test('Sitzungen: anlegen, listen, filtern, abfragen, löschen', async t => {
  const ctx = await serve(t);
  const [status, session] = await json(ctx, 'POST', '/v1/sessions', { documentId: UUID_UPPER, title: 'Mathe' });
  assert.equal(status, 201);
  assert.deepEqual(Object.keys(session).sort(), ['documentId', 'id', 'messages', 'revision', 'status', 'title', 'updatedAt']);
  assert.equal(session.status, 'idle');
  assert.equal(session.documentId, UUID_UPPER);
  assert.equal(typeof session.updatedAt, 'number');
  const [, other] = await json(ctx, 'POST', '/v1/sessions', {});
  assert.equal(other.documentId, null);
  assert.equal((await ctx.call('POST', '/v1/sessions')).status, 201);
  assert.equal((await json(ctx, 'GET', '/v1/sessions'))[1].length, 3);
  const [, filtered] = await json(ctx, 'GET', `/v1/sessions?documentId=${UUID_UPPER.toLowerCase()}`);
  assert.deepEqual(filtered, [{ id: session.id, documentId: UUID_UPPER, title: 'Mathe', status: 'idle', revision: session.revision, updatedAt: session.updatedAt }]);
  assert.equal((await ctx.call('GET', `/v1/sessions/${session.id}?after=${session.revision}`)).status, 204);
  assert.equal((await ctx.call('GET', `/v1/sessions/${session.id.toUpperCase()}?after=0`)).status, 200);
  const del = await ctx.call('DELETE', `/v1/sessions/${session.id}`);
  assert.equal(del.status, 204);
  assert.equal((await ctx.call('GET', `/v1/sessions/${session.id}`)).status, 404);
  assert.equal((await ctx.call('DELETE', `/v1/sessions/${session.id}`)).status, 404);
});

test('Neueste Sitzung zuerst', async t => {
  let now = 1000;
  const ctx = await serve(t, { store: { now: () => now++, retentionDays: 100000 } });
  const [, a] = await json(ctx, 'POST', '/v1/sessions', { title: 'A' });
  await json(ctx, 'POST', '/v1/sessions', { title: 'B' });
  await ctx.hub.store.save(ctx.store.get(a.id, USER));
  assert.deepEqual((await json(ctx, 'GET', '/v1/sessions'))[1].map(s => s.title), ['A', 'B']);
});

test('UUID-Prüfung und Eingabefehler', async t => {
  const ctx = await serve(t);
  for (const id of ['abc', 'e621e1f8-c36c-495a-93fc-0c247a3e6e5g', 'E621E1F8C36C495A93FC0C247A3E6E5F']) {
    assert.equal((await ctx.call('GET', `/v1/sessions/${id}`)).status, 400, id);
  }
  assert.equal((await ctx.call('GET', '/v1/sessions?documentId=abc')).status, 400);
  assert.equal((await ctx.call('GET', '/v1/sessions?documentId=')).status, 400);
  assert.equal((await ctx.call('POST', '/v1/sessions', { documentId: 'abc' })).status, 400);
  assert.equal((await ctx.call('POST', '/v1/sessions', { title: 'x'.repeat(201) })).status, 400);
  assert.equal((await ctx.call('POST', '/v1/sessions', { title: 7 })).status, 400);
  assert.equal((await ctx.call('POST', '/v1/sessions', '{kaputt')).status, 400);
  assert.equal((await ctx.call('POST', '/v1/sessions', '[]')).status, 400);
  const { port } = ctx.api.address();
  const text = await raw(port, { path: '/v1/sessions', headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'text/plain', 'content-length': 2 }, chunks: ['{}'] });
  assert.equal(text.status, 415);
  const [, session] = await json(ctx, 'POST', '/v1/sessions', {});
  assert.equal((await ctx.call('GET', `/v1/sessions/${session.id}?after=abc`)).status, 400);
  assert.equal((await ctx.call('POST', `/v1/sessions/${UUID_UPPER}/turns`, request())).status, 404);
  assert.equal((await ctx.call('POST', `/v1/sessions/${UUID_UPPER}/cancel`)).status, 404);
  assert.equal((await ctx.call('POST', `/v1/sessions/${session.id}/turns`, { text: 'x' })).status, 400);
  assert.equal((await ctx.call('PUT', `/v1/sessions/${session.id}`)).status, 404);
  assert.equal((await ctx.call('POST', `/v1/sessions/${session.id}/andere`)).status, 404);
  assert.equal((await ctx.call('GET', `/v1/sessions/${session.id}/a/b`)).status, 404);
});

test('Körpergrenze: Content-Length und chunked', async t => {
  const ctx = await serve(t);
  const { port } = ctx.api.address();
  const [, session] = await json(ctx, 'POST', '/v1/sessions', {});
  const path = `/v1/sessions/${session.id}/turns`;
  const headers = { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' };
  assert.equal((await raw(port, { path, headers: { ...headers, 'content-length': MAX_BODY + 1 } })).status, 413);
  const chunk = Buffer.alloc(1024 * 1024, 0x20);
  const res = await raw(port, { path, headers, chunks: Array(25).fill(chunk) });
  assert.equal(res.status, 413);
  assert.match(res.body, /zu groß/);
});

test('Interne Fehler verraten keine Details', async t => {
  const ctx = await serve(t);
  ctx.store.list = () => { throw new Error('/var/lib/geheim/pfad'); };
  const res = await ctx.call('GET', '/v1/sessions');
  assert.equal(res.status, 500);
  assert.deepEqual(await res.json(), { error: 'Interner Fehler.' });
});

test('Ablauf über HTTP: Frage, 202, Polling mit after, Wiederholung, Abbruch', async t => {
  const ctx = await serve(t);
  const [, session] = await json(ctx, 'POST', '/v1/sessions', {});
  const body = request('anfrage-0001', { context: { label: 'Mathe, Seite 3', text: 'X' }, images: [{ mimeType: 'image/png', base64: PNG.toString('base64') }] });
  const [status, accepted] = await json(ctx, 'POST', `/v1/sessions/${session.id}/turns`, body);
  assert.equal(status, 202);
  assert.equal(accepted.status, 'running');
  assert.deepEqual(Object.keys(accepted.messages[0]).sort(), ['contextLabel', 'id', 'imageCount', 'role', 'text']);
  assert.ok(!('requests' in accepted));
  await settled(ctx.store, session.id);
  await until(() => ctx.hub.runs.size === 0);
  const [, done] = await json(ctx, 'GET', `/v1/sessions/${session.id}?after=${accepted.revision}`);
  assert.equal(done.status, 'idle');
  assert.equal(done.messages.at(-1).text, 'Antwort [S. 3]');
  assert.equal((await ctx.call('GET', `/v1/sessions/${session.id}?after=${done.revision}`)).status, 204);
  assert.equal((await ctx.call('POST', `/v1/sessions/${session.id}/turns`, body)).status, 202);
  assert.equal(ctx.instances.length, 1);
  assert.deepEqual(await json(ctx, 'POST', `/v1/sessions/${session.id}/cancel`), [200, { ok: true }]);
});

test('Info und Usage über HTTP; Dienstfehler als 503', async t => {
  const ctx = await serve(t);
  const [status, info] = await json(ctx, 'GET', '/v1/info');
  assert.equal(status, 200);
  assert.equal(info.account, 'chatgpt');
  assert.equal((await ctx.call('GET', '/v1/usage')).status, 200);
  const down = await serve(t, { rpc: { failStart: true } });
  const res = await down.call('GET', '/v1/info');
  assert.equal(res.status, 503);
  assert.match((await res.json()).error, /nicht erreichbar/);
});

test('Tageslimit und parallele Läufe als 429, laufend als 409', async t => {
  const ctx = await serve(t, { rpc: { onTurn: () => {} } });
  const ids = [];
  for (let i = 0; i < 3; i++) ids.push((await json(ctx, 'POST', '/v1/sessions', {}))[1].id);
  assert.equal((await ctx.call('POST', `/v1/sessions/${ids[0]}/turns`, request())).status, 202);
  assert.equal((await ctx.call('POST', `/v1/sessions/${ids[0]}/turns`, request('anfrage-0002'))).status, 409);
  assert.equal((await ctx.call('POST', `/v1/sessions/${ids[1]}/turns`, request())).status, 202);
  assert.equal((await ctx.call('POST', `/v1/sessions/${ids[2]}/turns`, request())).status, 429);
});

test('Sitzungsdatei enthält nach HTTP-Lauf den Kontext nicht', async t => {
  const ctx = await serve(t);
  const [, session] = await json(ctx, 'POST', '/v1/sessions', {});
  await ctx.call('POST', `/v1/sessions/${session.id}/turns`, request('anfrage-0001', { context: { label: 'L', text: 'HTTP-MARKER-99' } }));
  await settled(ctx.store, session.id);
  await ctx.store.flush();
  assert.ok(!(await readFile(ctx.store.file(session.id), 'utf8')).includes('HTTP-MARKER-99'));
});
