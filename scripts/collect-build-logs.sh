#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/collect-build-logs.sh <profile> <variant> <workspace-dir> <dist-dir>
EOF
}

if [ "$#" -ne 4 ]; then
  usage >&2
  exit 1
fi

PROFILE="$1"
VARIANT="$2"
WORKSPACE_DIR="$3"
DIST_DIR="$4"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_SOURCE_DIR="$REPO_ROOT/.logs/$PROFILE/$VARIANT"
LOG_DIST_DIR="$DIST_DIR/logs"
ZIP_PATH="$LOG_DIST_DIR/CoreShift-logs-$PROFILE-$VARIANT.zip"
STAGING_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$LOG_DIST_DIR" "$STAGING_DIR/logs"
LOG_DIST_DIR="$(cd "$LOG_DIST_DIR" && pwd)"
ZIP_PATH="$LOG_DIST_DIR/CoreShift-logs-$PROFILE-$VARIANT.zip"

{
  echo "profile=$PROFILE"
  echo "variant=$VARIANT"
  echo "workspace_dir=$WORKSPACE_DIR"
  echo "dist_dir=$DIST_DIR"
  echo "log_source_dir=$LOG_SOURCE_DIR"
  date -u '+collected_at_utc=%Y-%m-%dT%H:%M:%SZ'
  if [ -d "$WORKSPACE_DIR" ]; then
    echo
    echo "workspace diagnostics:"
    du -sh "$WORKSPACE_DIR" 2>/dev/null || true
    find "$WORKSPACE_DIR" -maxdepth 2 -type d \( -name out -o -name output_user_root -o -name dist \) -print 2>/dev/null || true
  fi
} > "$STAGING_DIR/workspace-diagnostics.txt"

copy_if_exists() {
  local source_path="$1"
  local relative_path="$2"
  if [ -f "$source_path" ]; then
    mkdir -p "$STAGING_DIR/$(dirname "$relative_path")"
    cp "$source_path" "$STAGING_DIR/$relative_path"
  fi
}

copy_tree_if_exists() {
  local source_path="$1"
  local relative_path="$2"
  if [ -d "$source_path" ]; then
    mkdir -p "$STAGING_DIR/$(dirname "$relative_path")"
    cp -a "$source_path" "$STAGING_DIR/$relative_path"
  fi
}

copy_tree_if_exists "$LOG_SOURCE_DIR" "logs/$PROFILE/$VARIANT"

copy_if_exists "$WORKSPACE_DIR/manifest-trim-report.txt" "workspace/manifest-trim-report.txt"
copy_if_exists "$WORKSPACE_DIR/.repo/local_manifests/coreshift-overlay.xml" "workspace/coreshift-overlay.xml"
copy_if_exists "$WORKSPACE_DIR/common/features.fragment" "workspace/common/features.fragment"
copy_if_exists "$WORKSPACE_DIR/common/lto.fragment" "workspace/common/lto.fragment"
copy_if_exists "$WORKSPACE_DIR/common/private.required" "workspace/common/private.required"
copy_if_exists "$WORKSPACE_DIR/common/coreshift.kleaf.fragment" "workspace/common/coreshift.kleaf.fragment"
copy_if_exists "$WORKSPACE_DIR/common/.config" "workspace/common/.config"
copy_if_exists "$WORKSPACE_DIR/dist/.config" "workspace/dist/.config"
copy_if_exists "$WORKSPACE_DIR/dist/System.map" "workspace/dist/System.map"
copy_if_exists "$WORKSPACE_DIR/dist/build.log" "workspace/dist/build.log"

if [ -d "$WORKSPACE_DIR/common" ]; then
  while IFS= read -r -d '' reject_file; do
    relative_reject="${reject_file#"$WORKSPACE_DIR/common/"}"
    copy_if_exists "$reject_file" "workspace/common-rejects/$relative_reject"
  done < <(find "$WORKSPACE_DIR/common" -type f -name '*.rej' -print0)
fi

find "$STAGING_DIR" \
  \( -name .git -o -path '*/out/*' -o -path '*/output_user_root/*' -o -name '*.zip' \) \
  -prune -exec rm -rf {} + 2>/dev/null || true

if command -v zip >/dev/null 2>&1; then
  (
    cd "$STAGING_DIR"
    zip -qr "$ZIP_PATH" .
  )
else
  python3 - "$STAGING_DIR" "$ZIP_PATH" <<'PY'
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
zip_path = Path(sys.argv[2])
with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            zf.write(path, path.relative_to(root))
PY
fi

echo "Created log bundle: $ZIP_PATH"
