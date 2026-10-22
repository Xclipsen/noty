#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"
. ./scripts/env.sh
mkdir -p .tools
task_check="$(mktemp -d "$task_root/.tools/page-workflow-XXXXXX")"
swiftc -swift-version 6 -parse-as-library Core/Sources/NotebookCore/*.swift scripts/PageWorkflowCheck.swift -o "$task_check/check"
"$task_check/check" "$task_root/fixtures/Seitenformate.pdf" "$task_check/results"
python3 -B scripts/verify_backup.py "$task_check/results/heft.notybackup" --compare "$task_check/results/current.json"
# Format 1 as Build 53 wrote it (schema 11, embedded original).
python3 -B scripts/verify_backup.py "$task_check/results/heft-v1.notybackup" --compare "$task_check/results/current-v11.json"
# Schema 13 (polyline/polygon shapes) written by Swift.
python3 -B scripts/verify_backup.py "$task_check/results/heft-v13.notybackup" --compare "$task_check/results/current-v13.json"
# Schema 14 (page text migrated to free fields, rotated/automatic-width field) written by Swift.
python3 -B scripts/verify_backup.py "$task_check/results/heft-v14.notybackup" --compare "$task_check/results/current-v14.json"
python3 -B scripts/verify_device_store.py "$task_check/results/FlowMigration"
python3 -B scripts/verify_library_backup.py "$task_check/results/bibliothek.notylibrary"
python3 -B scripts/verify_device_store.py "$task_check/results/Source"
# Restore copies (Restores/*) and the migrated schema-11 package carry their assets.
python3 -B scripts/verify_device_store.py "$task_check/results/RestoreCheck"
python3 -B scripts/verify_device_store.py "$task_check/results/Legacy"
if python3 -B scripts/verify_backup.py "$task_check/results/corrupt.notybackup" > "$task_check/expected-corruption.log" 2>&1; then
    echo 'FEHLER: beschädigtes Backup wurde akzeptiert' >&2
    exit 1
fi
if python3 -B scripts/verify_library_backup.py "$task_check/results/corrupt.notylibrary" > "$task_check/expected-library-corruption.log" 2>&1; then
    echo 'FEHLER: beschädigtes Bibliotheksbackup wurde akzeptiert' >&2
    exit 1
fi
# Real schema-12 asset records written by Swift, verified independently by Python.
python3 -B - "$task_root/scripts" "$task_check/results" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import verify_backup, verify_device_store, verify_library_backup
from notebook_format import check

results = Path(sys.argv[2])
_, backup = verify_backup.verify(results / "heft.notybackup")
library = verify_library_backup.verify(results / "bibliothek.notylibrary")
_, store = verify_device_store.load_store(results / "Source")
_, legacy = verify_device_store.load_store(results / "Legacy")
_, restores = verify_device_store.load_store(results / "RestoreCheck")
check(backup["assets"] == 1 and library["assets"] == 1 and store["assets"] == 1, "Asset records missing")
check(legacy["assets"] == 1 and restores["assets"] == 2, "Assets of the migrated package or the restore copies missing")
print(json.dumps({"swiftAssetRecordsVerifiedByPython": True, "backupAssets": backup["assets"], "libraryAssets": library["assets"],
                  "assetBytes": backup["assetBytes"], "storeAssets": store["assets"], "legacyPackageAssets": legacy["assets"],
                  "restoredCopyAssets": restores["assets"]}))
PY
bash scripts/check_verifiers.sh
echo "Host-Roundtrip geprüft; Artefakte: $task_check"
