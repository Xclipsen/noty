import { createServer } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';

const MAX_SESSIONS = 10;
const readBody = async req => { const chunks = []; for await (const chunk of req) chunks.push(chunk); return Buffer.concat(chunks).toString('utf8'); };
const sha256 = value => createHash('sha256').update(value).digest('hex');
const part = value => Buffer.from(JSON.stringify(value)).toString('base64url');

/** Unsigniertes, aber formgleiches Apple-Identity-Token; im Token steht wie bei Apple `sha256(nonce)`. */
export function fakeIdToken({ sub, nonceHash, aud = 'de.xclipsen.noty.web' }) {
  const now = Math.floor(Date.now() / 1000);
  return [part({ alg: 'RS256', kid: 'synthetisch' }), part({ iss: 'https://appleid.apple.com', aud, sub, nonce: nonceHash, iat: now, exp: now + 600 }), 'c3ludGhldGlzY2g'].join('.');
}

/**
 * Ersatz für das Konto-Backend. `users` bildet feste Schlüssel auf Konten ab. `logins` sind
 * `{ id, name, email?, password }` und verhalten sich wie `server/api.mjs` der Gesetzessammlung:
 * nur native Aufrufe bekommen ein Token, je Konto bleiben die neuesten 10 Sitzungen.
 * `apple` sind `{ sub, id, name }` für `POST /api/apple/login` nach docs/APPLE-LOGIN.md; die
 * Signatur prüft der Ersatz nicht, wohl aber `sha256(nonce)` gegen das Token und `create: false`.
 */
export async function startAccountBackend(users, { logins = [], apple = [] } = {}) {
  const backend = { seen: [], sessions: new Map(), loginBodies: [], appleBodies: [], logoutCalls: 0, loginStatus: null, appleStatus: null, logoutFailures: 0 };
  const startSession = user => {
    const fresh = randomBytes(32).toString('hex');
    backend.sessions.set(fresh, { user });
    const mine = [...backend.sessions].filter(([, session]) => session.user.id === user.id);
    for (const [old] of mine.slice(0, -MAX_SESSIONS)) backend.sessions.delete(old);
    return fresh;
  };
  const send = (res, status, data) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(data)); };
  const server = createServer(async (req, res) => {
    backend.seen.push(req.headers.authorization);
    const token = /^Bearer ([a-f0-9]{64})$/.exec(req.headers.authorization ?? '')?.[1];
    const native = req.headers['x-noty-client'] === '1' && !('origin' in req.headers) && !('cookie' in req.headers) && !('sec-fetch-site' in req.headers);
    if (req.method === 'GET' && req.url === '/api/session') { send(res, 200, { user: users.get(token) ?? backend.sessions.get(token)?.user ?? null }); return; }
    if (req.method === 'POST' && req.url === '/api/login') {
      if (!native) { send(res, 403, { error: 'Bitte verwende die sichere Website für diese Aktion.' }); return; }
      const body = JSON.parse(await readBody(req));
      backend.loginBodies.push(body);
      if (backend.loginStatus) { send(res, backend.loginStatus, { error: 'Synthetischer Fehler' }); return; }
      const key = body.email ?? body.name;
      const found = logins.find(login => (login.name === key || login.email === key) && login.password === body.password);
      if (!found) { send(res, 401, { error: 'E-Mail/Name oder Passwort stimmt nicht.' }); return; }
      const user = { id: found.id, name: found.name };
      const fresh = startSession(user);
      res.setHeader('Set-Cookie', `law_session=${fresh}; Path=/; HttpOnly`);
      send(res, 200, { user: { ...user, token: fresh } });
      return;
    }
    if (req.method === 'POST' && req.url === '/api/apple/login') {
      if (!native) { send(res, 403, { error: 'Bitte verwende die sichere Website für diese Aktion.' }); return; }
      const body = JSON.parse(await readBody(req));
      backend.appleBodies.push(body);
      if (backend.appleStatus) { send(res, backend.appleStatus, { error: 'Synthetischer Fehler' }); return; }
      let claims;
      try { claims = JSON.parse(Buffer.from(String(body.identityToken).split('.')[1], 'base64url').toString('utf8')); } catch { claims = null; }
      if (!claims || typeof body.nonce !== 'string' || claims.nonce !== sha256(body.nonce)) { send(res, 401, { error: 'Die Anmeldung mit Apple ist ungültig.' }); return; }
      let found = apple.find(entry => entry.sub === claims.sub);
      const created = !found && body.create !== false;
      if (created) { found = { sub: claims.sub, id: `konto-${randomBytes(4).toString('hex')}`, name: `apple-${randomBytes(3).toString('hex')}` }; apple.push(found); }
      if (!found) { send(res, 401, { error: 'E-Mail/Name oder Passwort stimmt nicht.' }); return; }
      const user = { id: found.id, name: found.name };
      const fresh = startSession(user);
      res.setHeader('Set-Cookie', `law_session=${fresh}; Path=/; HttpOnly`);
      send(res, 200, { user: { ...user, token: fresh }, created });
      return;
    }
    if (req.method === 'POST' && req.url === '/api/logout') {
      backend.logoutCalls++;
      if (backend.logoutFailures > 0) { backend.logoutFailures--; send(res, 500, { error: 'Synthetischer Fehler' }); return; }
      if (!native) { send(res, 403, { error: 'Bitte verwende die sichere Website für diese Aktion.' }); return; }
      backend.sessions.delete(token);
      send(res, 200, { ok: true });
      return;
    }
    res.writeHead(404); res.end();
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return Object.assign(backend, { url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }) });
}

/** Legt eine bestehende App-Sitzung an, wie sie ein früherer Login hinterlassen hätte. */
export function appSession(backend, user) {
  const token = randomBytes(32).toString('hex');
  backend.sessions.set(token, { user });
  return token;
}
