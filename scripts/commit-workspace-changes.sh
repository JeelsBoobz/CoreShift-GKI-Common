#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: scripts/commit-workspace-changes.sh <workspace-dir> [message]" >&2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 1
fi

WORKSPACE_DIR="$1"
MESSAGE="${2:-CoreShift: prepare build workspace}"
COMMON_DIR="$WORKSPACE_DIR/common"

if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "Workspace directory not found: $WORKSPACE_DIR" >&2
  exit 1
fi

if [ ! -d "$COMMON_DIR" ]; then
  echo "Workspace common directory not found: $COMMON_DIR" >&2
  exit 1
fi

if ! git -C "$COMMON_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Warning: common workspace is not a git repo, skipping workspace commit: $COMMON_DIR" >&2
  exit 0
fi

git -C "$COMMON_DIR" config user.name "CoreShift Builder"
git -C "$COMMON_DIR" config user.email "coreshift-builder@localhost"

for metadata_path in \
  "$COMMON_DIR/Baseband-guard/.github" \
  "$COMMON_DIR/KernelSU/.github"
do
  [ -e "$metadata_path" ] && rm -rf "$metadata_path"
done

mapfile -t nested_git_paths < <(
  find "$COMMON_DIR" \
    -path "$COMMON_DIR/.git" -prune -o \
    -type d -name .git -print
)

if [ "${#nested_git_paths[@]}" -gt 0 ]; then
  echo "Nested git repositories detected (will be excluded from commit):" >&2
  printf '%s\n' "${nested_git_paths[@]}" >&2
fi

git_add_args=(
  add -A -- .
  ":(exclude)out/"
  ":(exclude)dist/"
  ":(exclude).packaging/"
)

for nested_git_path in "${nested_git_paths[@]}"; do
  repo_root="${nested_git_path%/.git}"

  if [ "$repo_root" = "$COMMON_DIR" ]; then
    continue
  fi

  rel_path="${repo_root#$COMMON_DIR/}"

  git_add_args+=(":(exclude)$rel_path/")

  echo "Excluding nested repository from workspace commit: $rel_path" >&2
done

git -C "$COMMON_DIR" "${git_add_args[@]}"

staged_raw_diff="$(git -C "$COMMON_DIR" diff --cached --raw)"

if printf '%s\n' "$staged_raw_diff" | grep -Eq '(^|[[:space:]])160000[[:space:]]+160000[[:space:]]|(^|[[:space:]])160000[[:space:]]+[0-7]{6}[[:space:]]|(^|[[:space:]])[0-7]{6}[[:space:]]+160000[[:space:]]'; then
  echo "Error: embedded git repositories/submodules are forbidden in prepared workspace commits." >&2
  printf '%s\n' "$staged_raw_diff" >&2
  git -C "$COMMON_DIR" diff --cached --stat
  exit 1
fi

if ! git -C "$COMMON_DIR" diff --cached --quiet; then
  git -C "$COMMON_DIR" commit -m "$MESSAGE"
else
  echo "No workspace changes to commit"
fi

git -C "$COMMON_DIR" status --short -- \
  . \
  ":(exclude)out/" \
  ":(exclude)dist/" \
  ":(exclude).packaging/"

git -C "$COMMON_DIR" rev-parse --short HEAD