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
python3 -B scripts/verify_backup.py "$task_check/results/heft-v1.notybackup" --compare "$task_check/results/current.json"
python3 -B scripts/verify_library_backup.py "$task_check/results/bibliothek.notylibrary"
python3 -B scripts/verify_device_store.py "$task_check/results/Source"
if python3 -B scripts/verify_backup.py "$task_check/results/corrupt.notybackup" > "$task_check/expected-corruption.log" 2>&1; then
    echo 'FEHLER: beschädigtes Backup wurde akzeptiert' >&2
    exit 1
fi
if python3 -B scripts/verify_library_backup.py "$task_check/results/corrupt.notylibrary" > "$task_check/expected-library-corruption.log" 2>&1; then
    echo 'FEHLER: beschädigtes Bibliotheksbackup wurde akzeptiert' >&2
    exit 1
fi
# Asset records written by Swift (synthetic references until schema 12),
# verified by the independent Python readers.
python3 -B - "$task_root/scripts" "$task_check/results" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import verify_backup, verify_library_backup
from notebook_format import check

results = Path(sys.argv[2])
references = {key.upper(): value for key, value in json.loads((results / "asset-references.json").read_text()).items()}
for module in (verify_backup, verify_library_backup):
    module.validate_notebook = (lambda original: lambda doc: (original(doc), references.get(doc["id"].upper(), {}))[1])(module.validate_notebook)
_, backup = verify_backup.verify(results / "assets.notybackup")
library = verify_library_backup.verify(results / "assets.notylibrary")
expected = sum(len(value) for value in references.values())
check(backup["assets"] == expected and library["assets"] == expected, "Asset records missing")
print(json.dumps({"swiftAssetRecordsVerifiedByPython": True, "backupAssets": backup["assets"], "libraryAssets": library["assets"],
                  "assetBytes": backup["assetBytes"]}))
PY
bash scripts/check_verifiers.sh
echo "Host-Roundtrip geprüft; Artefakte: $task_check"
