import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { EventEmitter } from 'node:events';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { ApiError, writeAtomic } from './store.mjs';

// Die Vorlagen-Schalter allein reichen nicht: view_image, multi_agent und goals bleiben sonst an,
// und je nach Modell liefert der Katalog exec, apply_patch und Unteragenten. Siehe toolFreeCatalog.
const FEATURES_OFF = ['shell_tool', 'unified_exec', 'code_mode', 'code_mode_host', 'apply_patch_freeform', 'view_image', 'image_generation',
  'multi_agent', 'goals', 'plugins', 'apps', 'tool_suggest', 'skill_search', 'sleep_tool', 'browser_use', 'computer_use', 'in_app_browser', 'hooks'];
export const CODEX_ARGS = ['app-server', '--stdio',
  ...FEATURES_OFF.flatMap(name => ['-c', `features.${name}=false`]),
  '-c', 'web_search="disabled"', '-c', 'history.persistence="none"', '-c', 'analytics.enabled=false'];

/** Modelleintrag ohne Shell, Patch, Code-Modus und Unteragenten; übrig bleibt allein request_user_input, das die Bridge zurückweist. */
export function toolFreeModel(model) {
  const { tool_mode, multi_agent_version, multi_agent_reasoning_effort, ...rest } = model;
  return { ...rest, shell_type: 'disabled', apply_patch_tool_type: null, supports_search_tool: false, experimental_supported_tools: [],
    include_apps_usage_instructions: false, include_plugin_usage_instructions: false, include_skills_usage_instructions: false };
}

/** Schreibt den Katalog für Läufe aus dem von Codex gepflegten Cache; ohne Cache gibt es keinen Lauf. */
export async function toolFreeCatalog({ codexHome, file }) {
  let models;
  try { ({ models } = JSON.parse(await readFile(path.join(codexHome, 'models_cache.json'), 'utf8'))); } catch { models = null; }
  if (!Array.isArray(models) || !models.length) throw new ApiError(503, 'Der Modellkatalog ist noch nicht verfügbar.');
  await writeAtomic(file, JSON.stringify({ models: models.map(toolFreeModel) }));
  return file;
}

export class CodexRpc extends EventEmitter {
  constructor({ command = 'codex', cwd, codexHome, catalog, timeout = 45000, killAfter = 2000 }) {
    super();
    this.options = { command, cwd, codexHome, catalog, timeout, killAfter };
    this.pending = new Map(); this.nextId = 1; this.failed = false; this.closing = null;
  }
  async start() {
    const { command, cwd, codexHome, catalog } = this.options;
    // Eigene Prozessgruppe: der npm-Starter von Codex ist nur ein Wrapper um das native Programm.
    this.child = spawn(command, [...CODEX_ARGS, ...(catalog ? ['-c', `model_catalog_json=${JSON.stringify(catalog)}`] : [])], {
      cwd, detached: true, stdio: ['pipe', 'pipe', 'ignore'],
      env: { PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8', CODEX_HOME: codexHome }
    });
    this.child.on('error', error => this.fail(error));
    this.child.stdin.on('error', error => this.fail(error));
    this.child.on('exit', () => { this.signal('SIGKILL'); this.fail(new Error('Codex connection closed.')); });
    this.lines = createInterface({ input: this.child.stdout });
    this.lines.on('line', line => this.receive(line));
    await this.request('initialize', { clientInfo: { name: 'noty_ai', title: 'noty KI', version: '0.1.0' }, capabilities: { experimentalApi: true } });
    this.send({ method: 'initialized', params: {} });
    return this;
  }
  receive(line) {
    let message; try { message = JSON.parse(line); } catch { return; }
    if (message.method) { this.emit('message', message); return; }
    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id); clearTimeout(pending.timer);
    if (message.error) pending.reject(new Error(message.error.message)); else pending.resolve(message.result);
  }
  send(message) {
    if (!this.child?.stdin.writable) throw new Error('Codex is not connected.');
    this.child.stdin.write(JSON.stringify(message) + '\n');
  }
  request(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`Codex request timed out: ${method}`)); }, this.options.timeout);
      this.pending.set(id, { resolve, reject, timer });
      try { this.send({ id, method, params }); } catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }
  respond(id, result) { this.send({ id, result }); }
  reject(id, code, message) { this.send({ id, error: { code, message } }); }
  fail(error) {
    if (this.failed) return;
    this.failed = true;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear(); this.emit('disconnect', error);
  }
  signal(name) {
    try { process.kill(-this.child.pid, name); } catch { /* Gruppe ist bereits beendet. */ }
  }
  /** Beendet den Prozess sicher; aufgelöst erst, wenn er wirklich weg ist. */
  close() {
    if (this.closing) return this.closing;
    this.lines?.close();
    const child = this.child;
    if (!child?.pid || child.exitCode !== null || child.signalCode !== null) return (this.closing = Promise.resolve());
    this.closing = new Promise(resolve => {
      const timer = setTimeout(() => this.signal('SIGKILL'), this.options.killAfter);
      child.once('exit', () => { clearTimeout(timer); resolve(); });
      child.stdin.end();
      this.signal('SIGTERM');
    });
    return this.closing;
  }
}
