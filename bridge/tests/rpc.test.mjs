#!/usr/bin/env node
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile, chmod, stat } from 'node:fs/promises';
import path from 'node:path';
import { CodexRpc, CODEX_ARGS, toolFreeCatalog, toolFreeModel } from '../server/rpc.mjs';
import { tempDir } from './helpers.mjs';

const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
const wait = async condition => { for (let i = 0; i < 400; i++) { if (condition()) return true; await new Promise(r => setTimeout(r, 10)); } return false; };

/** Kleines Ersatzprogramm für `codex`; `body` läuft zusätzlich zum JSON-RPC-Echo. */
async function fakeCodex(root, body = '') {
  const file = path.join(root, 'codex');
  await writeFile(file, `#!${process.execPath}
const fs = require('node:fs'), rl = require('node:readline');
fs.writeFileSync(${JSON.stringify(path.join(root, 'start.json'))}, JSON.stringify({ argv: process.argv.slice(2), env: process.env, cwd: process.cwd(), pid: process.pid }));
process.stderr.write('STDERR-MARKER\\n');
${body}
rl.createInterface({ input: process.stdin }).on('line', line => {
  const m = JSON.parse(line);
  if (m.method === 'crash') process.exit(3);
  if (m.method === 'ask') { console.log(JSON.stringify({ id: 99, method: 'item/commandExecution/requestApproval', params: {} })); console.log('kein json'); }
  if (m.id !== undefined) console.log(JSON.stringify(m.method === 'bad' ? { id: m.id, error: { message: 'nein' } } : { id: m.id, result: { echo: m.method } }));
});
`);
  await chmod(file, 0o755);
  return file;
}
const start = async (t, root, options = {}) => {
  const rpc = new CodexRpc({ command: await fakeCodex(root, options.body), cwd: root, codexHome: root, timeout: options.timeout ?? 2000, killAfter: 100 });
  t.after(() => rpc.close());
  await rpc.start();
  return rpc;
};

test('Start: Werkzeuge aus, enge Umgebung, Name noty_ai', async t => {
  const root = await tempDir(t);
  process.env.BRIDGE_GEHEIM = 'nicht-weitergeben';
  t.after(() => { delete process.env.BRIDGE_GEHEIM; });
  const rpc = await start(t, root);
  const seen = JSON.parse(await readFile(path.join(root, 'start.json'), 'utf8'));
  assert.deepEqual(seen.argv, CODEX_ARGS);
  for (const flag of ['features.shell_tool=false', 'features.unified_exec=false', 'features.code_mode=false', 'features.apply_patch_freeform=false', 'features.view_image=false', 'features.multi_agent=false', 'web_search="disabled"']) assert.ok(seen.argv.includes(flag), flag);
  assert.equal(seen.env.BRIDGE_GEHEIM, undefined);
  assert.equal(seen.env.CODEX_HOME, root);
  assert.equal(seen.cwd, root);
  assert.equal(rpc.child.stdio[2], null, 'stderr wird verworfen, nicht gelesen');
});

test('Katalog ohne Werkzeuge: aus dem Cache, Datei 600, als Schalter übergeben', async t => {
  const root = await tempDir(t);
  const file = path.join(root, 'katalog.json');
  await assert.rejects(toolFreeCatalog({ codexHome: root, file }), e => e.status === 503);
  await writeFile(path.join(root, 'models_cache.json'), '{"models":[]}');
  await assert.rejects(toolFreeCatalog({ codexHome: root, file }), e => e.status === 503);
  const model = { slug: 'm', shell_type: 'unified_exec', apply_patch_tool_type: 'freeform', tool_mode: 'code_mode_only', multi_agent_version: 'v2', multi_agent_reasoning_effort: 'xhigh', supports_search_tool: true, experimental_supported_tools: ['clock'], display_name: 'M', include_skills_usage_instructions: true };
  await writeFile(path.join(root, 'models_cache.json'), JSON.stringify({ etag: 'x', identity: 'privat', models: [model] }));
  assert.equal(await toolFreeCatalog({ codexHome: root, file }), file);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  const saved = JSON.parse(await readFile(file, 'utf8'));
  assert.deepEqual(saved, { models: [toolFreeModel(model)] });
  const [stripped] = saved.models;
  assert.deepEqual([stripped.slug, stripped.display_name, stripped.shell_type, stripped.apply_patch_tool_type, stripped.supports_search_tool, stripped.experimental_supported_tools, stripped.include_skills_usage_instructions], ['m', 'M', 'disabled', null, false, [], false]);
  for (const key of ['tool_mode', 'multi_agent_version', 'multi_agent_reasoning_effort']) assert.ok(!(key in stripped), key);
  const rpc = new CodexRpc({ command: await fakeCodex(root), cwd: root, codexHome: root, catalog: file, timeout: 2000, killAfter: 100 });
  t.after(() => rpc.close());
  await rpc.start();
  const seen = JSON.parse(await readFile(path.join(root, 'start.json'), 'utf8'));
  assert.equal(seen.argv.at(-1), `model_catalog_json=${JSON.stringify(file)}`);
});

test('Anfragen, Fehlerantworten, Server-Requests, kaputte Zeilen', async t => {
  const root = await tempDir(t);
  const rpc = await start(t, root);
  assert.deepEqual(await rpc.request('hallo'), { echo: 'hallo' });
  await assert.rejects(rpc.request('bad'), /nein/);
  const message = new Promise(resolve => rpc.once('message', resolve));
  await rpc.request('ask');
  assert.equal((await message).method, 'item/commandExecution/requestApproval');
});

test('Absturz: offene Anfragen scheitern, disconnect kommt', async t => {
  const root = await tempDir(t);
  const rpc = await start(t, root);
  const disconnected = new Promise(resolve => rpc.once('disconnect', resolve));
  await assert.rejects(rpc.request('crash'), /closed/);
  await disconnected;
  await rpc.close();
});

test('Fehlendes Programm scheitert sauber', async t => {
  const root = await tempDir(t);
  const rpc = new CodexRpc({ command: path.join(root, 'fehlt'), cwd: root, codexHome: root, timeout: 500 });
  rpc.on('disconnect', () => {});
  await assert.rejects(rpc.start());
  await rpc.close();
});

test('Zeitüberschreitung einer Anfrage', async t => {
  const root = await tempDir(t);
  const rpc = await start(t, root, { timeout: 200 });
  rpc.options.timeout = 20;
  rpc.child.stdin.cork();
  await assert.rejects(rpc.request('hallo'), /timed out/);
  rpc.child.stdin.uncork();
});

test('close beendet den Prozess', async t => {
  const root = await tempDir(t);
  const rpc = await start(t, root);
  const { pid } = rpc.child;
  await rpc.close();
  assert.equal(alive(pid), false);
  await rpc.close();
});

test('close erzwingt das Ende, wenn SIGTERM ignoriert wird, samt Kindprozess', async t => {
  const root = await tempDir(t);
  const pidFile = path.join(root, 'kind.pid');
  const rpc = await start(t, root, { body: `
    process.on('SIGTERM', () => {});
    const kind = require('node:child_process').spawn(process.execPath, ['-e', "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"], { stdio: 'ignore' });
    fs.writeFileSync(${JSON.stringify(pidFile)}, String(kind.pid));` });
  assert.ok(await wait(() => { try { return !!Number(require_(pidFile)); } catch { return false; } }));
  const child = Number(require_(pidFile));
  assert.equal(alive(child), true);
  await rpc.close();
  assert.equal(alive(rpc.child.pid), false);
  assert.ok(await wait(() => !alive(child)), 'Kindprozess ist weg');
});

import { readFileSync } from 'node:fs';
function require_(file) { return readFileSync(file, 'utf8'); }
