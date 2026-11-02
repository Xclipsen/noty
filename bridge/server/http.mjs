import { createServer } from 'node:http';
import { ApiError } from './store.mjs';
import { isUuid } from './hub.mjs';
import { bearerToken } from './auth.mjs';

export const MAX_BODY = 24 * 1024 * 1024;
const MAX_SMALL_BODY = 4096;
const STATUS_TEXT = { pending: 'Dein Konto wartet noch auf Freischaltung.', blocked: 'Dein Konto ist für die KI gesperrt.' };

function readBody(req, limit) {
  if (Number(req.headers['content-length']) > limit) return Promise.reject(new ApiError(413, 'Die Anfrage ist zu groß.'));
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > limit) { req.pause(); chunks.length = 0; reject(new ApiError(413, 'Die Anfrage ist zu groß.')); } else chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

export async function readJson(req, limit, { optional = false } = {}) {
  const empty = !req.headers['transfer-encoding'] && !Number(req.headers['content-length']);
  if (optional && empty) return {};
  if (!/^application\/json\b/i.test(req.headers['content-type'] ?? '')) throw new ApiError(415, 'JSON erforderlich.');
  const raw = await readBody(req, limit);
  let body;
  try { body = JSON.parse(raw.toString('utf8')); } catch { throw new ApiError(400, 'Ungültiges JSON.'); }
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new ApiError(400, 'Ungültige Anfrage.');
  return body;
}

export function createApi({ hub, auth, accounts, admin }) {
  async function route(req, res, url) {
    const { method } = req;
    const parts = url.pathname.split('/').filter(Boolean);
    // `admin(req, res, url)` aus admin.mjs antwortet selbst und prüft eigenes Cookie, Origin und JSON.
    if (url.pathname === '/admin' || url.pathname.startsWith('/admin/')) {
      if (!admin) throw new ApiError(404, 'Pfad nicht gefunden.');
      await admin(req, res, url);
      return null;
    }
    if (parts[0] !== 'v1') throw new ApiError(404, 'Pfad nicht gefunden.');
    const account = await accounts.seen(await auth.verify(bearerToken(req.headers.authorization)));
    if (method === 'GET' && url.pathname === '/v1/me') return [200, hub.me(account)];
    if (account.status !== 'active') throw new ApiError(403, STATUS_TEXT[account.status], account.status);
    const userId = account.id;
    if (method === 'GET' && url.pathname === '/v1/info') return [200, await hub.info(userId)];
    if (method === 'GET' && url.pathname === '/v1/usage') return [200, await hub.usage()];
    if (url.pathname === '/v1/sessions' && method === 'GET') {
      const documentId = url.searchParams.get('documentId') ?? undefined;
      if (documentId !== undefined && !isUuid(documentId)) throw new ApiError(400, 'Ungültige Dokumentkennung.');
      return [200, hub.store.list(userId, documentId)];
    }
    if (url.pathname === '/v1/sessions' && method === 'POST') return [201, await hub.createSession(userId, await readJson(req, MAX_SMALL_BODY, { optional: true }))];
    if (parts[0] === 'v1' && parts[1] === 'sessions' && parts.length >= 3 && parts.length <= 4) {
      if (!isUuid(parts[2])) throw new ApiError(400, 'Ungültige Sitzungskennung.');
      const id = parts[2].toLowerCase();
      if (parts.length === 3 && method === 'GET') {
        const session = hub.store.get(id, userId);
        const after = url.searchParams.get('after');
        if (after !== null && !/^\d{1,15}$/.test(after)) throw new ApiError(400, 'Ungültige Revision.');
        return after === String(session.revision) ? [204] : [200, hub.store.public(session)];
      }
      if (parts.length === 3 && method === 'DELETE') { await hub.remove(userId, id); return [204]; }
      if (parts[3] === 'turns' && method === 'POST') {
        hub.store.get(id, userId);
        return [202, await hub.turn(userId, id, await readJson(req, MAX_BODY))];
      }
      if (parts[3] === 'cancel' && method === 'POST') { await hub.cancel(userId, id); return [200, { ok: true }]; }
    }
    throw new ApiError(404, 'Pfad nicht gefunden.');
  }

  return createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Content-Type-Options', 'nosniff');
    const reply = (status, data) => {
      if (data === undefined) res.writeHead(status);
      else res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(data === undefined ? undefined : JSON.stringify(data));
    };
    try {
      let url;
      try { url = new URL(req.url, 'http://localhost'); } catch { throw new ApiError(400, 'Ungültiger Pfad.'); }
      const result = await route(req, res, url);
      if (result) reply(...result);
    } catch (error) {
      if (res.headersSent) return;
      // Unbekannte Fehler können Pfade oder Inhalte tragen und bleiben intern.
      const known = error instanceof ApiError;
      if (known && error.status === 413) { res.setHeader('Connection', 'close'); res.once('finish', () => req.destroy()); }
      reply(known ? error.status : 500, { error: known ? error.message : 'Interner Fehler.', ...(error.code && known ? { code: error.code } : {}) });
    }
  });
}
