import { readFileSync, renameSync, writeFileSync } from 'node:fs';

const KEY = /^[a-f0-9]{64}$/;
const SAVE_MS = 30_000;

/**
 * Merkt sich SHA-256-Werte bewährter Sitzungen, nie die Schlüssel selbst. Eine Flut soll Rückkehrer
 * auch nach Neustart oder langer Pause nicht aussperren. Nur ein Puffer: Geht die Datei verloren,
 * gelten Tokens zunächst als unbekannt.
 */
export class KnownSessions {
  constructor({ file = null, ttlMs, maxEntries, saveMs = SAVE_MS, now = Date.now }) {
    Object.assign(this, { file, ttlMs, maxEntries, saveMs, now });
    this.entries = this.load();
    this.timer = null;
  }
  load() {
    if (!this.file) return new Map();
    try {
      const stored = Object.entries(JSON.parse(readFileSync(this.file, 'utf8')));
      const now = this.now();
      return new Map(stored.filter(([key, until]) => KEY.test(key) && Number.isFinite(until) && until > now).slice(-this.maxEntries));
    } catch { return new Map(); }
  }
  has(key) { return (this.entries.get(key) ?? 0) > this.now(); }
  add(key) {
    this.entries.delete(key);
    while (this.entries.size >= this.maxEntries) this.entries.delete(this.entries.keys().next().value);
    this.entries.set(key, this.now() + this.ttlMs);
    this.schedule();
  }
  remove(key) { if (this.entries.delete(key)) this.schedule(); }
  schedule() {
    if (!this.file || this.timer) return;
    this.timer = setTimeout(() => { this.timer = null; this.save(); }, this.saveMs);
    this.timer.unref?.();
  }
  save() {
    const temporary = `${this.file}.tmp`;
    try {
      writeFileSync(temporary, JSON.stringify(Object.fromEntries(this.entries)), { mode: 0o600 });
      renameSync(temporary, this.file);
    } catch { /* Beim nächsten Eintrag neuer Versuch; ohne Puffer greift nur die strengere Drossel. */ }
  }
}
