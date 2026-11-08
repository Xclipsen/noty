#!/usr/bin/env bash
# Richtet den Push-Dienst von noty calendar ein oder aktualisiert ihn
# (docs/PUSH.md). Als root ausführen. Idempotent; überschreibt nie
# vorhandene Geheimnisse oder die Konfiguration.
#  1. Binärdatei bauen (als la, statisch gegen die Swift-Laufzeit) und nach
#     /opt/noty-push kopieren.
#  2. Systembenutzer noty-push, /etc/noty-push (root, 0700): data.key wird
#     beim ersten Lauf erzeugt; config.json aus config.example.json nur, wenn
#     noch keine existiert. apns.p8 legt der Betreiber selbst ab (0600).
#  3. systemd-Unit installieren. Gestartet wird nur, wenn apns.p8 existiert
#     und `noty-push check` die Konfiguration annimmt.
#  4. nginx-Vorschläge nach /etc/nginx/noty-push*.conf kopieren – NICHT
#     einbinden (der Server-Block wird von Hand ergänzt, siehe Doku).
set -euo pipefail
cd "$(dirname "$0")/.."
PUSH_DIR="$(pwd)"
[ "$(id -u)" = 0 ] || { echo "Als root ausführen." >&2; exit 1; }
BUILD_USER="${BUILD_USER:-la}"

echo "== Bauen (als $BUILD_USER)"
# Die statische Foundation zieht FoundationXML mit (-lxml2); das System hat
# nur libxml2.so.16 ohne Entwicklungs-Symlink. Ein Symlink im Build-Ordner
# genügt dem Linker; --as-needed/--gc-sections halten die Abhängigkeit klein.
BUILD_FLAGS="-c release --static-swift-stdlib -Xlinker -L$PUSH_DIR/.build/linkshim -Xlinker --as-needed"
runuser -u "$BUILD_USER" -- bash -c "cd '$PUSH_DIR/..' && . ./scripts/env.sh >/dev/null 2>&1 && mkdir -p push/.build/linkshim \
  && ln -sf \"\$(ls /usr/lib/x86_64-linux-gnu/libxml2.so.* | head -1)\" push/.build/linkshim/libxml2.so \
  && swift build --package-path push $BUILD_FLAGS"
BIN="$(runuser -u "$BUILD_USER" -- bash -c "cd '$PUSH_DIR/..' && . ./scripts/env.sh >/dev/null 2>&1 && swift build --package-path push $BUILD_FLAGS --show-bin-path")/noty-push"
[ -x "$BIN" ] || { echo "Binärdatei fehlt: $BIN" >&2; exit 1; }
if env -u LD_LIBRARY_PATH ldd "$BIN" | grep -q -e "not found" -e "/home/"; then
  echo "Binärdatei hängt von Bibliotheken außerhalb des Systems ab:" >&2; env -u LD_LIBRARY_PATH ldd "$BIN" >&2; exit 1
fi

echo "== Benutzer und Dateien"
id noty-push >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin noty-push
install -d -m 755 /opt/noty-push
install -m 755 "$BIN" /opt/noty-push/noty-push.new
mv -f /opt/noty-push/noty-push.new /opt/noty-push/noty-push
install -d -m 711 -o root -g root /etc/noty-push
if [ ! -s /etc/noty-push/data.key ]; then
  ( umask 077; /opt/noty-push/noty-push genkey > /etc/noty-push/data.key )
  echo "Datenschlüssel erzeugt: /etc/noty-push/data.key (Sicherung getrennt von /var/lib/noty-push aufbewahren)"
fi
chmod 600 /etc/noty-push/data.key
if [ ! -e /etc/noty-push/config.json ]; then
  install -m 644 deploy/config.example.json /etc/noty-push/config.json
  echo "Konfiguration angelegt: /etc/noty-push/config.json – apnsKeyID eintragen!"
fi
[ -e /etc/noty-push/apns.p8 ] && chmod 600 /etc/noty-push/apns.p8
install -m 644 deploy/noty-push.service /etc/systemd/system/noty-push.service
install -m 644 deploy/nginx-noty-push.conf /etc/nginx/noty-push.conf
install -m 644 deploy/nginx-noty-push-proxy.conf /etc/nginx/noty-push-proxy.conf
systemctl daemon-reload

if [ ! -s /etc/noty-push/apns.p8 ]; then
  echo "APNs-Schlüssel fehlt: /etc/noty-push/apns.p8 (aus dem Apple-Developer-Konto, chmod 600). Dienst nicht gestartet."
  exit 0
fi
echo "== Prüfen"
# Gleiche Umgebung wie im Dienst: als Dienstbenutzer, Geheimnisse nur über
# systemd LoadCredential (keine Kopie der Schlüssel in /tmp oder anderswo).
# systemd-run --wait gibt den Exitcode von `check` zurück (set -e bricht ab).
install -d -m 700 -o noty-push -g noty-push /var/lib/noty-push
systemd-run --quiet --collect --wait --pipe \
  -p User=noty-push -p Group=noty-push -p WorkingDirectory=/ \
  -p LoadCredential=data.key:/etc/noty-push/data.key -p LoadCredential=apns.p8:/etc/noty-push/apns.p8 \
  -p ProtectHome=yes -p PrivateTmp=yes -p NoNewPrivileges=yes \
  /opt/noty-push/noty-push check --config /etc/noty-push/config.json
systemctl enable noty-push.service
systemctl restart noty-push.service
sleep 1
systemctl --no-pager --lines=5 status noty-push.service || true
curl -fsS http://127.0.0.1:8795/v1/health && echo
echo "Läuft lokal. nginx NICHT verändert: Einbindung siehe docs/PUSH.md („nginx freischalten“)."
