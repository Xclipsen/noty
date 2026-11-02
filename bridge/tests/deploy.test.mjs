import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

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
