import { createHash, randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { isIP } from 'node:net';
import { ApiError } from './store.mjs';
import { createListener, readJson } from './http.mjs';

const COOKIE = 'noty_ai_admin';
const SESSION_SECONDS = 8 * 60 * 60;
const MAX_SESSIONS = 20;
const ATTEMPT_WINDOW_MS = 15 * 60_000;
const MAX_FAILS_PER_IP = 5;
const MAX_FAILS_GLOBAL = 20;
const MAX_TRACKED_IPS = 1000;
const MAX_LOGIN_BODY = 4096;
const MAX_PATCH_BODY = 256;
const MAX_NAME_CHARS = 254;
const MAX_PASSWORD_BYTES = 1024;
const LOGIN_TIMEOUT_MS = 15_000; // Das Backend rechnet scrypt und erlaubt davon nur zwei zugleich.
const LOGOUT_TIMEOUT_MS = 5000;
const LOGOUT_RETRIES = 3;
const TOKEN = /^[a-f0-9]{64}$/;
// Ohne diese Kennung behandelt das Backend die Anfrage als Browser: Origin-Pflicht und kein Token in der Antwort.
const BACKEND_HEADERS = { 'x-noty-client': '1', accept: 'application/json' };

export const CONTRACT_HEADERS = {
  'Content-Security-Policy': "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'Strict-Transport-Security': 'max-age=31536000',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'Cache-Control': 'no-store'
};
const STATIC_FILES = {
  '/admin': ['index.html', 'text/html; charset=utf-8'],
  '/admin/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/admin/app.css': ['app.css', 'text/css; charset=utf-8']
};
const DEFAULT_STATIC_DIR = new URL('../admin/', import.meta.url);

const sha256 = value => createHash('sha256').update(value).digest('hex');
const denied = () => new ApiError(401, 'Name oder Passwort stimmt nicht.');
const expired = () => new ApiError(401, 'Die Sitzung ist abgelaufen. Bitte neu anmelden.');
const unavailable = () => new ApiError(503, 'Das Konto-Backend ist nicht erreichbar.');
const tooMany = () => new ApiError(429, 'Zu viele Anmeldeversuche. Bitte in 15 Minuten erneut versuchen.');

/** Exakter Ursprung ohne Pfad; unverschlüsselt nur lokal. Alles andere gilt als nicht gesetzt. */
export function parseAdminOrigin(value) {
  let url;
  try { url = new URL(value); } catch { return null; }
  const local = ['localhost', '127.0.0.1'].includes(url.hostname);
  return url.origin === value && (url.protocol === 'https:' || (url.protocol === 'http:' && local)) ? value : null;
}

/**
 * Gleitendes Fenster je IP und global, damit wechselnde oder gefälschte IPs nicht unbegrenzt raten.
 * Ein Versuch wird vor dem Backend-Aufruf reserviert, sonst kämen parallele Anfragen alle durch.
 * Abgelehnte Anfragen zählen nicht und verlängern die Sperre nicht.
 */
export class LoginThrottle {
  constructor({ perIp = MAX_FAILS_PER_IP, global = MAX_FAILS_GLOBAL, windowMs = ATTEMPT_WINDOW_MS, maxIps = MAX_TRACKED_IPS, now = Date.now } = {}) {
    Object.assign(this, { perIp, global, windowMs, maxIps, now });
    this.ips = new Map(); this.all = [];
  }
  recent(stamps) { const cutoff = this.now() - this.windowMs; return stamps.filter(stamp => stamp > cutoff); }
  sweep() {
    for (const [ip, stamps] of this.ips) {
      const recent = this.recent(stamps);
      if (recent.length) this.ips.set(ip, recent); else this.ips.delete(ip);
    }
    while (this.ips.size >= this.maxIps) this.ips.delete(this.ips.keys().next().value);
  }
  /** Liefert die Rücknahme des Versuchs oder null, wenn gesperrt ist. */
  acquire(ip) {
    this.all = this.recent(this.all);
    const mine = this.recent(this.ips.get(ip) ?? []);
    if (mine.length >= this.perIp || this.all.length >= this.global) return null;
    if (!this.ips.has(ip) && this.ips.size >= this.maxIps) this.sweep();
    const stamp = this.now();
    mine.push(stamp); this.all.push(stamp);
    this.ips.set(ip, mine);
    return () => {
      const without = list => { const at = list.lastIndexOf(stamp); if (at >= 0) list.splice(at, 1); return list; };
      without(this.all);
      const remaining = this.ips.get(ip);
      if (remaining && !without(remaining).length) this.ips.delete(ip);
    };
  }
}

/** Nur der Hash liegt im Speicher; ein Neustart meldet alle ab. */
export class AdminSessions {
  constructor({ ttlMs = SESSION_SECONDS * 1000, max = MAX_SESSIONS, now = Date.now } = {}) {
    Object.assign(this, { ttlMs, max, now });
    this.entries = new Map();
  }
  create(userId) {
    for (const [key, entry] of this.entries) if (this.now() >= entry.expiresAt) this.entries.delete(key);
    while (this.entries.size >= this.max) this.entries.delete(this.entries.keys().next().value);
    const token = randomBytes(32).toString('hex');
    this.entries.set(sha256(token), { userId, expiresAt: this.now() + this.ttlMs });
    return token;
  }
  valid(token) {
    if (typeof token !== 'string' || !TOKEN.test(token)) return false;
    const key = sha256(token);
    const entry = this.entries.get(key);
    if (entry && this.now() < entry.expiresAt) return true;
    this.entries.delete(key);
    return false;
  }
  remove(token) { if (typeof token === 'string') this.entries.delete(sha256(token)); }
}

function cookieToken(header) {
  for (const part of (header ?? '').split(';')) {
    const pair = part.trim();
    if (pair.startsWith(`${COOKIE}=`)) return pair.slice(COOKIE.length + 1);
  }
  return null;
}
const cookie = (token, maxAge) => `${COOKIE}=${token}; HttpOnly; Secure; SameSite=Strict; Path=/admin; Max-Age=${maxAge}`;
const sendJson = (res, status, data) => { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(data)); };

/** Nur für die Sperre; ohne gültigen Wert teilen sich alle denselben Zähler. */
function clientIp(req) {
  const value = String(req.headers['x-real-ip'] ?? '').trim();
  return isIP(value) ? value : 'unbekannt';
}

function parseCredentials({ name, password }) {
  const trimmed = typeof name === 'string' ? name.normalize('NFC').trim() : '';
  if (!trimmed || trimmed.length > MAX_NAME_CHARS || typeof password !== 'string' || !password || Buffer.byteLength(password) > MAX_PASSWORD_BYTES) {
    throw new ApiError(400, 'Bitte Name und Passwort eingeben.');
  }
  return { name: trimmed, password };
}

function parsePatch(body) {
  const keys = Object.keys(body);
  if (!keys.length || keys.some(key => !['status', 'dailyLimit'].includes(key))) throw new ApiError(400, 'Ungültige Änderung.');
  return { status: body.status, dailyLimit: body.dailyLimit };
}

function parseUserId(raw) {
  try { return decodeURIComponent(raw); } catch { throw new ApiError(400, 'Ungültige Kontokennung.'); }
}

/** Eigener Listener für ADMIN_PORT hinter nginx: nur `/admin`, kein `/v1`. */
export function createAdminApi(admin) {
  return createListener(async (req, res, url) => {
    // `admin(req, res, url)` antwortet selbst und prüft eigenes Cookie, Origin und JSON.
    if (url.pathname !== '/admin' && !url.pathname.startsWith('/admin/')) throw new ApiError(404, 'Pfad nicht gefunden.');
    await admin(req, res, url);
    return null;
  }, { headers: CONTRACT_HEADERS });
}

/**
 * Baut den Handler für `createAdminApi`. Fehler laufen als ApiError in dessen Fehlerpfad;
 * die Vertrags-Header stehen da schon auf der Antwort. Ohne gültigen NOTY_AI_ADMIN_ORIGIN oder
 * ohne Admin-Konten lehnt der Handler alles ab, die App-Schnittstelle /v1 bleibt davon unberührt.
 */
export async function createAdmin({ hub, accounts, accountUrl, origin, fetcher = globalThis.fetch, now = Date.now, staticDir = DEFAULT_STATIC_DIR, logoutRetryMs = 10_000 }) {
  const allowedOrigin = parseAdminOrigin(origin);
  const enabled = !!allowedOrigin && accounts.adminIds.size > 0;
  const base = String(accountUrl).replace(/\/+$/, '');
  const sessions = new AdminSessions({ now });
  const throttle = new LoginThrottle({ now });
  const files = new Map();
  if (enabled) for (const [pathname, [name, type]] of Object.entries(STATIC_FILES)) files.set(pathname, { type, body: await readFile(new URL(name, staticDir)) });

  async function backendLogin({ name, password }) {
    // Wie die App: Adressen gehen als email, das Backend prüft name strenger.
    const body = JSON.stringify({ [name.includes('@') ? 'email' : 'name']: name, password });
    let response;
    try {
      response = await fetcher(`${base}/api/login`, { method: 'POST', headers: { ...BACKEND_HEADERS, 'content-type': 'application/json' }, body, redirect: 'error', signal: AbortSignal.timeout(LOGIN_TIMEOUT_MS) });
    } catch { throw unavailable(); }
    if (response.status === 400 || response.status === 401) return null;
    if (response.status === 429) throw tooMany();
    if (response.status !== 200) throw unavailable();
    let user;
    try { ({ user } = await response.json()); } catch { throw unavailable(); }
    if (typeof user?.id !== 'string' || !user.id || typeof user.token !== 'string' || !TOKEN.test(user.token)) throw unavailable();
    return user;
  }

  /** Beendet die vom Login erzeugte Backend-Sitzung; das Token bleibt nur bis dahin im Speicher. */
  async function dropBackendSession(token, attempt = 0) {
    try {
      const response = await fetcher(`${base}/api/logout`, { method: 'POST', headers: { ...BACKEND_HEADERS, authorization: `Bearer ${token}` }, redirect: 'error', signal: AbortSignal.timeout(LOGOUT_TIMEOUT_MS) });
      if (!response.ok) throw new Error('unexpected status');
    } catch {
      if (attempt < LOGOUT_RETRIES) setTimeout(() => dropBackendSession(token, attempt + 1), logoutRetryMs).unref();
    }
  }

  async function login(req, res) {
    const credentials = parseCredentials(await readJson(req, MAX_LOGIN_BODY));
    const release = throttle.acquire(clientIp(req));
    if (!release) throw tooMany();
    let user;
    try { user = await backendLogin(credentials); } catch (error) { release(); throw error; }
    if (!user) throw denied();
    // Auch bei Nicht-Admins und ohne auf das Backend zu warten: gleiche Antwortzeit, keine verwaiste Sitzung.
    dropBackendSession(user.token);
    if (!accounts.isAdmin(user.id)) throw denied();
    release();
    res.setHeader('Set-Cookie', cookie(sessions.create(user.id), SESSION_SECONDS));
    sendJson(res, 200, { ok: true });
  }

  async function logout(req, res) {
    await readJson(req, MAX_PATCH_BODY, { optional: true });
    sessions.remove(cookieToken(req.headers.cookie));
    res.setHeader('Set-Cookie', cookie('', 0));
    res.writeHead(204); res.end();
  }

  async function patchUser(req, res, rawId) {
    const patch = parsePatch(await readJson(req, MAX_PATCH_BODY));
    const id = parseUserId(rawId);
    const account = await accounts.update(id, patch);
    if (account.status !== 'active' || account.effectiveDailyLimit === 0) await hub.abortUser(id);
    sendJson(res, 200, account);
  }

  function requireWrite(req) {
    if (req.headers.origin !== allowedOrigin) throw new ApiError(403, 'Diese Herkunft ist nicht erlaubt.');
    if ((req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase() !== 'application/json') throw new ApiError(415, 'JSON erforderlich.');
  }
  function requireSession(req) {
    if (!sessions.valid(cookieToken(req.headers.cookie))) throw expired();
  }
  function allow(req, res, method) {
    if (req.method === method) return;
    res.setHeader('Allow', method);
    throw new ApiError(405, 'Methode nicht erlaubt.');
  }

  return async function admin(req, res, url) {
    if (!enabled) throw new ApiError(503, 'Der Admin-Bereich ist nicht eingerichtet.');
    const { pathname } = url;
    const file = files.get(pathname); // Feste Liste: kein Pfad aus der Anfrage erreicht das Dateisystem.
    if (file) {
      allow(req, res, 'GET');
      res.writeHead(200, { 'Content-Type': file.type }); res.end(file.body);
      return;
    }
    if (pathname === '/admin/api/login') { allow(req, res, 'POST'); requireWrite(req); await login(req, res); return; }
    if (pathname === '/admin/api/logout') { allow(req, res, 'POST'); requireWrite(req); await logout(req, res); return; }
    if (pathname === '/admin/api/overview') { allow(req, res, 'GET'); requireSession(req); sendJson(res, 200, await hub.overview()); return; }
    const user = /^\/admin\/api\/users\/([^/]+)$/.exec(pathname);
    if (user) { allow(req, res, 'PATCH'); requireWrite(req); requireSession(req); await patchUser(req, res, user[1]); return; }
    throw new ApiError(404, 'Pfad nicht gefunden.');
  };
}
