#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/apply-bbg.sh <workspace-dir>
EOF
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 1
fi

WORKSPACE_DIR="$1"
COMMON_DIR="$WORKSPACE_DIR/common"
PRIVATE_FRAGMENT="$COMMON_DIR/private.fragment"
FEATURES_FRAGMENT="$COMMON_DIR/features.fragment"
BBG_DIR="$COMMON_DIR/Baseband-guard"
BBG_REPO="${BBG_REPO:-https://github.com/vc-teahouse/Baseband-guard.git}"
BBG_REF="${BBG_REF:-main}"
if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
  BBG_LOG_DIR="$CORESHIFT_LOG_DIR/patches/bbg"
  mkdir -p "$BBG_LOG_DIR"
else
  BBG_LOG_DIR=""
fi

update_bbg_fragment() {
  local private_required="$COMMON_DIR/private.required"
  local gki_defconfig="$COMMON_DIR/arch/arm64/configs/gki_defconfig"

  python3 - "$PRIVATE_FRAGMENT" "$FEATURES_FRAGMENT" "$private_required" "$gki_defconfig" <<'PY'
import sys
from pathlib import Path

private_fragment = Path(sys.argv[1])
features_fragment = Path(sys.argv[2])
private_required = Path(sys.argv[3])
gki_defconfig = Path(sys.argv[4])
fallback_lsm = "lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor"

def parse_active_lsm(lines: list[str]) -> list[str]:
    for line in lines:
        stripped = line.strip()
        if not stripped.startswith("CONFIG_LSM="):
            continue
        raw_value = stripped.split("=", 1)[1].strip()
        if len(raw_value) >= 2 and raw_value[0] == raw_value[-1] == '"':
            raw_value = raw_value[1:-1]
        return raw_value.split(",")
    return []

def unique_tokens(values: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for value in values:
        token = value.strip()
        if not token or token in seen:
            continue
        seen.add(token)
        ordered.append(token)
    return ordered

source_lsm_tokens: list[str] = []
for candidate in (private_fragment, private_required, gki_defconfig):
    if not candidate.is_file():
        continue
    source_lsm_tokens = parse_active_lsm(candidate.read_text(encoding="utf-8").splitlines())
    if source_lsm_tokens:
        break
if not source_lsm_tokens:
    source_lsm_tokens = fallback_lsm.split(",")

fragment_lines = features_fragment.read_text(encoding="utf-8").splitlines()
updated_lines: list[str] = []

for line in fragment_lines:
    if line.startswith("CONFIG_LSM="):
        continue
    if line == "CONFIG_BBG=y":
        continue
    updated_lines.append(line)

final_tokens = unique_tokens(source_lsm_tokens)
if "baseband_guard" not in final_tokens:
    final_tokens.append("baseband_guard")
final_lsm_value = ",".join(final_tokens)

updated_lines.append("CONFIG_BBG=y")
updated_lines.append(f'CONFIG_LSM="{final_lsm_value}"')
features_fragment.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
print(final_lsm_value)
PY
}

if [ ! -d "$COMMON_DIR" ]; then
  echo "Workspace common directory not found: $COMMON_DIR" >&2
  exit 1
fi

if ! git -C "$COMMON_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Workspace common directory is not a git repo: $COMMON_DIR" >&2
  exit 1
fi

if [ ! -f "$PRIVATE_FRAGMENT" ]; then
  echo "Workspace private fragment not found: $PRIVATE_FRAGMENT" >&2
  exit 1
fi

if [ ! -f "$FEATURES_FRAGMENT" ]; then
  echo "Workspace features fragment not found: $FEATURES_FRAGMENT" >&2
  exit 1
fi

if [ -e "$BBG_DIR" ] && [ ! -d "$BBG_DIR/.git" ]; then
  rm -rf "$BBG_DIR"
fi

if [ -d "$BBG_DIR/.git" ]; then
  git -C "$BBG_DIR" fetch --depth 1 origin "$BBG_REF" || true
else
  git clone --depth 1 "$BBG_REPO" "$BBG_DIR"
  git -C "$BBG_DIR" fetch --depth 1 origin "$BBG_REF" || true
fi

if ! git -C "$BBG_DIR" checkout "$BBG_REF"; then
  if git -C "$BBG_DIR" rev-parse --verify FETCH_HEAD >/dev/null 2>&1; then
    git -C "$BBG_DIR" checkout --detach FETCH_HEAD
  else
    echo "Unable to checkout BBG ref: $BBG_REF" >&2
    exit 1
  fi
fi

if [ ! -f "$BBG_DIR/setup.sh" ]; then
  echo "Missing upstream BBG setup script: $BBG_DIR/setup.sh" >&2
  exit 1
fi

(
  cd "$COMMON_DIR"
  if [ -n "$BBG_LOG_DIR" ]; then
    sh "$BBG_DIR/setup.sh" "$BBG_REF" 2>&1 | tee "$BBG_LOG_DIR/setup.log"
  else
    sh "$BBG_DIR/setup.sh" "$BBG_REF"
  fi
)

bbg_lsm_value="$(update_bbg_fragment)"
echo "BBG CONFIG_LSM=\"$bbg_lsm_value\""

bbg_commit="$(git -C "$BBG_DIR" rev-parse HEAD)"
if [ -n "$BBG_LOG_DIR" ]; then
  {
    echo "BBG repo: $BBG_REPO"
    echo "BBG ref: $BBG_REF"
    echo "BBG commit: $bbg_commit"
    echo "BBG source path: $BBG_DIR"
    echo "BBG CONFIG_LSM=\"$bbg_lsm_value\""
  } > "$BBG_LOG_DIR/source.txt"
fi
rm -rf "$BBG_DIR/.github"
echo "BBG commit: $bbg_commit"
echo "BBG source staged at: $BBG_DIR"
