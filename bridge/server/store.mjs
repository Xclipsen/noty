import { mkdir, open, readFile, rename, readdir, stat, unlink } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

export const DAY_MS = 86_400_000;
const DEFAULT_TITLE = 'Neuer Chat';
const RESTART_TEXT = 'Der Server wurde neu gestartet. Stelle die Frage bitte erneut.';

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

/** Schreibt seriell; ein wartender Auftrag übernimmt beim Start den jeweils neuesten Stand. */
export class LatestWriter {
  constructor(file, serialize) {
    Object.assign(this, { file, serialize });
    this.tail = Promise.resolve(); this.queued = null; this.cancelled = false;
  }
  save() {
    if (this.queued) return this.queued;
    const run = this.tail.catch(() => {}).then(() => {
      this.queued = null;
      if (!this.cancelled) return writeAtomic(this.file, this.serialize());
    });
    this.queued = run; this.tail = run;
    return run;
  }
  flush() { return this.tail.catch(() => {}); }
}

export class Store {
  constructor({ root, retentionDays = 30, now = Date.now }) {
    this.root = path.resolve(root); this.sessionsDir = path.join(this.root, 'sessions');
    this.retentionMs = retentionDays * DAY_MS; this.now = now;
    this.sessions = new Map(); this.writes = new Map();
  }
  file(id) { return path.join(this.sessionsDir, id + '.json'); }
  expired(time) { return time < this.now() - this.retentionMs; }
  async init() {
    await mkdir(this.sessionsDir, { recursive: true, mode: 0o700 });
    for (const name of await readdir(this.sessionsDir)) {
      const file = path.join(this.sessionsDir, name);
      if (name.endsWith('.tmp')) { await unlink(file).catch(() => {}); continue; }
      const id = /^([a-f0-9-]{36})\.json$/.exec(name)?.[1];
      if (!id) continue;
      let session = null;
      try { session = JSON.parse(await readFile(file, 'utf8')); } catch { /* unten behandelt */ }
      if (session?.id !== id || !Array.isArray(session.messages)) {
        // Unlesbare Dateien sperren den Dienst nicht, unterliegen aber der Aufbewahrung.
        console.error(`Sitzungsdatei ${id} ist ungültig und wird übersprungen.`);
        if (this.expired((await stat(file)).mtimeMs)) await unlink(file);
        continue;
      }
      if (this.expired(session.updatedAt)) { await unlink(file); continue; }
      this.sessions.set(id, session);
      if (session.status === 'running') {
        session.status = 'error';
        session.messages.push({ id: randomUUID(), role: 'system', text: RESTART_TEXT });
        // Der letzte Stand kann hinter einer schon abgefragten Revision liegen; kein 204 durch Zufallstreffer.
        session.revision += 1000;
        await this.save(session);
      }
    }
    return this;
  }
  /** Fremde Sitzungen sehen aus wie nicht vorhandene. */
  get(id, userId) {
    const session = this.sessions.get(id);
    if (!session || session.userId !== userId) throw new ApiError(404, 'Sitzung nicht gefunden.');
    return session;
  }
  list(userId, documentId) {
    const wanted = documentId?.toLowerCase();
    return [...this.sessions.values()]
      .filter(s => s.userId === userId && (wanted === undefined || s.documentId?.toLowerCase() === wanted))
      .sort((a, b) => b.updatedAt - a.updatedAt).map(s => this.summary(s));
  }
  async create({ userId, documentId = null, title }) {
    const session = { id: randomUUID(), userId, documentId, title: title ?? DEFAULT_TITLE, status: 'idle', revision: 0, updatedAt: 0, messages: [], requests: [] };
    this.sessions.set(session.id, session);
    await this.save(session);
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
    if (!this.sessions.has(session.id)) return Promise.resolve();
    let writer = this.writes.get(session.id);
    if (!writer) {
      writer = new LatestWriter(this.file(session.id), () => JSON.stringify(session));
      this.writes.set(session.id, writer);
    }
    return writer.save();
  }
  async remove(id) {
    this.sessions.delete(id);
    const writer = this.writes.get(id);
    this.writes.delete(id);
    if (writer) { writer.cancelled = true; await writer.flush(); }
    await unlink(this.file(id)).catch(error => { if (error.code !== 'ENOENT') throw error; });
  }
  async purge(active = () => false) {
    for (const session of [...this.sessions.values()]) {
      if (this.expired(session.updatedAt) && !active(session.id)) await this.remove(session.id);
    }
  }
  async flush() { await Promise.all([...this.writes.values()].map(writer => writer.flush())); }
}
