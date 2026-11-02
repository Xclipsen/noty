"""Richtet Benutzer, Laufzeit und Zustandsordner der noty-KI-Bridge ein. Idempotent.

Als root auf dem Zielserver ausführen. Kopiert keine bestehende Codex-Anmeldung,
gibt keine Schlüssel aus und startet keine Dienste.
"""
import os
import pwd
import shutil
import subprocess
from pathlib import Path

CODEX_VERSION = '0.166.0'
account = 'noty-ai'
app = Path('/opt/noty-ai')
state = Path('/var/lib/noty-ai')
node_source = Path('/root/.nvm/versions/node/v22.22.2/bin/node')
npm = node_source.with_name('npm')
bridge = Path(__file__).resolve().parent.parent
source = bridge / 'server'
marker = app / '.managed-by-noty-ai'

if os.geteuid() != 0:
    raise SystemExit('Als root auf dem Zielserver ausführen.')
if not node_source.is_file() or not npm.exists():
    raise SystemExit('Erwartete Node-Laufzeit fehlt; Pfade erst prüfen.')
if not (source / 'main.mjs').is_file() or not (bridge / 'admin/index.html').is_file():
    raise SystemExit('server/ und admin/ neben deploy/ nicht gefunden.')
if app.exists() and not marker.is_file():
    raise SystemExit('/opt/noty-ai existiert und gehört nicht zu dieser Einrichtung.')

try:
    user = pwd.getpwnam(account)
    if user.pw_dir != str(state):
        raise SystemExit('Vorhandenes Konto hat ein unerwartetes Heimatverzeichnis.')
except KeyError:
    subprocess.run(['useradd', '--system', '--user-group', '--home-dir', str(state),
                    '--no-create-home', '--shell', '/usr/sbin/nologin', account], check=True)
    user = pwd.getpwnam(account)

app.mkdir(mode=0o755, parents=True, exist_ok=True)
marker.touch(mode=0o644)
runtime = app / 'runtime'
(runtime / 'bin').mkdir(mode=0o755, parents=True, exist_ok=True)
if not (runtime / 'bin/node').exists():
    shutil.copy2(node_source, runtime / 'bin/node')

installed = runtime / 'node_modules/@openai/codex/package.json'
wanted = f'"version": "{CODEX_VERSION}"'
if not installed.is_file() or wanted not in installed.read_text():
    environment = {**os.environ, 'PATH': f'{node_source.parent}:{os.environ.get("PATH", "")}'}
    subprocess.run([str(npm), 'install', '--prefix', str(runtime), f'@openai/codex@{CODEX_VERSION}'],
                   check=True, env=environment)

for name in ['server', 'admin']:
    target = app / name
    temporary = app / f'{name}.new'
    shutil.rmtree(temporary, ignore_errors=True)
    shutil.copytree(bridge / name, temporary)
    for path in [temporary, *temporary.rglob('*')]:
        os.chmod(path, 0o755 if path.is_dir() else 0o644)
    shutil.rmtree(target, ignore_errors=True)
    temporary.rename(target)

for directory in [state, state / 'codex', state / 'state']:
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(directory, user.pw_uid, user.pw_gid)
    os.chmod(directory, 0o700)

config = state / 'codex/config.toml'
if not config.exists():
    config.write_text('forced_login_method = "chatgpt"\ncli_auth_credentials_store = "file"\n')
    os.chmod(config, 0o600)
    os.chown(config, user.pw_uid, user.pw_gid)

# Eine strenge umask von root darf den Dienstbenutzer nicht aussperren.
subprocess.run(['chmod', '-R', 'a+rX', str(app)], check=True)
subprocess.run(['setfacl', '-Rb', str(app)], check=False)

print('Benutzer, Laufzeit, Bridge-Code und eigenes Codex-Profil sind eingerichtet.')
print('Bestehende Anmeldungen und laufende Dienste wurden nicht verändert.')
