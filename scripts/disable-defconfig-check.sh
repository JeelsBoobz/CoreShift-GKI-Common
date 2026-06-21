#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/disable-defconfig-check.sh <workspace-dir>

Disables simple check_defconfig enforcement in a private workspace.
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

echo "Before disable-defconfig-check:"
grep -R -n -E 'check_defconfig|savedefconfig does not match' build common 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path
import re

roots = [Path("build"), Path("common")]
replacement = (
    'check_defconfig() {\n'
    '  echo "[SKIP] check_defconfig disabled by CoreShift user option"\n'
    '  return 0\n'
    '}\n'
)

for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue

        original = text
        text = re.sub(
            r'check_defconfig\s*\(\)\s*\{.*?^\}',
            replacement.rstrip("\n"),
            text,
            flags=re.MULTILINE | re.DOTALL,
        )
        text = re.sub(r'check_defconfig\s*&&\s*', '', text)
        text = re.sub(r'\s*&&\s*check_defconfig\b', '', text)
        text = re.sub(r'(?m)^[ \t]*check_defconfig[ \t]*\n', '', text)

        if text != original:
            path.write_text(text, encoding="utf-8")
PY

echo "After disable-defconfig-check:"
grep -R -n -E 'check_defconfig|savedefconfig does not match' build common 2>/dev/null || true

