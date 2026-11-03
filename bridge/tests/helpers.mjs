import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Store } from '../server/store.mjs';
import { Hub } from '../server/hub.mjs';
import { Accounts } from '../server/accounts.mjs';
import { Metering } from '../server/metering.mjs';
import { RunLog } from '../server/runlog.mjs';
import { SessionAuth } from '../server/auth.mjs';
import { UploadGate, createApi } from '../server/http.mjs';
import { RevisionWaits } from '../server/waits.mjs';
import { FakeRpc } from './fake-rpc.mjs';

export const TOKEN = 'a'.repeat(64);
export const TOKEN_B = 'b'.repeat(64);
export const USER = 'konto-a';
export const OWNER = { userId: USER };
export const USERS = new Map([[TOKEN, { id: USER, name: 'Anna', email: 'anna@example.invalid' }], [TOKEN_B, { id: 'konto-b', name: 'Ben' }]]);
export const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from('SYNTHETISCHES-PNG-BILD')]);

export async function tempDir(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'noty-ai-test-'));
  t.after(() => rm(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 10 }));
  return root;
}

export async function setup(t, { activate = [USER, 'konto-b'], rpc = {}, hub: hubOptions = {}, store: storeOptions = {}, accounts: accountOptions = {}, metering: meteringOptions = {}, runs: runOptions = {}, root } = {}) {
  root ??= await tempDir(t);
  const store = await new Store({ root, ...storeOptions }).init();
  const accounts = await new Accounts({ root, ...accountOptions }).init();
  const metering = await new Metering({ root, ...meteringOptions }).init();
  // Eine Uhr für Zähler und Laufprotokoll, damit Mitternachtstests beide gleich sehen.
  const runlog = await new RunLog({ root, ...(meteringOptions.now ? { now: meteringOptions.now } : {}), ...runOptions }).init();
  for (const user of USERS.values()) {
    if (!activate.includes(user.id)) continue;
    await accounts.seen(user);
    await accounts.update(user.id, { status: 'active' });
  }
  const instances = [];
  const hub = new Hub({ store, accounts, metering, runlog, cwd: root, prepareCatalog: async () => path.join(root, 'katalog.json'), rpcFactory: options => { const fake = new FakeRpc(rpc); fake.options = options; instances.push(fake); return fake; },
    // Ruhende Threads nur, wo ein Test sie ausdrücklich prüft; sonst gilt je Lauf ein neuer Prozess.
    maxWarm: 0, ...hubOptions });
  t.after(() => hub.close());
  return { root, store, accounts, metering, runlog, hub, instances };
}

/** Echte HTTP-Schicht mit Kontoprüfung gegen ein Ersatz-Backend im Speicher. */
export async function serve(t, { admin, backend = {}, uploads: uploadOptions, waits: waitOptions, ...options } = {}) {
  const context = await setup(t, options);
  const state = { down: false, users: new Map(USERS), lookups: 0, ...backend };
  const fetcher = async (url, { headers }) => {
    state.lookups++;
    if (state.down) throw new Error('Verbindung abgelehnt');
    const user = state.users.get(headers.authorization.replace('Bearer ', '')) ?? null;
    return new Response(JSON.stringify({ user }), { status: 200 });
  };
  const auth = new SessionAuth({ accountUrl: 'http://127.0.0.1:1', fetcher, ...options.auth });
  const uploads = new UploadGate(uploadOptions);
  const waits = new RevisionWaits(waitOptions);
  const api = createApi({ hub: context.hub, auth, accounts: context.accounts, uploads, waits });
  await new Promise(resolve => api.listen(0, '127.0.0.1', resolve));
  t.after(() => { api.close(); api.closeAllConnections(); });
  const base = `http://127.0.0.1:${api.address().port}`;
  const call = (method, pathname, body, headers = { authorization: `Bearer ${TOKEN}` }) => fetch(base + pathname, {
    method, headers: { ...headers, ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
    body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body)
  });
  return { ...context, api, base, call, auth, uploads, waits, backend: state };
}

export async function settled(store, id, userId = USER) {
  for (let i = 0; i < 400; i++) {
    if (store.get(id, userId).status !== 'running') return store.get(id, userId);
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  throw new Error('Lauf endet nicht');
}

export async function until(condition) {
  for (let i = 0; i < 400; i++) {
    if (condition()) return;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  throw new Error('Bedingung nicht erreicht');
}

export const request = (requestId = 'anfrage-0001', extra = {}) => ({ requestId, text: 'Was steht im Heft?', ...extra });
