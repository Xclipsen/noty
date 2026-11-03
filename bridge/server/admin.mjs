import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { isIP } from 'node:net';
import { ApiError } from './store.mjs';
import { createListener, readForm, readJson } from './http.mjs';
import { buildUsage, exportCsv, parseExportQuery, parseRunsQuery, parseUsageQuery } from './analytics.mjs';

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

// Mit Apple anmelden: Vertrag in docs/APPLE-LOGIN.md, Abschnitt Admin-Panel.
const APPLE_COOKIE = 'noty_ai_apple';
const APPLE_PATH = '/admin/api/apple';
const APPLE_CALLBACK = `${APPLE_PATH}/callback`;
const APPLE_AUTHORIZE_URL = 'https://appleid.apple.com/auth/authorize';
export const APPLE_DEFAULT_REDIRECT = `https://noty.xclipsen.de${APPLE_CALLBACK}`;
const APPLE_FLOW_SECONDS = 10 * 60;
const MAX_APPLE_FLOWS = 200;
const MAX_APPLE_FLOWS_PER_IP = 10;
const MAX_CALLBACK_BODY = 16 * 1024; // id_token, code, state; ohne angefragten scope schickt Apple kein `user`.
const MAX_ID_TOKEN_CHARS = 8192;
const SERVICES_ID = /^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$/;
const JWT = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
/** Ergebnisse, die die Zwischenseite als Fragment an /admin weitergibt; admin/app.js zeigt sie deutsch an. */
export const APPLE_RESULTS = ['abgelehnt', 'abgelaufen', 'abgebrochen', 'gesperrt', 'nicht-erreichbar', 'ungueltig'];

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
  '/admin/app.css': ['app.css', 'text/css; charset=utf-8'],
  '/admin/apple.svg': ['apple.svg', 'image/svg+xml']
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

/**
 * Offene Apple-Abläufe: `state` und Nonce-Rohwert nur im Speicher, 10 Minuten, einmalig. Ein
 * zufälliges Cookie bindet den Ablauf an den Browser, der ihn begonnen hat; gespeichert ist davon nur der Hash.
 * Begrenzt je IP und insgesamt, damit eine Flut von Starts fremde offene Abläufe nicht beliebig verdrängt.
 */
export class AppleFlows {
  constructor({ ttlMs = APPLE_FLOW_SECONDS * 1000, max = MAX_APPLE_FLOWS, perIp = MAX_APPLE_FLOWS_PER_IP, now = Date.now } = {}) {
    Object.assign(this, { ttlMs, max, perIp, now });
    this.entries = new Map();
  }
  create(ip) {
    for (const [key, entry] of this.entries) if (this.now() >= entry.expiresAt) this.entries.delete(key);
    const mine = [...this.entries].filter(([, entry]) => entry.ip === ip);
    while (mine.length >= this.perIp) this.entries.delete(mine.shift()[0]);
    while (this.entries.size >= this.max) this.entries.delete(this.entries.keys().next().value);
    const [state, nonce, binding] = [0, 1, 2].map(() => randomBytes(32).toString('hex'));
    this.entries.set(sha256(state), { nonce, binding: sha256(binding), ip, expiresAt: this.now() + this.ttlMs });
    return { state, nonce, binding };
  }
  /** Liefert den Nonce-Rohwert und verbraucht den Ablauf, nur mit passendem Cookie. */
  take(state, binding) {
    if (typeof state !== 'string' || !TOKEN.test(state)) return null;
    const key = sha256(state);
    const entry = this.entries.get(key);
    if (!entry) return null;
    if (this.now() >= entry.expiresAt) { this.entries.delete(key); return null; }
    // Ein fremdes oder fehlendes Cookie verbraucht nichts: Wer nur den state kennt, soll den echten Ablauf nicht abbrechen können.
    if (typeof binding !== 'string' || !TOKEN.test(binding) || !timingSafeEqual(Buffer.from(sha256(binding)), Buffer.from(entry.binding))) return null;
    this.entries.delete(key);
    return entry.nonce;
  }
}

/**
 * Ohne gültige Services ID ist Apple aus. Die Rücksprungadresse muss genau auf diesen Dienst
 * unter dem erlaubten Ursprung zeigen, sonst käme das Bindungs-Cookie nie an.
 */
export function parseAppleConfig({ servicesId, redirect, authorizeUrl = APPLE_AUTHORIZE_URL } = {}, allowedOrigin) {
  const id = typeof servicesId === 'string' ? servicesId.trim() : '';
  const target = redirect || APPLE_DEFAULT_REDIRECT;
  if (!allowedOrigin || !SERVICES_ID.test(id) || target !== `${allowedOrigin}${APPLE_CALLBACK}`) return null;
  return { servicesId: id, redirect: target, authorizeUrl };
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

function cookieToken(header, name = COOKIE) {
  for (const part of (header ?? '').split(';')) {
    const pair = part.trim();
    if (pair.startsWith(`${name}=`)) return pair.slice(name.length + 1);
  }
  return null;
}
const cookie = (token, maxAge) => `${COOKIE}=${token}; HttpOnly; Secure; SameSite=Strict; Path=/admin; Max-Age=${maxAge}`;
// SameSite=None: Apple schickt das Formular von appleid.apple.com, also seitenübergreifend.
const appleCookie = (binding, maxAge) => `${APPLE_COOKIE}=${binding}; HttpOnly; Secure; SameSite=None; Path=${APPLE_PATH}; Max-Age=${maxAge}`;
/** Fehler im Apple-Ablauf enden als 303 auf die Zwischenseite, nie als JSON im Browser. */
const appleBack = result => Object.assign(new ApiError(303, 'Weiterleitung.'), { location: `${APPLE_CALLBACK}?ergebnis=${result}` });

/**
 * Zwischenseite nach dem Rücksprung. Die Weiterleitung von Apple ist eine seitenübergreifende
 * Navigation: Ein 303 direkt auf /admin käme dort ohne das SameSite=Strict-Cookie an. Diese Seite
 * leitet per Meta-Refresh weiter, eine Navigation vom eigenen Ursprung, die das Cookie mitsendet.
 * Ohne Skript, die CSP bleibt unverändert; der Link hilft, falls der Browser Meta-Refresh abschaltet.
 */
function appleDonePage(result) {
  const target = APPLE_RESULTS.includes(result) ? `/admin#apple=${result}` : '/admin';
  return `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0; url=${target}">
<title>noty KI – Verwaltung</title>
<link rel="stylesheet" href="/admin/app.css">
</head>
<body>
<main class="login"><p><a href="${target}">Weiter zur Verwaltung</a></p></main>
</body>
</html>
`;
}
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
export async function createAdmin({ hub, accounts, accountUrl, origin, apple: appleOptions, fetcher = globalThis.fetch, now = Date.now, staticDir = DEFAULT_STATIC_DIR, logoutRetryMs = 10_000 }) {
  const allowedOrigin = parseAdminOrigin(origin);
  const enabled = !!allowedOrigin && accounts.adminIds.size > 0;
  const apple = parseAppleConfig(appleOptions, allowedOrigin);
  const base = String(accountUrl).replace(/\/+$/, '');
  const sessions = new AdminSessions({ now });
  const throttle = new LoginThrottle({ now });
  const flows = new AppleFlows({ now });
  const files = new Map();
  if (enabled) for (const [pathname, [name, type]] of Object.entries(STATIC_FILES)) files.set(pathname, { type, body: await readFile(new URL(name, staticDir)) });
  if (enabled && apple) {
    // Die Seite erfährt ohne Anmeldung und ohne eigene Abfrage, ob der Apple-Knopf erscheint.
    const html = files.get('/admin').body.toString('utf8');
    if (!html.includes('<body>')) throw new Error('admin/index.html ohne <body>.');
    files.get('/admin').body = Buffer.from(html.replace('<body>', '<body data-apple="on">'));
  }

  /** Login beim Backend; `null` heißt abgelehnt, Ausfälle werfen und kosten keinen Versuch. */
  async function backendSession(pathname, payload) {
    let response;
    try {
      response = await fetcher(`${base}${pathname}`, { method: 'POST', headers: { ...BACKEND_HEADERS, 'content-type': 'application/json' }, body: JSON.stringify(payload), redirect: 'error', signal: AbortSignal.timeout(LOGIN_TIMEOUT_MS) });
    } catch { throw unavailable(); }
    if (response.status === 400 || response.status === 401) return null;
    if (response.status === 429) throw tooMany();
    if (response.status !== 200) throw unavailable();
    let user;
    try { ({ user } = await response.json()); } catch { throw unavailable(); }
    if (typeof user?.id !== 'string' || !user.id || typeof user.token !== 'string' || !TOKEN.test(user.token)) throw unavailable();
    return user;
  }

  // Wie die App: Adressen gehen als email, das Backend prüft name strenger.
  const backendLogin = ({ name, password }) => backendSession('/api/login', { [name.includes('@') ? 'email' : 'name']: name, password });
  // `create: false`: Ein unbekanntes Apple-Konto legt über das Admin-Panel kein neues noty-Konto an.
  const backendAppleLogin = (identityToken, nonce) => backendSession('/api/apple/login', { identityToken, nonce, create: false });

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

  function appleStart(req, res) {
    const { state, nonce, binding } = flows.create(clientIp(req));
    // Von Hand kodiert: URLSearchParams schriebe das Leerzeichen in `code id_token` als `+`.
    const query = Object.entries({
      client_id: apple.servicesId, redirect_uri: apple.redirect, response_type: 'code id_token', response_mode: 'form_post', state, nonce: sha256(nonce)
    }).map(([key, value]) => `${key}=${encodeURIComponent(value)}`).join('&');
    res.setHeader('Set-Cookie', appleCookie(binding, APPLE_FLOW_SECONDS));
    res.writeHead(302, { Location: `${apple.authorizeUrl}?${query}` }); res.end();
  }

  /**
   * Rücksprung von Apple. Ohne Origin-Prüfung, das Formular kommt von appleid.apple.com; stattdessen
   * state plus Bindungs-Cookie. Danach dieselben Sperren, dieselbe Admin-Prüfung und dasselbe sofortige
   * Abmelden der Backend-Sitzung wie beim Passwort.
   */
  async function appleCallback(req, res) {
    res.setHeader('Set-Cookie', appleCookie('', 0));
    let form;
    try { form = await readForm(req, MAX_CALLBACK_BODY); } catch (error) { throw error instanceof ApiError ? appleBack('ungueltig') : error; }
    const single = name => { const values = form.getAll(name); return values.length === 1 ? values[0] : null; };
    const nonce = flows.take(single('state'), cookieToken(req.headers.cookie, APPLE_COOKIE));
    if (!nonce) throw appleBack('abgelaufen');
    if (form.has('error')) throw appleBack('abgebrochen');
    const idToken = single('id_token');
    if (!idToken || idToken.length > MAX_ID_TOKEN_CHARS || !JWT.test(idToken)) throw appleBack('ungueltig');
    const release = throttle.acquire(clientIp(req));
    if (!release) throw appleBack('gesperrt');
    let user;
    try { user = await backendAppleLogin(idToken, nonce); } catch (error) { release(); throw appleBack(error.status === 429 ? 'gesperrt' : 'nicht-erreichbar'); }
    if (!user) throw appleBack('abgelehnt');
    dropBackendSession(user.token);
    if (!accounts.isAdmin(user.id)) throw appleBack('abgelehnt');
    release();
    res.setHeader('Set-Cookie', [appleCookie('', 0), cookie(sessions.create(user.id), SESSION_SECONDS)]);
    res.writeHead(303, { Location: APPLE_CALLBACK }); res.end();
  }

  function appleDone(res, url) {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(appleDonePage(url.searchParams.get('ergebnis')));
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
  function allow(req, res, ...methods) {
    if (methods.includes(req.method)) return;
    res.setHeader('Allow', methods.join(', '));
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
    if (pathname === `${APPLE_PATH}/start` || pathname === APPLE_CALLBACK) {
      if (!apple) throw new ApiError(404, 'Pfad nicht gefunden.');
      if (pathname !== APPLE_CALLBACK) { allow(req, res, 'GET'); appleStart(req, res); return; }
      allow(req, res, 'GET', 'POST');
      if (req.method === 'GET') appleDone(res, url); else await appleCallback(req, res);
      return;
    }
    if (pathname === '/admin/api/overview') { allow(req, res, 'GET'); requireSession(req); sendJson(res, 200, await hub.overview()); return; }
    // Auswertungen: nur lesen, erst die Sitzung, dann die Abfrage prüfen; Antworten ohne Inhalte.
    if (pathname === '/admin/api/usage') { allow(req, res, 'GET'); requireSession(req); sendJson(res, 200, buildUsage({ accounts, metering: hub.metering, ...parseUsageQuery(url) })); return; }
    if (pathname === '/admin/api/runs') { allow(req, res, 'GET'); requireSession(req); sendJson(res, 200, hub.runlog.list(parseRunsQuery(url))); return; }
    if (pathname === '/admin/api/export') {
      allow(req, res, 'GET'); requireSession(req);
      const { filename, body } = exportCsv({ ...parseExportQuery(url), accounts, metering: hub.metering, runlog: hub.runlog, now: now() });
      res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': `attachment; filename="${filename}"` });
      res.end(body);
      return;
    }
    const user = /^\/admin\/api\/users\/([^/]+)$/.exec(pathname);
    if (user) { allow(req, res, 'PATCH'); requireWrite(req); requireSession(req); await patchUser(req, res, user[1]); return; }
    throw new ApiError(404, 'Pfad nicht gefunden.');
  };
}
