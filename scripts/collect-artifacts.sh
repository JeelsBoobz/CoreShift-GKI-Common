#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/collect-artifacts.sh <profile-name> <workspace-dir> <artifact-dir>

Collects common ACK/GKI kernel build artifacts from likely output directories.
EOF
}

if [ "$#" -ne 3 ]; then
  usage >&2
  exit 1
fi

PROFILE_NAME="$1"
WORKSPACE_DIR="$2"
ARTIFACT_DIR="$3"

if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "Workspace not found: $WORKSPACE_DIR" >&2
  exit 1
fi

mkdir -p "$(dirname "$ARTIFACT_DIR")"
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

declare -A SEEN_FILES=()

COLLECTED_COUNT=0
ESSENTIAL_FOUND=0

copy_matches_from_root() {
  local root="$1"
  local label="$2"
  local src=""
  local rel=""
  local dest=""
  local base=""

  [ -d "$root" ] || return 0

  while IFS= read -r -d '' src; do
    if [ -n "${SEEN_FILES[$src]:-}" ]; then
      continue
    fi

    SEEN_FILES["$src"]=1
    rel="${src#"$root"/}"
    dest="$ARTIFACT_DIR/$label/$rel"

    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"

    base="$(basename "$src")"
    case "$base" in
      Image|Image.gz|Image.lz4|vmlinux|System.map|.config)
        ESSENTIAL_FOUND=1
        ;;
    esac

    COLLECTED_COUNT=$((COLLECTED_COUNT + 1))
  done < <(
    find "$root" -type f \
      \( \
        -name 'Image' -o \
        -name 'Image.gz' -o \
        -name 'Image.lz4' -o \
        -name 'vmlinux' -o \
        -name 'System.map' -o \
        -name '.config' -o \
        -name 'modules.builtin' -o \
        -name 'modules.order' -o \
        -name '*.ko' -o \
        -name '*.dtb' -o \
        -name '*.dtbo' \
      \) \
      -print0
  )
}

copy_matches_from_root "$WORKSPACE_DIR/dist" "workspace-dist"
copy_matches_from_root "$WORKSPACE_DIR/out" "workspace-out"
copy_matches_from_root "$WORKSPACE_DIR/common/out" "common-out"

if [ "$COLLECTED_COUNT" -eq 0 ] || [ "$ESSENTIAL_FOUND" -eq 0 ]; then
  echo "Failed to collect essential kernel artifacts for profile $PROFILE_NAME." >&2
  echo "Searched: $WORKSPACE_DIR/dist, $WORKSPACE_DIR/out, $WORKSPACE_DIR/common/out" >&2
  echo "Need at least one of: Image, Image.gz, Image.lz4, vmlinux, System.map, .config" >&2
  exit 1
fi

echo "Collected artifacts for $PROFILE_NAME into $ARTIFACT_DIR"
find "$ARTIFACT_DIR" -type f | sort
