import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { assertNotRoot, boot } from '../server/main.mjs';
import { tempDir, TOKEN, TOKEN_B } from './helpers.mjs';
import { startAccountBackend } from './fake-account-backend.mjs';

const env = async (t, extra = {}) => {
  const root = await tempDir(t);
  return { STATE_DIR: path.join(root, 'state'), CODEX_HOME: root, NOTY_AI_ACCOUNT_URL: 'http://127.0.0.1:9', CODEX_BIN: '/bin/false', PORT: '0', ADMIN_PORT: '0', ...extra };
};

test('Dienst lehnt root ab', () => {
  assert.throws(() => assertNotRoot(0), /unprivilegierten/);
  assert.doesNotThrow(() => assertNotRoot(1000));
  if (process.getuid() !== 0) return;
  const run = spawnSync(process.execPath, [new URL('../server/main.mjs', import.meta.url).pathname], { env: {}, encoding: 'utf8' });
  assert.equal(run.status, 1);
  assert.match(run.stderr, /unprivilegierten/);
});

test('lauscht nur auf 127.0.0.1; Backend aus ergibt 503, nie Zugriff', async t => {
  const { api, close, address } = await boot(await env(t));
  t.after(close);
  assert.equal(address.address, '127.0.0.1');
  assert.equal(api.listening, true);
  const res = await fetch(`http://127.0.0.1:${address.port}/v1/sessions`, { headers: { authorization: `Bearer ${TOKEN}` } });
  assert.equal(res.status, 503);
});

test('End-to-End mit Konto-Backend über HTTP: pending, Admin aus NOTY_AI_ADMIN_IDS', async t => {
  const backend = await startAccountBackend(new Map([[TOKEN, { id: 'konto-admin', name: 'Admin' }], [TOKEN_B, { id: 'konto-neu', name: 'Neu' }]]));
  t.after(() => backend.close());
  const { close, address } = await boot(await env(t, { NOTY_AI_ACCOUNT_URL: backend.url, NOTY_AI_ADMIN_IDS: ' konto-x , konto-admin ' }));
  t.after(close);
  const call = (pathname, token) => fetch(`http://127.0.0.1:${address.port}${pathname}`, { headers: { authorization: `Bearer ${token}` } });
  const me = await (await call('/v1/me', TOKEN)).json();
  assert.deepEqual([me.user, me.status, me.role, me.dailyLimit], [{ id: 'konto-admin', name: 'Admin' }, 'active', 'admin', 200]);
  assert.equal((await call('/v1/sessions', TOKEN)).status, 200);
  assert.equal((await (await call('/v1/me', TOKEN_B)).json()).status, 'pending');
  assert.equal((await call('/v1/sessions', TOKEN_B)).status, 403);
  assert.equal((await call('/v1/me', 'c'.repeat(64))).status, 401);
  assert.equal(backend.seen.at(-1), 'Bearer ' + 'c'.repeat(64));
});

test('Standard-Boot hängt /admin wirklich ein: Seite, Anmeldung, Übersicht', async t => {
  const backend = await startAccountBackend(new Map(), { logins: [{ id: 'konto-admin', name: 'Chefin', password: 'synthetisch' }] });
  t.after(() => backend.close());
  const origin = 'https://noty.example.invalid';
  const { close, adminAddress } = await boot(await env(t, { NOTY_AI_ACCOUNT_URL: backend.url, NOTY_AI_ADMIN_IDS: 'konto-admin', NOTY_AI_ADMIN_ORIGIN: origin }));
  t.after(close);
  const base = `http://127.0.0.1:${adminAddress.port}`;
  const page = await fetch(`${base}/admin`);
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-security-policy'), /^default-src 'none'/);
  assert.match(await page.text(), /noty KI/);
  assert.equal((await fetch(`${base}/admin/app.js`)).status, 200);
  assert.equal((await fetch(`${base}/admin/api/overview`)).status, 401);
  const login = await fetch(`${base}/admin/api/login`, { method: 'POST', headers: { 'content-type': 'application/json', origin }, body: JSON.stringify({ name: 'Chefin', password: 'synthetisch' }) });
  assert.equal(login.status, 200);
  const overview = await fetch(`${base}/admin/api/overview`, { headers: { cookie: login.headers.getSetCookie()[0].split(';')[0] } });
  assert.equal(overview.status, 200);
  assert.deepEqual(Object.keys(await overview.json()).sort(), ['account', 'plan', 'running', 'today', 'users']);
});

test('Standard-Boot ohne NOTY_AI_ADMIN_ORIGIN: /admin lehnt ab, /v1 läuft', async t => {
  const backend = await startAccountBackend(new Map([[TOKEN, { id: 'konto-admin', name: 'Chefin' }]]));
  t.after(() => backend.close());
  const { close, address, adminAddress } = await boot(await env(t, { NOTY_AI_ACCOUNT_URL: backend.url, NOTY_AI_ADMIN_IDS: 'konto-admin' }));
  t.after(close);
  for (const pathname of ['/admin', '/admin/app.js', '/admin/api/overview']) assert.equal((await fetch(`http://127.0.0.1:${adminAddress.port}${pathname}`)).status, 503, pathname);
  assert.equal((await fetch(`http://127.0.0.1:${address.port}/v1/me`, { headers: { authorization: `Bearer ${TOKEN}` } })).status, 200);
});

test('boot nimmt einen eigenen Admin-Handler an', async t => {
  const { close, adminAddress } = await boot(await env(t), { admin: (req, res) => { res.writeHead(418); res.end(); } });
  t.after(close);
  assert.equal((await fetch(`http://127.0.0.1:${adminAddress.port}/admin`)).status, 418);
});

test('Konfigurationsfehler auf Deutsch', async t => {
  await assert.rejects(boot({}), /STATE_DIR fehlt/);
  await assert.rejects(boot(await env(t, { PORT: 'x' })), /PORT ist ungültig/);
  await assert.rejects(boot(await env(t, { PORT: '70000' })), /PORT ist ungültig/);
  await assert.rejects(boot(await env(t, { NOTY_AI_DAILY_LIMIT: '0' })), /NOTY_AI_DAILY_LIMIT/);
  await assert.rejects(boot(await env(t, { NOTY_AI_RETENTION_DAYS: '-1' })), /NOTY_AI_RETENTION_DAYS/);
  await assert.rejects(boot(await env(t, { NOTY_AI_USAGE_DAYS: '0' })), /NOTY_AI_USAGE_DAYS/);
  await assert.rejects(boot(await env(t, { NOTY_AI_ACCOUNT_URL: 'kaputt' })), /NOTY_AI_ACCOUNT_URL/);
  await assert.rejects(boot(await env(t, { NOTY_AI_ACCOUNT_URL: 'http://konten.example' })), /https oder lokal/);
  await assert.rejects(boot(await env(t, { CODEX_HOME: '/fehlt/noty' })), /CODEX_HOME/);
});

test('Kein Inhalt im Server-Code landet in Logs', async () => {
  for (const name of ['http', 'hub', 'rpc', 'usage', 'auth', 'known-sessions', 'accounts', 'metering', 'admin']) {
    const source = await readFile(new URL(`../server/${name}.mjs`, import.meta.url), 'utf8');
    assert.ok(!/console\.(log|error|warn|info|debug)/.test(source), name);
  }
});
