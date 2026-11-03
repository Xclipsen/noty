import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { RunLog, isRunEntry, mergeQuota, quotaFromRead, quotaShare } from '../server/runlog.mjs';
import { Metering, emptyCounters } from '../server/metering.mjs';
import { DAY_MS } from '../server/store.mjs';
import { setup, settled, tempDir, until, request, PNG, USER, OWNER } from './helpers.mjs';

const IMAGE = { mimeType: 'image/png', base64: PNG.toString('base64'), label: 'BILDNAME-MARKER' };
const TOTAL = { inputTokens: 1000, cachedInputTokens: 600, cacheWriteInputTokens: 40, outputTokens: 120, reasoningOutputTokens: 30, totalTokens: 1120 };
const hang = () => {};
const started = (instances, index = 0) => until(() => instances[index]?.calls.some(c => c.method === 'turn/start'));
const only = runlog => { assert.equal(runlog.entries.length, 1); return runlog.entries[0]; };
const done = async ({ hub, store }, id) => { await settled(store, id); await until(() => hub.runs.size === 0); };

function entry(extra = {}) {
  return { id: randomUUID(), userId: USER, sessionId: randomUUID(), day: '2026-03-01', startedAt: Date.parse('2026-03-01T10:00:00Z'), endedAt: Date.parse('2026-03-01T10:00:05Z'),
    durationMs: 5000, status: 'completed', model: 'demo', effort: null, parallel: false, images: 0, imageBytes: 0, contextChars: 0, questionChars: 5, answerChars: 7,
    tokens: { ...TOTAL }, quotaBefore: null, quota: null, ...extra };
}

test('Laufprotokoll: vollständiger Lauf mit Zahlen, Modell, Denkstufe, Kontingent davor und danach', async t => {
  const onTurn = rpc => {
    rpc.emit('message', { method: 'turn/started', params: { threadId: rpc.threadId, turn: { id: rpc.turnId } } });
    rpc.usage({ ...TOTAL, inputTokens: 10, totalTokens: 12 });
    rpc.usage(TOTAL);
    rpc.quota({ limitId: 'codex', limitName: 'PRIVATER-NAME', primary: { usedPercent: 33, windowDurationMins: 300, resetsAt: 1900000000 }, secondary: null, credits: { balance: '99' }, planType: 'plus' });
    rpc.quota({ limitId: 'codex', primary: null, secondary: { usedPercent: 7, windowDurationMins: 10080, resetsAt: 1900500000 } });
    rpc.finish('Antwort mit 23 Zeichen..');
  };
  const ctx = await setup(t, { rpc: { onTurn, reasoningEffort: 'medium' } });
  const s = await ctx.store.create(OWNER);
  await ctx.hub.turn(USER, s.id, request('anfrage-0001', { text: 'Frage?', context: { label: 'KONTEXTNAME', text: 'x'.repeat(1234) }, images: [IMAGE, IMAGE] }));
  await done(ctx, s.id);
  const run = only(ctx.runlog);
  assert.ok(isRunEntry(run));
  assert.deepEqual({ ...run, id: 0, startedAt: 0, endedAt: 0, durationMs: 0 }, {
    id: 0, userId: USER, sessionId: s.id, day: run.day, startedAt: 0, endedAt: 0, durationMs: 0, status: 'completed', model: 'demo', effort: 'medium', parallel: false,
    images: 2, imageBytes: 2 * PNG.length, contextChars: 1234, questionChars: 6, answerChars: 24, tokens: TOTAL,
    quotaBefore: [{ id: 'codex', windows: [{ slot: 'primary', usedPercent: 32, windowDurationMins: 300, resetsAt: 1900000000 }] }],
    quota: [{ id: 'codex', windows: [{ slot: 'primary', usedPercent: 33, windowDurationMins: 300, resetsAt: 1900000000 }, { slot: 'secondary', usedPercent: 7, windowDurationMins: 10080, resetsAt: 1900500000 }] }]
  });
  assert.equal(run.endedAt - run.startedAt, run.durationMs);
  assert.deepEqual(quotaShare(run), [{ id: 'codex', slot: 'primary', points: 1 }]);
  const counters = ctx.metering.forToday(USER);
  assert.deepEqual([counters.imageBytes, counters.contextChars, counters.cacheWriteInputTokens, counters.totalTokens, counters.timedTurns, counters.durationMs],
    [2 * PNG.length, 1234, 40, 1120, 1, run.durationMs]);
});

test('Laufprotokoll: Standardmodell ohne Wahl, model/rerouted gewinnt, ungültige Kennungen bleiben draußen', async t => {
  const ctx = await setup(t, { rpc: { onTurn: rpc => {
    rpc.emit('message', { method: 'model/rerouted', params: { threadId: rpc.threadId, turnId: rpc.turnId, fromModel: 'demo', toModel: 'sicher-1', reason: 'highRiskCyberActivity' } });
    rpc.emit('message', { method: 'model/rerouted', params: { threadId: rpc.threadId, turnId: rpc.turnId, toModel: '<b>kaputt</b>' } });
    rpc.finish();
  } } });
  await ctx.hub.codexDetails();
  const s = await ctx.store.create(OWNER);
  await ctx.hub.turn(USER, s.id, request('anfrage-0001', { model: 'demo', effort: 'high' }));
  await done(ctx, s.id);
  assert.deepEqual([only(ctx.runlog).model, only(ctx.runlog).effort], ['sicher-1', 'high']);

  // Ohne Antwort von Codex bleibt der bekannte Standard aus model/list stehen.
  const quiet = await setup(t, { rpc: { onTurn: rpc => rpc.finish() } });
  await quiet.hub.codexDetails();
  const factory = quiet.hub.rpcFactory;
  quiet.hub.rpcFactory = options => {
    const rpc = factory(options); const forward = rpc.request.bind(rpc);
    rpc.request = async (method, params) => method === 'thread/start' ? { thread: { id: 'thread-test' } } : forward(method, params);
    return rpc;
  };
  const other = await quiet.store.create(OWNER);
  await quiet.hub.turn(USER, other.id, request());
  await done(quiet, other.id);
  assert.deepEqual([only(quiet.runlog).model, only(quiet.runlog).effort], ['demo', null]);
});

test('Laufprotokoll: Fehler, Zeitlimit, Abbruch, Sperre und Löschen ergeben den passenden Status', async t => {
  const cases = [
    ['failed', { onTurn: rpc => { rpc.usage(TOTAL); rpc.complete('failed', { message: 'x' }); } }, {}, async () => {}],
    ['failed', { failThread: true }, {}, async () => {}],
    ['timeout', { onTurn: hang }, { turnTimeoutMs: 30 }, async () => {}],
    ['interrupted', { onTurn: rpc => rpc.usage(TOTAL) }, {}, async ({ hub, s }) => { await until(() => hub.runs.get(s.id)?.turnId); await hub.cancel(USER, s.id); }],
    ['interrupted', { onTurn: hang }, {}, async ({ hub, instances }) => { await started(instances); await hub.abortUser(USER); }],
    ['interrupted', { onTurn: hang }, {}, async ({ hub, s, instances }) => { await started(instances); await hub.remove(USER, s.id); }]
  ];
  for (const [status, rpc, hubOptions, act] of cases) {
    const ctx = await setup(t, { rpc, hub: hubOptions });
    const s = await ctx.store.create(OWNER);
    await ctx.hub.turn(USER, s.id, request());
    await act({ ...ctx, s });
    await until(() => ctx.hub.runs.size === 0);
    const run = only(ctx.runlog);
    assert.equal(run.status, status, JSON.stringify(rpc));
    assert.ok(Number.isSafeInteger(run.durationMs) && run.endedAt >= run.startedAt, status);
    assert.equal(ctx.metering.forToday(USER).timedTurns, 1, status);
    if (rpc.onTurn && rpc.onTurn !== hang) assert.equal(run.tokens.inputTokens, 1000, status);
  }
});

test('Laufprotokoll: Neustart im Lauf ergibt restarted, beim Herunterfahren mit Ende, beim Absturz ohne', async t => {
  const first = await setup(t, { rpc: { onTurn: rpc => rpc.usage(TOTAL) } });
  const s = await first.store.create(OWNER);
  await first.hub.turn(USER, s.id, request());
  await started(first.instances);
  await until(() => first.runlog.entries[0]?.tokens.inputTokens === 1000);
  await first.hub.close();
  const closed = JSON.parse(await readFile(first.runlog.file, 'utf8'));
  assert.deepEqual([closed.length, closed[0].status, closed[0].tokens.inputTokens], [1, 'restarted', 1000]);
  assert.ok(Number.isSafeInteger(closed[0].durationMs));
  const second = await setup(t, { root: first.root });
  await second.hub.startRetention();
  assert.equal(only(second.runlog).status, 'restarted');
  assert.equal(second.metering.forToday(USER).failedTurns, 1);

  // Harter Absturz: Der Eintrag steht noch als running auf der Platte.
  const crash = await setup(t, { rpc: { onTurn: hang } });
  const c = await crash.store.create(OWNER);
  await crash.hub.turn(USER, c.id, request());
  await started(crash.instances);
  await crash.runlog.flush();
  assert.equal(JSON.parse(await readFile(crash.runlog.file, 'utf8'))[0].status, 'running');
  const reborn = await new RunLog({ root: crash.root }).init();
  assert.deepEqual([only(reborn).status, only(reborn).endedAt, only(reborn).durationMs], ['restarted', null, null]);
  assert.equal(JSON.parse(await readFile(crash.runlog.file, 'utf8'))[0].status, 'restarted');
  await crash.hub.cancel(USER, c.id);
});

test('Laufprotokoll: Lauf über Mitternacht UTC bleibt auf dem Tag der Reservierung', async t => {
  let now = Date.parse('2026-03-01T23:59:50Z');
  let rpcRef;
  const ctx = await setup(t, { metering: { now: () => now }, rpc: { onTurn: rpc => { rpcRef = rpc; } } });
  const s = await ctx.store.create(OWNER);
  await ctx.hub.turn(USER, s.id, request());
  await until(() => rpcRef);
  now = Date.parse('2026-03-02T00:00:20Z');
  rpcRef.usage(TOTAL);
  rpcRef.finish();
  await done(ctx, s.id);
  const run = only(ctx.runlog);
  assert.deepEqual([run.day, run.startedAt, run.endedAt, run.durationMs], ['2026-03-01', Date.parse('2026-03-01T23:59:50Z'), now, 30_000]);
  const day = ctx.metering.days.get('2026-03-01').get(USER);
  assert.deepEqual([day.turns, day.totalTokens, day.durationMs, day.timedTurns], [1, 1120, 30_000, 1]);
  assert.equal(ctx.metering.days.get('2026-03-02')?.get(USER), undefined);
});

test('Laufprotokoll: parallele Läufe sind markiert und haben keinen Anteil am Kontingent', async t => {
  const ctx = await setup(t, { rpc: { onTurn: hang } });
  const a = await ctx.store.create(OWNER);
  const b = await ctx.store.create(OWNER);
  await ctx.hub.turn(USER, a.id, request('anfrage-0001'));
  await ctx.hub.turn(USER, b.id, request('anfrage-0002'));
  assert.deepEqual(ctx.runlog.entries.map(run => run.parallel), [true, true]);
  const run = entry({ parallel: true, quotaBefore: [{ id: 'codex', windows: [{ slot: 'primary', usedPercent: 1, windowDurationMins: 300, resetsAt: 5 }] }], quota: [{ id: 'codex', windows: [{ slot: 'primary', usedPercent: 2, windowDurationMins: 300, resetsAt: 5 }] }] });
  assert.equal(quotaShare(run), null);
  assert.deepEqual(quotaShare({ ...run, parallel: false }), [{ id: 'codex', slot: 'primary', points: 1 }]);
  assert.equal(quotaShare({ ...run, parallel: false, quota: [{ id: 'codex', windows: [{ slot: 'primary', usedPercent: 2, windowDurationMins: 300, resetsAt: 6 }] }] }), null, 'anderes Fenster');
  assert.equal(quotaShare({ ...run, parallel: false, quotaBefore: null }), null);
  await ctx.hub.abortUser(USER);
});

test('Laufprotokoll: Kontingentstand davor zählt nicht, wenn er nach der ersten Meldung ankommt', async t => {
  let answer;
  const ctx = await setup(t, { rpc: { onTurn: rpc => { rpc.quota({ limitId: 'codex', primary: { usedPercent: 40, windowDurationMins: 300, resetsAt: 1900000000 } }); answer(); rpc.finish(); } } });
  const late = new Promise(resolve => { answer = resolve; });
  ctx.hub.rpcFactory = (factory => options => {
    const rpc = factory(options); const request = rpc.request.bind(rpc);
    rpc.request = async (method, params) => { if (method === 'account/rateLimits/read') { await late; await new Promise(setImmediate); } return request(method, params); };
    return rpc;
  })(ctx.hub.rpcFactory);
  const s = await ctx.store.create(OWNER);
  await ctx.hub.turn(USER, s.id, request());
  await done(ctx, s.id);
  assert.equal(only(ctx.runlog).quotaBefore, null);
  assert.equal(only(ctx.runlog).quota[0].windows[0].usedPercent, 40);
});

test('Kontingent: spärliche Meldungen, nur Zahlen, begrenzt', () => {
  let quota = mergeQuota(null, { limitId: 'codex', limitName: 'GEHEIM', primary: { usedPercent: 3, windowDurationMins: 300, resetsAt: 10 }, credits: { balance: '5' } });
  quota = mergeQuota(quota, { limitId: 'codex', primary: { usedPercent: 4 }, secondary: null });
  assert.deepEqual(quota, [{ id: 'codex', windows: [{ slot: 'primary', usedPercent: 4, windowDurationMins: null, resetsAt: null }] }]);
  assert.equal(mergeQuota(quota, { primary: { usedPercent: -1 } }), quota);
  assert.equal(mergeQuota(quota, 'x'), quota);
  assert.equal(mergeQuota(null, { limitId: '<b>', primary: { usedPercent: 1 } })[0].id, 'codex');
  for (let i = 0; i < 20; i++) quota = mergeQuota(quota, { limitId: `l${i}`, primary: { usedPercent: i } });
  assert.equal(quota.length, 8);
  assert.ok(!JSON.stringify(quota).includes('GEHEIM'));
  assert.deepEqual(quotaFromRead({ rateLimitsByLimitId: { codex: { primary: { usedPercent: 2 } } }, rateLimits: { limitId: 'x', primary: { usedPercent: 9 } } }), [{ id: 'codex', windows: [{ slot: 'primary', usedPercent: 2, windowDurationMins: null, resetsAt: null }] }]);
  assert.equal(quotaFromRead(null), null);
});

test('Laufprotokoll: keine Inhalte in Dateien, auch nicht gekürzt oder gehasht', async t => {
  const { createHash } = await import('node:crypto');
  const markers = { frage: 'FRAGE-MARKER-4711', antwort: 'ANTWORT-MARKER-4712', kontext: 'KONTEXT-MARKER-4713', kontextname: 'KONTEXTNAME-MARKER-4714', bild: 'BILDNAME-MARKER' };
  const ctx = await setup(t, { rpc: { tokens: [TOTAL], answer: markers.antwort } });
  const s = await ctx.store.create(OWNER);
  await ctx.hub.turn(USER, s.id, request('anfrage-0001', { text: markers.frage, context: { label: markers.kontextname, text: markers.kontext }, images: [IMAGE] }));
  await done(ctx, s.id);
  await ctx.runlog.flush(); await ctx.metering.flush();
  const raw = await readFile(ctx.runlog.file, 'utf8') + await readFile(path.join(ctx.root, 'metering.json'), 'utf8');
  const hashes = Object.values(markers).flatMap(marker => ['sha256', 'sha1', 'md5'].map(name => createHash(name).update(marker).digest('hex').slice(0, 12)));
  for (const needle of [...Object.values(markers), ...Object.values(markers).map(m => m.slice(0, 8)), 'MARKER', PNG.toString('base64').slice(0, 12), 'anfrage-0001', ...hashes]) assert.ok(!raw.includes(needle), needle);
  const keys = Object.keys(JSON.parse(await readFile(ctx.runlog.file, 'utf8'))[0]).sort();
  assert.deepEqual(keys, ['answerChars', 'contextChars', 'day', 'durationMs', 'effort', 'endedAt', 'id', 'imageBytes', 'images', 'model', 'parallel', 'questionChars', 'quota', 'quotaBefore', 'sessionId', 'startedAt', 'status', 'tokens', 'userId'].sort());
  assert.equal((await stat(ctx.runlog.file)).mode & 0o777, 0o600);
});

test('Laufprotokoll: höchstens 5000 Einträge und nicht älter als NOTY_AI_USAGE_DAYS', async t => {
  const root = await tempDir(t);
  let now = Date.parse('2026-03-01T00:00:00Z');
  const log = await new RunLog({ root, now: () => now, maxEntries: 5, usageDays: 2 }).init();
  for (let i = 0; i < 8; i++) log.finish(log.start({ userId: USER, sessionId: randomUUID(), day: '2026-03-01' }), 'completed');
  assert.equal(log.entries.length, 5);
  assert.deepEqual(log.entries.map(run => run.startedAt - now), [3, 4, 5, 6, 7], 'eindeutige, steigende Startzeiten');
  now += 2 * DAY_MS + 3;
  await log.prune();
  assert.equal(log.entries.length, 5, 'genau an der Grenze bleibt alles');
  now += 1;
  await log.prune();
  assert.equal(log.entries.length, 4);
  now += 10;
  await log.prune();
  assert.equal(log.entries.length, 0);
  await log.flush();
  assert.deepEqual(JSON.parse(await readFile(log.file, 'utf8')), []);
  assert.equal(new RunLog({ root }).maxEntries, 5000);

  // Eine zu lange Datei wird beim Laden gekürzt, Älteres zuerst.
  const many = Array.from({ length: 12 }, (_, i) => entry({ startedAt: now + i, endedAt: now + i + 1, durationMs: 1 }));
  now += 5;
  await writeFile(log.file, JSON.stringify(many.reverse()));
  const loaded = await new RunLog({ root, now: () => now, maxEntries: 10 }).init();
  assert.deepEqual(loaded.entries.map(run => run.startedAt - now + 5), [2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
});

test('Laufprotokoll: Prüfung beim Laden; kaputte Dateien stoppen den Start wie metering.json', async t => {
  const root = await tempDir(t);
  const file = path.join(root, 'runs.json');
  const bad = [
    'kein json', '{}', '5', '"abc"', 'null', '[5]', '[null]',
    JSON.stringify([entry({ status: 'unbekannt' })]), JSON.stringify([entry({ id: 'x' })]), JSON.stringify([entry({ userId: '' })]),
    JSON.stringify([entry({ tokens: { ...TOTAL, inputTokens: -1 } })]), JSON.stringify([entry({ tokens: { inputTokens: 1 } })]), JSON.stringify([entry({ imageBytes: 1.5 })]),
    JSON.stringify([entry({ model: 'mit leerzeichen' })]), JSON.stringify([entry({ effort: 'HOCH' })]), JSON.stringify([entry({ day: '1.3.2026' })]),
    JSON.stringify([entry({ quota: [{ id: 'codex', windows: [{ slot: 'tertiary', usedPercent: 1, windowDurationMins: null, resetsAt: null }] }] })]),
    JSON.stringify([entry({ quota: [{ id: 'codex', windows: [{ slot: 'primary', usedPercent: Number.MAX_VALUE, windowDurationMins: null, resetsAt: null }] }] })]),
    JSON.stringify([entry({ parallel: 'nein' })]), JSON.stringify([entry({ startedAt: 0 })])
  ];
  for (const content of bad) {
    await writeFile(file, content);
    await assert.rejects(new RunLog({ root }).init(), /Laufprotokoll ist unlesbar/, content.slice(0, 80));
    await assert.rejects(setup(t, { root }), /Laufprotokoll ist unlesbar/);
  }
  // Unbekannte Felder werden nicht übernommen, doppelte Einträge nur einmal.
  const good = entry({ text: 'FREMDTEXT', tokens: { ...TOTAL, extra: 'FREMD' } });
  await writeFile(file, JSON.stringify([good, good]));
  const log = await new RunLog({ root }).init();
  assert.equal(log.entries.length, 1);
  await log.flush();
  assert.ok(!(await readFile(file, 'utf8')).includes('FREMD'));
});

test('Laufprotokoll: list blättert neueste zuerst, filtert Konto und Status, liefert next', async t => {
  const root = await tempDir(t);
  let now = 1_800_000_000_000;
  const log = await new RunLog({ root, now: () => now }).init();
  for (let i = 0; i < 7; i++) {
    const run = log.start({ userId: i % 2 ? 'konto-b' : USER, sessionId: randomUUID(), day: '2027-01-15' });
    if (i !== 6) log.finish(run, i % 3 ? 'completed' : 'failed');
    now += 1000;
  }
  const first = log.list({ limit: 3 });
  assert.deepEqual(first.runs.map(run => run.status), ['running', 'completed', 'completed']);
  const second = log.list({ limit: 3, before: first.next });
  assert.deepEqual(second.runs.map(run => run.startedAt), [1_800_000_003_000, 1_800_000_002_000, 1_800_000_001_000]);
  const third = log.list({ limit: 3, before: second.next });
  assert.deepEqual([third.runs.length, third.next], [1, null]);
  assert.deepEqual(log.list({ user: 'konto-b' }).runs.map(run => run.userId), ['konto-b', 'konto-b', 'konto-b']);
  assert.deepEqual(log.list({ status: 'failed' }).runs.length, 2);
  assert.deepEqual(log.list({ status: 'failed', user: 'konto-b' }).runs.length, 1);
  assert.equal(log.list({ limit: 2, user: 'fehlt' }).next, null);
  assert.ok(log.list().runs.every(run => 'quotaShare' in run));
  log.list().runs[0].tokens.inputTokens = 99;
  assert.equal(log.entries.at(-1).tokens.inputTokens, 0, 'list liefert Kopien');
});

test('Metering: ältere Dateien bleiben lesbar, totalTokens wird abgeleitet, neue Zähler starten bei 0', async t => {
  const root = await tempDir(t);
  await writeFile(path.join(root, 'metering.json'), JSON.stringify({ '2026-03-01': { a: { turns: 2, failedTurns: 0, images: 1, inputTokens: 100, cachedInputTokens: 40, outputTokens: 20, reasoningOutputTokens: 5 } } }));
  const metering = await new Metering({ root, now: () => Date.parse('2026-03-01T12:00:00Z') }).init();
  assert.deepEqual(metering.forToday('a'), { ...emptyCounters(), turns: 2, images: 1, inputTokens: 100, cachedInputTokens: 40, outputTokens: 20, reasoningOutputTokens: 5, totalTokens: 120 });
  await writeFile(path.join(root, 'metering.json'), JSON.stringify({ '2026-03-01': { a: { turns: 1, inputTokens: 100, outputTokens: 20, totalTokens: 999 } } }));
  assert.equal((await new Metering({ root, now: () => Date.parse('2026-03-01T12:00:00Z') }).init()).forToday('a').totalTokens, 999, 'vorhandener Wert bleibt');
  const series = metering.series(3);
  assert.deepEqual([series.from, series.to, series.total.sum.turns, Object.keys(series.users.get('a').days)], ['2026-02-27', '2026-03-01', 2, ['2026-03-01']]);
  assert.deepEqual(metering.rows().map(row => [row.day, row.userId, row.counters.totalTokens]), [['2026-03-01', 'a', 120]]);
});

test('Laufprotokoll: bleibt bei Schreibfehlern im Speicher und holt nach', async t => {
  const ctx = await setup(t, { runs: { updateSaveMs: 5 } });
  ctx.runlog.writer.retryMs = 5;
  const file = ctx.runlog.writer.file;
  ctx.runlog.writer.file = path.join(ctx.root, 'fehlt', 'runs.json');
  const s = await ctx.store.create(OWNER);
  await ctx.hub.turn(USER, s.id, request());
  await done(ctx, s.id);
  assert.equal(s.status, 'idle', 'Lauf übersteht den Schreibfehler');
  ctx.runlog.writer.file = file;
  await until(() => { try { return JSON.parse(readFileSync(file, 'utf8'))[0]?.status === 'completed'; } catch { return false; } });
  assert.deepEqual((await readdir(ctx.root)).filter(name => name.endsWith('.tmp')), []);
});
