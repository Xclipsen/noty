import test from 'node:test';
import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import { connect } from 'node:net';
import { readFile, rename } from 'node:fs/promises';
import { createAdminApi } from '../server/admin.mjs';
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
  const ctx = await serve(t, { auth: { failureTtlMs: 0 } });
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

test('Der App-Listener kennt /admin nicht, der Admin-Listener prüft keine Kontositzung', async t => {
  const ctx = await serve(t);
  for (const path of ['/admin', '/admin/api/overview', '/adminx']) assert.equal((await ctx.call('GET', path, undefined, {})).status, 404, path);
  const seen = [];
  const listen = async handler => {
    const server = createAdminApi(handler);
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    t.after(() => { server.close(); server.closeAllConnections(); });
    return `http://127.0.0.1:${server.address().port}`;
  };
  const base = await listen(async (req, res, url) => { seen.push(url.pathname); res.writeHead(200); res.end('panel'); });
  const res = await fetch(`${base}/admin`);
  assert.equal(await res.text(), 'panel');
  assert.deepEqual(seen, ['/admin']);
  assert.equal((await fetch(`${base}/adminx`)).status, 404);
  assert.deepEqual(seen, ['/admin']);
  const failing = await listen(async () => { throw new Error('intern'); });
  assert.deepEqual(await (await fetch(`${failing}/admin/x`)).json(), { error: 'Interner Fehler.' });
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

const authHeaders = (token = TOKEN) => ({ authorization: `Bearer ${token}`, 'content-type': 'application/json' });

/** Hält einen Upload offen: Kopf ist da, der Körper kommt erst mit `finish`. */
function openUpload(port, path, headers = authHeaders()) {
  const upload = {};
  upload.done = new Promise((resolve, reject) => {
    upload.req = httpRequest({ port, host: '127.0.0.1', method: 'POST', path, headers: { ...headers, 'transfer-encoding': 'chunked' } }, res => {
      let body = ''; res.setEncoding('utf8'); res.on('data', d => { body += d; }); res.on('end', () => resolve({ status: res.statusCode, body, headers: res.headers }));
    });
    upload.req.on('error', reject);
  });
  upload.req.flushHeaders();
  upload.req.write(' ');
  return upload;
}
const turnsPath = async (ctx, token = TOKEN) => {
  const res = await ctx.call('POST', '/v1/sessions', {}, { authorization: `Bearer ${token}` });
  return `/v1/sessions/${(await res.json()).id}/turns`;
};
const waitFor = async (condition, what) => {
  for (let i = 0; i < 400; i++) { if (await condition()) return; await new Promise(resolve => setTimeout(resolve, 5)); }
  assert.fail(what);
};

test('Befund 3: Sperre während des Uploads kommt als 403 mit code beim Client an', async t => {
  const ctx = await serve(t);
  const path = await turnsPath(ctx);
  const upload = openUpload(ctx.api.address().port, path);
  await waitFor(() => ctx.uploads.active === 1, 'Upload läuft nicht');
  await ctx.accounts.update(USER, { status: 'pending' });
  upload.req.end(JSON.stringify(request()));
  const res = await upload.done;
  assert.equal(res.status, 403);
  assert.equal(JSON.parse(res.body).code, 'pending');
  assert.equal(ctx.instances.length, 0);
});

test('Befund 5: parallele Uploads sind je Konto und global gedeckelt', async t => {
  const ctx = await serve(t, { uploads: { perAccount: 2, global: 3 } });
  const { port } = ctx.api.address();
  const mine = await Promise.all([turnsPath(ctx), turnsPath(ctx), turnsPath(ctx)]);
  const other = await Promise.all([turnsPath(ctx, TOKEN_B), turnsPath(ctx, TOKEN_B)]);
  const open = [openUpload(port, mine[0]), openUpload(port, mine[1])];
  await waitFor(() => ctx.uploads.active === 2, 'Uploads laufen nicht');
  const third = await raw(port, { path: mine[2], headers: authHeaders(), chunks: [JSON.stringify(request())] });
  assert.equal(third.status, 429);
  assert.match(JSON.parse(third.body).error, /Upload/);
  assert.ok(Number(third.headers['retry-after']) > 0);
  open.push(openUpload(port, other[0], authHeaders(TOKEN_B)));
  await waitFor(() => ctx.uploads.active === 3, 'Upload läuft nicht');
  const global = await raw(port, { path: other[1], headers: authHeaders(TOKEN_B), chunks: [JSON.stringify(request())] });
  assert.equal(global.status, 429);
  for (const [index, upload] of open.entries()) {
    upload.req.end(JSON.stringify(request()));
    assert.equal((await upload.done).status, 202);
    await settled(ctx.store, (index === 2 ? other[0] : mine[index]).split('/')[3], index === 2 ? 'konto-b' : USER);
    await waitFor(() => ctx.hub.runs.size === 0, 'Lauf endet nicht');
  }
  assert.equal(ctx.uploads.active, 0);
});

test('Befund 5: abgebrochener Upload gibt seinen Platz frei', async t => {
  const ctx = await serve(t, { uploads: { perAccount: 1, global: 1 } });
  const path = await turnsPath(ctx);
  const upload = openUpload(ctx.api.address().port, path);
  upload.done.catch(() => {});
  await waitFor(() => ctx.uploads.active === 1, 'Upload läuft nicht');
  upload.req.destroy();
  await waitFor(() => ctx.uploads.active === 0, 'Platz bleibt belegt');
  const res = await raw(ctx.api.address().port, { path, headers: authHeaders(), chunks: [JSON.stringify(request())] });
  assert.equal(res.status, 202);
  await settled(ctx.store, path.split('/')[3]);
});

test('Befund 5: Fehlerfälle geben den Upload-Platz frei', async t => {
  const ctx = await serve(t, { uploads: { perAccount: 1, global: 1 } });
  const { port } = ctx.api.address();
  const path = await turnsPath(ctx);
  for (const [body, status] of [['{kaputt', 400], ['{"requestId":"x"}', 400]]) assert.equal((await raw(port, { path, headers: authHeaders(), chunks: [body] })).status, status);
  assert.equal(ctx.uploads.active, 0);
});

test('Befund 5: Standardgrenzen stehen im Code', async t => {
  const ctx = await serve(t);
  assert.deepEqual([ctx.uploads.perAccount, ctx.uploads.global], [2, 4]);
});

test('Befund 2: Flut über HTTP ergibt 429 mit Retry-After; X-Real-IP trennt Clients', async t => {
  const ctx = await serve(t, { auth: { maxClientLookups: 2 } });
  const flood = (ip, token) => ctx.call('GET', '/v1/me', undefined, { authorization: `Bearer ${token}`, 'x-real-ip': ip });
  for (const token of ['1', '2']) assert.equal((await flood('198.51.100.1', token.repeat(64))).status, 401);
  const res = await flood('198.51.100.1', '3'.repeat(64));
  assert.equal(res.status, 429);
  assert.ok(Number(res.headers.get('retry-after')) > 0);
  assert.equal((await flood('198.51.100.2', '4'.repeat(64))).status, 401);
  assert.equal((await ctx.call('GET', '/v1/me')).status, 200);
});

test('Befund 10: POST /v1/sessions bei voller Platte ist 503 und hinterlässt nichts', async t => {
  const ctx = await serve(t);
  const moved = `${ctx.store.sessionsDir}.weg`;
  await rename(ctx.store.sessionsDir, moved);
  const res = await ctx.call('POST', '/v1/sessions', {});
  assert.equal(res.status, 503);
  await rename(moved, ctx.store.sessionsDir);
  assert.deepEqual(await (await ctx.call('GET', '/v1/sessions')).json(), []);
  assert.equal((await ctx.call('POST', '/v1/sessions', {})).status, 201);
});

test('Befund 10: DELETE, das nicht löschen kann, ist 503 und lässt alles stehen', async t => {
  const ctx = await serve(t);
  const session = await (await ctx.call('POST', '/v1/sessions', {})).json();
  ctx.store.unlinkFile = async () => { throw Object.assign(new Error('EROFS'), { code: 'EROFS' }); };
  assert.equal((await ctx.call('DELETE', `/v1/sessions/${session.id}`)).status, 503);
  assert.equal((await ctx.call('GET', `/v1/sessions/${session.id}`)).status, 200);
  assert.equal((await (await ctx.call('GET', '/v1/sessions')).json()).length, 1);
});

test('Befund 10: neues Konto bei voller Platte ist 503, kein halbes Konto', async t => {
  const ctx = await serve(t, { activate: [] });
  const file = ctx.accounts.writer.file;
  ctx.accounts.writer.file = `${ctx.root}/fehlt/accounts.json`;
  assert.equal((await ctx.call('GET', '/v1/me')).status, 503);
  assert.deepEqual(ctx.accounts.list(), []);
  ctx.accounts.writer.file = file;
  assert.equal((await (await ctx.call('GET', '/v1/me')).json()).status, 'pending');
});

test('Befund 13: mimeType-Liste ergibt über HTTP 400', async t => {
  const ctx = await serve(t);
  const path = await turnsPath(ctx);
  const res = await ctx.call('POST', path, request('anfrage-0001', { images: [{ mimeType: ['image/png'], base64: PNG.toString('base64') }] }));
  assert.equal(res.status, 400);
});

/** Lädt den ganzen Körper hoch wie ein Client, der nicht auf die Antwort wartet, und liest danach. */
function fullUpload(port, head, body) {
  return new Promise((resolve, reject) => {
    const socket = connect(port, '127.0.0.1');
    let data = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => { data += chunk; if (data.includes('\r\n\r\n') && data.endsWith('}')) { socket.destroy(); resolve(data); } });
    socket.on('error', reject);
    socket.on('close', () => resolve(data));
    socket.write(head);
    socket.write(body);
  });
}

test('Befund 13: 413 kommt auch bei vollem Upload an, statt ECONNRESET', async t => {
  const ctx = await serve(t);
  const { port } = ctx.api.address();
  const path = await turnsPath(ctx);
  const head = size => `POST ${path} HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${TOKEN}\r\nContent-Type: application/json\r\nContent-Length: ${size}\r\n\r\n`;
  const answer = await fullUpload(port, head(MAX_BODY + 1), Buffer.alloc(MAX_BODY + 1, 0x20));
  assert.match(answer, /^HTTP\/1\.1 413 /);
  assert.match(answer, /zu groß/);
  const chunked = `POST ${path} HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${TOKEN}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n`;
  const chunk = Buffer.alloc(1024 * 1024, 0x20);
  const framed = Buffer.concat([...Array(30).fill(0).flatMap(() => [Buffer.from('100000\r\n'), chunk, Buffer.from('\r\n')]), Buffer.from('0\r\n\r\n')]);
  const second = await fullUpload(port, chunked, framed);
  assert.match(second, /^HTTP\/1\.1 413 /);
});

test('Befund 13: die Körpergrenze bleibt beim Nachlesen hart, nichts wird gepuffert', async t => {
  const ctx = await serve(t);
  const { port } = ctx.api.address();
  const path = await turnsPath(ctx);
  const before = process.memoryUsage().arrayBuffers;
  const head = `POST ${path} HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${TOKEN}\r\nContent-Type: application/json\r\nContent-Length: ${MAX_BODY * 100}\r\n\r\n`;
  const socket = connect(port, '127.0.0.1');
  let data = '';
  socket.on('error', () => {});
  socket.setEncoding('utf8');
  socket.on('data', chunk => { data += chunk; });
  const closed = new Promise(resolve => socket.on('close', resolve));
  socket.write(head);
  const chunk = Buffer.alloc(1024 * 1024, 0x20);
  // Endlos sendender Client: Nach der Nachlese-Grenze trennt der Server.
  const pump = () => { for (let i = 0; i < 8 && !socket.destroyed; i++) socket.write(chunk); if (!socket.destroyed) setImmediate(pump); };
  pump();
  await closed;
  assert.match(data, /^HTTP\/1\.1 413 /);
  assert.equal(ctx.store.get(path.split('/')[3], USER).messages.length, 0);
  assert.ok(process.memoryUsage().arrayBuffers - before < 512 * 1024 * 1024);
});

test('Gegenprüfung: Abbruch während der Kontoprüfung gibt den Upload-Platz frei', async t => {
  const ctx = await serve(t);
  const session = await (await ctx.call('POST', '/v1/sessions', {})).json();
  const original = ctx.auth.verify.bind(ctx.auth);
  let release;
  ctx.auth.verify = async (...args) => { await new Promise(resolve => { release = resolve; }); ctx.auth.verify = original; return original(...args); };
  const body = JSON.stringify(request('abbruch-1'));
  const socket = connect(ctx.api.address().port, '127.0.0.1');
  socket.write(`POST /v1/sessions/${session.id}/turns HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${TOKEN}\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body) + 100}\r\n\r\n${body}`);
  await until(() => release);
  socket.destroy();
  await new Promise(resolve => setTimeout(resolve, 30));
  release();
  await new Promise(resolve => setTimeout(resolve, 50));
  assert.equal(ctx.uploads.active, 0);
  assert.equal((await ctx.call('GET', '/v1/me')).status, 200);
});
