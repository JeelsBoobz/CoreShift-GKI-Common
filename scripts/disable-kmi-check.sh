#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/disable-kmi-check.sh <workspace-dir>

Clears strict KMI enforcement variables in a private workspace.
EOF
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || {
  echo "Missing required tool: python3" >&2
  exit 1
}

WORKSPACE_DIR="$1"

if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "Workspace not found: $WORKSPACE_DIR" >&2
  exit 1
fi

cd "$WORKSPACE_DIR"

report_matches() {
  find . -maxdepth 1 -type f -name 'build.config*' \
    -exec grep -n -E 'KMI_SYMBOL_LIST_STRICT_MODE|TRIM_NONLISTED_KMI' {} + 2>/dev/null || true
  find common -maxdepth 1 -type f -name 'build.config*' \
    -exec grep -n -E 'KMI_SYMBOL_LIST_STRICT_MODE|TRIM_NONLISTED_KMI' {} + 2>/dev/null || true
}

echo "Before disable-kmi-check:"
report_matches

python3 - <<'PY'
from pathlib import Path
import re

paths = list(Path(".").glob("build.config*")) + list(Path("common").glob("build.config*"))

for path in paths:
    if not path.is_file():
        continue
    text = path.read_text(encoding="utf-8")
    original = text
    text = re.sub(r'(?m)^KMI_SYMBOL_LIST_STRICT_MODE=.*$', 'KMI_SYMBOL_LIST_STRICT_MODE=', text)
    text = re.sub(r'(?m)^TRIM_NONLISTED_KMI=.*$', 'TRIM_NONLISTED_KMI=', text)
    if text != original:
        path.write_text(text, encoding="utf-8")
PY

echo "After disable-kmi-check:"
report_matches
