'use strict';

// Alle Werte gehen über textContent oder Attribute ins DOM, nie als Markup.
const REFRESH_MS = 15_000;
const LIMIT_MAX = 1_000_000;
const TIGHT_PERCENT = 90;
const STATUS_LABEL = { active: 'Aktiv', pending: 'Wartet', blocked: 'Gesperrt' };
const STATUS_ORDER = { pending: 0, active: 1, blocked: 2 };
const ROLE_LABEL = { admin: 'Admin', user: 'Nutzer' };
const USAGE_COLUMNS = [['today', 'Heute'], ['last7', '7 Tage'], ['last30', '30 Tage'], ['total', 'Gesamt']];
// Ergebnisse des Apple-Rücksprungs, siehe APPLE_RESULTS in server/admin.mjs.
const APPLE_RESULTS = {
  abgelehnt: 'Mit diesem Apple-Konto ist keine Anmeldung möglich.',
  abgelaufen: 'Die Anmeldung mit Apple ist abgelaufen oder wurde in einem anderen Browser begonnen. Bitte erneut versuchen.',
  abgebrochen: 'Die Anmeldung mit Apple wurde abgebrochen.',
  gesperrt: 'Zu viele Anmeldeversuche. Bitte in 15 Minuten erneut versuchen.',
  'nicht-erreichbar': 'Das Konto-Backend ist nicht erreichbar.',
  ungueltig: 'Die Antwort von Apple war ungültig. Bitte erneut versuchen.'
};

const integer = new Intl.NumberFormat('de-DE');
// Zähler immer exakt mit Tausendertrennzeichen; nur Durchschnitte und Quoten haben eine Nachkommastelle.
const decimal = new Intl.NumberFormat('de-DE', { maximumFractionDigits: 1 });
const percent = new Intl.NumberFormat('de-DE', { maximumFractionDigits: 1 });
const moment = new Intl.DateTimeFormat('de-DE', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
const clock = new Intl.DateTimeFormat('de-DE', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
const stamp = new Intl.DateTimeFormat('de-DE', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' });
const dayLabel = new Intl.DateTimeFormat('de-DE', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });

const $ = id => document.getElementById(id);
const state = {
  signedIn: false, data: null, editing: null, busy: false, loading: false, reload: false, timer: null, notice: '',
  days: 7, usage: null, history: [], runs: { items: [], next: null, pages: 0, loading: false, generation: 0 }
};

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(props)) {
    if (name === 'class') node.className = value;
    else if (name === 'text') node.textContent = value;
    else if (name === 'data') Object.assign(node.dataset, value);
    else if (name === 'on') for (const [event, handler] of Object.entries(value)) node.addEventListener(event, handler);
    else node[name] = value;
  }
  node.append(...children.filter(Boolean));
  return node;
}

function show(node, text) {
  node.textContent = text ?? '';
  node.hidden = !text;
}

class SignedOut extends Error {}

async function api(path, { method = 'GET', body } = {}) {
  let response;
  try {
    response = await fetch(path, {
      method,
      credentials: 'same-origin',
      headers: method === 'GET' ? {} : { 'Content-Type': 'application/json' },
      body: method === 'GET' ? undefined : JSON.stringify(body ?? {})
    });
  } catch {
    throw new Error('Der Server ist nicht erreichbar.');
  }
  if (response.status === 204) return null;
  const data = await response.json().catch(() => null);
  if (response.ok) return data;
  const message = data?.error ?? `Unerwartete Antwort (${response.status}).`;
  if (response.status === 401 && path !== '/admin/api/login') throw new SignedOut(message);
  throw new Error(message);
}

/* Anzeige */

const plural = (count, one, many) => `${integer.format(count)}\u00a0${count === 1 ? one : many}`;

function windowName(minutes) {
  if (!minutes) return 'Fenster';
  if (minutes % 1440 === 0) return plural(minutes / 1440, 'Tag', 'Tage');
  if (minutes % 60 === 0) return plural(minutes / 60, 'Stunde', 'Stunden');
  return plural(minutes, 'Minute', 'Minuten');
}

function usageDetail(counters) {
  return [
    counters.failedTurns ? plural(counters.failedTurns, 'Fehler', 'Fehler') : '',
    counters.images ? plural(counters.images, 'Bild', 'Bilder') : ''
  ].filter(Boolean).join(' · ');
}

function tokenLine(counters) {
  if (!counters.inputTokens && !counters.outputTokens) return '';
  const part = (value, label) => `${integer.format(value)} ${label}`.replaceAll(' ', '\u00a0');
  return `${part(counters.inputTokens, 'rein')} · ${part(counters.outputTokens, 'raus')}`;
}

function usageTitle(counters) {
  return `Tokens rein ${integer.format(counters.inputTokens)}, davon aus dem Cache ${integer.format(counters.cachedInputTokens)}, Cache-Schreiben ${integer.format(counters.cacheWriteInputTokens ?? 0)}; `
    + `raus ${integer.format(counters.outputTokens)}, davon Reasoning ${integer.format(counters.reasoningOutputTokens)}; gesamt ${integer.format(counters.totalTokens ?? 0)}`;
}

function renderPlan(plan) {
  const windows = (plan?.limits ?? []).flatMap(limit => limit.windows.map(window => ({ limit, window })));
  if (!windows.length) {
    $('plan').replaceChildren(el('p', { class: 'muted', text: plan ? 'Keine Kontingentdaten vorhanden.' : 'Gerade nicht abrufbar.' }));
    return;
  }
  $('plan').replaceChildren(...windows.map(({ limit, window }) => {
    const used = Math.min(100, Math.max(0, window.usedPercent));
    const tight = used >= TIGHT_PERCENT;
    const reset = window.resetsAt ? `Neu ab ${moment.format(new Date(window.resetsAt * 1000))}` : 'Reset-Zeit unbekannt';
    return el('div', { class: tight ? 'window tight' : 'window' },
      el('div', { class: 'window-head' },
        el('span', { text: `${limit.name}, ${windowName(window.windowDurationMins)}` }),
        el('span', { text: `${percent.format(window.usedPercent)} % verbraucht` })),
      el('progress', { max: 100, value: used, ariaLabel: `${limit.name}, ${windowName(window.windowDurationMins)}` }),
      el('span', { class: 'muted', text: tight ? `Fast aufgebraucht. ${reset}` : reset }));
  }));
}

function renderSummary(data) {
  const signedIn = data.account === 'chatgpt';
  const account = $('codex-account');
  account.textContent = signedIn ? 'ChatGPT' : 'Nicht angemeldet oder nicht erreichbar';
  account.className = signedIn ? 'value good' : 'value bad';
  $('running').textContent = integer.format(data.running);
  $('today').textContent = plural(data.today.turns, 'Lauf', 'Läufe');
  const tokens = tokenLine(data.today);
  const detail = [plural(data.today.failedTurns, 'Fehler', 'Fehler'), plural(data.today.images, 'Bild', 'Bilder'), tokens && `Tokens ${tokens}`].filter(Boolean);
  $('today-detail').textContent = detail.join(' · ');
  $('today-detail').title = usageTitle(data.today);
}

function limitCell(user) {
  const value = integer.format(user.effectiveDailyLimit);
  if (user.dailyLimit === null) return [value, 'Standard'];
  return user.effectiveDailyLimit === 0 ? [value, 'keine Läufe'] : [value, 'eigenes Limit'];
}

const editing = (user, mode) => state.editing?.id === user.id && state.editing.mode === mode;

async function change(user, patch) {
  if (state.busy) return;
  state.busy = true; state.editing = null;
  show($('banner'));
  try {
    await api(`/admin/api/users/${encodeURIComponent(user.id)}`, { method: 'PATCH', body: patch });
  } catch (error) {
    if (error instanceof SignedOut) { signedOut(error.message); return; }
    show($('banner'), `${user.name}: ${error.message}`);
  } finally {
    state.busy = false;
  }
  await refresh();
}

function edit(next) {
  state.editing = next;
  renderUsers();
  document.querySelector('[data-autofocus]')?.focus();
}

function limitForm(user) {
  const inputId = `limit-${user.id}`;
  const input = el('input', { id: inputId, type: 'number', min: 0, max: LIMIT_MAX, step: 1, inputMode: 'numeric', placeholder: 'Standard', value: user.dailyLimit ?? '', data: { autofocus: '' } });
  const submit = event => {
    event.preventDefault();
    const text = input.value.trim();
    const limit = text === '' ? null : Number(text);
    if (input.validity.badInput || (limit !== null && (!Number.isInteger(limit) || limit < 0 || limit > LIMIT_MAX))) {
      show($('banner'), `Das Limit muss eine ganze Zahl von 0 bis ${integer.format(LIMIT_MAX)} sein.`);
      return;
    }
    change(user, { dailyLimit: limit });
  };
  return el('form', { class: 'limit-form', noValidate: true, on: { submit } },
    el('label', { htmlFor: inputId, text: 'Limit je Tag, leer = Standard, 0 = keine Läufe und laufende abbrechen' }),
    input,
    el('div', { class: 'limit-buttons' },
      el('button', { type: 'submit', class: 'primary', text: 'Speichern' }),
      el('button', { type: 'button', text: 'Abbrechen', on: { click: () => edit(null) } })));
}

function actions(user) {
  if (editing(user, 'limit')) return limitForm(user);
  if (editing(user, 'block')) {
    return el('div', { class: 'actions' },
      el('span', { class: 'confirm-text', text: 'Sperren? Laufende Läufe brechen sofort ab.' }),
      el('button', { type: 'button', class: 'danger', text: 'Ja, sperren', data: { autofocus: '' }, on: { click: () => change(user, { status: 'blocked' }) } }),
      el('button', { type: 'button', text: 'Abbrechen', on: { click: () => edit(null) } }));
  }
  const admin = user.role === 'admin';
  return el('div', { class: 'actions' },
    user.status !== 'active' && el('button', { type: 'button', class: 'primary', text: 'Freischalten', on: { click: () => change(user, { status: 'active' }) } }),
    el('button', {
      type: 'button', text: 'Sperren',
      disabled: admin || user.status === 'blocked',
      title: admin ? 'Admins lassen sich nicht sperren.' : user.status === 'blocked' ? 'Dieses Konto ist schon gesperrt.' : '',
      on: { click: () => edit({ id: user.id, mode: 'block' }) }
    }),
    el('button', { type: 'button', text: 'Limit setzen', on: { click: () => edit({ id: user.id, mode: 'limit' }) } }));
}

function userRow(user) {
  const [limit, limitNote] = limitCell(user);
  const usage = USAGE_COLUMNS.map(([field, label]) => {
    const counters = user[field];
    const detail = usageDetail(counters);
    const tokens = tokenLine(counters);
    return el('td', { class: 'cell-usage', title: usageTitle(counters), data: { label } },
      el('span', { class: 'lines', text: plural(counters.turns, 'Lauf', 'Läufe') }),
      detail && el('span', { class: 'lines muted', text: detail }),
      tokens && el('span', { class: 'lines muted', text: tokens }));
  });
  return el('tr', {},
    el('td', { class: 'cell-name', text: user.name || user.id }),
    el('td', { data: { label: 'Status' } }, el('span', { class: `badge ${user.status}`, text: STATUS_LABEL[user.status] ?? user.status })),
    el('td', { text: ROLE_LABEL[user.role] ?? user.role, data: { label: 'Rolle' } }),
    el('td', { data: { label: 'Limit' } }, el('span', { class: 'lines', text: limit }), el('span', { class: 'lines muted', text: limitNote })),
    ...usage,
    el('td', { class: 'cell-seen', text: user.lastSeenAt ? moment.format(new Date(user.lastSeenAt)) : 'noch nie', data: { label: 'Zuletzt aktiv' } }),
    el('td', { class: 'cell-actions' }, actions(user)));
}

function renderUsers() {
  const users = [...state.data.users].sort((a, b) => (STATUS_ORDER[a.status] ?? 3) - (STATUS_ORDER[b.status] ?? 3) || (b.lastSeenAt ?? 0) - (a.lastSeenAt ?? 0));
  $('users-body').replaceChildren(...users.map(userRow));
  $('users-empty').hidden = users.length > 0;
  $('users-wrap').hidden = users.length === 0;
}

/* Auswertung: Zeitraum, Kennzahlen je Konto, Tagesbalken, Laufprotokoll, Kontingentverlauf */

const RUN_STATUS_LABEL = { running: 'Läuft', completed: 'Fertig', failed: 'Fehler', interrupted: 'Abgebrochen', timeout: 'Zeitlimit', restarted: 'Neustart' };
const SLOT_LABEL = { primary: 'primär', secondary: 'sekundär' };
const RUNS_PAGE = 25;
const HISTORY_RUNS = 100;
const HISTORY_ROWS = 12;
const DENSE_BARS = 100;
const DAY_MS = 86_400_000;
const dash = '–';

const bytes = value => `${integer.format(value)}\u00a0B`;
const duration = ms => (Number.isFinite(ms) ? `${decimal.format(ms / 1000)}\u00a0s` : dash);
const ratio = (part, whole) => (whole > 0 ? `${percent.format(part / whole * 100)}\u00a0%` : dash);
const average = (sum, count) => (count > 0 ? decimal.format(sum / count) : dash);
const userName = id => state.data?.users.find(user => user.id === id)?.name || id;
const limitName = id => state.data?.plan?.limits.find(limit => limit.id === id)?.name ?? (id === 'codex' ? 'Codex' : id);

/** Kennzahlen eines Zählerstands in Tabellenreihenfolge. */
function metrics(counters) {
  return [
    ['Läufe', integer.format(counters.turns)],
    ['Fehler', integer.format(counters.failedTurns)],
    ['Bilder', integer.format(counters.images), counters.imageBytes ? bytes(counters.imageBytes) : ''],
    ['Tokens rein', integer.format(counters.inputTokens)],
    ['davon gecacht', integer.format(counters.cachedInputTokens)],
    ['Cache-Schreiben', integer.format(counters.cacheWriteInputTokens)],
    ['Tokens raus', integer.format(counters.outputTokens)],
    ['davon Reasoning', integer.format(counters.reasoningOutputTokens)],
    ['Tokens gesamt', integer.format(counters.totalTokens)],
    ['Ø Tokens je Lauf', average(counters.totalTokens, counters.turns)],
    ['Ø Dauer', counters.timedTurns ? duration(counters.durationMs / counters.timedTurns) : dash],
    ['Cache-Quote', ratio(counters.cachedInputTokens, counters.inputTokens)]
  ];
}

function statsRow(label, counters, total = false) {
  return el('tr', { class: total ? 'total' : '' },
    el('th', { scope: 'row', class: 'cell-name', text: label }),
    ...metrics(counters).map(([name, value, detail]) => el('td', { class: 'num', data: { label: name } },
      el('span', { class: 'lines', text: value }), detail && el('span', { class: 'lines muted', text: detail }))));
}

function renderStats() {
  const usage = state.usage;
  if (!usage) return;
  const active = usage.users.filter(user => user.sum.turns > 0 || user.sum.totalTokens > 0)
    .sort((a, b) => b.sum.totalTokens - a.sum.totalTokens || b.sum.turns - a.sum.turns || String(a.name ?? a.id).localeCompare(String(b.name ?? b.id), 'de'));
  $('stats-body').replaceChildren(statsRow('Alle Konten', usage.total.sum, true), ...active.map(user => statsRow(user.name || user.id, user.sum)));
  const from = dayLabel.format(new Date(`${usage.from}T00:00:00Z`));
  const to = dayLabel.format(new Date(`${usage.to}T00:00:00Z`));
  $('range').textContent = usage.from === usage.to ? `${to}, UTC` : `${from} bis ${to}, UTC`;
}

/** Alle UTC-Tage des Zeitraums, auch ohne Einträge. */
function dayList(from, to) {
  const days = [];
  for (let time = Date.parse(`${from}T00:00:00Z`); time <= Date.parse(`${to}T00:00:00Z`); time += DAY_MS) days.push(new Date(time).toISOString().slice(0, 10));
  return days;
}

/** Balken als Elemente mit Höhenklasse h0 bis h100 aus app.css; keine Inline-Styles, die CSP bleibt streng. */
function renderChart(name, days, series, field, unit) {
  const values = days.map(day => series.days[day]?.[field] ?? 0);
  const max = Math.max(0, ...values);
  const plot = $(`chart-${name}`);
  plot.className = values.length > DENSE_BARS ? 'chart-plot dense' : 'chart-plot';
  const describe = index => {
    const counters = series.days[days[index]];
    const extra = field === 'turns' && counters?.failedTurns ? `, davon ${plural(counters.failedTurns, 'Fehler', 'Fehler')}` : '';
    return `${dayLabel.format(new Date(`${days[index]}T00:00:00Z`))}: ${integer.format(values[index])} ${unit}${extra}`;
  };
  plot.replaceChildren(...values.map((value, index) => {
    const level = value === 0 || max === 0 ? 0 : Math.max(1, Math.round(value / max * 100));
    // Die ganze Spalte ist Trefferfläche, auch über niedrigen Balken.
    return el('span', { class: 'col', title: describe(index), data: { index: String(index) } }, el('span', { class: `fill h${level}` }));
  }));
  plot.ariaLabel = `${$(`chart-${name}-title`).textContent} je Tag, höchstens ${integer.format(max)} ${unit}`;
  plot.describe = describe;
  $(`chart-${name}-max`).textContent = `höchstens ${integer.format(max)}`;
  $(`chart-${name}-from`).textContent = days.length ? dayLabel.format(new Date(`${days[0]}T00:00:00Z`)) : '';
  $(`chart-${name}-to`).textContent = days.length > 1 ? dayLabel.format(new Date(`${days.at(-1)}T00:00:00Z`)) : '';
  $(`chart-${name}-detail`).textContent = 'Balken antippen oder darüberfahren für den Tageswert.';
}

/** Zeigt den Wert des berührten Balkens unter dem Diagramm; auch per Antippen auf dem iPad. */
function pointAt(name, target) {
  const plot = $(`chart-${name}`);
  const column = target?.closest?.('[data-index]');
  if (!column || !plot.describe) return;
  for (const other of plot.querySelectorAll('.col.active')) other.classList.remove('active');
  column.classList.add('active');
  const index = column.dataset.index;
  $(`chart-${name}-detail`).textContent = plot.describe(Number(index));
}

function renderCharts() {
  const usage = state.usage;
  if (!usage) return;
  const wanted = $('chart-user').value;
  const series = wanted ? usage.users.find(user => user.id === wanted) ?? { days: {} } : usage.total;
  const days = dayList(usage.from, usage.to);
  renderChart('tokens', days, series, 'totalTokens', 'Tokens');
  renderChart('turns', days, series, 'turns', 'Läufe');
}

/** Auswahllisten der Konten; die gewählte Auswahl bleibt bei jeder Aktualisierung stehen. */
function fillUserSelect(select) {
  const current = select.value;
  const users = [...(state.data?.users ?? [])].sort((a, b) => String(a.name || a.id).localeCompare(String(b.name || b.id), 'de'));
  select.replaceChildren(el('option', { value: '', text: 'Alle Konten' }), ...users.map(user => el('option', { value: user.id, text: user.name || user.id })));
  select.value = users.some(user => user.id === current) ? current : '';
}

function quotaLines(run) {
  if (!run.quota) return [el('span', { class: 'lines muted', text: 'nicht gemeldet' })];
  return run.quota.flatMap(limit => limit.windows.map(window => {
    const share = run.quotaShare?.find(entry => entry.id === limit.id && entry.slot === window.slot);
    const name = `${limitName(limit.id)}, ${window.windowDurationMins ? windowName(window.windowDurationMins) : SLOT_LABEL[window.slot]}`;
    return el('span', { class: 'lines', text: `${name}: ${percent.format(window.usedPercent)}\u00a0%${share ? ` (+${percent.format(share.points)})` : ''}` });
  }));
}

function runRow(run) {
  const tokens = run.tokens;
  return el('tr', {},
    el('td', { data: { label: 'Start' } }, el('span', { class: 'lines', text: stamp.format(new Date(run.startedAt)) }),
      run.endedAt && el('span', { class: 'lines muted', text: `Ende ${clock.format(new Date(run.endedAt))}` })),
    el('td', { class: 'cell-name', data: { label: 'Konto' }, text: userName(run.userId) }),
    el('td', { data: { label: 'Modell' } }, el('span', { class: 'lines', text: run.model ?? dash }), run.effort && el('span', { class: 'lines muted', text: `Denkstufe ${run.effort}` })),
    el('td', { data: { label: 'Status' } }, el('span', { class: `badge run-${run.status}`, text: RUN_STATUS_LABEL[run.status] ?? run.status }),
      run.parallel && el('span', { class: 'lines muted', text: 'parallel' })),
    el('td', { class: 'num', data: { label: 'Dauer' }, text: duration(run.durationMs) }),
    el('td', { class: 'num', data: { label: 'Bilder' } }, el('span', { class: 'lines', text: integer.format(run.images) }), run.imageBytes > 0 && el('span', { class: 'lines muted', text: bytes(run.imageBytes) })),
    el('td', { class: 'num', data: { label: 'Zeichen' } },
      el('span', { class: 'lines', text: `Frage ${integer.format(run.questionChars)}` }),
      el('span', { class: 'lines muted', text: `Kontext ${integer.format(run.contextChars)}` }),
      el('span', { class: 'lines muted', text: `Antwort ${integer.format(run.answerChars)}` })),
    el('td', { class: 'num', data: { label: 'Tokens rein' } }, el('span', { class: 'lines', text: integer.format(tokens.inputTokens) }),
      el('span', { class: 'lines muted', text: `gecacht ${integer.format(tokens.cachedInputTokens)}` }),
      tokens.cacheWriteInputTokens > 0 && el('span', { class: 'lines muted', text: `Cache-Schreiben ${integer.format(tokens.cacheWriteInputTokens)}` })),
    el('td', { class: 'num', data: { label: 'Tokens raus' } }, el('span', { class: 'lines', text: integer.format(tokens.outputTokens) }),
      el('span', { class: 'lines muted', text: `Reasoning ${integer.format(tokens.reasoningOutputTokens)}` })),
    el('td', { class: 'num', data: { label: 'Tokens gesamt' }, text: integer.format(tokens.totalTokens) }),
    el('td', { class: 'cell-quota', data: { label: 'Kontingent danach' } }, ...quotaLines(run)));
}

function renderRuns() {
  const { items, next } = state.runs;
  $('runs-body').replaceChildren(...items.map(runRow));
  $('runs-empty').hidden = items.length > 0;
  $('runs-wrap').hidden = items.length === 0;
  $('runs-more').hidden = next === null;
}

function renderHistory() {
  const rows = [];
  for (const run of state.history) {
    if (!run.quota) continue;
    for (const limit of run.quota) for (const window of limit.windows) {
      const share = run.quotaShare?.find(entry => entry.id === limit.id && entry.slot === window.slot);
      rows.push(el('tr', {},
        el('td', { data: { label: 'Lauf' }, text: stamp.format(new Date(run.startedAt)) }),
        el('td', { class: 'cell-name', data: { label: 'Konto' }, text: userName(run.userId) }),
        el('td', { data: { label: 'Fenster' }, text: `${limitName(limit.id)}, ${window.windowDurationMins ? windowName(window.windowDurationMins) : SLOT_LABEL[window.slot]}` }),
        el('td', { class: 'num', data: { label: 'Danach' }, text: `${percent.format(window.usedPercent)}\u00a0%` }),
        el('td', { class: 'num', data: { label: 'Anteil' }, text: share ? `+${percent.format(share.points)}\u00a0${share.points === 1 ? 'Punkt' : 'Punkte'}` : dash }),
        el('td', { data: { label: 'Reset' }, text: window.resetsAt ? moment.format(new Date(window.resetsAt * 1000)) : dash })));
    }
    if (rows.length >= HISTORY_ROWS) break;
  }
  $('quota-history-body').replaceChildren(...rows.slice(0, HISTORY_ROWS));
  $('quota-history-wrap').hidden = rows.length === 0;
  $('quota-history-empty').hidden = rows.length > 0;
}

function runsQuery(before) {
  const query = new URLSearchParams({ limit: String(RUNS_PAGE) });
  if (before !== undefined) query.set('before', String(before));
  if ($('runs-user').value) query.set('user', $('runs-user').value);
  if ($('runs-status').value) query.set('status', $('runs-status').value);
  return `/admin/api/runs?${query}`;
}

/** Erste Seite neu laden; eine spätere Antwort einer älteren Auswahl wird verworfen. */
async function loadRuns() {
  const generation = ++state.runs.generation;
  const page = await api(runsQuery());
  if (generation !== state.runs.generation) return;
  Object.assign(state.runs, { items: page.runs, next: page.next, pages: 1 });
  renderRuns();
}

async function moreRuns() {
  const { next, generation } = state.runs;
  if (next === null || state.runs.loading) return;
  state.runs.loading = true;
  $('runs-more').disabled = true;
  try {
    const page = await api(runsQuery(next));
    if (generation !== state.runs.generation) return;
    state.runs.items.push(...page.runs);
    state.runs.next = page.next; state.runs.pages++;
    renderRuns();
  } finally {
    state.runs.loading = false;
    $('runs-more').disabled = false;
  }
}

async function loadUsage() {
  const days = state.days;
  const usage = await api(`/admin/api/usage?days=${days}`);
  if (days !== state.days) return;
  state.usage = usage;
  renderStats();
  renderCharts();
}

async function loadHistory() {
  state.history = (await api(`/admin/api/runs?limit=${HISTORY_RUNS}`)).runs;
  renderHistory();
}

function renderPeriod() {
  for (const button of $('period').querySelectorAll('button')) button.ariaPressed = String(Number(button.dataset.days) === state.days);
}

/** Fehler der Auswertung lassen die Übersicht stehen; nur 401 meldet ab. */
async function guarded(work) {
  try { await work(); } catch (error) {
    if (error instanceof SignedOut) { signedOut(error.message); return; }
    show($('banner'), `Auswertung fehlgeschlagen: ${error.message}`);
  }
}

/** Bei der regelmäßigen Abfrage: Laufliste nur, solange nicht weitergeblättert wurde. */
function refreshAnalysis() {
  return guarded(() => Promise.all([loadUsage(), loadHistory(), state.runs.pages > 1 ? null : loadRuns()]));
}

function render() {
  renderSummary(state.data);
  renderPlan(state.data.plan);
  // Offene Eingaben überleben die Aktualisierung; die Tabelle folgt nach dem Schließen.
  if (!state.editing) renderUsers();
  fillUserSelect($('runs-user'));
  fillUserSelect($('chart-user'));
}

/* Ablauf */

/** Liest das Ergebnis eines Apple-Rücksprungs aus dem Fragment und entfernt es aus der Adresszeile. */
function takeAppleResult() {
  const match = /^#apple=([a-z-]+)$/.exec(location.hash);
  if (!match) return '';
  history.replaceState(null, '', location.pathname + location.search);
  return Object.hasOwn(APPLE_RESULTS, match[1]) ? APPLE_RESULTS[match[1]] : APPLE_RESULTS.ungueltig;
}

function schedule() {
  clearTimeout(state.timer);
  if (state.signedIn && document.visibilityState === 'visible') state.timer = setTimeout(refresh, REFRESH_MS);
}

function signedIn() {
  state.signedIn = true;
  $('login-view').hidden = true;
  $('panel-view').hidden = false;
}

function signedOut(message) {
  clearTimeout(state.timer);
  Object.assign(state, { signedIn: false, data: null, editing: null });
  $('panel-view').hidden = true;
  $('login-view').hidden = false;
  show($('login-error'), message);
  $('login-name').focus();
}

async function refresh() {
  // Eine laufende Abfrage kann älter sein als eine gerade gespeicherte Änderung.
  if (state.loading) { state.reload = true; return; }
  state.loading = true;
  try {
    const data = await api('/admin/api/overview');
    state.data = data;
    state.notice = '';
    signedIn();
    render();
    show($('banner'));
    $('updated').textContent = `Stand ${clock.format(new Date())}`;
    await refreshAnalysis();
  } catch (error) {
    if (error instanceof SignedOut) { signedOut(state.signedIn ? error.message : state.notice); state.notice = ''; return; }
    // Nur 401 heißt abgemeldet. Bei 5xx oder Netzfehlern ist das Cookie weiter gültig; die nächste Abfrage holt die Daten.
    signedIn();
    show($('banner'), `Aktualisierung fehlgeschlagen: ${error.message}`);
  } finally {
    state.loading = false;
    if (state.reload) { state.reload = false; refresh(); } else schedule();
  }
}

$('login-form').addEventListener('submit', async event => {
  event.preventDefault();
  const button = $('login-submit');
  const password = $('login-password');
  button.disabled = true;
  show($('login-error'));
  try {
    await api('/admin/api/login', { method: 'POST', body: { name: $('login-name').value, password: password.value } });
    password.value = '';
    await refresh();
  } catch (error) {
    password.value = '';
    show($('login-error'), error.message);
    password.focus();
  } finally {
    button.disabled = false;
  }
});

$('logout').addEventListener('click', async () => {
  try {
    await api('/admin/api/logout', { method: 'POST' });
    signedOut('');
  } catch (error) {
    show($('banner'), `Abmelden fehlgeschlagen: ${error.message}`);
  }
});

$('period').addEventListener('click', event => {
  const days = Number(event.target.dataset?.days);
  if (!days || days === state.days) return;
  state.days = days;
  renderPeriod();
  guarded(loadUsage);
});
$('chart-user').addEventListener('change', renderCharts);
$('runs-user').addEventListener('change', () => guarded(loadRuns));
$('runs-status').addEventListener('change', () => guarded(loadRuns));
$('runs-more').addEventListener('click', () => guarded(moreRuns));
for (const name of ['tokens', 'turns']) {
  $(`chart-${name}`).addEventListener('mouseover', event => pointAt(name, event.target));
  $(`chart-${name}`).addEventListener('click', event => pointAt(name, event.target));
}

document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && state.editing) edit(null);
});

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && state.signedIn) refresh();
  else clearTimeout(state.timer);
});

// Der Server markiert die Seite nur mit eingerichteter Services ID; sonst gibt es den Knopf nicht.
$('apple-area').hidden = document.body.dataset.apple !== 'on';
state.notice = takeAppleResult();
renderPeriod();
refresh();
