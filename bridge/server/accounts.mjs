import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { ApiError, LatestWriter } from './store.mjs';

export const STATUSES = ['pending', 'active', 'blocked'];
export const MAX_DAILY_LIMIT = 1_000_000;
const SEEN_WRITE_MS = 60_000;
const STATUS_TEXT = { pending: 'Dein Konto wartet noch auf Freischaltung.', blocked: 'Dein Konto ist für die KI gesperrt.' };

/** 403 mit `code` für alles außer `active`. */
export const statusError = status => new ApiError(403, STATUS_TEXT[status], status);

const isLimit = value => value === null || value === undefined || (Number.isInteger(value) && value >= 0 && value <= MAX_DAILY_LIMIT);
const isRecord = record => !!record && typeof record === 'object' && typeof record.id === 'string' && !!record.id && typeof record.name === 'string'
  && STATUSES.includes(record.status) && isLimit(record.dailyLimit) && Number.isFinite(record.lastSeenAt);

export class Accounts {
  constructor({ root, adminIds = [], defaultDailyLimit = 200, now = Date.now }) {
    this.file = path.join(path.resolve(root), 'accounts.json');
    this.adminIds = new Set(adminIds); this.defaultDailyLimit = defaultDailyLimit; this.now = now;
    this.records = new Map();
    this.writer = new LatestWriter(this.file, () => JSON.stringify([...this.records.values()]));
  }
  async init() {
    let saved;
    try { saved = JSON.parse(await readFile(this.file, 'utf8')); } catch (error) {
      if (error.code === 'ENOENT') return this;
      throw new Error('Kontodatei ist unlesbar.');
    }
    if (!Array.isArray(saved) || !saved.every(isRecord)) throw new Error('Kontodatei ist unlesbar.');
    for (const record of saved) this.records.set(record.id, { ...record, name: record.name.toWellFormed() });
    return this;
  }
  isAdmin(id) { return this.adminIds.has(id); }
  /** Ohne Eintrag gibt es keine Freischaltung. */
  statusOf(id) { return this.isAdmin(id) ? 'active' : this.records.get(id)?.status ?? 'pending'; }
  limitFor(id) { return this.records.get(id)?.dailyLimit ?? this.defaultDailyLimit; }
  /** Konto für Anzeige und Prüfung; `dailyLimit` null heißt Standard. */
  view({ id, name, status, dailyLimit, lastSeenAt }) {
    const admin = this.isAdmin(id);
    return { id, name, status: admin ? 'active' : status, role: admin ? 'admin' : 'user', dailyLimit, effectiveDailyLimit: dailyLimit ?? this.defaultDailyLimit, lastSeenAt };
  }
  get(id) {
    const record = this.records.get(id);
    if (!record) throw new ApiError(404, 'Konto nicht gefunden.');
    return this.view(record);
  }
  list() { return [...this.records.values()].map(record => this.view(record)); }
  /** Vermerkt eine geprüfte Kontositzung; neue Konten starten als pending. */
  async seen({ id, name }) {
    const now = this.now();
    const record = this.records.get(id);
    if (!record) {
      const created = { id, name, status: 'pending', dailyLimit: null, lastSeenAt: now };
      this.records.set(id, created);
      try { await this.writer.save(); } catch {
        if (this.records.get(id) === created) this.records.delete(id);
        throw new ApiError(503, 'Das Konto konnte nicht gespeichert werden.');
      }
      return this.view(created);
    }
    const stale = record.name !== name || now - record.lastSeenAt >= SEEN_WRITE_MS;
    record.name = name; record.lastSeenAt = now;
    if (stale) this.writer.save().catch(() => {});
    return this.view(record);
  }
  /** Kontoänderung für das Admin-Panel: `{ status?, dailyLimit? }`, null setzt den Standard. */
  async update(id, { status, dailyLimit } = {}) {
    const record = this.records.get(id);
    if (!record) throw new ApiError(404, 'Konto nicht gefunden.');
    if (status !== undefined && !STATUSES.includes(status)) throw new ApiError(400, 'Ungültiger Status.');
    if (dailyLimit !== undefined && dailyLimit !== null && (!Number.isInteger(dailyLimit) || dailyLimit < 0 || dailyLimit > MAX_DAILY_LIMIT)) throw new ApiError(400, 'Ungültiges Tageslimit.');
    if (status !== undefined && status !== 'active' && this.isAdmin(id)) throw new ApiError(409, 'Admins lassen sich nicht sperren.');
    const previous = { ...record };
    if (status !== undefined) record.status = status;
    if (dailyLimit !== undefined) record.dailyLimit = dailyLimit;
    try { await this.writer.save(); } catch {
      Object.assign(record, previous);
      throw new ApiError(503, 'Die Änderung konnte nicht gespeichert werden.');
    }
    return this.view(record);
  }
  flush() { return this.writer.flush(); }
  close() { return this.writer.close(); }
}

/** Daten von `GET /admin/api/overview`, ausschließlich Konten und Zähler. */
export function buildOverview({ accounts, metering, account = null, plan = null, running = 0 }) {
  return {
    account, plan, running, today: metering.todayTotal(),
    users: accounts.list().map(user => ({ ...user, today: metering.forToday(user.id), last7: metering.sum(user.id, 7), last30: metering.sum(user.id, 30), total: metering.sum(user.id) }))
  };
}
