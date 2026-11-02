#!/usr/bin/env node
import { mkdir, realpath } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import path from 'node:path';
import { Store } from './store.mjs';
import { Hub } from './hub.mjs';
import { CodexRpc, toolFreeCatalog } from './rpc.mjs';
import { SessionAuth } from './auth.mjs';
import { Accounts } from './accounts.mjs';
import { Metering } from './metering.mjs';
import { createApi } from './http.mjs';
import { createAdmin, createAdminApi } from './admin.mjs';

export function assertNotRoot(uid = process.getuid?.()) {
  if (uid === 0) throw new Error('Den Dienst als eigenen unprivilegierten Benutzer starten.');
}

function portNumber(value, fallback, name) {
  const port = integer(value, fallback, name, 0);
  if (port > 65535) throw new Error(`${name} ist ungültig.`);
  return port;
}

const listen = (server, port) => new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(port, '127.0.0.1', resolve);
});

function integer(value, fallback, name, minimum) {
  if (value === undefined || value === '') return fallback;
  const number = Number(value);
  if (!Number.isInteger(number) || number < minimum) throw new Error(`${name} ist ungültig.`);
  return number;
}

/** Kontositzungen dürfen unverschlüsselt nur an die lokale Maschine gehen. */
function checkAccountUrl(value) {
  let url;
  try { url = new URL(value); } catch { throw new Error('NOTY_AI_ACCOUNT_URL ist ungültig.'); }
  const local = ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname);
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && local)) throw new Error('NOTY_AI_ACCOUNT_URL muss https oder lokal sein.');
  return url.href;
}

export async function boot(env, options = {}) {
  for (const key of ['STATE_DIR', 'CODEX_HOME', 'NOTY_AI_ACCOUNT_URL']) {
    if (!env[key]) throw new Error(`${key} fehlt. Siehe README.md.`);
  }
  const port = portNumber(env.PORT, 8790, 'PORT');
  const adminPort = portNumber(env.ADMIN_PORT, 8791, 'ADMIN_PORT');
  if (port !== 0 && port === adminPort) throw new Error('ADMIN_PORT muss sich von PORT unterscheiden.');
  const dailyLimit = integer(env.NOTY_AI_DAILY_LIMIT, 200, 'NOTY_AI_DAILY_LIMIT', 1);
  const retentionDays = integer(env.NOTY_AI_RETENTION_DAYS, 30, 'NOTY_AI_RETENTION_DAYS', 1);
  const usageDays = integer(env.NOTY_AI_USAGE_DAYS, 400, 'NOTY_AI_USAGE_DAYS', 1);
  const accountUrl = checkAccountUrl(env.NOTY_AI_ACCOUNT_URL);
  const adminIds = (env.NOTY_AI_ADMIN_IDS ?? '').split(',').map(id => id.trim()).filter(Boolean);
  const stateDir = path.resolve(env.STATE_DIR);
  await mkdir(stateDir, { recursive: true, mode: 0o700 });
  const codexHome = await realpath(env.CODEX_HOME).catch(() => { throw new Error('CODEX_HOME ist nicht erreichbar.'); });
  const cwd = path.join(stateDir, 'work');
  await mkdir(cwd, { recursive: true, mode: 0o700 });
  const store = await new Store({ root: stateDir, retentionDays }).init();
  const accounts = await new Accounts({ root: stateDir, adminIds, defaultDailyLimit: dailyLimit }).init();
  const metering = await new Metering({ root: stateDir, usageDays }).init();
  const hub = new Hub({ store, accounts, metering, cwd,
    prepareCatalog: () => toolFreeCatalog({ codexHome, file: path.join(stateDir, 'tool-free-catalog.json') }),
    rpcFactory: ({ catalog } = {}) => new CodexRpc({ cwd, codexHome, catalog, command: env.CODEX_BIN ?? 'codex' }) });
  const admin = options.admin ?? await createAdmin({ hub, accounts, accountUrl, origin: env.NOTY_AI_ADMIN_ORIGIN });
  const api = createApi({ hub, accounts, auth: new SessionAuth({ accountUrl, knownFile: path.join(stateDir, 'known-sessions.json') }) });
  const adminApi = createAdminApi(admin);
  await hub.startRetention();
  const close = async () => {
    for (const server of [api, adminApi]) { server.close(); server.closeAllConnections(); }
    await hub.close();
  };
  try {
    await listen(api, port);
    await listen(adminApi, adminPort);
  } catch (error) { await close(); throw error; }
  return { api, adminApi, hub, close, address: api.address(), adminAddress: adminApi.address() };
}

if (process.argv[1] && import.meta.filename === realpathSync(process.argv[1])) {
  try {
    assertNotRoot();
    const { close, address, adminAddress } = await boot(process.env);
    console.log(`noty KI-Bridge: /v1 auf ${address.address}:${address.port}, /admin auf ${adminAddress.address}:${adminAddress.port} (nur lokal, HTTPS-Proxy erforderlich)`);
    const shutdown = () => close().finally(() => process.exit(0));
    process.once('SIGINT', shutdown); process.once('SIGTERM', shutdown);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
