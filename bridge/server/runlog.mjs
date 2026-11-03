import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { DAY_MS, LatestWriter } from './store.mjs';

// Laufprotokoll: je Lauf genau ein Eintrag aus Zahlen, Zeitpunkten und Kennungen. Bewusst ohne Platz
// für Frage, Antwort, Kontext, Kontextnamen, Bilder oder Bildnamen, auch nicht gekürzt oder gehasht.
export const RUN_STATUSES = ['running', 'completed', 'failed', 'interrupted', 'timeout', 'restarted'];
export const FAILED_STATUSES = ['failed', 'timeout', 'restarted'];
export const TOKEN_FIELDS = ['inputTokens', 'cachedInputTokens', 'cacheWriteInputTokens', 'outputTokens', 'reasoningOutputTokens', 'totalTokens'];
export const MAX_RUN_ENTRIES = 5000;
const COUNT_FIELDS = ['images', 'imageBytes', 'contextChars', 'questionChars', 'answerChars'];
const SLOTS = ['primary', 'secondary'];
const MAX_LIMITS = 8;
// Token- und Kontingentstände kommen mehrmals je Lauf; die Datei wird dafür höchstens alle 5 Sekunden geschrieben.
const UPDATE_SAVE_MS = 5000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
export const MODEL = /^[a-zA-Z0-9._:-]{1,100}$/;
export const EFFORT = /^[a-z0-9_-]{1,32}$/;
const LIMIT_ID = /^[A-Za-z0-9._:-]{1,64}$/;
const MAX_USER_ID_CHARS = 200;

const isPlainObject = value => !!value && typeof value === 'object' && !Array.isArray(value);
const isCount = value => Number.isSafeInteger(value) && value >= 0;
const isTime = value => Number.isSafeInteger(value) && value > 0;
const isOptional = (value, check) => value === null || check(value);
export const isUserId = value => typeof value === 'string' && value.length > 0 && value.length <= MAX_USER_ID_CHARS && value.isWellFormed();
export const emptyTokens = () => Object.fromEntries(TOKEN_FIELDS.map(name => [name, 0]));

/** Ein Fenster des Abo-Kontingents; Prozent sind von Codex ganzzahlig, Kommazahlen bleiben erlaubt. */
function cleanWindow(slot, window) {
  if (!isPlainObject(window) || !Number.isFinite(window.usedPercent) || window.usedPercent < 0 || window.usedPercent > 1000) return null;
  return {
    slot, usedPercent: window.usedPercent,
    windowDurationMins: Number.isSafeInteger(window.windowDurationMins) && window.windowDurationMins > 0 ? window.windowDurationMins : null,
    resetsAt: Number.isSafeInteger(window.resetsAt) && window.resetsAt > 0 ? window.resetsAt : null
  };
}

/**
 * Führt einen Codex-Kontingentstand (`RateLimitSnapshot`) in die bisherige Liste ein. Die Meldungen sind
 * spärlich: fehlende oder `null`-Fenster lassen den bekannten Wert stehen. Namen, Credits und Tarif bleiben draußen.
 */
export function mergeQuota(previous, snapshot) {
  if (!isPlainObject(snapshot)) return previous;
  const id = typeof snapshot.limitId === 'string' && LIMIT_ID.test(snapshot.limitId) ? snapshot.limitId : 'codex';
  const windows = SLOTS.map(slot => cleanWindow(slot, snapshot[slot])).filter(Boolean);
  if (!windows.length) return previous;
  const list = (previous ?? []).map(limit => ({ ...limit, windows: [...limit.windows] }));
  let limit = list.find(entry => entry.id === id);
  if (!limit) {
    if (list.length >= MAX_LIMITS) return previous;
    limit = { id, windows: [] };
    list.push(limit);
  }
  for (const window of windows) {
    const at = limit.windows.findIndex(entry => entry.slot === window.slot);
    if (at >= 0) limit.windows[at] = window; else limit.windows.push(window);
  }
  limit.windows.sort((a, b) => SLOTS.indexOf(a.slot) - SLOTS.indexOf(b.slot));
  return list;
}

/** Stand aus `account/rateLimits/read`: alle Buckets, sonst der Einzelstand. */
export function quotaFromRead(response) {
  let quota = null;
  const mapped = isPlainObject(response?.rateLimitsByLimitId) ? Object.entries(response.rateLimitsByLimitId) : [];
  for (const [key, snapshot] of mapped) if (isPlainObject(snapshot)) quota = mergeQuota(quota, { ...snapshot, limitId: snapshot.limitId ?? key });
  if (!quota && isPlainObject(response?.rateLimits)) quota = mergeQuota(quota, response.rateLimits);
  return quota;
}

const isWindow = window => isPlainObject(window) && SLOTS.includes(window.slot) && Number.isFinite(window.usedPercent) && window.usedPercent >= 0 && window.usedPercent <= 1000
  && isOptional(window.windowDurationMins, isTime) && isOptional(window.resetsAt, isTime);
const isQuota = quota => quota === null || (Array.isArray(quota) && quota.length <= MAX_LIMITS && quota.every(limit => isPlainObject(limit)
  && typeof limit.id === 'string' && LIMIT_ID.test(limit.id) && Array.isArray(limit.windows) && limit.windows.length <= SLOTS.length && limit.windows.every(isWindow)));

/** Vollständige Prüfung eines Eintrags; unbekannte Felder werden beim Laden verworfen, nicht übernommen. */
export function isRunEntry(entry) {
  return isPlainObject(entry) && typeof entry.id === 'string' && UUID.test(entry.id) && isUserId(entry.userId)
    && typeof entry.sessionId === 'string' && UUID.test(entry.sessionId) && typeof entry.day === 'string' && DAY.test(entry.day)
    && isTime(entry.startedAt) && isOptional(entry.endedAt, isTime) && isOptional(entry.durationMs, isCount)
    && RUN_STATUSES.includes(entry.status) && isOptional(entry.model, value => typeof value === 'string' && MODEL.test(value))
    && isOptional(entry.effort, value => typeof value === 'string' && EFFORT.test(value)) && typeof entry.parallel === 'boolean'
    && COUNT_FIELDS.every(name => isCount(entry[name])) && isPlainObject(entry.tokens) && TOKEN_FIELDS.every(name => isCount(entry.tokens[name]))
    && isQuota(entry.quotaBefore) && isQuota(entry.quota);
}

const cloneQuota = quota => quota === null ? null : quota.map(limit => ({ id: limit.id, windows: limit.windows.map(({ slot, usedPercent, windowDurationMins, resetsAt }) => ({ slot, usedPercent, windowDurationMins, resetsAt })) }));
/** Baut einen Eintrag nur aus bekannten Feldern neu auf. */
function cleanEntry(entry) {
  return {
    id: entry.id, userId: entry.userId, sessionId: entry.sessionId, day: entry.day, startedAt: entry.startedAt, endedAt: entry.endedAt,
    durationMs: entry.durationMs, status: entry.status, model: entry.model, effort: entry.effort, parallel: entry.parallel,
    ...Object.fromEntries(COUNT_FIELDS.map(name => [name, entry[name]])),
    tokens: Object.fromEntries(TOKEN_FIELDS.map(name => [name, entry.tokens[name]])),
    quotaBefore: cloneQuota(entry.quotaBefore), quota: cloneQuota(entry.quota)
  };
}

/**
 * Anteil eines Laufs am Kontingent in Prozentpunkten, je Fenster. Nur ableitbar, wenn der Stand vor und
 * nach dem Lauf vorliegt, dasselbe Fenster meint (gleicher Reset) und kein anderer Lauf parallel lief.
 * Fremde Nutzung desselben Abos außerhalb der Bridge kann trotzdem mitzählen.
 */
export function quotaShare(entry) {
  if (!entry.quotaBefore || !entry.quota || entry.parallel) return null;
  const shares = [];
  for (const limit of entry.quota) {
    const before = entry.quotaBefore.find(other => other.id === limit.id);
    for (const window of limit.windows) {
      const earlier = before?.windows.find(other => other.slot === window.slot);
      if (!earlier || earlier.resetsAt !== window.resetsAt || earlier.windowDurationMins !== window.windowDurationMins || window.usedPercent < earlier.usedPercent) continue;
      shares.push({ id: limit.id, slot: window.slot, points: Math.round((window.usedPercent - earlier.usedPercent) * 1000) / 1000 });
    }
  }
  return shares.length ? shares : null;
}

/** Atomar geschrieben (Modus 600), höchstens `maxEntries` und nicht älter als `usageDays`. */
export class RunLog {
  constructor({ root, usageDays = 400, maxEntries = MAX_RUN_ENTRIES, now = Date.now, updateSaveMs = UPDATE_SAVE_MS }) {
    this.file = path.join(path.resolve(root), 'runs.json');
    Object.assign(this, { usageDays, maxEntries, now, updateSaveMs });
    this.entries = []; this.lastStart = 0; this.timer = null;
    this.writer = new LatestWriter(this.file, () => JSON.stringify(this.entries));
  }
  /** Wie metering.json: Eine unlesbare oder falsch geformte Datei stoppt den Start, statt still verloren zu gehen. */
  async init() {
    let saved;
    try { saved = JSON.parse(await readFile(this.file, 'utf8')); } catch (error) {
      if (error.code === 'ENOENT') return this;
      throw new Error('Laufprotokoll ist unlesbar.');
    }
    if (!Array.isArray(saved) || !saved.every(isRunEntry)) throw new Error('Laufprotokoll ist unlesbar.');
    const ids = new Set();
    let changed = false;
    for (const entry of saved.map(cleanEntry)) {
      if (ids.has(entry.id)) { changed = true; continue; }
      ids.add(entry.id);
      // Ein Lauf, der beim Beenden noch lief: Prozess abgestürzt, das Ende ist unbekannt.
      if (entry.status === 'running') { Object.assign(entry, { status: 'restarted', endedAt: null, durationMs: null }); changed = true; }
      this.entries.push(entry);
    }
    this.entries.sort((a, b) => a.startedAt - b.startedAt);
    this.lastStart = this.entries.at(-1)?.startedAt ?? 0;
    changed = this.trim() || changed;
    if (changed) await this.save().catch(() => {});
    return this;
  }
  /** Entfernt das Älteste über den Grenzen; liefert, ob sich etwas geändert hat. */
  trim() {
    const first = this.now() - this.usageDays * DAY_MS;
    const before = this.entries.length;
    this.entries = this.entries.filter(entry => entry.startedAt >= first || entry.status === 'running');
    if (this.entries.length > this.maxEntries) this.entries.splice(0, this.entries.length - this.maxEntries);
    return this.entries.length !== before;
  }
  /** Neuer Eintrag mit Status `running`; `startedAt` ist eindeutig und steigt streng, damit `before=` sauber blättert. */
  start({ userId, sessionId, day, model = null, effort = null, parallel = false, images = 0, imageBytes = 0, contextChars = 0, questionChars = 0 }) {
    const startedAt = Math.max(this.now(), this.lastStart + 1);
    this.lastStart = startedAt;
    const entry = { id: randomUUID(), userId, sessionId, day, startedAt, endedAt: null, durationMs: null, status: 'running',
      model, effort, parallel, images, imageBytes, contextChars, questionChars, answerChars: 0, tokens: emptyTokens(), quotaBefore: null, quota: null };
    this.entries.push(entry);
    this.trim();
    this.save().catch(() => {});
    return entry;
  }
  /** Zwischenstände wie Tokens; geschrieben wird gebündelt. */
  touch() {
    if (this.timer) return;
    this.timer = setTimeout(() => { this.timer = null; this.save().catch(() => {}); }, this.updateSaveMs);
    this.timer.unref();
  }
  /** Schließt einen Eintrag ab und liefert die Dauer in Millisekunden. */
  finish(entry, status, fields = {}, endedAt = this.now()) {
    if (entry.status !== 'running') return entry.durationMs;
    Object.assign(entry, fields);
    entry.status = status;
    entry.endedAt = Math.max(endedAt, entry.startedAt);
    entry.durationMs = entry.endedAt - entry.startedAt;
    this.save().catch(() => {});
    return entry.durationMs;
  }
  /** Neueste zuerst; `before` ist exklusiv, `next` der Wert für die nächste Seite oder null. */
  list({ limit = 50, before, user, status } = {}) {
    const result = [];
    for (let at = this.entries.length - 1; at >= 0 && result.length <= limit; at--) {
      const entry = this.entries[at];
      if (before !== undefined && entry.startedAt >= before) continue;
      if (user !== undefined && entry.userId !== user) continue;
      if (status !== undefined && entry.status !== status) continue;
      result.push(entry);
    }
    const more = result.length > limit;
    const runs = result.slice(0, limit).map(entry => ({ ...cleanEntry(entry), quotaShare: quotaShare(entry) }));
    return { runs, next: more ? runs.at(-1).startedAt : null };
  }
  /** Alle Einträge, neueste zuerst, für den CSV-Export. */
  all() { return this.entries.map(entry => ({ ...cleanEntry(entry), quotaShare: quotaShare(entry) })).reverse(); }
  async prune() { if (this.trim()) await this.save(); }
  save() { clearTimeout(this.timer); this.timer = null; return this.writer.save(); }
  flush() { if (this.timer) this.save().catch(() => {}); return this.writer.flush(); }
  close() { clearTimeout(this.timer); this.timer = null; this.save().catch(() => {}); return this.writer.close(); }
}
