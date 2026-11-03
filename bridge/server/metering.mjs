import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { DAY_MS, LatestWriter } from './store.mjs';

export const TOKEN_COUNTERS = ['inputTokens', 'cachedInputTokens', 'cacheWriteInputTokens', 'outputTokens', 'reasoningOutputTokens', 'totalTokens'];
// `durationMs` summiert die Laufzeit der Läufe mit bekanntem Ende, `timedTurns` zählt diese Läufe für den Durchschnitt.
export const COUNTERS = ['turns', 'failedTurns', 'images', 'imageBytes', 'contextChars', ...TOKEN_COUNTERS, 'durationMs', 'timedTurns'];
export const emptyCounters = () => Object.fromEntries(COUNTERS.map(name => [name, 0]));
export const dayKey = time => new Date(time).toISOString().slice(0, 10);
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const isPlainObject = value => !!value && typeof value === 'object' && !Array.isArray(value);
const isUsageFile = saved => isPlainObject(saved) && Object.entries(saved).every(([day, users]) =>
  DAY.test(day) && isPlainObject(users) && Object.values(users).every(isPlainObject));
/**
 * Ältere Dateien kennen `totalTokens` nicht. Codex rechnet ihn als inputTokens + outputTokens (der Cache steckt
 * schon in inputTokens), also wird er dort abgeleitet; Cache-Schreiben, Bildbytes, Kontext und Laufzeit bleiben 0.
 */
const upgrade = counters => Object.hasOwn(counters, 'totalTokens') ? counters
  : { ...counters, totalTokens: (Number.isSafeInteger(counters.inputTokens) ? counters.inputTokens : 0) + (Number.isSafeInteger(counters.outputTokens) ? counters.outputTokens : 0) };
const addTo = (target, delta) => {
  for (const name of COUNTERS) {
    const value = delta[name];
    if (Number.isSafeInteger(value)) target[name] = Math.max(0, target[name] + value);
  }
  return target;
};

/** Nur Zähler je Konto und UTC-Tag; bewusst kein Platz für Inhalte. */
export class Metering {
  constructor({ root, usageDays = 400, now = Date.now }) {
    this.file = path.join(path.resolve(root), 'metering.json');
    this.usageDays = usageDays; this.now = now; this.days = new Map();
    this.writer = new LatestWriter(this.file, () => JSON.stringify(Object.fromEntries(
      [...this.days].map(([day, users]) => [day, Object.fromEntries(users)]))));
  }
  async init() {
    let saved;
    try { saved = JSON.parse(await readFile(this.file, 'utf8')); } catch (error) {
      if (error.code === 'ENOENT') return this;
      throw new Error('Verbrauchsdatei ist unlesbar.');
    }
    if (!isUsageFile(saved)) throw new Error('Verbrauchsdatei ist unlesbar.');
    for (const [day, users] of Object.entries(saved)) {
      this.days.set(day, new Map(Object.entries(users).map(([id, counters]) => [id, addTo(emptyCounters(), upgrade(counters))])));
    }
    return this;
  }
  today() { return dayKey(this.now()); }
  /** `day` hält einen Lauf auf dem Tag seiner Reservierung, auch über Mitternacht. */
  add(userId, delta, day = this.today()) {
    if (!this.days.has(day)) this.days.set(day, new Map());
    const users = this.days.get(day);
    if (!users.has(userId)) users.set(userId, emptyCounters());
    addTo(users.get(userId), delta);
  }
  save() { return this.writer.save(); }
  flush() { return this.writer.flush(); }
  close() { return this.writer.close(); }
  /** Letzter Gesamtstand eines Laufs aus `tokenUsage.total` von thread/tokenUsage/updated. */
  static tokens(total) {
    return Object.fromEntries(TOKEN_COUNTERS.map(name => [name, total?.[name]]));
  }
  /** Zähler eines Kontos; `days` zählt den heutigen UTC-Tag mit, ohne Angabe gilt alles. */
  sum(userId, days) {
    const first = days === undefined ? '' : dayKey(this.now() - (days - 1) * DAY_MS);
    const result = emptyCounters();
    for (const [day, users] of this.days) if (day >= first && users.has(userId)) addTo(result, users.get(userId));
    return result;
  }
  /** Tagesreihe der letzten `days` UTC-Tage einschließlich heute: je Konto und gesamt, nur Tage mit Einträgen. */
  series(days) {
    const to = this.today();
    const from = dayKey(this.now() - (days - 1) * DAY_MS);
    const users = new Map();
    const total = { sum: emptyCounters(), days: {} };
    for (const [day, entries] of this.days) {
      if (day < from || day > to) continue;
      for (const [id, counters] of entries) {
        if (!users.has(id)) users.set(id, { sum: emptyCounters(), days: {} });
        const user = users.get(id);
        user.days[day] = addTo(emptyCounters(), counters);
        addTo(user.sum, counters);
        total.days[day] = addTo(total.days[day] ?? emptyCounters(), counters);
        addTo(total.sum, counters);
      }
    }
    return { from, to, users, total };
  }
  /** Alle Tage aufsteigend, je Konto, für den CSV-Export. */
  rows() {
    const rows = [];
    for (const day of [...this.days.keys()].sort()) for (const [id, counters] of this.days.get(day)) rows.push({ day, userId: id, counters: { ...counters } });
    return rows;
  }
  forToday(userId) { return { ...emptyCounters(), ...this.days.get(this.today())?.get(userId) }; }
  /** Heutige Zähler über alle Konten. */
  todayTotal() {
    const result = emptyCounters();
    for (const counters of this.days.get(this.today())?.values() ?? []) addTo(result, counters);
    return result;
  }
  async prune() {
    const first = dayKey(this.now() - this.usageDays * DAY_MS);
    let changed = false;
    for (const day of [...this.days.keys()]) if (day < first) { this.days.delete(day); changed = true; }
    if (changed) await this.save();
  }
}
