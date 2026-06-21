#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/apply-susfs.sh <workspace-dir> <profile-name>
EOF
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 1
fi

WORKSPACE_DIR="$1"
PROFILE_NAME="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_DIR="$WORKSPACE_DIR/common"
FEATURES_FRAGMENT="$COMMON_DIR/features.fragment"
SUSFS_DIR="$COMMON_DIR/SUSFS"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REFS_CONFIG="$REPO_ROOT/configs/susfs-refs.json"
LOCAL_SUSFS_PATCH_ROOT="$REPO_ROOT/patches/susfs"
LOCAL_KSU_PATCH_ROOT="$REPO_ROOT/patches/ksu"
if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
  SUSFS_LOG_DIR="$CORESHIFT_LOG_DIR/patches/susfs"
  mkdir -p "$SUSFS_LOG_DIR"
else
  SUSFS_LOG_DIR=""
fi

log() {
  echo "[susfs] $*"
}

fail() {
  echo "[susfs] $*" >&2
  exit 1
}

derive_profile_parts() {
  python3 - "$PROFILE_NAME" <<'PY'
import re
import sys

profile = sys.argv[1]
match = re.fullmatch(r"(android\d+)-(\d+\.\d+)-lts", profile)
if not match:
    raise SystemExit(f"Could not derive Android release/kernel version from profile: {profile}")
print(match.group(1))
print(match.group(2))
PY
}

resolve_configured_ref() {
  [ -f "$SUSFS_REFS_CONFIG" ] || return 1
  python3 - "$SUSFS_REFS_CONFIG" "$PROFILE_NAME" "$ANDROID_RELEASE" "$KERNEL_VERSION" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
profile = sys.argv[2]
android_release = sys.argv[3]
kernel_version = sys.argv[4]
android_kernel = f"{android_release}-{kernel_version}"

data = json.loads(path.read_text(encoding="utf-8"))

def lookup(container, key):
    if isinstance(container, dict):
        value = container.get(key)
        if isinstance(value, str) and value:
            return value
    return None

for container, key in (
    (data.get("profiles"), profile),
    (data.get("android_kernels"), android_kernel),
    (data.get("kernels"), kernel_version),
    (data, profile),
    (data, android_kernel),
    (data, kernel_version),
):
    value = lookup(container, key)
    if value:
        print(value)
        break
PY
}

remote_head_exists() {
  local candidate="$1"
  git ls-remote --heads "$SUSFS_REPO" "$candidate" | grep -q .
}

resolve_susfs_ref() {
  if [ -n "${SUSFS_REF:-}" ]; then
    printf '%s\n' "$SUSFS_REF"
    return 0
  fi

  local configured_ref
  configured_ref="$(resolve_configured_ref || true)"
  if [ -n "$configured_ref" ]; then
    if [[ "$configured_ref" != *-dev ]] && remote_head_exists "${configured_ref}-dev"; then
      printf '%s\n' "${configured_ref}-dev"
    else
      printf '%s\n' "$configured_ref"
    fi
    return 0
  fi

  local candidate
  local candidates=(
    "gki-$ANDROID_RELEASE-$KERNEL_VERSION"
    "gki-$ANDROID_RELEASE-$KERNEL_VERSION-dev"
    "$ANDROID_RELEASE-$KERNEL_VERSION"
    "$ANDROID_RELEASE-$KERNEL_VERSION-dev"
    "kernel-$KERNEL_VERSION"
    "kernel-$KERNEL_VERSION-dev"
    "$KERNEL_VERSION"
    "$KERNEL_VERSION-dev"
    "main"
    "master"
  )

  for candidate in "${candidates[@]}"; do
    if remote_head_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Could not resolve SUSFS ref for $PROFILE_NAME. Set SUSFS_REF or add configs/susfs-refs.json entry." >&2
  return 1
}

clone_susfs_source() {
  local ref="$1"

  if [ -e "$SUSFS_DIR" ] && [ ! -d "$SUSFS_DIR/.git" ]; then
    log "Removing non-git SUSFS directory: $SUSFS_DIR"
    rm -rf "$SUSFS_DIR"
  fi

  if [ -d "$SUSFS_DIR/.git" ]; then
    log "Reusing existing SUSFS checkout: $SUSFS_DIR"
    git -C "$SUSFS_DIR" fetch --depth 1 origin "$ref"
    git -C "$SUSFS_DIR" checkout --detach FETCH_HEAD
    return 0
  fi

  log "Cloning SUSFS ref $ref into $SUSFS_DIR"
  if git clone --depth 1 --branch "$ref" "$SUSFS_REPO" "$SUSFS_DIR"; then
    return 0
  fi

  log "Branch clone for $ref failed, falling back to detached fetch"
  rm -rf "$SUSFS_DIR"
  git clone --depth 1 "$SUSFS_REPO" "$SUSFS_DIR"
  git -C "$SUSFS_DIR" fetch --depth 1 origin "$ref"
  git -C "$SUSFS_DIR" checkout --detach FETCH_HEAD
}

find_susfs_repo_path() {
  local relative_path="$1"
  local patch_root

  for patch_root in "$SUSFS_DIR/kernel_patches" "$SUSFS_DIR/patches"; do
    if [ -e "$patch_root/$relative_path" ]; then
      printf '%s\n' "$patch_root/$relative_path"
      return 0
    fi
  done

  return 1
}

list_susfs_repo_paths() {
  local relative_glob="$1"
  local patch_root
  local found=1
  local matches=()

  for patch_root in "$SUSFS_DIR/kernel_patches" "$SUSFS_DIR/patches"; do
    [ -d "$patch_root" ] || continue
    mapfile -t matches < <(compgen -G "$patch_root/$relative_glob" || true)
    if [ "${#matches[@]}" -eq 0 ]; then
      continue
    fi
    printf '%s\n' "${matches[@]}"
    found=0
  done

  return "$found"
}

copy_repo_file_if_needed() {
  local source_path="$1"
  local target_path="$2"

  mkdir -p "$(dirname "$target_path")"
  if [ -f "$target_path" ] && cmp -s "$source_path" "$target_path"; then
    log "SUSFS source already up to date: $target_path"
    return 0
  fi

  cp "$source_path" "$target_path"
  log "Copied SUSFS source: $source_path -> $target_path"
}

copy_susfs_sources_if_present() {
  local source_glob="$1"
  local target_dir_rel="$2"
  local target_dir="$COMMON_DIR/$target_dir_rel"
  local copied_any=1
  local source_path

  mkdir -p "$target_dir"
  while IFS= read -r source_path; do
    [ -n "$source_path" ] || continue
    copy_repo_file_if_needed "$source_path" "$target_dir/$(basename "$source_path")"
    copied_any=0
  done < <(list_susfs_repo_paths "$source_glob" || true)

  if [ "$copied_any" -ne 0 ]; then
    log "No SUSFS source files matched in selected ref: $source_glob"
  fi
}

resolve_kernel_patch_dir() {
  local patch_root
  local candidate_dirs=(
    "$SUSFS_DIR/kernel_patches/$PROFILE_NAME"
    "$SUSFS_DIR/kernel_patches/$ANDROID_RELEASE-$KERNEL_VERSION"
    "$SUSFS_DIR/kernel_patches/$KERNEL_VERSION"
    "$SUSFS_DIR/patches/$PROFILE_NAME"
    "$SUSFS_DIR/patches/$ANDROID_RELEASE-$KERNEL_VERSION"
    "$SUSFS_DIR/patches/$KERNEL_VERSION"
  )

  for patch_root in "${candidate_dirs[@]}"; do
    if [ -d "$patch_root" ] && find "$patch_root" -maxdepth 1 -type f -name '*.patch' -print -quit | grep -q .; then
      printf '%s\n' "$patch_root"
      return 0
    fi
  done

  for patch_root in "$SUSFS_DIR/kernel_patches" "$SUSFS_DIR/patches"; do
    [ -d "$patch_root" ] || continue
    if find "$patch_root" -maxdepth 1 -type f -name '*.patch' -print -quit | grep -q .; then
      printf '%s\n' "$patch_root"
      return 0
    fi
  done

  return 1
}

collect_patch_files() {
  local patch_root="$1"
  [ -d "$patch_root" ] || return 1
  find "$patch_root" -maxdepth 1 -type f -name '*.patch' | sort
}

resolve_local_kernel_patch_dir() {
  local patch_root
  local candidate_dirs=(
    "$LOCAL_SUSFS_PATCH_ROOT/$PROFILE_NAME"
    "$LOCAL_SUSFS_PATCH_ROOT/$ANDROID_RELEASE-$KERNEL_VERSION"
    "$LOCAL_SUSFS_PATCH_ROOT/$KERNEL_VERSION"
  )

  for patch_root in "${candidate_dirs[@]}"; do
    if [ -d "$patch_root" ] && find "$patch_root" -type f -name '*.patch' -print -quit | grep -q .; then
      printf '%s\n' "$patch_root"
      return 0
    fi
  done

  return 1
}

collect_local_override_patch_files() {
  local patch_root="$1"
  [ -d "$patch_root" ] || return 1
  find "$patch_root" -type f -name '*.patch' | sort
}

build_filtered_kernel_patch() {
  local patch_file="$1"
  local override_dir="$2"
  local filtered_patch

  filtered_patch="$(mktemp)"
  python3 - "$patch_file" "$override_dir" "$filtered_patch" <<'PY'
import re
import sys
from pathlib import Path

patch_path = Path(sys.argv[1])
override_dir = Path(sys.argv[2])
output_path = Path(sys.argv[3])

lines = patch_path.read_text(encoding="utf-8").splitlines(keepends=True)
sections = []
current = []

for line in lines:
    if line.startswith("diff --git "):
        if current:
            sections.append(current)
        current = [line]
    else:
        current.append(line)

if current:
    sections.append(current)

kept = []
for section in sections:
    header = section[0].rstrip("\n")
    match = re.match(r"^diff --git a/(.+) b/(.+)$", header)
    if not match:
        kept.extend(section)
        continue

    target_path = match.group(2)
    if (override_dir / f"{target_path}.patch").is_file():
        continue

    kept.extend(section)

if kept:
    output_path.write_text("".join(kept), encoding="utf-8")
PY

  if [ -s "$filtered_patch" ]; then
    printf '%s\n' "$filtered_patch"
  else
    rm -f "$filtered_patch"
  fi
}

looks_like_kernelsu_dir() {
  local candidate="$1"
  [ -d "$candidate" ] || return 1
  [ -f "$candidate/kernel/Kconfig" ] ||
    [ -f "$candidate/kernel/Kbuild" ] ||
    [ -f "$candidate/kernel/Makefile" ] ||
    [ -f "$candidate/kernel/setup.sh" ]
}

find_kernelsu_dir() {
  local candidate
  local fixed_candidates=(
    "$COMMON_DIR/KernelSU"
    "$COMMON_DIR/KernelSU-Next"
    "$COMMON_DIR/drivers/kernelsu"
    "$COMMON_DIR/drivers/KernelSU"
  )

  for candidate in "${fixed_candidates[@]}"; do
    if looks_like_kernelsu_dir "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  while IFS= read -r candidate; do
    if looks_like_kernelsu_dir "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(
    find "$COMMON_DIR" -mindepth 1 -maxdepth 5 -type d \
      \( -iname 'KernelSU' -o -iname 'KernelSU-*' -o -iname 'kernelsu' -o -iname 'kernelsu-*' \) \
      | sort
  )

  return 1
}

scan_patch_config_symbols() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi

  grep -hE '^\+[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z0-9_]*' "$@" |
    sed -E 's/^\+[[:space:]]*config[[:space:]]+//' |
    sort -u || true
}

scan_tree_config_symbols() {
  find "$COMMON_DIR" -type f \( -name 'Kconfig' -o -name 'Kconfig.*' \) -print0 |
    xargs -0 -r grep -hE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z0-9_]*' |
    sed -E 's/^[[:space:]]*config[[:space:]]+//' |
    sort -u || true
}

ensure_line_once() {
  local wanted_line="$1"
  local target_file="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' RETURN
  grep -Fvx "$wanted_line" "$target_file" > "$tmp_file" || true
  printf '%s\n' "$wanted_line" >> "$tmp_file"
  mv "$tmp_file" "$target_file"
  trap - RETURN
}

patch_log_path() {
  local patch_file="$1"
  local label="$2"
  local patch_base

  patch_base="$(basename "$patch_file")"
  if [ -n "$SUSFS_LOG_DIR" ]; then
    printf '%s\n' "$SUSFS_LOG_DIR/${label}-${patch_base}.log"
  else
    mktemp
  fi
}

cleanup_patch_log() {
  local patch_log="$1"
  if [ -z "$SUSFS_LOG_DIR" ]; then
    rm -f "$patch_log"
  fi
}

apply_patch_file() {
  local patch_file="$1"
  local target_dir="$2"
  local label="$3"
  local patch_log

  patch_log="$(patch_log_path "$patch_file" "$label")"
  : > "$patch_log"

  log "Dry-run ${label} patch: $patch_file"
  if (cd "$target_dir" && patch --dry-run --fuzz=3 -p1 < "$patch_file") >"$patch_log" 2>&1; then
    log "Applying ${label} patch: $patch_file"
    if ! (cd "$target_dir" && patch --fuzz=3 -p1 < "$patch_file") >>"$patch_log" 2>&1; then
      echo "Failed to apply ${label} patch: $patch_file" >&2
      sed -n '1,120p' "$patch_log" >&2
      cleanup_patch_log "$patch_log"
      return 1
    fi
    cleanup_patch_log "$patch_log"
    return 0
  fi

  if (cd "$target_dir" && patch --dry-run -R --fuzz=3 -p1 < "$patch_file") >"$patch_log" 2>&1; then
    log "Skipping already-applied ${label} patch: $patch_file"
    cleanup_patch_log "$patch_log"
    return 0
  fi

  echo "Failed dry-run for ${label} patch: $patch_file" >&2
  echo "Patch target directory: $target_dir" >&2
  sed -n '1,120p' "$patch_log" >&2
  cleanup_patch_log "$patch_log"
  return 1
}

verify_susfs_integration() {
  local ksu_dir="$1"

  [ -f "$COMMON_DIR/fs/susfs.c" ] || fail "Missing SUSFS source after apply: $COMMON_DIR/fs/susfs.c"
  log "Verified SUSFS source exists: $COMMON_DIR/fs/susfs.c"

  [ -f "$COMMON_DIR/include/linux/susfs.h" ] || fail "Missing SUSFS header after apply: $COMMON_DIR/include/linux/susfs.h"
  log "Verified SUSFS header exists: $COMMON_DIR/include/linux/susfs.h"

  [ -f "$COMMON_DIR/include/linux/susfs_def.h" ] || fail "Missing SUSFS header after apply: $COMMON_DIR/include/linux/susfs_def.h"
  log "Verified SUSFS header exists: $COMMON_DIR/include/linux/susfs_def.h"

  if ! grep -R -E -q 'KSU_SUSFS|susfs' "$ksu_dir"; then
    fail "KernelSU source tree does not contain SUSFS integration strings: $ksu_dir"
  fi
  log "Verified KernelSU tree contains SUSFS integration strings: $ksu_dir"

  if ! grep -R -E -q --exclude-dir=.git --exclude-dir=SUSFS 'KSU_SUSFS' "$COMMON_DIR"; then
    fail "Kernel tree does not contain KSU_SUSFS references after SUSFS integration"
  fi
  log "Verified kernel tree contains KSU_SUSFS references"

  if ! grep -Eq '^CONFIG_KSU_SUSFS' "$FEATURES_FRAGMENT"; then
    fail "features.fragment is missing CONFIG_KSU_SUSFS entries after SUSFS integration"
  fi
  log "Verified features.fragment contains CONFIG_KSU_SUSFS entries"
}

if [ ! -d "$COMMON_DIR" ]; then
  fail "Workspace common directory not found: $COMMON_DIR"
fi

if ! git -C "$COMMON_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Workspace common directory is not a git repo: $COMMON_DIR"
fi

if [ ! -f "$FEATURES_FRAGMENT" ]; then
  fail "Workspace features fragment not found: $FEATURES_FRAGMENT"
fi

if ! grep -Fxq 'CONFIG_KSU=y' "$FEATURES_FRAGMENT"; then
  fail "SUSFS requires KernelSU. Use ksu-susfs or ksu-susfs-bbg."
fi

mapfile -t profile_parts < <(derive_profile_parts)
ANDROID_RELEASE="${profile_parts[0]}"
KERNEL_VERSION="${profile_parts[1]}"
RESOLVED_SUSFS_REF="$(resolve_susfs_ref)"

clone_susfs_source "$RESOLVED_SUSFS_REF"
rm -rf "$SUSFS_DIR/.github"

copy_susfs_sources_if_present 'fs/susfs*.c' 'fs'
copy_susfs_sources_if_present 'include/linux/susfs*.h' 'include/linux'

KERNEL_PATCH_DIR="$(resolve_kernel_patch_dir || true)"
[ -n "$KERNEL_PATCH_DIR" ] || fail "No SUSFS kernel patch directory found for $PROFILE_NAME in selected ref $RESOLVED_SUSFS_REF"
log "Using SUSFS kernel patch directory: $KERNEL_PATCH_DIR"
LOCAL_KERNEL_PATCH_DIR="$(resolve_local_kernel_patch_dir || true)"
if [ -n "$LOCAL_KERNEL_PATCH_DIR" ]; then
  log "Using local SUSFS kernel patch overrides: $LOCAL_KERNEL_PATCH_DIR"
fi

mapfile -t susfs_kernel_patch_files < <(collect_patch_files "$KERNEL_PATCH_DIR" || true)
if [ "${#susfs_kernel_patch_files[@]}" -eq 0 ]; then
  fail "No SUSFS kernel patch files found in $KERNEL_PATCH_DIR"
fi

declare -a effective_kernel_patch_files=()
declare -a local_override_patch_files=()
if [ -n "$LOCAL_KERNEL_PATCH_DIR" ]; then
  mapfile -t local_override_patch_files < <(collect_local_override_patch_files "$LOCAL_KERNEL_PATCH_DIR" || true)
  for patch_file in "${local_override_patch_files[@]}"; do
    log "Using local SUSFS kernel patch override: $patch_file"
  done
fi

for patch_file in "${susfs_kernel_patch_files[@]}"; do
  filtered_patch_file="$patch_file"
  if [ "${#local_override_patch_files[@]}" -gt 0 ]; then
    filtered_patch_file="$(build_filtered_kernel_patch "$patch_file" "$LOCAL_KERNEL_PATCH_DIR")"
    if [ -n "$filtered_patch_file" ] && [ "$filtered_patch_file" != "$patch_file" ]; then
      log "Filtered upstream SUSFS kernel patch through local overrides: $patch_file"
    fi
  fi
  if [ -n "$filtered_patch_file" ]; then
    effective_kernel_patch_files+=("$filtered_patch_file")
  fi
done
effective_kernel_patch_files+=("${local_override_patch_files[@]}")
if [ "${#effective_kernel_patch_files[@]}" -eq 0 ]; then
  fail "No effective SUSFS kernel patch files selected for $PROFILE_NAME"
fi

KSU_VARIANT="${KSU_VARIANT:-ksu}"

KERNELSU_DIR="$(find_kernelsu_dir || true)"
[ -n "$KERNELSU_DIR" ] || fail "Could not locate an existing KernelSU source tree under $COMMON_DIR"
log "Resolved KernelSU source tree: $KERNELSU_DIR"

declare -a config_patch_inputs=()
if [ "$KSU_VARIANT" = "kowsu" ]; then
  log "Skipping upstream KernelSU SUSFS patch for kowsu variant (incompatible file structure)"
else
  KERNELSU_PATCH_FILE="$(find_susfs_repo_path 'KernelSU/10_enable_susfs_for_ksu.patch' || true)"
  if [ -n "$KERNELSU_PATCH_FILE" ]; then
    log "Using KernelSU SUSFS patch: $KERNELSU_PATCH_FILE"
    apply_patch_file "$KERNELSU_PATCH_FILE" "$KERNELSU_DIR" "kernelsu"
    config_patch_inputs+=("$KERNELSU_PATCH_FILE")
  else
    log "KernelSU SUSFS patch not present in selected ref"
  fi
fi

for ksu_local_dir in \
  "$LOCAL_KSU_PATCH_ROOT/ksu-next/$PROFILE_NAME" \
  "$LOCAL_KSU_PATCH_ROOT/ksu-next/$ANDROID_RELEASE-$KERNEL_VERSION" \
  "$LOCAL_KSU_PATCH_ROOT/ksu-next/$KERNEL_VERSION" \
  "$LOCAL_KSU_PATCH_ROOT/ksu-next" \
  "$LOCAL_KSU_PATCH_ROOT/kowsu/$PROFILE_NAME" \
  "$LOCAL_KSU_PATCH_ROOT/kowsu/$ANDROID_RELEASE-$KERNEL_VERSION" \
  "$LOCAL_KSU_PATCH_ROOT/kowsu/$KERNEL_VERSION" \
  "$LOCAL_KSU_PATCH_ROOT/kowsu" \
  "$LOCAL_KSU_PATCH_ROOT/$PROFILE_NAME" \
  "$LOCAL_KSU_PATCH_ROOT/$ANDROID_RELEASE-$KERNEL_VERSION" \
  "$LOCAL_KSU_PATCH_ROOT/$KERNEL_VERSION" \
  ; do
  # variant-specific dirs only apply when variant matches
  case "$ksu_local_dir" in
    *"/ksu-next"*) [ "$KSU_VARIANT" = "ksu-next" ] || continue ;;
    *"/kowsu"*)    [ "$KSU_VARIANT" = "kowsu" ]    || continue ;;
  esac
  [ -d "$ksu_local_dir" ] || continue
  while IFS= read -r patch_file; do
    apply_patch_file "$patch_file" "$KERNELSU_DIR" "ksu-local"
    config_patch_inputs+=("$patch_file")
  done < <(find "$ksu_local_dir" -maxdepth 1 -name '*.patch' | sort)
  break
done

for patch_file in "${effective_kernel_patch_files[@]}"; do
  apply_patch_file "$patch_file" "$COMMON_DIR" "kernel"
  config_patch_inputs+=("$patch_file")
done

mapfile -t reject_files < <(find "$COMMON_DIR" -name '*.rej' -print)
if [ "${#reject_files[@]}" -gt 0 ]; then
  echo "SUSFS patch rejects created:" >&2
  printf '%s\n' "${reject_files[@]}" >&2
  exit 1
fi

mapfile -t patch_config_symbols < <(scan_patch_config_symbols "${config_patch_inputs[@]}")
mapfile -t tree_config_symbols < <(scan_tree_config_symbols)
mapfile -t susfs_config_symbols < <(
  {
    printf '%s\n' "${patch_config_symbols[@]}"
    printf '%s\n' "${tree_config_symbols[@]}"
  } | sed '/^$/d' | sort -u
)

if [ "${#susfs_config_symbols[@]}" -eq 0 ]; then
  log "SUSFS config scan found no KSU_SUSFS* symbols; falling back to CONFIG_KSU_SUSFS=y"
  susfs_config_symbols=("KSU_SUSFS")
fi

ensure_line_once 'CONFIG_KSU=y' "$FEATURES_FRAGMENT"
for config_symbol in "${susfs_config_symbols[@]}"; do
  ensure_line_once "CONFIG_${config_symbol}=y" "$FEATURES_FRAGMENT"
done

verify_susfs_integration "$KERNELSU_DIR"

susfs_commit="$(git -C "$SUSFS_DIR" rev-parse HEAD)"
if [ -n "$SUSFS_LOG_DIR" ]; then
  {
    echo "SUSFS repo: $SUSFS_REPO"
    echo "SUSFS ref: $RESOLVED_SUSFS_REF"
    echo "SUSFS commit: $susfs_commit"
    echo "SUSFS source path: $SUSFS_DIR"
    echo "KernelSU source path: $KERNELSU_DIR"
    echo "Kernel patch directory: $KERNEL_PATCH_DIR"
    if [ -n "$LOCAL_KERNEL_PATCH_DIR" ]; then
      echo "Local kernel override directory: $LOCAL_KERNEL_PATCH_DIR"
    fi
    if [ -n "$KERNELSU_PATCH_FILE" ]; then
      echo "KernelSU patch file: $KERNELSU_PATCH_FILE"
    fi
  } > "$SUSFS_LOG_DIR/susfs-source.txt"
  for config_symbol in "${susfs_config_symbols[@]}"; do
    echo "CONFIG_${config_symbol}=y"
  done > "$SUSFS_LOG_DIR/susfs-config-symbols.txt"
fi

echo "SUSFS repo: $SUSFS_REPO"
echo "SUSFS ref: $RESOLVED_SUSFS_REF"
echo "SUSFS commit: $susfs_commit"
echo "SUSFS source path: $SUSFS_DIR"
echo "KernelSU source path: $KERNELSU_DIR"
echo "Kernel patch directory: $KERNEL_PATCH_DIR"
if [ -n "$LOCAL_KERNEL_PATCH_DIR" ]; then
  echo "Local kernel override directory: $LOCAL_KERNEL_PATCH_DIR"
fi
if [ -n "$KERNELSU_PATCH_FILE" ]; then
  echo "KernelSU patch file: $KERNELSU_PATCH_FILE"
fi
echo "SUSFS config symbols enabled:"
for config_symbol in "${susfs_config_symbols[@]}"; do
  echo "  CONFIG_${config_symbol}=y"
done
