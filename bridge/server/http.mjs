import { createServer } from 'node:http';
import { isIP } from 'node:net';
import { ApiError } from './store.mjs';
import { isUuid } from './hub.mjs';
import { bearerToken } from './auth.mjs';
import { statusError } from './accounts.mjs';
import { RevisionWaits } from './waits.mjs';

export const MAX_BODY = 24 * 1024 * 1024;
const MAX_SMALL_BODY = 4096;
// Nach einer Ablehnung liest der Dienst den Rest des Körpers ungepuffert weg, damit der Client die
// Antwort sieht statt ECONNRESET. Mehr oder länger nicht: danach wird die Verbindung getrennt.
const MAX_DRAIN_BYTES = 64 * 1024 * 1024;
const DRAIN_TIMEOUT_MS = 15_000;
const MAX_PATH_DECODES = 4;
const UPLOAD_RETRY_S = 5;
const BASE_HEADERS = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };

function readBody(req, limit) {
  if (Number(req.headers['content-length']) > limit) return Promise.reject(new ApiError(413, 'Die Anfrage ist zu groß.'));
  // Während der Kontoprüfung kann der Client schon weg sein; dann feuert kein Ereignis mehr.
  if (req.destroyed && !req.readableEnded) return Promise.reject(new ApiError(400, 'Die Anfrage wurde abgebrochen.'));
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    const onData = chunk => {
      size += chunk.length;
      if (size <= limit) { chunks.push(chunk); return; }
      req.off('data', onData); chunks.length = 0;
      reject(new ApiError(413, 'Die Anfrage ist zu groß.'));
    };
    req.on('data', onData);
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
    // Ein abgerissener Upload muss seinen Platz in der UploadGate freigeben.
    req.on('close', () => { if (!req.complete) reject(new ApiError(400, 'Die Anfrage wurde abgebrochen.')); });
  });
}

/**
 * Antwortet und schließt nur die Schreibseite. Node würde die Verbindung sonst mit `destroySoon`
 * sofort trennen, ein noch sendender Client bekäme ECONNRESET statt der Antwort.
 */
function closeAfterDrain(req, res) {
  res.setHeader('Connection', 'close');
  req.socket.destroySoon = req.socket.end;
  let bytes = 0;
  const stop = () => req.destroy();
  const timer = setTimeout(stop, DRAIN_TIMEOUT_MS);
  timer.unref();
  req.once('close', () => clearTimeout(timer));
  req.on('data', chunk => { bytes += chunk.length; if (bytes > MAX_DRAIN_BYTES) stop(); });
  req.resume();
}

/**
 * Prüft die Rohform von `req.url`, bevor `new URL` sie deutet. nginx normalisiert anders als Node:
 * `//admin/v1/me` wäre Host `admin` mit Pfad `/v1/me`, `\` zählt für Node als `/`. Abgelehnt werden
 * deshalb alles außer absoluten Pfaden sowie `//`, `\`, `.`- und `..`-Formen, auch prozentkodiert,
 * und mehrfach kodierte Pfade, die nicht zur Ruhe kommen. Eine einzelne Kodierung wie `konto%2Fx` bleibt erlaubt.
 */
export function isSafeRawPath(target) {
  if (typeof target !== 'string' || !target.startsWith('/') || target.includes('#')) return false;
  let pathname = target.split('?', 1)[0];
  for (let round = 0; round <= MAX_PATH_DECODES; round++) {
    if (/\/\/|\\|\.\.|\/\.(?:\/|$)|[\x00-\x20\x7f]/.test(pathname)) return false;
    const decoded = pathname.replace(/%([0-9a-f]{2})/gi, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
    if (decoded === pathname) return true;
    pathname = decoded;
  }
  return false;
}

/** Für die Drossel je Client; hinter nginx zählt X-Real-IP, sonst die Socket-Adresse. */
export function clientAddress(req) {
  const value = String(req.headers['x-real-ip'] ?? '').trim();
  return isIP(value) ? value : req.socket.remoteAddress ?? 'unbekannt';
}

/** Deckelt große Körper im Speicher: Ein Lauf-Upload hält bis zu 24 MiB, dazu Strings aus JSON.parse. */
export class UploadGate {
  constructor({ perAccount = 2, global = 4 } = {}) {
    Object.assign(this, { perAccount, global });
    this.accounts = new Map(); this.active = 0;
  }
  acquire(userId) {
    const mine = this.accounts.get(userId) ?? 0;
    if (mine >= this.perAccount || this.active >= this.global) {
      throw Object.assign(new ApiError(429, 'Zu viele gleichzeitige Uploads. Bitte kurz warten.'), { retryAfter: UPLOAD_RETRY_S });
    }
    this.accounts.set(userId, mine + 1); this.active++;
    let released = false;
    return () => {
      if (released) return;
      released = true; this.active--;
      const left = this.accounts.get(userId) - 1;
      if (left) this.accounts.set(userId, left); else this.accounts.delete(userId);
    };
  }
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

/** Formularkörper wie das `form_post` von Apple; Typ exakt, ohne Typ oder mit anderem `415`. */
export async function readForm(req, limit) {
  if ((req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase() !== 'application/x-www-form-urlencoded') throw new ApiError(415, 'Formular erforderlich.');
  return new URLSearchParams((await readBody(req, limit)).toString('utf8'));
}

/** Gemeinsamer HTTP-Rahmen beider Listener: Rohpfadprüfung, Fehlerabbildung, Nachlesen. */
export function createListener(route, { headers = BASE_HEADERS } = {}) {
  return createServer(async (req, res) => {
    for (const [name, value] of Object.entries(headers)) res.setHeader(name, value);
    const reply = (status, data) => {
      if (data === undefined) res.writeHead(status);
      else res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(data === undefined ? undefined : JSON.stringify(data));
    };
    try {
      if (!isSafeRawPath(req.url)) throw new ApiError(404, 'Pfad nicht gefunden.');
      let url;
      try { url = new URL(req.url, 'http://localhost'); } catch { throw new ApiError(400, 'Ungültiger Pfad.'); }
      const result = await route(req, res, url);
      if (result) reply(...result);
    } catch (error) {
      if (res.headersSent) return;
      // Unbekannte Fehler können Pfade oder Inhalte tragen und bleiben intern.
      const known = error instanceof ApiError;
      if (known && error.retryAfter) res.setHeader('Retry-After', String(error.retryAfter));
      if (!req.complete) closeAfterDrain(req, res);
      // Browser-Ablauf ohne JSON-Leser, zum Beispiel der Rücksprung von Apple: Fehler als Weiterleitung.
      if (known && error.location) { res.setHeader('Location', error.location); reply(error.status); return; }
      reply(known ? error.status : 500, { error: known ? error.message : 'Interner Fehler.', ...(error.code && known ? { code: error.code } : {}) });
    }
  });
}

/**
 * `GET /v1/sessions/:id`: ohne `after` oder bei anderer Revision sofort `200`. Gleiche Revision: ohne
 * `wait=1` sofort `204`, mit `wait=1` Long-Polling bis zur nächsten Revision (`200`) oder bis zum Ablauf
 * (`204`). Konto und Sitzung werden nach dem Warten erneut geprüft.
 */
async function readSession({ hub, accounts, waits }, userId, id, url, res) {
  const after = url.searchParams.get('after');
  const wait = url.searchParams.get('wait');
  if (after !== null && !/^\d{1,15}$/.test(after)) throw new ApiError(400, 'Ungültige Revision.');
  if (wait !== null && wait !== '0' && wait !== '1') throw new ApiError(400, 'Ungültiger Warteparameter.');
  const session = hub.store.get(id, userId);
  if (after !== String(session.revision)) return [200, hub.store.public(session)];
  if (wait !== '1') return [204];
  const reason = await waits.wait(userId, id, res);
  // Client weg: niemand liest die Antwort mehr.
  if (res.destroyed || res.writableEnded) return null;
  if (reason === 'closed') return [204];
  const status = accounts.statusOf(userId);
  if (status !== 'active') throw statusError(status);
  const current = hub.store.get(id, userId);
  return after === String(current.revision) ? [204] : [200, hub.store.public(current)];
}

/** Nur `/v1` für die App, gedacht für PORT hinter Tailscale. `/admin` gibt es hier nicht. */
export function createApi({ hub, auth, accounts, uploads = new UploadGate(), waits = new RevisionWaits() }) {
  const server = createListener(async (req, res, url) => {
    const { method } = req;
    const parts = url.pathname.split('/').filter(Boolean);
    if (parts[0] !== 'v1') throw new ApiError(404, 'Pfad nicht gefunden.');
    const account = await accounts.seen(await auth.verify(bearerToken(req.headers.authorization), clientAddress(req)));
    if (method === 'GET' && url.pathname === '/v1/me') return [200, hub.me(account)];
    if (account.status !== 'active') throw statusError(account.status);
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
      if (parts.length === 3 && method === 'GET') return readSession({ hub, accounts, waits }, userId, id, url, res);
      if (parts.length === 3 && method === 'DELETE') { await hub.remove(userId, id); return [204]; }
      if (parts[3] === 'turns' && method === 'POST') {
        hub.store.get(id, userId);
        const release = uploads.acquire(userId);
        try { return [202, await hub.turn(userId, id, await readJson(req, MAX_BODY))]; } finally { release(); }
      }
      if (parts[3] === 'cancel' && method === 'POST') { await hub.cancel(userId, id); return [200, { ok: true }]; }
    }
    throw new ApiError(404, 'Pfad nicht gefunden.');
  });
  // Jede neue Revision weckt die Wartenden ihrer Sitzung; beim Schließen wartet niemand weiter.
  const unwatch = hub.store.watch(id => waits.notify(id));
  server.on('close', () => { unwatch(); waits.close(); });
  server.waits = waits;
  return server;
}
