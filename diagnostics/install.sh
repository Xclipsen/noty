#!/usr/bin/env bash
# Richtet den Empfang der Fehlerberichte auf diesem Server ein oder
# aktualisiert ihn (docs/DIAGNOSE.md). Als root ausführen. Idempotent:
# - Systembenutzer noty-diag, /opt/noty-diagnostics/server.py, systemd-Unit;
# - beim ersten Lauf einen Schlüssel (/etc/noty-diagnostics/keys) und einen
#   geheimen Pfad erzeugen und beides als DIAG_KEY/DIAG_URL in .tools/ota.env
#   eintragen (publish_ota.sh schreibt sie in die App; nie ins Repo);
# - nginx: die Location aus /etc/nginx/noty-diagnostics.conf in den
#   OTA-Server-Block einbinden (einmalig von Hand, siehe Doku) und neu laden.
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="${OTA_ENV:-/home/la/workspace/noty/.tools/ota.env}"
[ "$(id -u)" = 0 ] || { echo "Als root ausführen." >&2; exit 1; }

id noty-diag >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin noty-diag
install -d -m 755 /opt/noty-diagnostics
install -m 644 server.py /opt/noty-diagnostics/server.py
install -m 644 noty-diagnostics.service /etc/systemd/system/noty-diagnostics.service
install -d -m 750 -g noty-diag /etc/noty-diagnostics

if [ ! -s /etc/noty-diagnostics/keys ]; then
  umask 027
  python3 -c 'import secrets;print(secrets.token_hex(24))' > /etc/noty-diagnostics/keys
  chgrp noty-diag /etc/noty-diagnostics/keys; chmod 640 /etc/noty-diagnostics/keys
fi
KEY="$(grep -v '^#' /etc/noty-diagnostics/keys | tail -1)"

if ! grep -q '^DIAG_URL=' "$ENV_FILE"; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  HOST="$(printf '%s' "$OTA_URL" | sed -E 's#^(https://[^/]+).*#\1#')"
  SECRET="noty-diag-$(python3 -c 'import secrets;print(secrets.token_hex(16))')"
  printf 'DIAG_URL=%s/%s/v1/report\nDIAG_KEY=%s\n' "$HOST" "$SECRET" "$KEY" >> "$ENV_FILE"
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
SECRET_PATH="$(printf '%s' "$DIAG_URL" | sed -E 's#^https://[^/]+(/.*)/v1/report$#\1#')"
cat > /etc/nginx/noty-diagnostics.conf <<NGINX
# noty-Fehlerberichte (docs/DIAGNOSE.md), erzeugt von diagnostics/install.sh.
# Nur dieser eine exakte Pfad; alles andere bleibt beim Server-Block.
location = $SECRET_PATH/v1/report {
    limit_except POST { deny all; }
    client_max_body_size 1m;
    proxy_pass http://127.0.0.1:8794/v1/report;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header Host \$host;
    proxy_read_timeout 30s;
    access_log /var/log/nginx/noty-diagnostics.log;
}
NGINX
chmod 640 /etc/nginx/noty-diagnostics.conf

systemctl daemon-reload
systemctl enable --now noty-diagnostics.service
systemctl restart noty-diagnostics.service
if nginx -t 2>/dev/null; then systemctl reload nginx; else nginx -t; exit 1; fi
echo "Eingerichtet. Adresse und Schlüssel stehen als DIAG_URL/DIAG_KEY in $ENV_FILE; Ablage /var/lib/noty-diagnostics/reports"
