'use strict';

// Alle Werte gehen über textContent oder Attribute ins DOM, nie als Markup.
const REFRESH_MS = 15_000;
const LIMIT_MAX = 1_000_000;
const TIGHT_PERCENT = 90;
const STATUS_LABEL = { active: 'Aktiv', pending: 'Wartet', blocked: 'Gesperrt' };
const STATUS_ORDER = { pending: 0, active: 1, blocked: 2 };
const ROLE_LABEL = { admin: 'Admin', user: 'Nutzer' };
const USAGE_COLUMNS = [['today', 'Heute'], ['last7', '7 Tage'], ['last30', '30 Tage'], ['total', 'Gesamt']];

const integer = new Intl.NumberFormat('de-DE');
const compact = new Intl.NumberFormat('de-DE', { notation: 'compact', maximumFractionDigits: 1 });
const percent = new Intl.NumberFormat('de-DE', { maximumFractionDigits: 1 });
const moment = new Intl.DateTimeFormat('de-DE', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
const clock = new Intl.DateTimeFormat('de-DE', { hour: '2-digit', minute: '2-digit', second: '2-digit' });

const $ = id => document.getElementById(id);
const state = { signedIn: false, data: null, editing: null, busy: false, loading: false, reload: false, timer: null };

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
  const part = (value, label) => `${compact.format(value)} ${label}`.replaceAll(' ', '\u00a0');
  return `${part(counters.inputTokens, 'rein')} · ${part(counters.outputTokens, 'raus')}`;
}

function usageTitle(counters) {
  return `Tokens rein ${integer.format(counters.inputTokens)}, davon aus dem Cache ${integer.format(counters.cachedInputTokens)}; raus ${integer.format(counters.outputTokens)}, davon Denken ${integer.format(counters.reasoningOutputTokens)}`;
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
  document.querySelector('.table-wrap').hidden = users.length === 0;
}

function render() {
  renderSummary(state.data);
  renderPlan(state.data.plan);
  // Offene Eingaben überleben die Aktualisierung; die Tabelle folgt nach dem Schließen.
  if (!state.editing) renderUsers();
}

/* Ablauf */

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
    signedIn();
    render();
    show($('banner'));
    $('updated').textContent = `Stand ${clock.format(new Date())}`;
  } catch (error) {
    if (error instanceof SignedOut) { signedOut(state.signedIn ? error.message : ''); return; }
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

document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && state.editing) edit(null);
});

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && state.signedIn) refresh();
  else clearTimeout(state.timer);
});

refresh();
