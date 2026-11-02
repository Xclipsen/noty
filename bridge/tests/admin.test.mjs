import test from 'node:test';
import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import { readFile } from 'node:fs/promises';
import { AdminSessions, CONTRACT_HEADERS, LoginThrottle, createAdmin, parseAdminOrigin } from '../server/admin.mjs';
import { SessionAuth } from '../server/auth.mjs';
import { createApi } from '../server/http.mjs';
import { emptyCounters } from '../server/metering.mjs';
import { TOKEN, USER, request, setup, until } from './helpers.mjs';
import { appSession, startAccountBackend } from './fake-account-backend.mjs';

const ORIGIN = 'https://noty.example.invalid';
const ADMIN = { id: 'konto-admin', name: 'Chefin' };
const CSP = "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
const PASSWORD = 'synthetisches-passwort';
const LOGINS = [{ ...ADMIN, email: 'chefin@example.invalid', password: PASSWORD }, { id: USER, name: 'Anna', password: 'anna-passwort' }];
const FAKE_COOKIE = `noty_ai_admin=${'f'.repeat(64)}`;

async function panel(t, { origin = ORIGIN, adminIds = [ADMIN.id], now, options = {}, ...rest } = {}) {
  const backend = await startAccountBackend(new Map([[TOKEN, { id: USER, name: 'Anna' }]]), { logins: LOGINS });
  t.after(() => backend.close());
  const ctx = await setup(t, { accounts: { adminIds }, ...rest });
  await ctx.accounts.seen(ADMIN);
  await ctx.accounts.seen({ id: USER, name: 'Anna' });
  await ctx.accounts.seen({ id: 'konto-c/d', name: 'Clara' });
  const admin = await createAdmin({ hub: ctx.hub, accounts: ctx.accounts, accountUrl: `${backend.url}/`, origin, now, logoutRetryMs: 5, ...options });
  const api = createApi({ hub: ctx.hub, accounts: ctx.accounts, auth: new SessionAuth({ accountUrl: backend.url }), admin });
  await new Promise(resolve => api.listen(0, '127.0.0.1', resolve));
  t.after(() => { api.close(); api.closeAllConnections(); });
  const base = `http://127.0.0.1:${api.address().port}`;
  const send = (method, pathname, { body, headers = {}, cookie, from = ORIGIN, type = 'application/json' } = {}) => fetch(base + pathname, {
    method, body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body),
    headers: { ...(method === 'GET' || from === null ? {} : { origin: from }), ...(method === 'GET' || type === null ? {} : { 'content-type': type }), ...(cookie ? { cookie } : {}), ...headers }
  });
  const login = (name, password, ip = '198.51.100.1') => send('POST', '/admin/api/login', { body: { name, password }, headers: { 'x-real-ip': ip } });
  const signIn = async () => {
    const res = await login(ADMIN.name, PASSWORD);
    assert.equal(res.status, 200);
    return res.headers.getSetCookie()[0].split(';')[0];
  };
  return { ...ctx, api, backend, base, send, login, signIn };
}

const rawGet = (port, path) => new Promise((resolve, reject) => {
  const req = httpRequest({ port, host: '127.0.0.1', method: 'GET', path }, res => {
    let body = ''; res.setEncoding('utf8'); res.on('data', d => { body += d; }); res.on('end', () => resolve({ status: res.statusCode, body }));
  });
  req.on('error', reject); req.end();
});

function assertContractHeaders(res, label) {
  assert.equal(res.headers.get('content-security-policy'), CSP, label);
  assert.match(res.headers.get('strict-transport-security'), /^max-age=\d{8,}/, label);
  assert.equal(res.headers.get('referrer-policy'), 'no-referrer', label);
  assert.equal(res.headers.get('x-frame-options'), 'DENY', label);
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff', label);
  assert.equal(res.headers.get('cache-control'), 'no-store', label);
}

test('Anmeldung: Admin kommt rein, Backend-Sitzung wird sofort beendet, nichts wird durchgereicht', async t => {
  const ctx = await panel(t);
  const res = await ctx.login(ADMIN.name, PASSWORD);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true });
  const cookies = res.headers.getSetCookie();
  assert.equal(cookies.length, 1);
  assert.ok(!cookies[0].includes('law_session'));
  assert.deepEqual(ctx.backend.loginBodies, [{ name: ADMIN.name, password: PASSWORD }]);
  await until(() => ctx.backend.logoutCalls === 1);
  await until(() => ctx.backend.sessions.size === 0);
  const overview = await ctx.send('GET', '/admin/api/overview', { cookie: cookies[0].split(';')[0] });
  assert.equal(overview.status, 200);
});

test('Anmeldung per E-Mail geht als email ans Backend, wie in der App', async t => {
  const ctx = await panel(t);
  assert.equal((await ctx.login('  chefin@example.invalid ', PASSWORD)).status, 200);
  assert.deepEqual(ctx.backend.loginBodies, [{ email: 'chefin@example.invalid', password: PASSWORD }]);
});

test('Falsches Passwort und Nicht-Admin ergeben dieselbe Antwort, kein Cookie, keine verwaiste Sitzung', async t => {
  const ctx = await panel(t);
  const wrong = await ctx.login(ADMIN.name, 'falsch', '198.51.100.2');
  const stranger = await ctx.login('Anna', 'anna-passwort', '198.51.100.3');
  assert.deepEqual([wrong.status, stranger.status], [401, 401]);
  const [a, b] = [await wrong.json(), await stranger.json()];
  assert.deepEqual(a, b);
  assert.deepEqual(a, { error: 'Name oder Passwort stimmt nicht.' });
  assert.deepEqual([wrong.headers.getSetCookie(), stranger.headers.getSetCookie()], [[], []]);
  await until(() => ctx.backend.logoutCalls === 1);
  assert.equal(ctx.backend.sessions.size, 0);
  assert.equal((await ctx.send('GET', '/admin/api/overview', { cookie: stranger.headers.get('set-cookie') ?? FAKE_COOKIE })).status, 401);
});

test('Unvollständige Eingaben gehen nicht ans Backend und kosten keinen Versuch', async t => {
  const ctx = await panel(t);
  for (const body of [{}, { name: 'x' }, { password: 'x' }, { name: 1, password: 'x' }, { name: 'x', password: 1 }, { name: ' ', password: 'x' }, { name: 'n'.repeat(255), password: 'x' }, { name: 'x', password: 'p'.repeat(1025) }]) {
    assert.equal((await ctx.send('POST', '/admin/api/login', { body })).status, 400);
  }
  assert.equal((await ctx.send('POST', '/admin/api/login', { body: '{kaputt' })).status, 400);
  assert.equal(ctx.backend.loginBodies.length, 0);
  assert.equal((await ctx.login(ADMIN.name, PASSWORD)).status, 200);
});

test('Sperre: 5 Fehlversuche je IP in 15 Minuten, auch das richtige Passwort, andere IP bleibt frei', async t => {
  let now = Date.parse('2026-03-01T12:00:00Z');
  const ctx = await panel(t, { now: () => now });
  for (let i = 0; i < 5; i++) assert.equal((await ctx.login(ADMIN.name, `falsch-${i}`)).status, 401);
  assert.equal(ctx.backend.loginBodies.length, 5);
  const locked = await ctx.login(ADMIN.name, PASSWORD);
  assert.equal(locked.status, 429);
  assert.match((await locked.json()).error, /Zu viele/);
  assert.equal(ctx.backend.loginBodies.length, 5);
  assert.equal((await ctx.login(ADMIN.name, PASSWORD, '198.51.100.9')).status, 200);
  now += 15 * 60_000 - 1;
  assert.equal((await ctx.login(ADMIN.name, PASSWORD)).status, 429);
  now += 1;
  assert.equal((await ctx.login(ADMIN.name, PASSWORD)).status, 200);
});

test('Sperre: Nicht-Admin mit richtigem Passwort zählt als Fehlversuch', async t => {
  const ctx = await panel(t);
  for (let i = 0; i < 5; i++) assert.equal((await ctx.login('Anna', 'anna-passwort')).status, 401);
  assert.equal((await ctx.login('Anna', 'anna-passwort')).status, 429);
});

test('Sperre gilt auch für gleichzeitige Anfragen: höchstens 5 erreichen das Backend', async t => {
  const ctx = await panel(t);
  const results = await Promise.all(Array.from({ length: 30 }, (_, i) => ctx.login(ADMIN.name, `falsch-${i}`)));
  assert.equal(results.filter(res => res.status === 401).length, 5);
  assert.equal(results.filter(res => res.status === 429).length, 25);
  assert.equal(ctx.backend.loginBodies.length, 5);
});

test('Sperre global: wechselnde oder unbrauchbare X-Real-IP raten nicht unbegrenzt', async t => {
  const ctx = await panel(t);
  for (let i = 0; i < 20; i++) assert.equal((await ctx.login(ADMIN.name, 'falsch', `203.0.113.${i + 1}`)).status, 401);
  assert.equal((await ctx.login(ADMIN.name, PASSWORD, '192.0.2.77')).status, 429);
  assert.equal(ctx.backend.loginBodies.length, 20);

  const junk = await panel(t);
  for (let i = 0; i < 5; i++) assert.equal((await junk.login(ADMIN.name, 'falsch', `kein-ip-${i}`)).status, 401);
  assert.equal((await junk.login(ADMIN.name, 'falsch', 'noch-was-anderes')).status, 429);
});

test('Sperrzähler bleiben im Speicher begrenzt', () => {
  let now = 1000;
  const throttle = new LoginThrottle({ perIp: 2, global: 1e6, maxIps: 10, windowMs: 100, now: () => now });
  for (let i = 0; i < 500; i++) { assert.ok(throttle.acquire(`ip-${i}`)); now++; }
  assert.ok(throttle.ips.size <= 10);
  const limited = new LoginThrottle({ perIp: 1, global: 2, now: () => now });
  const release = limited.acquire('a');
  assert.equal(limited.acquire('a'), null);
  release();
  assert.ok(limited.acquire('a'));
  assert.ok(limited.acquire('b'));
  assert.equal(limited.acquire('c'), null);
  assert.equal(limited.ips.has('c'), false);
});

test('Backend-Ausfälle kosten keinen Versuch und öffnen nichts', async t => {
  const ctx = await panel(t);
  for (const [status, expected] of [[500, 503], [403, 503], [429, 429], [503, 503]]) {
    ctx.backend.loginStatus = status;
    for (let i = 0; i < 6; i++) {
      const res = await ctx.login(ADMIN.name, PASSWORD);
      assert.equal(res.status, expected, `Status ${status}`);
      assert.deepEqual(res.headers.getSetCookie(), []);
    }
  }
  ctx.backend.loginStatus = null;
  assert.equal((await ctx.login(ADMIN.name, PASSWORD)).status, 200);

  for (const fetcher of [
    async () => { throw new Error('Verbindung abgelehnt'); },
    async () => new Response('kein json', { status: 200 }),
    async () => new Response(JSON.stringify({ user: { id: ADMIN.id, name: ADMIN.name } }), { status: 200 }), // ohne Token nicht abmeldbar
    async () => new Response(JSON.stringify({ user: { token: 'a'.repeat(64) } }), { status: 200 })
  ]) {
    const down = await panel(t, { options: { fetcher } });
    assert.equal((await down.login(ADMIN.name, PASSWORD)).status, 503);
  }
});

test('Scheitert das Abmelden im Backend, wird es wiederholt', async t => {
  const ctx = await panel(t);
  ctx.backend.logoutFailures = 2;
  assert.equal((await ctx.login(ADMIN.name, PASSWORD)).status, 200);
  await until(() => ctx.backend.logoutCalls === 3);
  await until(() => ctx.backend.sessions.size === 0);
});

test('Sitzungsgrenze des Backends: Logins lassen die Zahl nicht wachsen; bei 10 Sitzungen fällt genau die älteste', async t => {
  const ctx = await panel(t);
  const app = appSession(ctx.backend, ADMIN);
  for (let i = 0; i < 12; i++) {
    assert.equal((await ctx.login(ADMIN.name, PASSWORD, `198.51.100.${i + 20}`)).status, 200);
    await until(() => ctx.backend.sessions.size === 1);
  }
  assert.ok(ctx.backend.sessions.has(app), 'App-Sitzung übersteht beliebig viele Admin-Logins');

  const full = await panel(t);
  const tokens = Array.from({ length: 10 }, () => appSession(full.backend, ADMIN));
  assert.equal((await full.login(ADMIN.name, PASSWORD)).status, 200);
  await until(() => full.backend.sessions.size === 9);
  assert.equal(full.backend.sessions.has(tokens[0]), false, 'Das Backend kürzt schon beim Login, also vor dem Abmelden');
  assert.ok(tokens.slice(1).every(token => full.backend.sessions.has(token)));
  assert.equal((await full.login(ADMIN.name, PASSWORD)).status, 200);
  await until(() => full.backend.logoutCalls === 2);
  assert.ok(tokens.slice(1).every(token => full.backend.sessions.has(token)), 'Danach verdrängt kein weiterer Login etwas');
});

test('Cookie: alle Attribute nach Vertrag, 8 Stunden, Abmelden löscht es', async t => {
  const ctx = await panel(t);
  const res = await ctx.login(ADMIN.name, PASSWORD);
  const [cookie] = res.headers.getSetCookie();
  assert.match(cookie, /^noty_ai_admin=[a-f0-9]{64}; /);
  const attributes = cookie.split('; ').slice(1).sort();
  assert.deepEqual(attributes, ['HttpOnly', 'Max-Age=28800', 'Path=/admin', 'SameSite=Strict', 'Secure']);
  const out = await ctx.send('POST', '/admin/api/logout', { cookie: cookie.split(';')[0] });
  assert.equal(out.status, 204);
  assert.deepEqual(out.headers.getSetCookie()[0].split('; ').slice(1).sort(), ['HttpOnly', 'Max-Age=0', 'Path=/admin', 'SameSite=Strict', 'Secure']);
});

test('Sitzung läuft nach 8 Stunden ab, Abmelden wirkt sofort, Abmelden ohne Cookie ist harmlos', async t => {
  let now = Date.parse('2026-03-01T12:00:00Z');
  const ctx = await panel(t, { now: () => now });
  const cookie = await ctx.signIn();
  now += 8 * 3600_000 - 1;
  assert.equal((await ctx.send('GET', '/admin/api/overview', { cookie })).status, 200);
  now += 1;
  assert.equal((await ctx.send('GET', '/admin/api/overview', { cookie })).status, 401);

  const again = await ctx.signIn();
  assert.equal((await ctx.send('POST', '/admin/api/logout', { cookie: again })).status, 204);
  assert.equal((await ctx.send('GET', '/admin/api/overview', { cookie: again })).status, 401);
  assert.equal((await ctx.send('POST', '/admin/api/logout')).status, 204);
  assert.equal((await ctx.send('POST', '/admin/api/logout', { body: {} })).status, 204);
  const big = await ctx.send('POST', '/admin/api/logout', { body: { x: 'y'.repeat(1000) } });
  assert.equal(big.status, 413);
});

test('Sitzungsspeicher: nur Hashes, höchstens 20, die älteste fällt zuerst', () => {
  let now = 0;
  const sessions = new AdminSessions({ now: () => now });
  const tokens = Array.from({ length: 21 }, (_, i) => sessions.create(`konto-${i}`));
  assert.equal(sessions.entries.size, 20);
  assert.equal(sessions.valid(tokens[0]), false);
  assert.equal(sessions.valid(tokens[20]), true);
  for (const token of tokens) assert.ok(!sessions.entries.has(token) && !JSON.stringify([...sessions.entries]).includes(token));
  for (const bad of [null, undefined, '', 'x', 'A'.repeat(64), 42]) assert.equal(sessions.valid(bad), false);
  now = 8 * 3600_000;
  assert.equal(sessions.valid(tokens[20]), false);
  assert.equal(sessions.entries.has(tokens[20]), false);
  sessions.create('neu');
  assert.equal(sessions.entries.size, 1);
});

test('Schreibende Anfragen: Origin exakt, sonst 403 ohne Wirkung', async t => {
  const ctx = await panel(t);
  const cookie = await ctx.signIn();
  const count = ctx.backend.loginBodies.length;
  for (const from of [null, 'null', 'https://boese.example.invalid', 'http://noty.example.invalid', `${ORIGIN}/`, `${ORIGIN}:8443`, ORIGIN.toUpperCase(), `${ORIGIN}.boese.example.invalid`]) {
    for (const [method, pathname, body] of [['POST', '/admin/api/login', { name: ADMIN.name, password: PASSWORD }], ['POST', '/admin/api/logout', {}], ['PATCH', `/admin/api/users/${USER}`, { status: 'active' }]]) {
      const res = await ctx.send(method, pathname, { body, cookie, from });
      assert.equal(res.status, 403, `${method} ${pathname} ${from}`);
      assert.match((await res.json()).error, /Herkunft/);
    }
  }
  assert.equal(ctx.backend.loginBodies.length, count);
  assert.equal(ctx.accounts.get(USER).status, 'pending');
  assert.equal((await ctx.send('GET', '/admin/api/overview', { cookie })).status, 200, 'Abmelden wurde nicht ausgeführt');
});

test('Schreibende Anfragen verlangen application/json', async t => {
  const ctx = await panel(t);
  const cookie = await ctx.signIn();
  for (const type of [null, 'text/plain', 'application/x-www-form-urlencoded', 'multipart/form-data; boundary=x', 'application/json-patch+json', 'application/jsonx']) {
    for (const [method, pathname] of [['POST', '/admin/api/login'], ['POST', '/admin/api/logout'], ['PATCH', `/admin/api/users/${USER}`]]) {
      assert.equal((await ctx.send(method, pathname, { body: '{"status":"active"}', cookie, type })).status, 415, `${pathname} ${type}`);
    }
  }
  assert.equal((await ctx.send('PATCH', `/admin/api/users/${USER}`, { body: { status: 'active' }, cookie, type: 'Application/JSON; charset=utf-8' })).status, 200);
});

test('Vertrags-Header und no-store auf jeder Antwort, auch bei Fehlern', async t => {
  const ctx = await panel(t);
  const cookie = await ctx.signIn();
  assert.deepEqual(CONTRACT_HEADERS['Content-Security-Policy'], CSP);
  const cases = [
    await ctx.send('GET', '/admin'), await ctx.send('GET', '/admin/app.js'), await ctx.send('GET', '/admin/app.css'),
    await ctx.send('GET', '/admin/api/overview'), await ctx.send('GET', '/admin/api/overview', { cookie }), await ctx.send('GET', '/admin/fehlt'),
    await ctx.send('POST', '/admin'), await ctx.send('POST', '/admin/api/login', { from: 'https://x.example.invalid' }),
    await ctx.send('POST', '/admin/api/login', { body: { name: 'x'.repeat(5000), password: 'y' } }),
    await ctx.login(ADMIN.name, 'falsch'), await ctx.login(ADMIN.name, PASSWORD), await ctx.send('POST', '/admin/api/logout', { cookie })
  ];
  for (const res of cases) assertContractHeaders(res, `${res.url} ${res.status}`);
  assert.deepEqual(cases.map(res => res.status), [200, 200, 200, 401, 200, 404, 405, 403, 413, 401, 200, 204]);
  assert.equal(cases[6].headers.get('allow'), 'GET');
});

test('Statische Dateien: richtige Typen, keine externen Ressourcen, keine Inline-Skripte oder -Styles', async t => {
  const ctx = await panel(t);
  const types = { '/admin': 'text/html', '/admin/app.js': 'text/javascript', '/admin/app.css': 'text/css' };
  for (const [pathname, type] of Object.entries(types)) assert.ok((await ctx.send('GET', pathname)).headers.get('content-type').startsWith(type));
  const html = await (await ctx.send('GET', '/admin')).text();
  const js = await (await ctx.send('GET', '/admin/app.js')).text();
  const css = await (await ctx.send('GET', '/admin/app.css')).text();
  assert.ok(!/\sstyle\s*=/i.test(html), 'style-Attribut');
  assert.ok(!/<style/i.test(html), 'style-Element');
  assert.ok(!/\son[a-z]+\s*=/i.test(html), 'Inline-Handler');
  assert.deepEqual([...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)].map(m => [m[1].trim(), m[2].trim()]), [['src="/admin/app.js" defer', '']]);
  assert.ok(!/https?:\/\/|\/\/[a-z]/i.test(html + css), 'externe Ressource');
  assert.ok(!/url\(/i.test(css));
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\b|new Function|setAttribute\('style'|\.style\b/.test(js), 'unsichere DOM-API');
  assert.ok(!/https?:\/\//.test(js), 'externe Adresse');
  assert.ok(!/localStorage|sessionStorage/.test(js), 'kein clientseitiger Speicher');
});

test('Pfad-Traversal: nur die drei festen Dateien, nichts aus server/', async t => {
  const ctx = await panel(t);
  const port = ctx.api.address().port;
  for (const path of ['/admin/../server/main.mjs', '/admin/..%2fserver%2fmain.mjs', '/admin/%2e%2e/server/admin.mjs', '/admin/%2e%2e%2fpackage.json', '/admin/..%5cserver%5cmain.mjs', '/admin/app.js/../../server/hub.mjs', '/admin/app.js%2f..%2f..%2fserver%2fhub.mjs', '/admin/index.html', '/admin/app.js%00.html', '/admin//app.js', '/admin/./../admin.mjs', '/admin/admin.mjs', '/admin/']) {
    const res = await rawGet(port, path);
    assert.equal(res.status, 404, path);
    assert.ok(!/import |createAdmin/.test(res.body), path);
  }
});

test('Fehlt NOTY_AI_ADMIN_ORIGIN oder ist er ungültig, lehnt /admin alles ab; /v1 läuft weiter', async t => {
  for (const origin of [undefined, '', 'kaputt', 'http://noty.example.invalid', `${ORIGIN}/`, `${ORIGIN}/admin`]) {
    const ctx = await panel(t, { options: { origin } });
    for (const [method, pathname] of [['GET', '/admin'], ['GET', '/admin/app.js'], ['GET', '/admin/api/overview'], ['POST', '/admin/api/login']]) {
      const res = await ctx.send(method, pathname, { body: method === 'POST' ? { name: ADMIN.name, password: PASSWORD } : undefined, from: origin || ORIGIN });
      assert.equal(res.status, 503, `${method} ${pathname} ${origin}`);
      assertContractHeaders(res, pathname);
      assert.match((await res.json()).error, /nicht eingerichtet/);
    }
    assert.equal(ctx.backend.loginBodies.length, 0);
    assert.equal((await ctx.send('GET', '/v1/me', { headers: { authorization: `Bearer ${TOKEN}` } })).status, 200);
  }
  const noAdmins = await panel(t, { adminIds: [] });
  assert.equal((await noAdmins.login(ADMIN.name, PASSWORD)).status, 503);
  assert.equal(noAdmins.backend.loginBodies.length, 0);
});

test('Ursprung: nur nackter https-Ursprung, http nur lokal', () => {
  for (const good of ['https://noty.xclipsen.de', 'https://noty.example.invalid:8443', 'http://localhost:9000', 'http://127.0.0.1:9000']) assert.equal(parseAdminOrigin(good), good);
  for (const bad of [undefined, null, '', ' ', 'noty.xclipsen.de', 'http://noty.xclipsen.de', 'https://noty.xclipsen.de/', 'https://noty.xclipsen.de/admin', 'https://a@noty.xclipsen.de', 'https://NOTY.xclipsen.de']) assert.equal(parseAdminOrigin(bad), null, String(bad));
});

test('Übersicht: Vertragsform, nur Konten und Zähler, keine Chatinhalte, keine Anmeldedaten', async t => {
  const ctx = await panel(t);
  const cookie = await ctx.signIn();
  const session = await ctx.store.create({ userId: USER, title: 'TITEL-MARKER' });
  await ctx.accounts.update(USER, { status: 'active' });
  await ctx.hub.turn(USER, session.id, request('anfrage-0001', { text: 'FRAGE-MARKER', context: { label: 'KONTEXT-MARKER', text: 'HEFT-MARKER' } }));
  await until(() => ctx.hub.runs.size === 0);
  const res = await ctx.send('GET', '/admin/api/overview', { cookie });
  assert.equal(res.status, 200);
  const raw = await res.text();
  for (const marker of ['MARKER', 'Antwort', 'privat@', 'privates-konto', PASSWORD, cookie.split('=')[1]]) assert.ok(!raw.includes(marker), marker);
  const overview = JSON.parse(raw);
  assert.deepEqual(Object.keys(overview).sort(), ['account', 'plan', 'running', 'today', 'users']);
  assert.equal(overview.account, 'chatgpt');
  assert.equal(overview.running, 0);
  assert.deepEqual(Object.keys(overview.today), Object.keys(emptyCounters()));
  assert.equal(overview.plan.limits[0].windows[0].resetsAt, 1900000000);
  const anna = overview.users.find(user => user.id === USER);
  assert.deepEqual(Object.keys(anna).sort(), ['dailyLimit', 'effectiveDailyLimit', 'id', 'last30', 'last7', 'lastSeenAt', 'name', 'role', 'status', 'today', 'total']);
  assert.deepEqual([anna.status, anna.role, anna.today.turns, anna.total.turns], ['active', 'user', 1, 1]);
  assert.equal(overview.users.find(user => user.id === ADMIN.id).role, 'admin');
});

test('Übersicht ohne Codex: account und plan sind null, Konten bleiben sichtbar', async t => {
  const ctx = await panel(t, { rpc: { failStart: true } });
  const cookie = await ctx.signIn();
  const overview = await (await ctx.send('GET', '/admin/api/overview', { cookie })).json();
  assert.deepEqual([overview.account, overview.plan, overview.users.length], [null, null, 3]);
});

test('PATCH: Freischalten, Sperren, Limit, Standard; Antwort ist das Konto', async t => {
  const ctx = await panel(t, { accounts: { adminIds: [ADMIN.id], defaultDailyLimit: 7 } });
  const cookie = await ctx.signIn();
  const patch = async (id, body) => { const res = await ctx.send('PATCH', `/admin/api/users/${encodeURIComponent(id)}`, { body, cookie }); return [res.status, await res.json()]; };
  const [status, active] = await patch(USER, { status: 'active' });
  assert.equal(status, 200);
  assert.deepEqual([active.id, active.status, active.role, active.dailyLimit, active.effectiveDailyLimit], [USER, 'active', 'user', null, 7]);
  assert.equal((await patch(USER, { dailyLimit: 3 }))[1].effectiveDailyLimit, 3);
  assert.equal((await patch(USER, { dailyLimit: null }))[1].effectiveDailyLimit, 7);
  assert.deepEqual((await patch(USER, { status: 'blocked', dailyLimit: 2 })).map(v => v.status ?? v), [200, 'blocked']);
  assert.equal(ctx.accounts.get(USER).dailyLimit, 2);
  assert.equal((await patch('konto-c/d', { status: 'active' }))[0], 200, 'Kennung mit Schrägstrich');
  assert.equal((await patch(ADMIN.id, { dailyLimit: 9 }))[0], 200);
  assert.equal((await patch(ADMIN.id, { status: 'active' }))[0], 200);
});

test('PATCH: alle Fehlerfälle', async t => {
  const ctx = await panel(t);
  const cookie = await ctx.signIn();
  const patch = (pathname, body, extra = {}) => ctx.send('PATCH', pathname, { body, cookie, ...extra });
  const user = `/admin/api/users/${USER}`;
  for (const body of [{}, { name: 'Hack' }, { role: 'admin' }, { status: 'active', role: 'admin' }, { status: 'aktiv' }, { status: null }, { status: 1 }, { dailyLimit: -1 }, { dailyLimit: 1.5 }, { dailyLimit: '3' }, { dailyLimit: 1_000_001 }, '[]', 'null', '{kaputt', '']) {
    const res = await patch(user, body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.ok((await res.json()).error);
  }
  assert.equal((await patch('/admin/api/users/%E0%A4%A', { status: 'active' })).status, 400);
  assert.equal((await patch('/admin/api/users/unbekannt', { status: 'active' })).status, 404);
  const blocked = await patch(`/admin/api/users/${ADMIN.id}`, { status: 'blocked' });
  assert.equal(blocked.status, 409);
  assert.match((await blocked.json()).error, /Admins/);
  assert.equal((await patch(`/admin/api/users/${ADMIN.id}`, { status: 'pending' })).status, 409);
  assert.equal((await patch(user, { status: 'active', note: 'x'.repeat(500) })).status, 413);
  assert.equal((await patch('/admin/api/users', { status: 'active' })).status, 404);
  assert.equal((await patch(`${user}/mehr`, { status: 'active' })).status, 404);
  for (const method of ['GET', 'PUT', 'DELETE', 'POST']) {
    const res = await ctx.send(method, user, { body: method === 'GET' ? undefined : {}, cookie });
    assert.equal(res.status, 405, method);
    assert.equal(res.headers.get('allow'), 'PATCH');
  }
  ctx.accounts.writer.save = () => Promise.reject(new Error('voll'));
  assert.equal((await patch(user, { status: 'active' })).status, 503);
  assert.equal(ctx.accounts.get(USER).status, 'pending');
});

test('Ohne gültiges Cookie gibt es keine Daten und keine Änderung', async t => {
  const ctx = await panel(t);
  const cookie = await ctx.signIn();
  for (const headers of [{}, { cookie: FAKE_COOKIE }, { cookie: 'noty_ai_admin=' }, { cookie: 'noty_ai_admin=kurz' }, { cookie: `andere=${cookie.split('=')[1]}` }]) {
    const overview = await ctx.send('GET', '/admin/api/overview', { headers });
    assert.equal(overview.status, 401);
    assert.deepEqual(Object.keys(await overview.json()), ['error']);
    assert.equal((await ctx.send('PATCH', `/admin/api/users/${USER}`, { body: { status: 'active' }, headers })).status, 401);
  }
  assert.equal(ctx.accounts.get(USER).status, 'pending');
  const page = await (await ctx.send('GET', '/admin')).text();
  assert.ok(!/Anna|Clara|konto-/.test(page));
});

test('Ein Bearer-Token der App öffnet /admin/api nicht, auch nicht von Admins', async t => {
  const ctx = await panel(t);
  const appToken = appSession(ctx.backend, ADMIN);
  for (const token of [TOKEN, appToken]) {
    const headers = { authorization: `Bearer ${token}` };
    assert.equal((await ctx.send('GET', '/admin/api/overview', { headers })).status, 401);
    assert.equal((await ctx.send('PATCH', `/admin/api/users/${USER}`, { body: { status: 'active' }, headers })).status, 401);
    assert.equal((await ctx.send('GET', '/admin/api/overview', { headers: { cookie: `noty_ai_admin=${token}` } })).status, 401);
  }
});

test('/v1 akzeptiert das Admin-Cookie nicht, weder als Cookie noch als Bearer', async t => {
  const ctx = await panel(t);
  const cookie = await ctx.signIn();
  assert.equal((await ctx.send('GET', '/admin/api/overview', { cookie })).status, 200);
  for (const pathname of ['/v1/me', '/v1/info', '/v1/usage', '/v1/sessions']) {
    assert.equal((await ctx.send('GET', pathname, { cookie })).status, 401, pathname);
    assert.equal((await ctx.send('GET', pathname, { headers: { authorization: `Bearer ${cookie.split('=')[1]}` } })).status, 401, pathname);
  }
});

for (const [label, patch] of [['Sperren', { status: 'blocked' }], ['Limit 0', { dailyLimit: 0 }]]) {
  test(`${label} bricht den laufenden Lauf sofort ab, fremde Läufe bleiben`, async t => {
    const ctx = await panel(t, { rpc: { onTurn: () => {} }, hub: { cancelGraceMs: 60_000 } });
    const cookie = await ctx.signIn();
    await ctx.accounts.update(USER, { status: 'active' });
    await ctx.accounts.update('konto-c/d', { status: 'active' });
    const mine = await ctx.store.create({ userId: USER });
    const other = await ctx.store.create({ userId: 'konto-c/d' });
    await ctx.hub.turn(USER, mine.id, request('anfrage-0001'));
    await ctx.hub.turn('konto-c/d', other.id, request('anfrage-0002'));
    await until(() => ctx.instances.filter(rpc => rpc.calls.some(call => call.method === 'turn/start')).length === 2);
    assert.equal((await (await ctx.send('GET', '/admin/api/overview', { cookie })).json()).running, 2);
    const res = await ctx.send('PATCH', `/admin/api/users/${USER}`, { body: patch, cookie });
    assert.equal(res.status, 200);
    // Schon mit der Antwort steht der Lauf; kein Warten auf turn/interrupt oder die Karenzzeit.
    assert.equal(ctx.store.get(mine.id, USER).status, 'interrupted');
    assert.equal(ctx.hub.runs.has(mine.id), false);
    assert.equal(ctx.hub.runs.has(other.id), true);
    const turns = ctx.instances.filter(rpc => rpc.calls.some(call => call.method === 'turn/start'));
    assert.deepEqual(turns.map(rpc => rpc.closed).sort(), [false, true]);
    assert.ok(!turns.some(rpc => rpc.calls.some(call => call.method === 'turn/interrupt')));
    assert.equal(ctx.store.get(other.id, 'konto-c/d').status, 'running');
    assert.equal((await (await ctx.send('GET', '/admin/api/overview', { cookie })).json()).running, 1);
  });
}

test('Andere Änderungen lassen Läufe weiterlaufen; scheitert das Speichern, läuft der Lauf auch weiter', async t => {
  const ctx = await panel(t, { rpc: { onTurn: () => {} } });
  const cookie = await ctx.signIn();
  await ctx.accounts.update(USER, { status: 'active' });
  const session = await ctx.store.create({ userId: USER });
  await ctx.hub.turn(USER, session.id, request());
  await until(() => ctx.instances.at(-1)?.calls.some(call => call.method === 'turn/start'));
  assert.equal((await ctx.send('PATCH', `/admin/api/users/${USER}`, { body: { dailyLimit: 5 }, cookie })).status, 200);
  assert.equal((await ctx.send('PATCH', `/admin/api/users/${USER}`, { body: { status: 'active' }, cookie })).status, 200);
  assert.equal(ctx.hub.runs.has(session.id), true);
  ctx.accounts.writer.save = () => Promise.reject(new Error('voll'));
  assert.equal((await ctx.send('PATCH', `/admin/api/users/${USER}`, { body: { status: 'blocked' }, cookie })).status, 503);
  assert.equal(ctx.hub.runs.has(session.id), true);
});

test('Server-Code: Admin-Teil schreibt nichts in Dateien oder Logs', async () => {
  const source = await readFile(new URL('../server/admin.mjs', import.meta.url), 'utf8');
  assert.ok(!/console\.|writeFile|appendFile|createWriteStream/.test(source));
});
