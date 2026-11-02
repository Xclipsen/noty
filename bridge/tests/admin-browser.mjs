#!/usr/bin/env node
// Browser-Rauchtest des Admin-Panels mit synthetischen Daten; gehört nicht zu `node --test`.
// Aufruf: PLAYWRIGHT_MODULE=/pfad/node_modules/playwright node tests/admin-browser.mjs
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createAdmin, createAdminApi } from '../server/admin.mjs';
import { request, setup, until } from './helpers.mjs';
import { startAccountBackend } from './fake-account-backend.mjs';

const OUT = process.env.NOTY_ADMIN_SHOTS ?? '/tmp/noty-admin';
const { chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT_MODULE ?? 'playwright');
const cleanups = [];
const t = { after: fn => cleanups.push(fn) };
const PASSWORD = 'synthetisches-passwort';
const HOSTILE_NAME = '<img src=x onerror=window.pwned=1>';

const backend = await startAccountBackend(new Map(), { logins: [{ id: 'konto-admin', name: 'Chefin', password: PASSWORD }] });
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

let handler;
const api = createAdminApi((...args) => handler(...args));
await new Promise(resolve => api.listen(0, '127.0.0.1', resolve));
cleanups.push(() => { api.close(); api.closeAllConnections(); });
const origin = `http://localhost:${api.address().port}`;
handler = await createAdmin({ hub: ctx.hub, accounts: ctx.accounts, accountUrl: backend.url, origin });

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
cleanups.push(() => browser.close());
const context = await browser.newContext({ locale: 'de-DE', timezoneId: 'Europe/Berlin', viewport: { width: 1440, height: 900 } });
const page = await context.newPage();
const consoleLines = []; const violations = []; const pageErrors = []; const external = [];
page.on('console', message => consoleLines.push(`${message.type()}: ${message.text()}`));
page.on('pageerror', error => pageErrors.push(String(error)));
page.on('request', req => { if (!req.url().startsWith(origin)) external.push(req.url()); });
await page.addInitScript(() => {
  window.cspViolations = [];
  document.addEventListener('securitypolicyviolation', event => window.cspViolations.push(`${event.violatedDirective} ${event.blockedURI}`));
});
const collect = async () => violations.push(...await page.evaluate(() => window.cspViolations));
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
const cspConsole = consoleLines.filter(line => /Content Security Policy|Refused to/i.test(line));
const otherErrors = consoleLines.filter(line => line.startsWith('error') && !cspConsole.includes(line) && !/status of 401/.test(line));
console.log(JSON.stringify({ cspViolations: violations, cspConsole, pageErrors, otherConsoleErrors: otherErrors, externalRequests: external }, null, 1));
assert.deepEqual([violations, cspConsole, pageErrors, otherErrors, external], [[], [], [], [], []]);
await until(() => backend.sessions.size === 0);
console.log('Backend-Sitzungen übrig: 0');
for (const cleanup of cleanups.reverse()) await cleanup();
console.log('Rauchtest bestanden');
process.exit(0);
