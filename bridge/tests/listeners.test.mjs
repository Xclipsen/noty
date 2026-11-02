import test from 'node:test';
import assert from 'node:assert/strict';
import { connect } from 'node:net';
import path from 'node:path';
import { boot } from '../server/main.mjs';
import { tempDir, TOKEN } from './helpers.mjs';
import { startAccountBackend } from './fake-account-backend.mjs';

const ORIGIN = 'https://noty.example.invalid';
const BEARER = { Authorization: `Bearer ${TOKEN}` };

/** Schickt die Anfragezeile unverändert über TCP: fetch und http.request würden den Pfad normalisieren. */
export function rawRequest(port, target, headers = BEARER, method = 'GET') {
  return new Promise((resolve, reject) => {
    const socket = connect(port, '127.0.0.1');
    let data = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => { data += chunk; });
    socket.on('error', reject);
    socket.on('end', () => {
      const [head, body] = [data.slice(0, data.indexOf('\r\n\r\n')), data.slice(data.indexOf('\r\n\r\n') + 4)];
      resolve({ status: Number(head.split(' ')[1]), head, body });
    });
    const lines = [`${method} ${target} HTTP/1.1`, 'Host: 127.0.0.1', 'Connection: close', ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`)];
    socket.write(lines.join('\r\n') + '\r\n\r\n');
  });
}

async function bridge(t) {
  const backend = await startAccountBackend(new Map([[TOKEN, { id: 'konto-admin', name: 'Chefin' }]]));
  t.after(() => backend.close());
  const root = await tempDir(t);
  const started = await boot({ STATE_DIR: path.join(root, 'state'), CODEX_HOME: root, NOTY_AI_ACCOUNT_URL: backend.url, CODEX_BIN: '/bin/false', PORT: '0', ADMIN_PORT: '0', NOTY_AI_ADMIN_IDS: 'konto-admin', NOTY_AI_ADMIN_ORIGIN: ORIGIN });
  t.after(started.close);
  return { ...started, backend, port: started.address.port, adminPort: started.adminAddress?.port };
}

test('Befund 1: /v1 nur auf PORT, /admin nur auf ADMIN_PORT, beide nur lokal', async t => {
  const { address, adminAddress, port, adminPort } = await bridge(t);
  assert.equal(address.address, '127.0.0.1');
  assert.equal(adminAddress.address, '127.0.0.1');
  assert.notEqual(port, adminPort);
  assert.equal((await rawRequest(port, '/v1/me')).status, 200);
  for (const target of ['/admin', '/admin/', '/admin/app.js', '/admin/api/overview', '/admin/api/login']) assert.equal((await rawRequest(port, target)).status, 404, target);
  assert.equal((await rawRequest(adminPort, '/admin')).status, 200);
  assert.equal((await rawRequest(adminPort, '/admin/api/overview')).status, 401);
  for (const target of ['/v1/me', '/v1', '/v1/sessions', '/', '/irgendwas', '/adminx']) {
    const res = await rawRequest(adminPort, target);
    assert.equal(res.status, 404, target);
    assert.match(res.head, /content-security-policy: default-src 'none'/i, target);
  }
});

const SMUGGLED = [
  '//admin/v1/me', '/admin/..\\v1/me', '/admin\\..\\v1\\me', '\\\\admin\\v1\\me', '/admin/../v1/me', '/admin/./../v1/me',
  '/admin/%2e%2e/v1/me', '/admin/.%2E/v1/me', '/admin/%2E./v1/me', '/admin/..%5Cv1/me', '/admin/%2e%2e%5cv1/me', '/admin/%252e%252e/v1/me', '/admin/%25252e%25252e/v1/me',
  '/%2Fadmin/v1/me', '/%2fadmin%2fv1/me%2F%2F', '%2F%2Fadmin/v1/me', '/v1//me', '/v1/%2F/me', '/v1/me/..', '/v1/./me',
  'http://admin/v1/me', 'http://127.0.0.1/v1/me', 'HTTP://127.0.0.1/admin', 'admin/v1/me', '*'
];

test('Befund 1: umgedeutete Rohpfade ergeben auf beiden Listenern 404, ohne Kontoprüfung', async t => {
  const { port, adminPort, backend } = await bridge(t);
  for (const listener of [port, adminPort]) {
    for (const target of SMUGGLED) {
      const res = await rawRequest(listener, target);
      // Formen, die schon der HTTP-Parser verwirft, sind ebenfalls kein Zugriff.
      assert.ok(res.status === 404 || res.status === 400, `${target}: ${res.status}`);
      if (res.status === 404) assert.match(res.body, /nicht gefunden/, target);
      assert.ok(!res.body.includes('Chefin'), target);
    }
  }
  assert.deepEqual(backend.seen, []);
});

test('Befund 1: harmlose Pfade und Abfragen bleiben erlaubt', async t => {
  const { port, adminPort } = await bridge(t);
  assert.equal((await rawRequest(port, '/v1/sessions?documentId=E621E1F8-C36C-495A-93FC-0C247A3E6E5F')).status, 200);
  assert.equal((await rawRequest(port, '/v1/me?hinweis=a..b//c')).status, 200);
  assert.equal((await rawRequest(adminPort, '/admin/api/users/konto-c%2Fd', {}, 'PATCH')).status, 403);
});

test('Befund 1: ADMIN_PORT wird geprüft', async t => {
  const root = await tempDir(t);
  const env = { STATE_DIR: path.join(root, 'state'), CODEX_HOME: root, NOTY_AI_ACCOUNT_URL: 'http://127.0.0.1:9', CODEX_BIN: '/bin/false', PORT: '0' };
  await assert.rejects(boot({ ...env, ADMIN_PORT: 'x' }), /ADMIN_PORT ist ungültig/);
  await assert.rejects(boot({ ...env, ADMIN_PORT: '70000' }), /ADMIN_PORT ist ungültig/);
  await assert.rejects(boot({ ...env, PORT: '18790', ADMIN_PORT: '18790' }), /ADMIN_PORT/);
});

test('Befund 1: belegter zweiter Port beendet den Start sauber', async t => {
  const first = await bridge(t);
  const root = await tempDir(t);
  await assert.rejects(boot({ STATE_DIR: path.join(root, 'state'), CODEX_HOME: root, NOTY_AI_ACCOUNT_URL: 'http://127.0.0.1:9', CODEX_BIN: '/bin/false', PORT: '0', ADMIN_PORT: String(first.adminPort) }), /EADDRINUSE/);
});
