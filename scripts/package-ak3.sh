#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-ak3.sh <profile-name> <workspace-dir> <artifact-dir>

Packages a built kernel into an AnyKernel3 flashable zip.
EOF
}

if [ "$#" -ne 3 ]; then
  usage >&2
  exit 1
fi

PROFILE_NAME="$1"
WORKSPACE_DIR="$2"
ARTIFACT_DIR="$3"
AK3_REF="${AK3_REF:-master}"
AK3_DIR="$WORKSPACE_DIR/.packaging/AnyKernel3"
AK3_REPO_URL="https://github.com/DikyVinus/AnyKernel3.git"

for tool in git zip unzip strings; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool for AnyKernel3 packaging: $tool" >&2
    exit 1
  }
done

if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "Workspace not found: $WORKSPACE_DIR" >&2
  exit 1
fi

if [ ! -d "$ARTIFACT_DIR" ]; then
  echo "Artifact directory not found: $ARTIFACT_DIR" >&2
  exit 1
fi

WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

find_first_named() {
  local name="$1"
  shift
  local root=""
  local found=""

  for root in "$@"; do
    [ -d "$root" ] || continue
    found="$(find "$root" -type f -name "$name" | sort | head -n 1)"
    if [ -n "$found" ]; then
      printf '%s\n' "$found"
      return 0
    fi
  done

  return 1
}

select_final_config() {
  local candidates=()
  local candidate=""
  local best=""
  local best_rank=99
  local rank=0

  while IFS= read -r candidate; do
    [ -n "$candidate" ] && candidates+=("$candidate")
  done < <(find "$ARTIFACT_DIR" -type f -name '.config' | sort)

  if [ "${#candidates[@]}" -eq 0 ]; then
    while IFS= read -r candidate; do
      [ -n "$candidate" ] && candidates+=("$candidate")
    done < <(
      find "$WORKSPACE_DIR/out" "$WORKSPACE_DIR/common/out" "$WORKSPACE_DIR/dist" \
        -type f -name '.config' 2>/dev/null | sort
    )
  fi

  for candidate in "${candidates[@]}"; do
    rank=3
    case "$candidate" in
      *workspace-out*)
        rank=0
        ;;
      *common-out*)
        rank=1
        ;;
      *workspace-dist*)
        rank=2
        ;;
    esac

    if [ -z "$best" ] || [ "$rank" -lt "$best_rank" ] || { [ "$rank" -eq "$best_rank" ] && [[ "$candidate" < "$best" ]]; }; then
      best="$candidate"
      best_rank="$rank"
    fi
  done

  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

RAW_IMAGE_PATH="$(find_first_named "Image" "$ARTIFACT_DIR" "$WORKSPACE_DIR/dist" "$WORKSPACE_DIR/out" "$WORKSPACE_DIR/common/out" || true)"

if [ -z "$RAW_IMAGE_PATH" ]; then
  if find_first_named "Image.gz" "$ARTIFACT_DIR" "$WORKSPACE_DIR/dist" "$WORKSPACE_DIR/out" "$WORKSPACE_DIR/common/out" >/dev/null 2>&1 \
    || find_first_named "Image.lz4" "$ARTIFACT_DIR" "$WORKSPACE_DIR/dist" "$WORKSPACE_DIR/out" "$WORKSPACE_DIR/common/out" >/dev/null 2>&1; then
    echo "AnyKernel3 packaging currently requires raw Image because anykernel.sh expects Image at zip root." >&2
    exit 1
  fi

  echo "No kernel Image found for AnyKernel3 packaging." >&2
  exit 1
fi

FINAL_CONFIG_PATH="$(select_final_config || true)"
if [ -z "$FINAL_CONFIG_PATH" ]; then
  echo "No final .config found for AnyKernel3 packaging." >&2
  exit 1
fi

rm -rf "$AK3_DIR"
mkdir -p "$(dirname "$AK3_DIR")"
git clone --depth 1 --branch "$AK3_REF" "$AK3_REPO_URL" "$AK3_DIR"

if [ ! -f "$AK3_DIR/anykernel.sh" ] || [ ! -d "$AK3_DIR/tools" ]; then
  echo "Cloned AnyKernel3 tree is missing expected files: $AK3_DIR" >&2
  exit 1
fi

cp -f "$RAW_IMAGE_PATH" "$AK3_DIR/Image"
cp -f "$FINAL_CONFIG_PATH" "$AK3_DIR/ikconfig.txt"
cp -f "$FINAL_CONFIG_PATH" "$ARTIFACT_DIR/ikconfig.txt"

kernel_version="$(strings "$AK3_DIR/Image" 2>/dev/null | grep -E -m1 'Linux version ' | awk '{print $3}' || true)"
if [ -z "$kernel_version" ]; then
  kernel_version="$PROFILE_NAME"
fi

sanitized_kernel_version="$(
  printf '%s' "$kernel_version" \
    | tr ' /' '--' \
    | sed 's/[^A-Za-z0-9._+-]/-/g; s/--*/-/g; s/^-//; s/-$//'
)"
if [ -z "$sanitized_kernel_version" ]; then
  sanitized_kernel_version="$PROFILE_NAME"
fi

suffixes=("CoreShift")
if [ -n "${CORESHIFT_AK3_SUFFIXES:-}" ]; then
  IFS=',' read -r -a extra_suffixes <<< "${CORESHIFT_AK3_SUFFIXES}"
  for suffix in "${extra_suffixes[@]}"; do
    suffix="$(
      printf '%s' "$suffix" \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[^A-Za-z0-9._+-]/-/g; s/--*/-/g; s/^-//; s/-$//'
    )"
    [ -n "$suffix" ] || continue
    suffixes+=("$suffix")
  done
fi

suffix_string="$(IFS=-; printf '%s' "${suffixes[*]}")"
ZIP_PATH="$ARTIFACT_DIR/${sanitized_kernel_version}-${suffix_string}.zip"
POINTER_PATH="$ARTIFACT_DIR/ak3-zip-path.txt"

rm -f "$ZIP_PATH"
(
  cd "$AK3_DIR"
  zip -r9 "$ZIP_PATH" . -x ".git/*" ".github/*" "README.md"
)

printf '%s\n' "$(basename "$ZIP_PATH")" > "$POINTER_PATH"

echo "Packaged AnyKernel3 zip: $ZIP_PATH"
unzip -l "$ZIP_PATH" | sed -n '1,160p'
