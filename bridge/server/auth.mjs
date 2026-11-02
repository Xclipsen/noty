import { createHash } from 'node:crypto';
import { ApiError } from './store.mjs';

const TOKEN = /^[a-f0-9]{64}$/;
const WINDOW_MS = 5 * 60_000;
// Das Backend erlaubt 1200 Anfragen je 5 Minuten aus einem Topf; ein Teil bleibt für alles andere frei.
const MAX_LOOKUPS = 900;
const MAX_UNKNOWN_LOOKUPS = 300; // Der Rest bleibt für die erneute Prüfung bekannter Tokens reserviert.
const MAX_CLIENT_LOOKUPS = 60;
const MAX_CONCURRENT = 8;
const MAX_UNKNOWN_CONCURRENT = 4;
const MAX_CLIENTS = 1000;
const KNOWN_MS = 24 * 60 * 60_000;
const MAX_COOLDOWN_MS = 5 * 60_000;
const LIMITED_RETRY_S = 30;
const BUSY_RETRY_S = 5;
const invalid = () => new ApiError(401, 'Die Anmeldung ist abgelaufen oder ungültig.');
const unavailable = () => new ApiError(503, 'Das Konto-Backend ist nicht erreichbar.');
const limited = () => Object.assign(new ApiError(429, 'Zu viele Anmeldeprüfungen. Bitte kurz warten.'), { retryAfter: LIMITED_RETRY_S });
const busy = () => Object.assign(new ApiError(503, 'Die Anmeldeprüfung ist gerade ausgelastet.'), { retryAfter: BUSY_RETRY_S });

export function bearerToken(header) {
  return /^Bearer ([a-f0-9]{64})$/.exec(header ?? '')?.[1] ?? null;
}

/**
 * Prüft noty-Kontositzungen serverseitig. Jede Unklarheit endet in 401, 429 oder 503, nie in Zugriff.
 *
 * Jedes gültig geformte Token kostet sonst eine Backend-Abfrage. Deshalb: Fehlschläge kurz merken,
 * Abfragen in einem gleitenden Fenster und gleichzeitig deckeln. Unbekannte Tokens teilen sich nur
 * einen Teil des Budgets, damit eine Flut laufende Konten weder aussperrt noch aus dem Cache drängt.
 */
export class SessionAuth {
  constructor({ accountUrl, fetcher = globalThis.fetch, ttlMs = 60_000, negativeTtlMs = 30_000, failureTtlMs = 3000, knownMs = KNOWN_MS, timeoutMs = 5000, maxEntries = 2000,
    windowMs = WINDOW_MS, maxLookups = MAX_LOOKUPS, maxUnknownLookups = MAX_UNKNOWN_LOOKUPS, maxClientLookups = MAX_CLIENT_LOOKUPS,
    maxConcurrent = MAX_CONCURRENT, maxUnknownConcurrent = MAX_UNKNOWN_CONCURRENT, maxClients = MAX_CLIENTS, now = Date.now }) {
    this.url = accountUrl.replace(/\/+$/, '') + '/api/session';
    Object.assign(this, { fetcher, ttlMs, negativeTtlMs, failureTtlMs, knownMs, timeoutMs, maxEntries, windowMs, maxLookups, maxUnknownLookups, maxClientLookups, maxConcurrent, maxUnknownConcurrent, maxClients, now });
    this.cache = new Map(); this.negative = new Map(); this.pending = new Map();
    this.lookups = []; this.unknownLookups = []; this.clients = new Map();
    this.active = 0; this.activeUnknown = 0; this.coolingUntil = 0;
  }
  /** Schlüssel nur als SHA-256; `client` wirkt nur auf unbekannte Tokens. */
  async verify(token, client = 'unbekannt') {
    if (typeof token !== 'string' || !TOKEN.test(token)) throw invalid();
    const key = createHash('sha256').update(token).digest('hex');
    const now = this.now();
    const entry = this.cache.get(key);
    if (entry && now < entry.expiresAt) return entry.user;
    const miss = this.negative.get(key);
    if (miss && now < miss.expiresAt) throw miss.failed ? unavailable() : invalid();
    let pending = this.pending.get(key);
    if (!pending) {
      const release = this.admit(!!entry && now < entry.knownUntil, client);
      pending = this.lookup(token).finally(() => { release(); this.pending.delete(key); });
      this.pending.set(key, pending);
    }
    let user;
    try { user = await pending; } catch (error) { this.rememberMiss(key, true); throw error; }
    if (!user) { this.cache.delete(key); this.rememberMiss(key, false); throw invalid(); }
    this.remember(key, user);
    return user;
  }
  remember(key, user) {
    this.cache.delete(key); this.negative.delete(key);
    while (this.cache.size >= this.maxEntries) this.cache.delete(this.cache.keys().next().value);
    const now = this.now();
    this.cache.set(key, { user, expiresAt: now + this.ttlMs, knownUntil: now + this.knownMs });
  }
  rememberMiss(key, failed) {
    const ttl = failed ? this.failureTtlMs : this.negativeTtlMs;
    if (ttl <= 0) return;
    this.negative.delete(key);
    while (this.negative.size >= this.maxEntries) this.negative.delete(this.negative.keys().next().value);
    this.negative.set(key, { failed, expiresAt: this.now() + ttl });
  }
  recent(stamps) { const cutoff = this.now() - this.windowMs; return stamps.filter(stamp => stamp > cutoff); }
  /** Bucht eine Abfrage oder wirft 429/503; ohne Reservierung kommen parallele Anfragen alle durch. */
  admit(known, client) {
    const now = this.now();
    if (now < this.coolingUntil) throw busy();
    if (this.active >= this.maxConcurrent || (!known && this.activeUnknown >= this.maxUnknownConcurrent)) throw busy();
    this.lookups = this.recent(this.lookups);
    if (this.lookups.length >= this.maxLookups) throw limited();
    if (!known) {
      this.unknownLookups = this.recent(this.unknownLookups);
      const mine = this.recent(this.clients.get(client) ?? []);
      if (this.unknownLookups.length >= this.maxUnknownLookups || mine.length >= this.maxClientLookups) throw limited();
      this.unknownLookups.push(now); mine.push(now);
      this.clients.delete(client);
      while (this.clients.size >= this.maxClients) this.clients.delete(this.clients.keys().next().value);
      this.clients.set(client, mine);
      this.activeUnknown++;
    }
    this.lookups.push(now);
    this.active++;
    return () => { this.active--; if (!known) this.activeUnknown--; };
  }
  /** Das Backend bremst alle Anfragen dieser Maschine; weitere Abfragen würden das nur verlängern. */
  cooldown(response) {
    const seconds = Number(response.headers?.get?.('retry-after'));
    const wait = Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : 60_000;
    this.coolingUntil = this.now() + Math.min(wait, MAX_COOLDOWN_MS);
  }
  async lookup(token) {
    let body;
    try {
      const response = await this.fetcher(this.url, {
        headers: { authorization: `Bearer ${token}`, accept: 'application/json' },
        redirect: 'error', signal: AbortSignal.timeout(this.timeoutMs)
      });
      if (response.status === 429) this.cooldown(response);
      if (response.status !== 200) throw new Error('unexpected status');
      body = await response.json();
    } catch { throw unavailable(); }
    if (!body || typeof body !== 'object' || !('user' in body)) throw unavailable();
    if (body.user === null) return null;
    const { id, name } = body.user ?? {};
    if (typeof id !== 'string' || !id || id.length > 200 || typeof name !== 'string') throw unavailable();
    return { id, name: name.slice(0, 200).toWellFormed() };
  }
}
