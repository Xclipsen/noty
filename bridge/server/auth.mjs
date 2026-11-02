import { createHash } from 'node:crypto';
import { ApiError } from './store.mjs';

const TOKEN = /^[a-f0-9]{64}$/;
const invalid = () => new ApiError(401, 'Die Anmeldung ist abgelaufen oder ungültig.');
const unavailable = () => new ApiError(503, 'Das Konto-Backend ist nicht erreichbar.');

export function bearerToken(header) {
  return /^Bearer ([a-f0-9]{64})$/.exec(header ?? '')?.[1] ?? null;
}

/** Prüft noty-Kontositzungen serverseitig. Jede Unklarheit endet in 401 oder 503, nie in Zugriff. */
export class SessionAuth {
  constructor({ accountUrl, fetcher = globalThis.fetch, ttlMs = 60_000, timeoutMs = 5000, maxEntries = 2000, now = Date.now }) {
    this.url = accountUrl.replace(/\/+$/, '') + '/api/session';
    Object.assign(this, { fetcher, ttlMs, timeoutMs, maxEntries, now });
    this.cache = new Map(); this.pending = new Map();
  }
  async verify(token) {
    if (typeof token !== 'string' || !TOKEN.test(token)) throw invalid();
    const key = createHash('sha256').update(token).digest('hex');
    const entry = this.cache.get(key);
    let user;
    if (entry && this.now() < entry.expiresAt) user = entry.user;
    else {
      this.cache.delete(key);
      let pending = this.pending.get(key);
      if (!pending) {
        pending = this.lookup(token).finally(() => this.pending.delete(key));
        this.pending.set(key, pending);
      }
      user = await pending;
      this.remember(key, user);
    }
    if (!user) throw invalid();
    return user;
  }
  remember(key, user) {
    this.cache.delete(key);
    while (this.cache.size >= this.maxEntries) this.cache.delete(this.cache.keys().next().value);
    this.cache.set(key, { user, expiresAt: this.now() + this.ttlMs });
  }
  async lookup(token) {
    let body;
    try {
      const response = await this.fetcher(this.url, {
        headers: { authorization: `Bearer ${token}`, accept: 'application/json' },
        redirect: 'error', signal: AbortSignal.timeout(this.timeoutMs)
      });
      if (response.status !== 200) throw new Error('unexpected status');
      body = await response.json();
    } catch { throw unavailable(); }
    if (!body || typeof body !== 'object' || !('user' in body)) throw unavailable();
    if (body.user === null) return null;
    const { id, name } = body.user ?? {};
    if (typeof id !== 'string' || !id || id.length > 200 || typeof name !== 'string') throw unavailable();
    return { id, name: name.slice(0, 200) };
  }
}
