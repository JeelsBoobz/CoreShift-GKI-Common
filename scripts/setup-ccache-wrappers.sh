#!/usr/bin/env bash
set -euo pipefail

# Populated by setup_ccache_wrappers(); read by disable_wrappers() for cleanup.
# Declared here so disable_wrappers() is safe to call before setup runs.
declare -gA INPLACE_RENAMES=()

usage() {
  echo "Usage: scripts/setup-ccache-wrappers.sh <workspace-dir> [build-config]" >&2
}

persist_wrapper_state() {
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "CCACHE_WRAPPER_DIR=${CCACHE_WRAPPER_DIR:-}" >> "$GITHUB_ENV"
    echo "CCACHE_PATH=${CCACHE_PATH:-}" >> "$GITHUB_ENV"
    echo "CORESHIFT_CCACHE_WRAPPERS_ENABLED=${CORESHIFT_CCACHE_WRAPPERS_ENABLED:-0}" >> "$GITHUB_ENV"
  fi

  if [ -n "${GITHUB_PATH:-}" ] && [ "${CORESHIFT_CCACHE_WRAPPERS_ENABLED:-0}" = "1" ]; then
    echo "$CCACHE_WRAPPER_DIR" >> "$GITHUB_PATH"
  fi
}

disable_wrappers() {
  local message="$1"
  export CORESHIFT_CCACHE_WRAPPERS_ENABLED=0
  unset CCACHE_WRAPPER_DIR
  unset CCACHE_PATH
  export PATH="$ORIGINAL_PATH"
  # Undo any in-place renames so the original compiler binary is restored.
  # Without this, the wrapper script we wrote at $tool stays in place and the
  # kernel build invokes it — which calls ccache with the Go-wrapper .real binary
  # that then fails looking for .real-real.
  local wrapper_bin backup_bin
  for wrapper_bin in "${!INPLACE_RENAMES[@]}"; do
    backup_bin="${INPLACE_RENAMES[$wrapper_bin]}"
    if [ -f "$backup_bin" ] && [ -f "$wrapper_bin" ]; then
      mv "$backup_bin" "$wrapper_bin"
      echo "restored in-place wrapper: $wrapper_bin"
    fi
  done
  persist_wrapper_state
  echo "$message"
}

normalize_clang_candidate() {
  local candidate="$1"
  local normalized=""

  [ -n "$candidate" ] || return 0

  case "$candidate" in
    */clang)
      normalized="$candidate"
      ;;
    *)
      if [ -d "$candidate" ]; then
        normalized="$candidate/clang"
      fi
      ;;
  esac

  [ -n "$normalized" ] || return 0
  [ -e "$normalized" ] || return 0
  [ -x "$normalized" ] || return 0

  normalized="$(readlink -f "$normalized")"

  case "$normalized" in
    "$WRAPPER_DIR"/*|/usr/bin/clang|/usr/local/bin/clang)
      return 0
      ;;
    "$WORKSPACE_DIR"/*)
      printf '%s\n' "$normalized"
      ;;
  esac
}

add_candidate() {
  local candidate="$1"
  local source_priority="$2"
  local normalized=""
  local family_weight=9
  local version_tag=""

  normalized="$(normalize_clang_candidate "$candidate")"
  [ -n "$normalized" ] || return 0

  version_tag="$(basename "$(dirname "$(dirname "$normalized")")")"
  case "$version_tag" in
    clang-r*)
      family_weight=0
      ;;
    clang-*)
      family_weight=1
      ;;
  esac

  if [ -n "${CANDIDATE_PRIORITY[$normalized]:-}" ]; then
    if [ "$source_priority" -gt "${CANDIDATE_PRIORITY[$normalized]}" ]; then
      return 0
    fi
  fi

  CANDIDATE_PRIORITY["$normalized"]="$source_priority"
  CANDIDATE_FAMILY["$normalized"]="$family_weight"
  CANDIDATE_VERSION["$normalized"]="$version_tag"
}

discover_candidates_from_build_config() {
  local build_config_rel="$1"
  local build_config_path="$WORKSPACE_DIR/$build_config_rel"
  local raw_candidate

  if [ ! -f "$build_config_path" ]; then
    echo "Build config not found in workspace: $build_config_path" >&2
    return 1
  fi

  echo "discovering clang from build config: $build_config_rel"

  if mapfile -t build_config_runtime_candidates < <(
    WORKSPACE_DIR="$WORKSPACE_DIR" BUILD_CONFIG_REL="$build_config_rel" bash <<'EOF'
set -eo pipefail
set +u
cd "$WORKSPACE_DIR"
export ROOT_DIR="$WORKSPACE_DIR"
export KERNEL_DIR="$WORKSPACE_DIR/common"
. "$BUILD_CONFIG_REL" >/dev/null 2>&1 || true
for var in CLANG_PREBUILT_BIN CLANG_PREBUILT_DIR CLANG_TOOLCHAIN CLANG_PATH; do
  eval "v=\${$var:-}"
  [ -n "$v" ] && printf '%s\n' "$v"
done
printf '%s\n' "${PATH:-}" | tr ':' '\n'
EOF
  ); then
    for raw_candidate in "${build_config_runtime_candidates[@]}"; do
      add_candidate "$raw_candidate" 0
    done
  else
    echo "Warning: could not source $build_config_rel for clang discovery; falling back to file-based detection" >&2
  fi

  if mapfile -t build_config_path_candidates < <(
    grep -RhoE '([^"[:space:]]*prebuilts[^"[:space:]]*/clang/host/linux-x86/[^"[:space:]]*/bin(/clang)?)' \
      "$build_config_path" \
      "$WORKSPACE_DIR"/common/build.config* \
      "$WORKSPACE_DIR"/build/* 2>/dev/null | sort -u
  ); then
    for raw_candidate in "${build_config_path_candidates[@]}"; do
      case "$raw_candidate" in
        /*)
          add_candidate "$raw_candidate" 1
          ;;
        *)
          add_candidate "$WORKSPACE_DIR/$raw_candidate" 1
          ;;
      esac
    done
  fi
}

setup_ccache_wrappers() {
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage
    return 1
  fi

  WORKSPACE_DIR="$1"
  BUILD_CONFIG_REL="${2:-}"
  WRAPPER_DIR="$HOME/.local/lib/coreshift-ccache-wrappers"
  CCACHE_BIN="$(command -v ccache || true)"
  ORIGINAL_PATH="${PATH:-}"

  if [ -z "$CCACHE_BIN" ]; then
    echo "ccache is required but not installed. Run ./scripts/install-build-tools.sh first." >&2
    return 1
  fi

  if [ ! -d "$WORKSPACE_DIR" ]; then
    echo "Workspace not found: $WORKSPACE_DIR" >&2
    return 1
  fi

  declare -gA CANDIDATE_PRIORITY=()
  declare -gA CANDIDATE_FAMILY=()
  declare -gA CANDIDATE_VERSION=()
  declare -gA INPLACE_RENAMES=()

  # Highest-priority candidate: CLANG_PREBUILT_BIN env var (set by build-kernel.sh
  # when a custom clang tarball was downloaded). Accepted even outside WORKSPACE_DIR.
  if [ -n "${CLANG_PREBUILT_BIN:-}" ]; then
    env_clang=""
    case "$CLANG_PREBUILT_BIN" in
      */clang) env_clang="$CLANG_PREBUILT_BIN" ;;
      *)       [ -d "$CLANG_PREBUILT_BIN" ] && env_clang="$CLANG_PREBUILT_BIN/clang" ;;
    esac
    if [ -n "$env_clang" ] && [ -x "$env_clang" ]; then
      env_clang="$(readlink -f "$env_clang")"
      CANDIDATE_PRIORITY["$env_clang"]=-1
      CANDIDATE_FAMILY["$env_clang"]=0
      CANDIDATE_VERSION["$env_clang"]="env-override"
      echo "CLANG_PREBUILT_BIN env candidate: $env_clang"
    fi
  fi

  if [ -n "$BUILD_CONFIG_REL" ]; then
    discover_candidates_from_build_config "$BUILD_CONFIG_REL"
  fi

  mapfile -t workspace_scan_candidates < <(
    find "$WORKSPACE_DIR" -path '*/bin/clang' -exec test -x {} \; -print 2>/dev/null | sort -u
  )
  for candidate in "${workspace_scan_candidates[@]}"; do
    add_candidate "$candidate" 2
  done

  mapfile -t filtered_candidates < <(
    for candidate in "${!CANDIDATE_PRIORITY[@]}"; do
      printf '%s\n' "$candidate"
    done | sort -u
  )

  echo "discovered clang candidates:"
  if [ "${#filtered_candidates[@]}" -gt 0 ]; then
    printf '  %s\n' "${filtered_candidates[@]}"
  else
    echo "  none"
  fi

  if [ "${#filtered_candidates[@]}" -eq 0 ]; then
    disable_wrappers "No repo/AOSP clang found in workspace; ccache wrapper will not be enabled to avoid falling back to system clang."
    return 0
  fi

  best_candidate_line="$(
    for candidate in "${filtered_candidates[@]}"; do
      printf '%s|%s|%s|%s\n' \
        "${CANDIDATE_PRIORITY[$candidate]}" \
        "${CANDIDATE_FAMILY[$candidate]}" \
        "${CANDIDATE_VERSION[$candidate]}" \
        "$candidate"
    done | sort -t'|' -k1,1n -k2,2n -k3,3r -k4,4 | head -n 1
  )"

  best_candidate="${best_candidate_line##*|}"
  best_dir="$(dirname "$best_candidate")"

  if ! selected_real_clang_version="$("$best_candidate" --version 2>&1)"; then
    disable_wrappers "ccache wrappers disabled because selected repo clang could not run"
    printf '%s\n' "$selected_real_clang_version" >&2
    return 0
  fi

  echo "selected real clang: $best_candidate"
  printf '%s\n' "$selected_real_clang_version" | head -n 3

  compiler_dirs=()
  for candidate in "${filtered_candidates[@]}"; do
    candidate_dir="$(dirname "$candidate")"
    if [ "$candidate_dir" != "$best_dir" ]; then
      compiler_dirs+=("$candidate_dir")
    fi
  done

  compiler_dirs=("$best_dir" "${compiler_dirs[@]}")

  mkdir -p "$WRAPPER_DIR"
  for tool in clang clang++ gcc g++ cc c++; do
    ln -sfn "$CCACHE_BIN" "$WRAPPER_DIR/$tool"
  done

  # Install wrapper scripts directly in $best_dir so that build.sh's internal
  # PATH="$CLANG_PREBUILT_BIN:$PATH" prepend does not bypass ccache. The wrapper
  # script passes the explicit .real path to ccache, so CCACHE_PATH lookup is not
  # used for this flow. A forwarding dir with .real symlinks is provided as the
  # CCACHE_PATH entry so the WRAPPER_DIR PATH-based symlinks also resolve to the
  # real binaries without looping through the wrapper scripts.
  CCACHE_REAL_BIN_DIR="$WRAPPER_DIR/real-clang-bin"
  mkdir -p "$CCACHE_REAL_BIN_DIR"
  inplace_count=0
  for tool in clang clang++ clang-cpp; do
    real_bin="$best_dir/$tool"
    real_bin_backup="$best_dir/${tool}.real"
    if [ -x "$real_bin" ] && [ ! -e "$real_bin_backup" ] && [ ! -L "$real_bin" ]; then
      mv "$real_bin" "$real_bin_backup"
      {
        printf '#!/bin/sh\n'
        printf 'exec %s %s "$@"\n' "$CCACHE_BIN" "$real_bin_backup"
      } > "$real_bin"
      chmod +x "$real_bin"
      INPLACE_RENAMES["$real_bin"]="$real_bin_backup"
      echo "installed in-place ccache wrapper: $real_bin"
      inplace_count=$(( inplace_count + 1 ))
    fi
    if [ -x "$real_bin_backup" ]; then
      ln -sfn "$real_bin_backup" "$CCACHE_REAL_BIN_DIR/$tool"
    fi
  done
  [ "$inplace_count" -gt 0 ] && echo "in-place wrappers installed: $inplace_count (in $best_dir)" \
    || echo "in-place wrappers: already present or no tools found in $best_dir"

  compiler_dirs_for_ccache=("$CCACHE_REAL_BIN_DIR")
  for _d in "${compiler_dirs[@]}"; do
    [ "$_d" != "$best_dir" ] && compiler_dirs_for_ccache+=("$_d")
  done
  compiler_path_prefix="$(IFS=:; printf '%s' "${compiler_dirs_for_ccache[*]}")"
  export CCACHE_WRAPPER_DIR="$WRAPPER_DIR"
  export CCACHE_PATH="$compiler_path_prefix:$ORIGINAL_PATH"
  export CORESHIFT_CCACHE_WRAPPERS_ENABLED=1
  export PATH="$CCACHE_WRAPPER_DIR:$ORIGINAL_PATH"

  wrapper_clang_path="$(command -v clang)"
  if ! wrapper_clang_version="$(clang --version 2>&1)"; then
    disable_wrappers "ccache wrappers disabled because selected repo clang could not run"
    printf '%s\n' "$wrapper_clang_version" >&2
    return 0
  fi

  echo "wrapper clang path: $wrapper_clang_path"
  printf '%s\n' "$wrapper_clang_version" | head -n 3

  if printf '%s\n' "$wrapper_clang_version" | grep -Fq "Ubuntu clang"; then
    disable_wrappers "ccache wrapper resolved to system Ubuntu clang; wrappers disabled to avoid using the wrong compiler."
    return 0
  fi

  persist_wrapper_state
  echo "ccache path: $CCACHE_BIN"
  echo "wrapper dir: $CCACHE_WRAPPER_DIR"
  echo "CCACHE_PATH=$CCACHE_PATH"
  command -v clang
  clang --version | head -n 3 || true
  ccache -s || true
}

setup_ccache_wrappers "$@"
