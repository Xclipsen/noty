import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { chmod, mkdir, readFile, stat, symlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { tempDir } from './helpers.mjs';

const read = name => readFile(new URL(`../deploy/${name}`, import.meta.url), 'utf8');

test('Unit: eigener Benutzer, Härtung, Port 8790, ohne Kopplungsreste', async () => {
  const unit = await read('noty-ai.service');
  for (const line of ['User=noty-ai', 'StateDirectory=noty-ai', 'Environment=PORT=8790', 'NoNewPrivileges=yes', 'ProtectSystem=strict', 'ProtectHome=yes', 'PrivateTmp=yes', 'CapabilityBoundingSet=', 'ReadWritePaths=/var/lib/noty-ai', 'InaccessiblePaths=-/srv/obsidian', 'Environment=NOTY_AI_ACCOUNT_URL=http://127.0.0.1:18083']) assert.ok(unit.includes(line), line);
  assert.ok(!/BRIDGE_TOKEN|VAULT_PATH|MyNotes/.test(unit));
  assert.ok(unit.includes('Environment=NOTY_AI_ADMIN_ORIGIN=https://noty.xclipsen.de'));
});

test('Provisionierung: kopiert keine Anmeldung, kennt keinen Bridge-Schlüssel', async () => {
  const script = await read('provision.py');
  assert.ok(!/auth\.json|bridge-token|\/root\/\.codex/.test(script));
  assert.match(script, /for name in \['server', 'admin'\]:/, 'admin.mjs lädt die Oberfläche beim Start aus ../admin');
  for (const text of ['forced_login_method = "chatgpt"', 'cli_auth_credentials_store = "file"', '0.166.0', "'install', '--prefix'", 'v22.22.2/bin/node']) assert.ok(script.includes(text), text);
});

test('Befund 1: Unit trennt PORT und ADMIN_PORT', async () => {
  const unit = await read('noty-ai.service');
  assert.ok(unit.includes('Environment=PORT=8790'));
  assert.ok(unit.includes('Environment=ADMIN_PORT=8791'));
});

test('Befund 5: Unit begrenzt Speicher, Aufgaben und CPU; Heap passt in MemoryMax', async () => {
  const unit = await read('noty-ai.service');
  for (const line of ['MemoryMax=1G', 'TasksMax=128', 'CPUQuota=200%', 'ProtectProc=invisible', 'ProcSubset=pid', 'RestrictNamespaces=yes', 'SystemCallArchitectures=native']) assert.ok(unit.split('\n').includes(line), line);
  const heap = Number(/--max-old-space-size=(\d+)/.exec(unit)?.[1]);
  assert.ok(heap >= 256 && heap <= 512, String(heap));
});

/**
 * Führt `prepare_state` aus provision.py in einem Testordner aus, ohne den Rest der Einrichtung.
 * Der Import läuft unter root: Ohne `__main__`-Schutz würde er den Dienst wirklich einrichten.
 */
function prepareState(state) {
  assert.match(readFileSync(new URL('../deploy/provision.py', import.meta.url), 'utf8'), /^if __name__ == '__main__':\n    main\(\)\n/m, 'provision.py darf ohne Schutz nicht importiert werden');
  const code = `import os, sys
sys.path.insert(0, ${JSON.stringify(new URL('../deploy/', import.meta.url).pathname)})
import provision
from pathlib import Path
provision.prepare_state(Path(sys.argv[1]), os.getuid(), os.getgid())`;
  return spawnSync('python3', ['-B', '-c', code, state], { encoding: 'utf8' });
}

test('Befund 6: normaler Lauf legt private Ordner und config.toml an und ist wiederholbar', async t => {
  const state = path.join(await tempDir(t), 'noty-ai');
  const first = prepareState(state);
  assert.equal(first.status, 0, first.stderr);
  for (const directory of [state, `${state}/codex`, `${state}/state`]) assert.equal((await stat(directory)).mode & 0o777, 0o700);
  const config = `${state}/codex/config.toml`;
  assert.equal((await stat(config)).mode & 0o777, 0o600);
  assert.match(await readFile(config, 'utf8'), /forced_login_method = "chatgpt"/);
  await writeFile(config, 'eigene = "werte"\n');
  assert.equal(prepareState(state).status, 0);
  assert.equal(await readFile(config, 'utf8'), 'eigene = "werte"\n');
});

test('Befund 6: Symlinks führen zum Abbruch, das Ziel bleibt unberührt', async t => {
  const cases = {
    state: async (state, target) => symlink(target, state),
    codex: async (state, target) => { await mkdir(state); await symlink(target, `${state}/codex`); },
    'state/state': async (state, target) => { await mkdir(state); await symlink(target, `${state}/state`); },
    'config.toml': async (state, target) => { await mkdir(`${state}/codex`, { recursive: true }); await symlink(`${target}/geheim`, `${state}/codex/config.toml`); },
    'config.toml ohne Ziel': async (state, target) => { await mkdir(`${state}/codex`, { recursive: true }); await symlink(`${target}/neu-angelegt`, `${state}/codex/config.toml`); }
  };
  for (const [label, arrange] of Object.entries(cases)) {
    const root = await tempDir(t);
    const target = path.join(root, 'ziel');
    await mkdir(target);
    await chmod(target, 0o755);
    await writeFile(`${target}/geheim`, 'unverändert');
    await chmod(`${target}/geheim`, 0o644);
    const state = path.join(root, 'noty-ai');
    await arrange(state, target);
    const run = prepareState(state);
    assert.notEqual(run.status, 0, label);
    assert.match(run.stderr, /Symlink|kein echter/, label);
    assert.ok(!run.stderr.includes('Traceback'), label);
    assert.equal((await stat(target)).mode & 0o777, 0o755, label);
    assert.equal((await stat(`${target}/geheim`)).mode & 0o777, 0o644, label);
    assert.equal(await readFile(`${target}/geheim`, 'utf8'), 'unverändert', label);
    await assert.rejects(stat(`${target}/neu-angelegt`), { code: 'ENOENT' }, label);
    await assert.rejects(stat(`${target}/codex`), { code: 'ENOENT' }, label);
  }
});

test('Befund 6: Datei statt Ordner bricht ebenfalls ab', async t => {
  const state = path.join(await tempDir(t), 'noty-ai');
  await mkdir(state);
  await writeFile(`${state}/codex`, 'Datei');
  const run = prepareState(state);
  assert.notEqual(run.status, 0);
  assert.ok(!run.stderr.includes('Traceback'));
});

test('Befund 6: Import von provision.py richtet nichts ein; Rechte auf /opt bleiben', async () => {
  const script = await read('provision.py');
  assert.match(script, /if __name__ == '__main__':/);
  assert.ok(script.includes("['chmod', '-R', 'a+rX', str(app)]"));
  assert.ok(script.includes("['setfacl', '-Rb', str(app)]"));
  assert.ok(script.includes('O_NOFOLLOW'));
  assert.ok(!/config\.write_text|\.write_text\(/.test(script));
});
