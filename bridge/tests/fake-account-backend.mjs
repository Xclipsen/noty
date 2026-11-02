import { createServer } from 'node:http';
import { randomBytes } from 'node:crypto';

const MAX_SESSIONS = 10;
const readBody = async req => { const chunks = []; for await (const chunk of req) chunks.push(chunk); return Buffer.concat(chunks).toString('utf8'); };

/**
 * Ersatz für das Konto-Backend. `users` bildet feste Schlüssel auf Konten ab. `logins` sind
 * `{ id, name, email?, password }` und verhalten sich wie `server/api.mjs` der Gesetzessammlung:
 * nur native Aufrufe bekommen ein Token, je Konto bleiben die neuesten 10 Sitzungen.
 */
export async function startAccountBackend(users, { logins = [] } = {}) {
  const backend = { seen: [], sessions: new Map(), loginBodies: [], logoutCalls: 0, loginStatus: null, logoutFailures: 0 };
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
      const fresh = randomBytes(32).toString('hex');
      const user = { id: found.id, name: found.name };
      backend.sessions.set(fresh, { user });
      const mine = [...backend.sessions].filter(([, session]) => session.user.id === found.id);
      for (const [old] of mine.slice(0, -MAX_SESSIONS)) backend.sessions.delete(old);
      res.setHeader('Set-Cookie', `law_session=${fresh}; Path=/; HttpOnly`);
      send(res, 200, { user: { ...user, token: fresh } });
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
