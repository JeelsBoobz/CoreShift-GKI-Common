#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: scripts/patch-54-uapi-sysroot.sh <workspace-dir>" >&2
  exit 1
fi

WORKSPACE_DIR="$1"
MAKEFILE_PATH="$WORKSPACE_DIR/common/usr/include/Makefile"
PATCH_LINE='UAPI_CFLAGS += $(UAPI_SYSROOT_CFLAGS)'
MATCH_LINE='UAPI_CFLAGS += $(filter -m32 -m64 --target=%, $(KBUILD_CPPFLAGS) $(KBUILD_CFLAGS))'

if [ ! -f "$MAKEFILE_PATH" ]; then
  echo "Missing Makefile to patch: $MAKEFILE_PATH" >&2
  exit 1
fi

echo "UAPI_CFLAGS before patch:"
grep -n -C 2 'UAPI_CFLAGS' "$MAKEFILE_PATH" || true

if grep -Fq "$PATCH_LINE" "$MAKEFILE_PATH"; then
  echo "5.4 UAPI sysroot patch already present: $MAKEFILE_PATH"
else
  python3 - "$MAKEFILE_PATH" "$MATCH_LINE" "$PATCH_LINE" <<'PY'
import pathlib
import sys

makefile_path = pathlib.Path(sys.argv[1])
match_line = sys.argv[2]
patch_line = sys.argv[3]

text = makefile_path.read_text(encoding="utf-8")
needle = match_line + "\n"

if patch_line in text:
    raise SystemExit(0)

if needle not in text:
    raise SystemExit(f"Expected line not found in {makefile_path}: {match_line}")

replacement = (
    needle
    + "# CoreShift: allow 5.4 UAPI header tests to see target libc headers.\n"
    + patch_line
    + "\n"
)

makefile_path.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
PY
  echo "Applied 5.4 UAPI sysroot patch: $MAKEFILE_PATH"
fi

echo "UAPI_CFLAGS after patch:"
grep -n -C 2 'UAPI_CFLAGS' "$MAKEFILE_PATH" || true
