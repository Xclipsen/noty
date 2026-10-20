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
python3 -B scripts/verify_library_backup.py "$task_check/results/bibliothek.notylibrary"
python3 -B scripts/verify_device_store.py "$task_check/results/Source"
if python3 -B scripts/verify_backup.py "$task_check/results/corrupt.notybackup" > "$task_check/expected-corruption.log" 2>&1; then
    echo 'FEHLER: beschädigtes Backup wurde akzeptiert' >&2
    exit 1
fi
bash scripts/check_verifiers.sh
echo "Host-Roundtrip geprüft; Artefakte: $task_check"
