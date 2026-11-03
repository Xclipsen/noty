#!/usr/bin/env node
// Browser-Rauchtest des Admin-Panels mit synthetischen Daten; gehört nicht zu `node --test`.
// Aufruf: PLAYWRIGHT_MODULE=/pfad/node_modules/playwright node tests/admin-browser.mjs
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { createAdmin, createAdminApi } from '../server/admin.mjs';
import { request, setup, until } from './helpers.mjs';
import { fakeIdToken, startAccountBackend } from './fake-account-backend.mjs';

const OUT = process.env.NOTY_ADMIN_SHOTS ?? '/tmp/noty-admin';
const { chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT_MODULE ?? 'playwright');
const cleanups = [];
const t = { after: fn => cleanups.push(fn) };
const PASSWORD = 'synthetisches-passwort';
const HOSTILE_NAME = '<img src=x onerror=window.pwned=1>';

const backend = await startAccountBackend(new Map(), {
  logins: [{ id: 'konto-admin', name: 'Chefin', password: PASSWORD }],
  apple: [{ sub: 'apple-sub-admin', id: 'konto-admin', name: 'Chefin' }, { sub: 'apple-sub-anna', id: 'konto-anna', name: 'Anna' }]
});
cleanups.push(() => backend.close());
const ctx = await setup(t, { activate: [], accounts: { adminIds: ['konto-admin'] }, rpc: { onTurn: () => {} } });

const big = { inputTokens: 1_284_330, cachedInputTokens: 900_000, outputTokens: 48_211, reasoningOutputTokens: 9000 };
await ctx.accounts.seen({ id: 'konto-admin', name: 'Chefin' });
for (const [id, name, status] of [['konto-anna', 'Anna', 'active'], ['konto-ben', 'Ben', 'active'], ['konto-clara', 'Clara', 'pending'], ['konto-dora', 'Dora', 'blocked'], ['konto-x', HOSTILE_NAME, 'pending']]) {
  await ctx.accounts.seen({ id, name });
  await ctx.accounts.update(id, { status });
}
await ctx.accounts.update('konto-anna', { dailyLimit: 25 });
ctx.metering.add('konto-admin', { turns: 3, images: 1, ...big });
ctx.metering.add('konto-anna', { turns: 12, failedTurns: 1, images: 4, ...big });
ctx.metering.add('konto-ben', { turns: 1, inputTokens: 1800, outputTokens: 240 });
ctx.hub.usage = async () => ({ checkedAt: Date.now(), limits: [
  { id: 'codex', name: 'Codex', windows: [
    { usedPercent: 32, windowDurationMins: 300, resetsAt: Math.floor(Date.now() / 1000) + 7200 },
    { usedPercent: 93.5, windowDurationMins: 10080, resetsAt: Math.floor(Date.now() / 1000) + 3 * 86400 }] }] });

// Mitschnitt, welche Cookies bei der Bridge ankommen, für den SameSite-Nachweis.
const seenByBridge = [];
const cookieNames = header => (header ?? '').split(';').map(part => part.trim().split('=')[0]).filter(Boolean);
let handler;
const api = createAdminApi((req, ...rest) => { seenByBridge.push({ method: req.method, path: req.url, cookies: cookieNames(req.headers.cookie), site: req.headers['sec-fetch-site'] }); return handler(req, ...rest); });
await new Promise(resolve => api.listen(0, '127.0.0.1', resolve));
cleanups.push(() => { api.close(); api.closeAllConnections(); });
const origin = `http://localhost:${api.address().port}`;

// Ersatz für appleid.apple.com auf 127.0.0.1: eine andere Site als localhost, der Rücksprung ist also
// seitenübergreifend wie in echt. Die Seite stellt das form_post von Apple nach.
const appleRequests = [];
const fakeApple = createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname !== '/auth/authorize') { res.writeHead(404); res.end(); return; }
  const params = Object.fromEntries(url.searchParams);
  appleRequests.push(params);
  const form = (label, id, fields) => `<form method="post" action="${params.redirect_uri}">${Object.entries(fields).map(([name, value]) => `<input type="hidden" name="${name}" value="${value}">`).join('')}<button id="${id}">${label}</button></form>`;
  const token = sub => fakeIdToken({ sub, nonceHash: params.nonce });
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(`<!doctype html><title>Fake Apple</title><h1>Synthetisches Apple</h1>
${form('Als Chefin fortfahren', 'apple-admin', { state: params.state, code: 'synthetisch', id_token: token('apple-sub-admin') })}
${form('Als Anna fortfahren', 'apple-anna', { state: params.state, code: 'synthetisch', id_token: token('apple-sub-anna') })}
${form('Abbrechen', 'apple-cancel', { state: params.state, error: 'user_cancelled_authorize' })}`);
});
await new Promise(resolve => fakeApple.listen(0, '127.0.0.1', resolve));
cleanups.push(() => { fakeApple.close(); fakeApple.closeAllConnections(); });
const appleOrigin = `http://127.0.0.1:${fakeApple.address().port}`;
handler = await createAdmin({ hub: ctx.hub, accounts: ctx.accounts, accountUrl: backend.url, origin,
  apple: { servicesId: 'de.example.noty.web', redirect: `${origin}/admin/api/apple/callback`, authorizeUrl: `${appleOrigin}/auth/authorize` } });

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
cleanups.push(() => browser.close());
const context = await browser.newContext({ locale: 'de-DE', timezoneId: 'Europe/Berlin', viewport: { width: 1440, height: 900 } });
const consoleLines = []; const violations = []; const pageErrors = []; const external = [];
async function watch(target) {
  target.on('console', message => consoleLines.push(`${message.type()}: ${message.text()}`));
  target.on('pageerror', error => pageErrors.push(String(error)));
  // Nur die Anmeldeseite des Apple-Ersatzes ist außerhalb erlaubt, sonst nichts.
  target.on('request', req => { if (!req.url().startsWith(origin) && !req.url().startsWith(`${appleOrigin}/auth/authorize?`)) external.push(req.url()); });
  await target.addInitScript(() => {
    window.cspViolations = [];
    document.addEventListener('securitypolicyviolation', event => window.cspViolations.push(`${event.violatedDirective} ${event.blockedURI}`));
  });
  return target;
}
const page = await watch(await context.newPage());
let collect = async () => violations.push(...await page.evaluate(() => window.cspViolations));
const row = name => page.locator('#users-body tr', { hasText: name });
const step = text => console.log(`ok: ${text}`);

await page.goto(`${origin}/admin`);
await page.waitForSelector('#login-form');
await page.screenshot({ path: `${OUT}-login.png` });

await page.fill('#login-name', 'Chefin');
await page.fill('#login-password', 'falsch');
await page.click('#login-submit');
await page.waitForSelector('#login-error:not([hidden])');
assert.equal(await page.textContent('#login-error'), 'Name oder Passwort stimmt nicht.');
assert.equal(await page.inputValue('#login-password'), '');
step('falsches Passwort zeigt Fehler und leert das Feld');

await page.fill('#login-password', PASSWORD);
await page.click('#login-submit');
await page.waitForSelector('#users-body tr');
assert.equal(await page.isVisible('#login-view'), false);
assert.equal(await row('Chefin').locator('button', { hasText: 'Sperren' }).isDisabled(), true);
assert.equal(await page.textContent('#codex-account'), 'ChatGPT');
step(`Anmeldung, Tabelle mit ${await page.locator('#users-body tr').count()} Konten, Admin nicht sperrbar`);

assert.ok(await page.locator('#users-body img').count() === 0);
assert.equal(await page.evaluate(() => window.pwned), undefined);
assert.equal(await row('onerror').locator('.cell-name').textContent(), HOSTILE_NAME);
step('feindlicher Name erscheint als Text');

await page.screenshot({ path: `${OUT}-desktop.png`, fullPage: true });

await row('Clara').locator('button', { hasText: 'Freischalten' }).click();
await row('Clara').locator('.badge.active').waitFor();
assert.equal(ctx.accounts.get('konto-clara').status, 'active');
step('Freischalten ändert Server und Anzeige');

const session = await ctx.store.create({ userId: 'konto-ben' });
await ctx.hub.turn('konto-ben', session.id, request());
await until(() => ctx.hub.runs.get(session.id)?.turnId);
await page.reload();
await page.waitForSelector('#users-body tr');
assert.equal(await page.textContent('#running'), '1');
await row('Ben').locator('button', { hasText: 'Sperren' }).click();
await row('Ben').locator('text=Laufende Läufe brechen sofort ab').waitFor();
assert.equal(ctx.accounts.get('konto-ben').status, 'active');
await page.screenshot({ path: `${OUT}-bestaetigung.png`, fullPage: true });
await row('Ben').locator('button', { hasText: 'Abbrechen' }).click();
assert.equal(ctx.accounts.get('konto-ben').status, 'active');
await row('Ben').locator('button', { hasText: 'Sperren' }).click();
await row('Ben').locator('button', { hasText: 'Ja, sperren' }).click();
await row('Ben').locator('.badge.blocked').waitFor();
assert.equal(ctx.store.get(session.id, 'konto-ben').status, 'interrupted');
assert.equal(await page.textContent('#running'), '0');
step('Sperren mit Bestätigung, laufender Lauf abgebrochen');

await row('Anna').locator('button', { hasText: 'Limit setzen' }).click();
const limit = row('Anna').locator('input');
assert.equal(await limit.inputValue(), '25');
await page.screenshot({ path: `${OUT}-limit.png`, fullPage: true });
await limit.fill('-3');
await limit.press('Enter');
await page.waitForSelector('#banner:not([hidden])');
assert.match(await page.textContent('#banner'), /ganze Zahl/);
await limit.fill('');
await limit.press('Enter');
await row('Anna').locator('td[data-label="Limit"]', { hasText: 'Standard' }).waitFor();
assert.equal(ctx.accounts.get('konto-anna').dailyLimit, null);
assert.equal(await row('Anna').locator('td[data-label="Limit"] .lines').first().textContent(), '200');
step('Limit: Prüfung, leer setzt Standard, wirksamer Wert sichtbar');

await context.setDefaultTimeout(5000);
await page.setViewportSize({ width: 820, height: 1180 });
await page.waitForTimeout(100);
assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'iPad hochkant ohne Querscrollen');
await page.screenshot({ path: `${OUT}-ipad.png`, fullPage: true });
await page.setViewportSize({ width: 1180, height: 820 });
await page.waitForTimeout(100);
assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'iPad quer ohne Querscrollen');
await page.screenshot({ path: `${OUT}-ipad-quer.png`, fullPage: true });
await page.setViewportSize({ width: 390, height: 844 });
await page.waitForTimeout(100);
assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'schmal ohne Querscrollen');
await page.setViewportSize({ width: 1440, height: 900 });
step('Breiten 1440, 1180, 820, 390 ohne Querscrollen');

// Abfrage nur bei sichtbarem Tab, offene Eingaben überleben sie.
await collect();
await page.clock.install();
await page.reload();
await page.waitForSelector('#users-body tr');
let polls = 0;
page.on('request', req => { if (req.url().endsWith('/admin/api/overview')) polls++; });
await page.clock.runFor(15_000);
await until(() => polls === 1);
await page.evaluate(() => { Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' }); document.dispatchEvent(new Event('visibilitychange')); });
await page.clock.runFor(60_000);
await page.waitForTimeout(100);
assert.equal(polls, 1, 'verdeckter Tab fragt nicht ab');
await page.evaluate(() => { Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'visible' }); document.dispatchEvent(new Event('visibilitychange')); });
await until(() => polls === 2);
await row('Anna').locator('button', { hasText: 'Limit setzen' }).click();
await row('Anna').locator('input').fill('12');
await page.clock.runFor(15_000);
await until(() => polls === 3);
await page.waitForTimeout(100);
assert.equal(await row('Anna').locator('input').inputValue(), '12');
await row('Anna').locator('button', { hasText: 'Abbrechen' }).click();
step('15-Sekunden-Abfrage, nur sichtbar, Eingabe bleibt erhalten');

await collect();
await context.clearCookies();
await page.clock.runFor(15_000);
await page.waitForSelector('#login-view:not([hidden])');
assert.match(await page.textContent('#login-error'), /abgelaufen/);
step('401 führt zur Anmeldung');

await page.fill('#login-name', 'Chefin');
await page.fill('#login-password', PASSWORD);
await page.click('#login-submit');
await page.waitForSelector('#users-body tr');
await page.click('#logout');
await page.waitForSelector('#login-view:not([hidden])');
assert.equal((await page.request.get(`${origin}/admin/api/overview`)).status(), 401);
assert.deepEqual(await context.cookies(), []);
step('Abmelden löscht das Cookie');
await collect();

// Mit Apple anmelden, in einem frischen Kontext ohne die installierte Uhr von oben.
const appleContext = await browser.newContext({ locale: 'de-DE', timezoneId: 'Europe/Berlin', viewport: { width: 1440, height: 900 } });
const applePage = await watch(await appleContext.newPage());
collect = async () => { if (applePage.url().startsWith(origin)) violations.push(...await applePage.evaluate(() => window.cspViolations)); };
const toApple = async () => {
  await applePage.click('#apple-login');
  await applePage.waitForURL(url => url.href.startsWith(appleOrigin));
};
const backAtLogin = async () => {
  await applePage.waitForURL(`${origin}/admin`);
  await applePage.waitForSelector('#login-error:not([hidden])');
  await collect();
  return applePage.textContent('#login-error');
};
await applePage.goto(`${origin}/admin`);
await applePage.waitForSelector('#apple-login');
assert.equal(await applePage.isVisible('#apple-login'), true);
assert.equal((await applePage.textContent('#apple-login')).trim(), 'Mit Apple anmelden');
assert.equal(await applePage.evaluate(() => document.querySelector('#apple-login img').naturalWidth > 0), true, 'Logo geladen');
await applePage.screenshot({ path: `${OUT}-apple.png` });
step('Apple-Knopf sichtbar, Logo als eigene SVG-Datei');

await toApple();
const asked = appleRequests.at(-1);
assert.deepEqual([asked.client_id, asked.response_type, asked.response_mode, asked.redirect_uri, asked.scope], ['de.example.noty.web', 'code id_token', 'form_post', `${origin}/admin/api/apple/callback`, undefined]);
assert.match(asked.nonce, /^[a-f0-9]{64}$/);
await applePage.click('#apple-anna');
assert.equal(await backAtLogin(), 'Mit diesem Apple-Konto ist keine Anmeldung möglich.');
assert.equal(new URL(applePage.url()).hash, '', 'Fragment entfernt');
await applePage.screenshot({ path: `${OUT}-apple-fehler.png` });
step('Apple mit Nicht-Admin: deutsche Meldung, kein Zugang');

await toApple();
await applePage.click('#apple-cancel');
assert.equal(await backAtLogin(), 'Die Anmeldung mit Apple wurde abgebrochen.');
step('Abbruch bei Apple: deutsche Meldung');

await toApple();
seenByBridge.length = 0;
await applePage.click('#apple-admin');
await applePage.waitForSelector('#users-body tr');
assert.equal(new URL(applePage.url()).pathname, '/admin');
assert.equal(await applePage.isVisible('#login-view'), false);
const hit = (method, path) => seenByBridge.find(entry => entry.method === method && entry.path === path);
const callback = hit('POST', '/admin/api/apple/callback');
const done = hit('GET', '/admin/api/apple/callback');
const landing = hit('GET', '/admin');
console.log('SameSite-Mitschnitt:', JSON.stringify(seenByBridge.filter(entry => entry.path !== '/admin/app.css' && entry.path !== '/admin/apple.svg')));
assert.ok(callback.cookies.includes('noty_ai_apple') && callback.site === 'cross-site', 'SameSite=None-Bindung kommt beim seitenübergreifenden form_post an');
assert.ok(!done.cookies.includes('noty_ai_admin') && done.site === 'cross-site', 'erwartet: Strict-Cookie fehlt nach der seitenübergreifenden Weiterleitung');
assert.ok(landing.cookies.includes('noty_ai_admin') && landing.site === 'same-origin', 'Meta-Refresh der Zwischenseite ist eine Navigation vom eigenen Ursprung');
assert.ok(hit('GET', '/admin/api/overview').cookies.includes('noty_ai_admin'));
const jar = await appleContext.cookies();
assert.deepEqual(jar.map(c => [c.name, c.sameSite, c.httpOnly, c.path]), [['noty_ai_admin', 'Strict', true, '/admin']]);
await collect();
await applePage.screenshot({ path: `${OUT}-apple-panel.png` });
step('Apple mit Admin: Panel offen, Strict-Cookie über die Zwischenseite, Bindungs-Cookie entfernt');

await applePage.reload();
await applePage.waitForSelector('#users-body tr');
await until(() => backend.sessions.size === 0);
step('Neu laden bleibt angemeldet, Backend-Sitzungen der Apple-Anmeldungen sind beendet');
await collect();
const cspConsole = consoleLines.filter(line => /Content Security Policy|Refused to/i.test(line));
const otherErrors = consoleLines.filter(line => line.startsWith('error') && !cspConsole.includes(line) && !/status of 401/.test(line));
console.log(JSON.stringify({ cspViolations: violations, cspConsole, pageErrors, otherConsoleErrors: otherErrors, externalRequests: external }, null, 1));
assert.deepEqual([violations, cspConsole, pageErrors, otherErrors, external], [[], [], [], [], []]);
await until(() => backend.sessions.size === 0);
console.log('Backend-Sitzungen übrig: 0');
for (const cleanup of cleanups.reverse()) await cleanup();
console.log('Rauchtest bestanden');
process.exit(0);
