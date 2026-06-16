#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/apply-ksu.sh <workspace-dir>
EOF
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 1
fi

WORKSPACE_DIR="$1"
COMMON_DIR="$WORKSPACE_DIR/common"
FEATURES_FRAGMENT="$COMMON_DIR/features.fragment"
KSU_DIR="$COMMON_DIR/KernelSU"
KSU_REPO="${KSU_REPO:-https://github.com/tiann/KernelSU.git}"
KSU_REF="${KSU_REF:-main}"
if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
  KSU_LOG_DIR="$CORESHIFT_LOG_DIR/patches/ksu"
  mkdir -p "$KSU_LOG_DIR"
else
  KSU_LOG_DIR=""
fi

ensure_line_once() {
  local wanted_line="$1"
  local target_file="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' EXIT
  grep -Fvx "$wanted_line" "$target_file" > "$tmp_file" || true
  printf '%s\n' "$wanted_line" >> "$tmp_file"
  mv "$tmp_file" "$target_file"
  trap - EXIT
}

if [ ! -d "$COMMON_DIR" ]; then
  echo "Workspace common directory not found: $COMMON_DIR" >&2
  exit 1
fi

if ! git -C "$COMMON_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Workspace common directory is not a git repo: $COMMON_DIR" >&2
  exit 1
fi

if [ ! -f "$FEATURES_FRAGMENT" ]; then
  echo "Workspace features fragment not found: $FEATURES_FRAGMENT" >&2
  exit 1
fi

if [ -e "$KSU_DIR" ] && [ ! -d "$KSU_DIR/.git" ]; then
  rm -rf "$KSU_DIR"
fi

if [ -d "$KSU_DIR/.git" ]; then
  git -C "$KSU_DIR" fetch --depth 1 origin "$KSU_REF" || true
else
  git clone --depth 1 "$KSU_REPO" "$KSU_DIR"
  git -C "$KSU_DIR" fetch --depth 1 origin "$KSU_REF" || true
fi

git -C "$KSU_DIR" checkout "$KSU_REF" || true

if [ ! -f "$KSU_DIR/kernel/setup.sh" ]; then
  echo "Missing upstream KernelSU setup script: $KSU_DIR/kernel/setup.sh" >&2
  exit 1
fi

(
  cd "$COMMON_DIR"
  if [ -n "$KSU_LOG_DIR" ]; then
    sh "$KSU_DIR/kernel/setup.sh" "$KSU_REF" 2>&1 | tee "$KSU_LOG_DIR/setup.log"
  else
    sh "$KSU_DIR/kernel/setup.sh" "$KSU_REF"
  fi
)

ensure_line_once 'CONFIG_KSU=y' "$FEATURES_FRAGMENT"

ksu_commit="$(git -C "$KSU_DIR" rev-parse HEAD)"
if [ -n "$KSU_LOG_DIR" ]; then
  {
    echo "KernelSU repo: $KSU_REPO"
    echo "KernelSU ref: $KSU_REF"
    echo "KernelSU commit: $ksu_commit"
    echo "KernelSU source path: $KSU_DIR"
  } > "$KSU_LOG_DIR/source.txt"
fi
rm -rf "$KSU_DIR/.github"
echo "KernelSU commit: $ksu_commit"
echo "KernelSU source staged at: $KSU_DIR"
