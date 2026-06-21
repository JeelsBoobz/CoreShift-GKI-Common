#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/apply-features.sh <workspace-dir> <features-csv> [profile-name]
EOF
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage >&2
  exit 1
fi

WORKSPACE_DIR="$1"
FEATURES_CSV="$2"
PROFILE_NAME="${3:-$(basename "$WORKSPACE_DIR")}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$WORKSPACE_DIR/common"
PRIVATE_FRAGMENT="$COMMON_DIR/private.fragment"
LTO_FRAGMENT="$COMMON_DIR/lto.fragment"
FEATURES_FRAGMENT="$COMMON_DIR/features.fragment"
KLEAF_FRAGMENT="$COMMON_DIR/coreshift.kleaf.fragment"

feature_requested() {
  local wanted="$1"
  shift
  local feature
  for feature in "$@"; do
    if [ "$feature" = "$wanted" ]; then
      return 0
    fi
  done
  return 1
}

sync_kleaf_fragment() {
  python3 - "$PRIVATE_FRAGMENT" "$LTO_FRAGMENT" "$FEATURES_FRAGMENT" "$KLEAF_FRAGMENT" <<'PY'
from pathlib import Path
import sys

private_fragment = Path(sys.argv[1])
lto_fragment = Path(sys.argv[2])
features_fragment = Path(sys.argv[3])
kleaf_fragment = Path(sys.argv[4])

def read_normalized(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")

def with_trailing_newline(text: str) -> str:
    if not text:
        return ""
    return text if text.endswith("\n") else text + "\n"

combined = (
    with_trailing_newline(read_normalized(private_fragment))
    + with_trailing_newline(read_normalized(lto_fragment))
    + with_trailing_newline(read_normalized(features_fragment))
)
kleaf_fragment.write_text(combined, encoding="utf-8")
PY
}

for required_path in "$COMMON_DIR" "$PRIVATE_FRAGMENT" "$LTO_FRAGMENT" "$FEATURES_FRAGMENT"; do
  if [ ! -e "$required_path" ]; then
    echo "Required fragment path not found: $required_path" >&2
    exit 1
  fi
done

trimmed_features=()
if [ -n "$FEATURES_CSV" ]; then
  IFS=',' read -r -a raw_features <<< "$FEATURES_CSV"
  for raw_feature in "${raw_features[@]}"; do
    feature="$(printf '%s' "$raw_feature" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$feature" ] || continue
    case "$feature" in
      ksu|kowsu|ksu-next|bbg|susfs)
        if ! feature_requested "$feature" "${trimmed_features[@]}"; then
          trimmed_features+=("$feature")
        fi
        ;;
      *)
        echo "Unknown feature: $feature" >&2
        exit 1
        ;;
    esac
  done
fi

if feature_requested "ksu" "${trimmed_features[@]}" &&
   feature_requested "kowsu" "${trimmed_features[@]}"; then
  echo "Cannot enable both ksu and kowsu." >&2
  exit 1
fi

if feature_requested "ksu-next" "${trimmed_features[@]}" && (
   feature_requested "ksu" "${trimmed_features[@]}" ||
   feature_requested "kowsu" "${trimmed_features[@]}"); then
  echo "Cannot enable ksu-next together with ksu or kowsu." >&2
  exit 1
fi

if feature_requested "susfs" "${trimmed_features[@]}" &&
   ! feature_requested "ksu" "${trimmed_features[@]}" &&
   ! feature_requested "kowsu" "${trimmed_features[@]}" &&
   ! feature_requested "ksu-next" "${trimmed_features[@]}"; then
  echo "SUSFS requires KernelSU. Use ksu-susfs, ksu-susfs-bbg, kowsu-susfs, kowsu-susfs-bbg, ksu-next-susfs, or ksu-next-susfs-bbg." >&2
  exit 1
fi

if feature_requested "ksu" "${trimmed_features[@]}"; then
  "$SCRIPT_DIR/apply-ksu.sh" "$WORKSPACE_DIR"
fi

if feature_requested "kowsu" "${trimmed_features[@]}"; then
  KSU_REPO="${KOWSU_REPO:-https://github.com/KOWX712/KernelSU.git}" \
    "$SCRIPT_DIR/apply-ksu.sh" "$WORKSPACE_DIR"
fi

if feature_requested "ksu-next" "${trimmed_features[@]}"; then
  if feature_requested "susfs" "${trimmed_features[@]}"; then
    KSU_REPO="${KSU_NEXT_REPO:-https://github.com/pershoot/KernelSU-Next.git}" \
      KSU_REF="${KSU_NEXT_SUSFS_REF:-dev-susfs}" \
      KSU_CLONE_BRANCH="${KSU_NEXT_SUSFS_REF:-dev-susfs}" \
      "$SCRIPT_DIR/apply-ksu.sh" "$WORKSPACE_DIR"
  else
    KSU_REPO="${KSU_NEXT_REPO:-https://github.com/pershoot/KernelSU-Next.git}" \
      "$SCRIPT_DIR/apply-ksu.sh" "$WORKSPACE_DIR"
  fi
fi

if feature_requested "susfs" "${trimmed_features[@]}"; then
  if feature_requested "kowsu" "${trimmed_features[@]}"; then
    KSU_VARIANT=kowsu "$SCRIPT_DIR/apply-susfs.sh" "$WORKSPACE_DIR" "$PROFILE_NAME"
  elif feature_requested "ksu-next" "${trimmed_features[@]}"; then
    KSU_VARIANT=ksu-next "$SCRIPT_DIR/apply-susfs.sh" "$WORKSPACE_DIR" "$PROFILE_NAME"
  else
    "$SCRIPT_DIR/apply-susfs.sh" "$WORKSPACE_DIR" "$PROFILE_NAME"
  fi
fi

if feature_requested "bbg" "${trimmed_features[@]}"; then
  "$SCRIPT_DIR/apply-bbg.sh" "$WORKSPACE_DIR"
fi

sync_kleaf_fragment

if [ "${#trimmed_features[@]}" -gt 0 ]; then
  echo "Applied features: $(IFS=,; printf '%s' "${trimmed_features[*]}")"
else
  echo "Applied features: none"
fi
