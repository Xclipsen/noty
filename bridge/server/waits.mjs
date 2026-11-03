import { ApiError } from './store.mjs';

/**
 * Long-Polling für `GET /v1/sessions/:id?after=REV&wait=1`: Eine Anfrage wartet bis zu `timeoutMs`
 * auf die nächste Revision ihrer Sitzung. Wartende sind je Konto und insgesamt begrenzt, damit
 * offene Verbindungen weder Speicher noch Dateideskriptoren aufbrauchen. Jede Wartestelle hat genau
 * einen Timer und hängt an `res` 'close': ein abgerissener Client räumt sofort auf.
 */
export const WAIT = { timeoutMs: 20_000, perAccount: 4, global: 64, retryAfter: 1 };

export class RevisionWaits {
  constructor({ timeoutMs = WAIT.timeoutMs, perAccount = WAIT.perAccount, global = WAIT.global } = {}) {
    Object.assign(this, { timeoutMs, perAccount, global });
    this.sessions = new Map(); this.accounts = new Map(); this.size = 0; this.closed = false;
  }
  /**
   * Endet mit 'changed', 'timeout' oder 'closed' (Client weg oder Dienst fährt herunter), nie mit
   * einem Fehler. Über der Grenze `429` mit `Retry-After`, bevor irgendetwas registriert ist.
   */
  wait(userId, sessionId, res) {
    if (this.closed || res.destroyed || res.writableEnded) return Promise.resolve('closed');
    if ((this.accounts.get(userId) ?? 0) >= this.perAccount || this.size >= this.global) {
      throw Object.assign(new ApiError(429, 'Zu viele wartende Abfragen. Bitte kurz warten.', 'too_many_waits'), { retryAfter: WAIT.retryAfter });
    }
    return new Promise(resolve => {
      let timer = null;
      const entry = { userId, done: false, finish: null };
      const onClose = () => entry.finish('closed');
      entry.finish = reason => {
        if (entry.done) return;
        entry.done = true;
        clearTimeout(timer);
        res.off('close', onClose);
        this.forget(userId, sessionId, entry);
        resolve(reason);
      };
      let waiting = this.sessions.get(sessionId);
      if (!waiting) { waiting = new Set(); this.sessions.set(sessionId, waiting); }
      waiting.add(entry);
      this.accounts.set(userId, (this.accounts.get(userId) ?? 0) + 1); this.size++;
      res.once('close', onClose);
      timer = setTimeout(() => entry.finish('timeout'), this.timeoutMs);
      timer.unref();
    });
  }
  forget(userId, sessionId, entry) {
    const waiting = this.sessions.get(sessionId);
    if (!waiting?.delete(entry)) return;
    if (!waiting.size) this.sessions.delete(sessionId);
    const left = this.accounts.get(userId) - 1;
    if (left > 0) this.accounts.set(userId, left); else this.accounts.delete(userId);
    this.size--;
  }
  /** Neue Revision, gelöschte oder abgelaufene Sitzung: alle Wartenden dieser Sitzung antworten. */
  notify(sessionId) {
    const waiting = this.sessions.get(sessionId);
    if (!waiting) return;
    for (const entry of [...waiting]) entry.finish('changed');
  }
  /** Beim Herunterfahren: niemand wartet weiter, neue Wartestellen enden sofort. */
  close() {
    this.closed = true;
    for (const waiting of [...this.sessions.values()]) for (const entry of [...waiting]) entry.finish('closed');
  }
}
