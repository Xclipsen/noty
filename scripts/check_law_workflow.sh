#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/env.sh
law_data_root="${1:-../gesetzessammlung-noty/public/data}"
if [[ ! -f "$law_data_root/catalog.json" ]]; then
  printf 'Gesetzesdaten fehlen: %s/catalog.json\n' "$law_data_root" >&2
  exit 1
fi
law_data_root="$(realpath "$law_data_root")"
NOTY_LAW_FIXTURE_ROOT="$law_data_root" swift test --package-path Core --filter LawRealCatalogTests --jobs 4
