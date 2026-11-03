import { mkdir, open, readFile, rename, readdir, stat, unlink } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

export const DAY_MS = 86_400_000;
const DEFAULT_TITLE = 'Neuer Chat';
const RESTART_TEXT = 'Der Server wurde neu gestartet. Stelle die Frage bitte erneut.';
const SESSION_STATUSES = ['idle', 'running', 'error', 'interrupted'];
const ROLES = ['user', 'assistant', 'system'];
const RETRY_MS = 1000;
const MAX_RETRY_MS = 60_000;

/** Fehler, dessen deutscher Text an den Client gehen darf. */
export class ApiError extends Error {
  constructor(status, message, code) { super(message); this.status = status; this.code = code; }
}

export async function writeAtomic(file, data, owner) {
  const temporary = `${file}.${randomUUID()}.tmp`;
  try {
    const handle = await open(temporary, 'wx', 0o600);
    try {
      await handle.writeFile(data);
      if (owner) await handle.chown(owner.uid, owner.gid);
      await handle.sync();
    } finally { await handle.close(); }
    await rename(temporary, file);
  } catch (error) { await unlink(temporary).catch(() => {}); throw error; }
}

/**
 * Schreibt seriell; ein wartender Auftrag übernimmt beim Start den jeweils neuesten Stand.
 * Scheitert ein Schreiben, erfährt das der Aufrufer, und der Stand im Speicher wird trotzdem
 * mit Backoff nachgeholt, bis es klappt.
 */
export class LatestWriter {
  constructor(file, serialize, { retryMs = RETRY_MS, maxRetryMs = MAX_RETRY_MS } = {}) {
    Object.assign(this, { file, serialize, retryMs, maxRetryMs });
    this.tail = Promise.resolve(); this.queued = null; this.cancelled = false; this.closed = false;
    this.timer = null; this.failures = 0;
  }
  save() {
    if (this.queued) return this.queued;
    const run = this.tail.catch(() => {}).then(async () => {
      this.queued = null;
      if (this.cancelled) return;
      try {
        await writeAtomic(this.file, this.serialize());
        this.failures = 0; this.stopRetry();
      } catch (error) { this.retry(); throw error; }
    });
    this.queued = run; this.tail = run;
    return run;
  }
  retry() {
    if (this.timer || this.cancelled || this.closed) return;
    const delay = Math.min(this.maxRetryMs, this.retryMs * 2 ** this.failures++);
    this.timer = setTimeout(() => { this.timer = null; this.save().catch(() => {}); }, delay);
    this.timer.unref();
  }
  stopRetry() { clearTimeout(this.timer); this.timer = null; }
  /** Beendet Schreiben und Wiederholung, etwa für eine gelöschte Sitzung. */
  cancel() { this.cancelled = true; this.stopRetry(); }
  /** Wartet auf den Stand der Platte; eine ausstehende Wiederholung kommt sofort dran. */
  async flush() {
    if (this.timer) { this.stopRetry(); this.save().catch(() => {}); }
    await this.tail.catch(() => {});
  }
  close() { this.closed = true; return this.flush(); }
}

const isCount = value => Number.isSafeInteger(value) && value >= 0;
// `usage` an Antworten: nur Zähler aus dem Laufprotokoll, ältere Dateien haben es nicht.
export const USAGE_FIELDS = ['inputTokens', 'cachedInputTokens', 'outputTokens', 'reasoningOutputTokens', 'totalTokens'];
const isUsage = usage => !!usage && typeof usage === 'object' && !Array.isArray(usage) && Object.entries(usage).every(([key, value]) => USAGE_FIELDS.includes(key) && isCount(value));
const isMessage = message => !!message && typeof message === 'object' && typeof message.id === 'string' && ROLES.includes(message.role) && typeof message.text === 'string'
  && (message.contextLabel === undefined || typeof message.contextLabel === 'string') && (message.imageCount === undefined || isCount(message.imageCount))
  && (message.usage === undefined || isUsage(message.usage));

/** Vollständige Prüfung einer Sitzungsdatei; alles Spätere darf sich auf diese Form verlassen. */
export function isValidSession(session, id) {
  return !!session && typeof session === 'object' && session.id === id && typeof session.userId === 'string' && !!session.userId
    && (session.documentId === null || typeof session.documentId === 'string') && typeof session.title === 'string'
    && SESSION_STATUSES.includes(session.status) && isCount(session.revision) && isCount(session.updatedAt)
    && Array.isArray(session.requests) && session.requests.every(request => typeof request === 'string')
    && Array.isArray(session.messages) && session.messages.every(isMessage);
}

/** Alte Dateien können einzelne Surrogate enthalten, die strikte JSON-Leser wie Swift ablehnen. */
function repairText(session) {
  let changed = false;
  const repair = (owner, key) => {
    if (typeof owner[key] !== 'string' || owner[key].isWellFormed()) return;
    owner[key] = owner[key].toWellFormed(); changed = true;
  };
  repair(session, 'title');
  for (const message of session.messages) { repair(message, 'text'); repair(message, 'contextLabel'); }
  return changed;
}

export class Store {
  constructor({ root, retentionDays = 30, now = Date.now, retryMs }) {
    this.root = path.resolve(root); this.sessionsDir = path.join(this.root, 'sessions');
    this.retentionMs = retentionDays * DAY_MS; this.now = now; this.retryMs = retryMs;
    this.sessions = new Map(); this.writes = new Map(); this.removing = new Set(); this.restarted = [];
    this.unlinkFile = unlink;
  }
  file(id) { return path.join(this.sessionsDir, id + '.json'); }
  expired(time) { return time < this.now() - this.retentionMs; }
  async init() {
    await mkdir(this.sessionsDir, { recursive: true, mode: 0o700 });
    await this.sweepRoot();
    for (const name of await readdir(this.sessionsDir)) {
      const file = path.join(this.sessionsDir, name);
      if (name.endsWith('.tmp')) { await this.unlinkFile(file).catch(() => {}); continue; }
      const id = /^([a-f0-9-]{36})\.json$/.exec(name)?.[1];
      if (!id) continue;
      let session = null;
      try { session = JSON.parse(await readFile(file, 'utf8')); } catch { /* unten behandelt */ }
      if (!isValidSession(session, id)) { await this.quarantine(file, id); continue; }
      if (this.expired(session.updatedAt)) { await this.discard(file, id); continue; }
      this.sessions.set(id, session);
      const repaired = repairText(session);
      const running = session.status === 'running';
      if (running) {
        this.restarted.push({ userId: session.userId, updatedAt: session.updatedAt });
        session.status = 'error';
        session.messages.push({ id: randomUUID(), role: 'system', text: RESTART_TEXT });
        // Der letzte Stand kann hinter einer schon abgefragten Revision liegen; kein 204 durch Zufallstreffer.
        session.revision += 1000;
      }
      // Scheitert das Schreiben, gilt der Stand im Speicher und der Writer holt ihn nach.
      if (running || repaired) await this.save(session).catch(() => {});
    }
    await this.sweepCorrupt();
    return this;
  }
  /** Reste abgebrochener Schreibvorgänge von Sitzungen, Konten, Zählern und Katalog. */
  async sweepRoot() {
    for (const name of await readdir(this.root)) {
      if (name.endsWith('.tmp')) await this.unlinkFile(path.join(this.root, name)).catch(() => {});
    }
  }
  /** Ungültige Dateien sperren den Dienst nicht und bleiben zur Untersuchung liegen, bis die Aufbewahrung endet. */
  async quarantine(file, id) {
    console.error(`Sitzungsdatei ${id} ist ungültig und wird übersprungen.`);
    await rename(file, `${file}.corrupt`).catch(() => console.error(`Sitzungsdatei ${id} lässt sich nicht verschieben.`));
  }
  async discard(file, id) {
    await this.unlinkFile(file).catch(() => console.error(`Sitzungsdatei ${id} lässt sich nicht löschen.`));
  }
  async sweepCorrupt() {
    const names = await readdir(this.sessionsDir).catch(() => []);
    for (const name of names.filter(entry => entry.endsWith('.corrupt'))) {
      const file = path.join(this.sessionsDir, name);
      const info = await stat(file).catch(() => null);
      if (info && this.expired(info.mtimeMs)) await this.discard(file, name);
    }
  }
  /** Läufe, die der Neustart unterbrochen hat, je einmal für die Zählung. */
  takeRestarted() { return this.restarted.splice(0); }
  visible(session) { return !this.removing.has(session.id) && !this.expired(session.updatedAt); }
  /** Fremde Sitzungen sehen aus wie nicht vorhandene, abgelaufene auch vor dem nächsten Aufräumen. */
  get(id, userId) {
    const session = this.sessions.get(id);
    if (!session || session.userId !== userId || !this.visible(session)) throw new ApiError(404, 'Sitzung nicht gefunden.');
    return session;
  }
  list(userId, documentId) {
    const wanted = documentId?.toLowerCase();
    return [...this.sessions.values()]
      .filter(s => s.userId === userId && this.visible(s) && (wanted === undefined || s.documentId?.toLowerCase() === wanted))
      .sort((a, b) => b.updatedAt - a.updatedAt).map(s => this.summary(s));
  }
  count(userId) { return [...this.sessions.values()].filter(s => s.userId === userId && this.visible(s)).length; }
  async create({ userId, documentId = null, title }) {
    const session = { id: randomUUID(), userId, documentId, title: title ?? DEFAULT_TITLE, status: 'idle', revision: 0, updatedAt: 0, messages: [], requests: [] };
    this.sessions.set(session.id, session);
    try { await this.save(session); } catch {
      this.sessions.delete(session.id);
      this.writes.get(session.id)?.cancel();
      this.writes.delete(session.id);
      throw new ApiError(503, 'Die Sitzung konnte nicht gespeichert werden.');
    }
    return session;
  }
  isDefaultTitle(session) { return session.title === DEFAULT_TITLE; }
  summary({ id, documentId, title, status, revision, updatedAt }) { return { id, documentId, title, status, revision, updatedAt }; }
  public(session) { return { ...this.summary(session), messages: session.messages }; }
  bump(session) { session.updatedAt = this.now(); session.revision++; }
  save(session) { this.bump(session); return this.persist(session); }
  /** Für Textdeltas: Revision sofort, Schreiben im Hintergrund. */
  touch(session) { this.bump(session); this.persist(session).catch(() => {}); }
  persist(session) {
    if (!this.sessions.has(session.id) || this.removing.has(session.id)) return Promise.resolve();
    let writer = this.writes.get(session.id);
    if (!writer) {
      writer = new LatestWriter(this.file(session.id), () => JSON.stringify(session), { retryMs: this.retryMs });
      this.writes.set(session.id, writer);
    }
    return writer.save();
  }
  /** Ganz oder gar nicht: Scheitert das Löschen, bleibt die Sitzung samt Writer bestehen. */
  async remove(id) {
    const writer = this.writes.get(id);
    this.removing.add(id);
    writer?.cancel();
    await writer?.flush();
    try {
      await this.unlinkFile(this.file(id)).catch(error => { if (error.code !== 'ENOENT') throw error; });
    } catch {
      this.removing.delete(id);
      if (writer) { writer.cancelled = false; writer.save().catch(() => {}); }
      throw new ApiError(503, 'Der Chat konnte nicht gelöscht werden.');
    }
    this.sessions.delete(id); this.writes.delete(id); this.removing.delete(id);
  }
  async purge(active = () => false) {
    for (const session of [...this.sessions.values()]) {
      if (!this.expired(session.updatedAt) || active(session.id)) continue;
      // Eine nicht löschbare Datei hält die übrigen nicht auf und ist für Nutzer schon unsichtbar.
      await this.remove(session.id).catch(() => console.error(`Sitzungsdatei ${session.id} lässt sich nicht löschen.`));
    }
    await this.sweepCorrupt();
  }
  async flush() { await Promise.all([...this.writes.values()].map(writer => writer.flush())); }
  async close() { await Promise.all([...this.writes.values()].map(writer => writer.close())); }
}
