import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { BASE_INSTRUCTIONS, buildPrompt, contextKey, threadStartParams, usageOf, WARM } from '../server/hub.mjs';
import { CODEX_ARGS, PROMPT_OFF } from '../server/rpc.mjs';
import { isValidSession, Store } from '../server/store.mjs';
import { setup, settled, until, request, USER, OWNER, PNG } from './helpers.mjs';

const CONTEXT = { label: 'Geschichte', text: '--- Seite 1 ---\nEbersfeld wurde 1183 gegründet.\n\n--- Seite 2 ---\nAm Lauterbach.\n[noty: geöffnete Seite 2]' };
const promptOf = (rpc, index = 0) => rpc.calls.filter(c => c.method === 'turn/start')[index].params.input[0].text;
const ask = async (hub, store, s, id, extra) => { await hub.turn(USER, s.id, request(id, extra)); await settled(store, s.id); await until(() => hub.runs.size === 0); };
const commonPrefix = (a, b) => { let i = 0; while (i < a.length && a[i] === b[i]) i++; return i; };
/** Codex zählt `tokenUsage.total` über den ganzen Thread; der Ersatz tut das hier auch. */
const cumulative = (perTurn = { inputTokens: 1000, cachedInputTokens: 0, outputTokens: 10, reasoningOutputTokens: 2, totalTokens: 1010 }) => {
  const sum = { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0, cacheWriteInputTokens: 0 };
  return rpc => { for (const [name, value] of Object.entries(perTurn)) sum[name] += value; rpc.usage({ ...sum }); rpc.finish(); };
};

test('Reihenfolge: Heftkontext vor Verlauf vor Bildnamen vor Frage; Kontext byte-gleich', () => {
  const prompt = buildPrompt({ nonce: 'n'.repeat(24), text: 'Neue Frage', context: CONTEXT, images: [{ label: 'Seite 2' }],
    history: [{ role: 'user', text: 'Alte Frage' }, { role: 'assistant', text: 'Alte Antwort' }] });
  const at = needle => { const index = prompt.indexOf(needle); assert.ok(index >= 0, needle); return index; };
  assert.ok(prompt.startsWith(`<noty-heftkontext-${'n'.repeat(24)} name="Geschichte">\n${CONTEXT.text}\n</noty-heftkontext-`));
  assert.ok(at('</noty-heftkontext-') < at('<noty-verlauf-'));
  assert.ok(at('</noty-verlauf-') < at('<noty-bilder-'));
  assert.ok(at('</noty-bilder-') < at('Frage:\nNeue Frage'));
  assert.ok(prompt.endsWith('Frage:\nNeue Frage'));
  // Die variable Schlussnotiz der App bleibt im Kontext, wo die App sie hingesetzt hat.
  assert.ok(prompt.includes('[noty: geöffnete Seite 2]\n</noty-heftkontext-'));
});

test('Grundanweisung ersetzt die Codex-Anweisung; Schalter sparen Umgebung, Freigaben, Skills und AGENTS.md', () => {
  const params = threadStartParams({ cwd: '/leer' });
  assert.deepEqual(params, { cwd: '/leer', approvalPolicy: 'never', sandbox: 'read-only', ephemeral: true, baseInstructions: BASE_INSTRUCTIONS, developerInstructions: '' });
  assert.equal(threadStartParams({ cwd: '/leer', model: 'demo' }).model, 'demo');
  for (const setting of ['include_permissions_instructions=false', 'include_environment_context=false', 'include_apps_instructions=false',
    'include_collaboration_mode_instructions=false', 'skills.include_instructions=false', 'project_doc_max_bytes=0', 'features.memories=false']) {
    assert.ok(PROMPT_OFF.includes(setting), setting);
    assert.equal(CODEX_ARGS[CODEX_ARGS.indexOf(setting) - 1], '-c', setting);
  }
});

test('Werkzeugfreiheit: bisherige Schalter unverändert vorhanden', () => {
  const features = ['shell_tool', 'unified_exec', 'code_mode', 'code_mode_host', 'apply_patch_freeform', 'view_image', 'image_generation',
    'multi_agent', 'goals', 'plugins', 'apps', 'tool_suggest', 'skill_search', 'sleep_tool', 'browser_use', 'computer_use', 'in_app_browser', 'hooks'];
  for (const name of features) assert.ok(CODEX_ARGS.includes(`features.${name}=false`), name);
  for (const flag of ['web_search="disabled"', 'history.persistence="none"', 'analytics.enabled=false']) assert.ok(CODEX_ARGS.includes(flag), flag);
  assert.deepEqual(CODEX_ARGS.slice(0, 2), ['app-server', '--stdio']);
  // Jeder Schalter steht hinter einem -c, keiner kann einen anderen verschlucken.
  for (let i = 2; i < CODEX_ARGS.length; i += 2) assert.equal(CODEX_ARGS[i], '-c');
});

test('Stabilität: neuer Thread je Lauf, Anfang bis einschließlich Heftkontext byte-gleich, Abgrenzer je Sitzung fest', async t => {
  const { hub, store, instances } = await setup(t);
  const s = await store.create(OWNER);
  await ask(hub, store, s, 'anfrage-0001', { text: 'Erste Frage', context: CONTEXT });
  await ask(hub, store, s, 'anfrage-0002', { text: 'Zweite Frage', context: CONTEXT });
  await ask(hub, store, s, 'anfrage-0003', { text: 'Dritte Frage', context: CONTEXT });
  const [first, second, third] = instances.map(rpc => promptOf(rpc));
  assert.equal(instances.length, 3, 'ohne ruhende Threads je Lauf ein Prozess');
  const contextEnd = first.indexOf('\n\nFrage:');
  assert.ok(commonPrefix(first, second) >= contextEnd, 'Kontext bleibt vorn gleich');
  // Der Verlauf wächst nur hinten: Lauf 3 teilt mit Lauf 2 auch den älteren Verlauf.
  const olderHistory = second.indexOf('\n</noty-verlauf-');
  assert.ok(commonPrefix(second, third) >= olderHistory, 'älterer Verlauf bleibt gleich');
  assert.deepEqual(instances.map(rpc => rpc.calls.find(c => c.method === 'thread/start').params), Array(3).fill(threadStartParams({ cwd: instances[0].calls.find(c => c.method === 'thread/start').params.cwd })));
  const other = await store.create(OWNER);
  await ask(hub, store, other, 'anfrage-0004', { text: 'Erste Frage', context: CONTEXT });
  const nonce = prompt => /<noty-heftkontext-([0-9a-f]{24}) /.exec(prompt)[1];
  assert.equal(nonce(first), nonce(third));
  assert.notEqual(nonce(first), nonce(promptOf(instances[3])), 'andere Sitzung, anderer Abgrenzer');
  const restarted = await setup(t, { root: path.join(path.dirname(store.sessionsDir)) });
  assert.notEqual(restarted.hub.nonceFor(s.id), hub.nonceFor(s.id), 'nach Neustart neu, nichts davon auf der Platte');
});

test('Ruhender Thread: Folgefrage im selben Thread, nur die Frage geht mit, Tokens je Lauf, usage an der Antwort', async t => {
  const { hub, store, instances, root, runlog } = await setup(t, { hub: { maxWarm: 2 }, rpc: { onTurn: cumulative() } });
  const s = await store.create(OWNER);
  await ask(hub, store, s, 'anfrage-0001', { text: 'Erste Frage', context: CONTEXT, effort: 'low' });
  assert.equal(instances[0].closed, false, 'Prozess ruht');
  assert.equal(hub.warm.size, 1);
  await ask(hub, store, s, 'anfrage-0002', { text: 'Zweite Frage', context: CONTEXT, effort: 'high' });
  assert.equal(instances.length, 1, 'kein zweiter Prozess');
  const rpc = instances[0];
  assert.equal(rpc.calls.filter(c => c.method === 'thread/start').length, 1);
  const turns = rpc.calls.filter(c => c.method === 'turn/start').map(c => c.params);
  assert.deepEqual(turns.map(turn => [turn.threadId, turn.effort]), [['thread-test', 'low'], ['thread-test', 'high']]);
  assert.equal(turns[1].input[0].text, 'Frage:\nZweite Frage', 'Kontext und Verlauf stehen schon im Thread');
  const answers = s.messages.filter(m => m.role === 'assistant');
  const usage = { inputTokens: 1000, cachedInputTokens: 0, outputTokens: 10, reasoningOutputTokens: 2, totalTokens: 1010 };
  assert.deepEqual(answers.map(m => m.usage), [usage, usage], 'je Lauf, nicht der aufsummierte Thread');
  await runlog.flush();
  const runs = JSON.parse(await readFile(path.join(root, 'runs.json'), 'utf8'));
  assert.deepEqual(runs.map(run => [run.effort, run.tokens.inputTokens, run.status]), [['low', 1000, 'completed'], ['high', 1000, 'completed']]);
  // usage steht in der Sitzungsdatei, ist gültig und übersteht das Laden.
  await store.close();
  const reloaded = await new Store({ root }).init();
  assert.deepEqual(reloaded.get(s.id, USER).messages.filter(m => m.role === 'assistant').map(m => m.usage), [usage, usage]);
  await reloaded.close();
});

test('Ruhender Thread passt nicht: anderer Kontext, Modell, Fehler, Abbruch → neuer Thread, alter Prozess endet', async t => {
  let fail = false;
  const onTurn = rpc => { if (fail) rpc.complete('failed', { codexErrorInfo: 'serverOverloaded' }); else rpc.finish(); };
  const { hub, store, instances } = await setup(t, { hub: { maxWarm: 2 }, rpc: { onTurn } });
  // Die Modellprüfung startet einen eigenen Abfrageprozess; gezählt werden nur Laufprozesse.
  const runners = () => instances.filter(rpc => rpc.calls.some(c => c.method === 'turn/start'));
  const s = await store.create(OWNER);
  await ask(hub, store, s, 'anfrage-0001', { context: CONTEXT });
  await ask(hub, store, s, 'anfrage-0002', { context: { ...CONTEXT, text: CONTEXT.text + ' geändert' } });
  assert.equal(runners().length, 2, 'anderer Kontext');
  assert.equal(runners()[0].closed, true);
  assert.match(promptOf(runners()[1]), /<noty-verlauf-/, 'neuer Thread bekommt den Verlauf als Text');
  await ask(hub, store, s, 'anfrage-0003', {});
  assert.equal(runners().length, 3, 'ohne Kontext nicht in einen Thread mit Heftinhalt');
  await ask(hub, store, s, 'anfrage-0004', { model: 'demo' });
  assert.equal(runners().length, 4, 'anderes Modell');
  fail = true;
  await ask(hub, store, s, 'anfrage-0005', { model: 'demo' });
  assert.equal(runners().length, 4, 'passender Thread wird genutzt');
  assert.equal(runners()[3].closed, true, 'nach einem Fehler ruht nichts');
  assert.equal(hub.warm.size, 0);
  fail = false;
  await ask(hub, store, s, 'anfrage-0006', {});
  assert.equal(runners().length, 5);
  // Abbruch: der Thread ist danach in unklarem Zustand.
  const hanging = await setup(t, { hub: { maxWarm: 2 }, rpc: { onTurn: () => {} } });
  const h = await hanging.store.create(OWNER);
  await hanging.hub.turn(USER, h.id, request('anfrage-0007'));
  await until(() => hanging.instances[0]?.turnId);
  await hanging.hub.cancel(USER, h.id);
  await settled(hanging.store, h.id);
  await until(() => hanging.hub.runs.size === 0);
  assert.equal(hanging.hub.warm.size, 0);
  assert.equal(hanging.instances[0].closed, true);
});

test('Ruhender Thread: nicht nach weiteren Nachrichten, Grenzen wie beim Verlauf', async t => {
  const { hub, store, instances } = await setup(t, { hub: { maxWarm: 2 } });
  const s = await store.create(OWNER);
  await ask(hub, store, s, 'anfrage-0001', {});
  s.messages.push({ id: 'fremd', role: 'system', text: 'Neustarthinweis' });
  await ask(hub, store, s, 'anfrage-0002', {});
  assert.equal(instances.length, 2, 'Sitzung hat sich seit dem Lauf verändert');
  for (let i = 3; i < 3 + WARM.turns; i++) await ask(hub, store, s, `anfrage-${String(i).padStart(4, '0')}`, {});
  assert.equal(instances.length, 3, `höchstens ${WARM.turns} Züge je Thread`);
  const images = await setup(t, { hub: { maxWarm: 2 } });
  const i = await images.store.create(OWNER);
  const image = { mimeType: 'image/png', base64: PNG.toString('base64') };
  await ask(images.hub, images.store, i, 'anfrage-0101', { images: [image, image, image] });
  await ask(images.hub, images.store, i, 'anfrage-0102', { images: [image, image] });
  assert.equal(images.instances.length, 2, 'Bilder im Thread höchstens wie in einem Lauf');
  const chars = await setup(t, { hub: { maxWarm: 2 }, rpc: { answer: 'x'.repeat(WARM.chars) } });
  const c = await chars.store.create(OWNER);
  await ask(chars.hub, chars.store, c, 'anfrage-0201', {});
  await ask(chars.hub, chars.store, c, 'anfrage-0202', {});
  assert.equal(chars.instances.length, 2, 'Zeichen im Thread höchstens wie im Textverlauf');
});

test('Ruhende Threads enden bei Zeitablauf, Löschen, Sperre, Herunterfahren und über der Höchstzahl', async t => {
  const { hub, store, instances } = await setup(t, { hub: { maxWarm: 2, warmIdleMs: 60 } });
  const [a, b, c] = [await store.create(OWNER), await store.create(OWNER), await store.create(OWNER)];
  await ask(hub, store, a, 'anfrage-0001', {});
  await until(() => instances[0].closed);
  assert.equal(hub.warm.size, 0, 'Zeitablauf');
  hub.warmIdleMs = 60_000;
  await ask(hub, store, a, 'anfrage-0002', {});
  await ask(hub, store, b, 'anfrage-0003', {});
  await ask(hub, store, c, 'anfrage-0004', {});
  assert.deepEqual([...hub.warm.keys()], [b.id, c.id], 'älteste weicht');
  assert.equal(instances[1].closed, true);
  await hub.remove(USER, b.id);
  assert.equal(instances[2].closed, true, 'Löschen');
  await hub.abortUser(USER);
  assert.equal(instances[3].closed, true, 'Sperre');
  await ask(hub, store, a, 'anfrage-0005', {});
  assert.equal(hub.warm.size, 1);
  await hub.close();
  assert.equal(instances[4].closed, true, 'Herunterfahren');
  assert.equal(hub.warm.size, 0);
});

test('Werkzeugfreiheit im ruhenden Thread: Freigaben abgelehnt, Rückfragen und Unbekanntes zurückgewiesen, auch ruhend', async t => {
  const methods = ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval', 'item/tool/requestUserInput', 'item/tool/call', 'mcpServer/elicitation/request'];
  const onTurn = rpc => { methods.forEach((method, id) => rpc.emit('message', { id, method, params: { threadId: rpc.threadId } })); rpc.finish(); };
  const { hub, store, instances } = await setup(t, { hub: { maxWarm: 2 }, rpc: { onTurn } });
  const s = await store.create(OWNER);
  await ask(hub, store, s, 'anfrage-0001', {});
  await ask(hub, store, s, 'anfrage-0002', {});
  const [rpc] = instances;
  assert.equal(instances.length, 1);
  const check = responses => {
    assert.deepEqual(responses.slice(0, 2).map(r => r.result), [{ decision: 'decline' }, { decision: 'decline' }]);
    for (const response of responses.slice(2)) assert.equal(response.error.code, -32601);
  };
  check(rpc.responses.slice(0, methods.length));
  check(rpc.responses.slice(methods.length, 2 * methods.length));
  // Ruhend wird gar nichts genehmigt.
  rpc.emit('message', { id: 77, method: 'item/commandExecution/requestApproval', params: {} });
  assert.deepEqual(rpc.responses.at(-1), { id: 77, error: { code: -32601, message: 'Unsupported client request' } });
});

test('Ruhender Thread: Nachzügler eines früheren Zugs zählen nicht im neuen Lauf', async t => {
  let turn = 0;
  const counting = cumulative();
  const onTurn = rpc => {
    turn++;
    if (turn === 2) rpc.emit('message', { method: 'thread/tokenUsage/updated', params: { threadId: rpc.threadId, turnId: 'alter-zug', tokenUsage: { total: { inputTokens: 999_999 } } } });
    counting(rpc);
  };
  const { hub, store, instances } = await setup(t, { hub: { maxWarm: 2 }, rpc: { onTurn } });
  const s = await store.create(OWNER);
  await ask(hub, store, s, 'anfrage-0001', {});
  await ask(hub, store, s, 'anfrage-0002', {});
  assert.equal(instances.length, 1);
  assert.deepEqual(s.messages.filter(m => m.role === 'assistant').map(m => m.usage.inputTokens), [1000, 1000]);
});

test('usage: nur bekannte Zähler, nur ganze Zahlen; Sitzungsdatei prüft die Form', () => {
  assert.deepEqual(usageOf({ inputTokens: 5, cachedInputTokens: 2, cacheWriteInputTokens: 1, outputTokens: 1, reasoningOutputTokens: 0, totalTokens: 6 }),
    { inputTokens: 5, cachedInputTokens: 2, outputTokens: 1, reasoningOutputTokens: 0, totalTokens: 6 });
  assert.equal(usageOf({}), undefined);
  assert.equal(usageOf({ inputTokens: -1, outputTokens: 1.5 }), undefined);
  const session = usage => ({ id: 'x', userId: 'u', documentId: null, title: 't', status: 'idle', revision: 0, updatedAt: 0, requests: [],
    messages: [{ id: 'm', role: 'assistant', text: 'a', ...(usage === undefined ? {} : { usage }) }] });
  assert.equal(isValidSession(session(), 'x'), true, 'ältere Dateien ohne usage');
  assert.equal(isValidSession(session({ inputTokens: 3 }), 'x'), true);
  for (const bad of [null, [], { inputTokens: '3' }, { inputTokens: -1 }, { frage: 1 }]) assert.equal(isValidSession(session(bad), 'x'), false, JSON.stringify(bad));
});

test('contextKey: gleicher Kontext gleich, Name zählt mit, ohne Kontext null', () => {
  assert.equal(contextKey(CONTEXT), contextKey({ ...CONTEXT }));
  assert.notEqual(contextKey(CONTEXT), contextKey({ ...CONTEXT, label: 'Anders' }));
  assert.notEqual(contextKey({ label: 'a', text: 'b\0c' }), contextKey({ label: 'a\0b', text: 'c' }));
  assert.equal(contextKey(undefined), null);
  assert.match(contextKey(CONTEXT), /^[0-9a-f]{64}$/);
});

test('Laufende und ruhende Codex-Prozesse zusammen höchstens zwei; ein neuer Lauf verdrängt den ruhenden', async t => {
  let hang = false;
  const { hub, store, instances } = await setup(t, { hub: { maxWarm: 2 }, rpc: { onTurn: rpc => { if (!hang) rpc.finish(); } } });
  const alive = () => instances.filter(rpc => !rpc.closed).length;
  const [a, b, c] = [await store.create(OWNER), await store.create(OWNER), await store.create(OWNER)];
  await ask(hub, store, a, 'anfrage-0001', {});
  await ask(hub, store, b, 'anfrage-0002', {});
  assert.equal(hub.warm.size, 2);
  hang = true;
  await hub.turn(USER, c.id, request('anfrage-0003'));
  await until(() => instances[2]?.turnId);
  assert.deepEqual([...hub.warm.keys()], [b.id], 'ältester ruhender weicht dem Lauf');
  assert.equal(alive(), 2);
  await hub.turn(USER, a.id, request('anfrage-0004'));
  await until(() => instances[3]?.turnId);
  assert.equal(hub.warm.size, 0);
  assert.equal(alive(), 2, 'zwei Läufe, nichts ruht');
  hang = false;
  for (const rpc of instances.slice(2)) rpc.finish();
  await settled(store, c.id); await settled(store, a.id);
  await until(() => hub.runs.size === 0);
  assert.equal(hub.warm.size, 2);
  assert.ok(alive() <= 2);
});
