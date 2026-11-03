import { ApiError } from './store.mjs';
import { COUNTERS, dayKey } from './metering.mjs';
import { RUN_STATUSES, TOKEN_FIELDS, isUserId } from './runlog.mjs';

// Auswertungen für das Admin-Panel: ausschließlich Zähler, Zeitpunkte, Kennungen und Kontonamen.
export const MAX_USAGE_DAYS = 400;
export const MAX_RUNS_PAGE = 200;
const DEFAULT_USAGE_DAYS = 30;
const DEFAULT_RUNS_PAGE = 50;
export const EXPORT_TYPES = ['runs', 'daily'];

const invalid = text => new ApiError(400, text);

/** Nur bekannte Parameter, jeder höchstens einmal; alles andere ist 400. */
function readQuery(url, allowed) {
  const values = {};
  for (const [name, value] of url.searchParams) {
    if (!allowed.includes(name) || Object.hasOwn(values, name)) throw invalid('Ungültige Abfrage.');
    values[name] = value;
  }
  return values;
}
function integerParam(value, { min, max, fallback, digits, message }) {
  if (value === undefined) return fallback;
  if (!new RegExp(`^\\d{1,${digits}}$`).test(value)) throw invalid(message);
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < min || number > max) throw invalid(message);
  return number;
}

export function parseUsageQuery(url) {
  const { days } = readQuery(url, ['days']);
  return { days: integerParam(days, { min: 1, max: MAX_USAGE_DAYS, fallback: DEFAULT_USAGE_DAYS, digits: 3, message: `days muss eine ganze Zahl von 1 bis ${MAX_USAGE_DAYS} sein.` }) };
}

export function parseRunsQuery(url) {
  const { limit, before, user, status } = readQuery(url, ['limit', 'before', 'user', 'status']);
  if (user !== undefined && !isUserId(user)) throw invalid('Ungültige Kontokennung.');
  if (status !== undefined && !RUN_STATUSES.includes(status)) throw invalid('Ungültiger Status.');
  return {
    limit: integerParam(limit, { min: 1, max: MAX_RUNS_PAGE, fallback: DEFAULT_RUNS_PAGE, digits: 3, message: `limit muss eine ganze Zahl von 1 bis ${MAX_RUNS_PAGE} sein.` }),
    before: integerParam(before, { min: 1, max: Number.MAX_SAFE_INTEGER, fallback: undefined, digits: 16, message: 'before muss ein Zeitpunkt in Millisekunden sein.' }),
    user, status
  };
}

export function parseExportQuery(url) {
  const { type } = readQuery(url, ['type']);
  if (!EXPORT_TYPES.includes(type)) throw invalid('type muss runs oder daily sein.');
  return { type };
}

/** Tagesreihe je Konto und gesamt; Konten ohne Verbrauch stehen mit Nullen da, Tage ohne Einträge fehlen. */
export function buildUsage({ accounts, metering, days }) {
  const { from, to, users, total } = metering.series(days);
  const known = new Map(accounts.list().map(user => [user.id, user]));
  const empty = () => ({ sum: Object.fromEntries(COUNTERS.map(name => [name, 0])), days: {} });
  const ids = [...new Set([...known.keys(), ...users.keys()])];
  return {
    from, to, days,
    users: ids.map(id => {
      const account = known.get(id);
      return { id, name: account?.name ?? null, status: account?.status ?? null, role: account?.role ?? null, ...(users.get(id) ?? empty()) };
    }),
    total
  };
}

/* CSV: Semikolon, CRLF, UTF-8 mit BOM für Tabellenprogramme, deutsche Spaltennamen. */

/**
 * Felder mit Semikolon, Anführungszeichen, Zeilenumbruch oder Randleerzeichen stehen in Anführungszeichen.
 * Text, den ein Tabellenprogramm als Formel lesen würde, bekommt ein führendes Apostroph.
 */
export function csvCell(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'number') return Number.isFinite(value) ? String(value).replace('.', ',') : '';
  if (typeof value === 'boolean') return value ? 'ja' : 'nein';
  let text = String(value).toWellFormed();
  if (/^[=+\-@\t\r|%]/.test(text)) text = `'${text}`;
  return /[;"\r\n]/.test(text) || text !== text.trim() ? `"${text.replaceAll('"', '""')}"` : text;
}
export const csvTable = (header, rows) => `﻿${[header, ...rows].map(row => row.map(csvCell).join(';')).join('\r\n')}\r\n`;

const iso = time => (Number.isFinite(time) ? new Date(time).toISOString() : null);
const SLOT_LABEL = { primary: 'primär', secondary: 'sekundär' };
const quotaText = quota => quota?.flatMap(limit => limit.windows.map(window => [
  `${limit.id} ${SLOT_LABEL[window.slot]} ${String(window.usedPercent).replace('.', ',')} %`,
  window.windowDurationMins ? `Fenster ${window.windowDurationMins} min` : '',
  window.resetsAt ? `Reset ${iso(window.resetsAt * 1000)}` : ''
].filter(Boolean).join(', '))).join(' | ') || null;
const shareText = shares => shares?.map(share => `${share.id} ${SLOT_LABEL[share.slot]} +${String(share.points).replace('.', ',')} Punkte`).join(' | ') || null;

const TOKEN_HEADERS = ['Tokens rein', 'davon gecacht', 'Cache-Schreiben', 'Tokens raus', 'davon Reasoning', 'Tokens gesamt'];
export const RUNS_HEADER = ['Start (UTC)', 'Ende (UTC)', 'Tag (UTC)', 'Konto-ID', 'Name', 'Sitzungs-ID', 'Lauf-ID', 'Modell', 'Denkstufe', 'Status', 'Dauer (ms)', 'Parallel',
  'Bilder', 'Bildbytes', 'Kontextzeichen', 'Fragezeichen', 'Antwortzeichen', ...TOKEN_HEADERS, 'Kontingent danach', 'Kontingent davor', 'Anteil am Kontingent'];
export const DAILY_HEADER = ['Tag (UTC)', 'Konto-ID', 'Name', 'Läufe', 'Fehler', 'Bilder', 'Bildbytes', 'Kontextzeichen', ...TOKEN_HEADERS, 'Laufzeit (ms)', 'Läufe mit Dauer'];

export function exportCsv({ type, accounts, metering, runlog, now = Date.now() }) {
  const names = new Map(accounts.list().map(user => [user.id, user.name]));
  const stamp = dayKey(now);
  if (type === 'runs') {
    const rows = runlog.all().map(run => [iso(run.startedAt), iso(run.endedAt), run.day, run.userId, names.get(run.userId) ?? null, run.sessionId, run.id, run.model, run.effort,
      run.status, run.durationMs, run.parallel, run.images, run.imageBytes, run.contextChars, run.questionChars, run.answerChars,
      ...TOKEN_FIELDS.map(name => run.tokens[name]), quotaText(run.quota), quotaText(run.quotaBefore), shareText(run.quotaShare)]);
    return { filename: `noty-ki-laeufe-${stamp}.csv`, body: csvTable(RUNS_HEADER, rows) };
  }
  const order = ['turns', 'failedTurns', 'images', 'imageBytes', 'contextChars', ...TOKEN_FIELDS, 'durationMs', 'timedTurns'];
  const rows = metering.rows().map(({ day, userId, counters }) => [day, userId, names.get(userId) ?? null, ...order.map(name => counters[name])]);
  return { filename: `noty-ki-tage-${stamp}.csv`, body: csvTable(DAILY_HEADER, rows) };
}
