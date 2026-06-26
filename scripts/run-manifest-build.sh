#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-manifest-build.sh <profile-json> <workspace-dir> <google_build_sh|kleaf> [extra-args...]

google_build_sh: runs build/build.sh with BUILD_CONFIG from the profile
kleaf: runs tools/bazel run with the Bazel target from the profile
EOF
}

ccache_warn_if_no_cacheable_calls() {
  local stats_output="$1"
  local wrappers_enabled="${2:-0}"
  if ! command -v ccache >/dev/null 2>&1; then
    return 0
  fi
  if [ "$wrappers_enabled" != "1" ]; then
    return 0
  fi
  if printf '%s\n' "$stats_output" | grep -Eq 'Cacheable calls:[[:space:]]+0([[:space:]]|$| /)'; then
    echo "ccache appears configured but compiler calls may not be routed through ccache. Google build.sh may be prepending the real Clang path after wrapper setup." >&2
  fi
}

if [ "$#" -lt 3 ]; then
  usage >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || {
  echo "Missing required tool: python3" >&2
  exit 1
}

PROFILE_JSON="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORKSPACE_DIR="$2"
BUILD_MODE="$3"
shift 3

if [ ! -f "$PROFILE_JSON" ]; then
  echo "Profile not found: $PROFILE_JSON" >&2
  exit 1
fi

if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "Workspace not found: $WORKSPACE_DIR" >&2
  exit 1
fi

WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"

if [ ! -d "$WORKSPACE_DIR/.repo" ]; then
  echo "Workspace is not a repo manifest checkout: $WORKSPACE_DIR" >&2
  exit 1
fi

eval "$(
  python3 - "$PROFILE_JSON" <<'PY'
import json
import shlex
import sys

profile_path = sys.argv[1]

with open(profile_path, encoding="utf-8") as fh:
    profile = json.load(fh)

for field in ("build_config", "bazel_target"):
    value = profile.get(field)
    if value is None:
        print(f"{field.upper()}=''")
        continue
    if not isinstance(value, str) or not value:
        raise SystemExit(
            f"{profile_path}: profile field {field!r} must be a non-empty string or null"
        )
    print(f"{field.upper()}={shlex.quote(value)}")
PY
)"

case "$BUILD_MODE" in
  google_build_sh)
    selected_build_config="${BUILD_CONFIG_OVERRIDE:-$BUILD_CONFIG}"
    jobs="${CORESHIFT_JOBS:-}"
    if [ -z "$selected_build_config" ]; then
      echo "Profile does not define build_config: $PROFILE_JSON" >&2
      exit 1
    fi
    if [ ! -f "$WORKSPACE_DIR/$selected_build_config" ]; then
      echo "BUILD_CONFIG not found in workspace: $WORKSPACE_DIR/$selected_build_config" >&2
      exit 1
    fi
    if [ ! -x "$WORKSPACE_DIR/build/build.sh" ]; then
      echo "Missing build/build.sh in workspace: $WORKSPACE_DIR" >&2
      exit 1
    fi
    (
      cd "$WORKSPACE_DIR"
      echo "CORESHIFT_CCACHE_WRAPPERS_ENABLED=${CORESHIFT_CCACHE_WRAPPERS_ENABLED:-}"
      echo "PATH=$PATH"
      echo "CCACHE_DIR=${CCACHE_DIR:-}"
      echo "CCACHE_WRAPPER_DIR=${CCACHE_WRAPPER_DIR:-}"
      echo "CCACHE_PATH=${CCACHE_PATH:-}"
      echo "CLANG_PREBUILT_BIN=${CLANG_PREBUILT_BIN:-}"
      if [ -n "${CLANG_PREBUILT_BIN:-}" ]; then
        export CLANG_PREBUILT_BIN
      fi
      command -v clang || true
      readlink -f "$(command -v clang 2>/dev/null)" 2>/dev/null || true
      clang_version_output="$(clang --version 2>/dev/null | head -n 3 || true)"
      printf '%s\n' "$clang_version_output"
      if [ "${CORESHIFT_CCACHE_WRAPPERS_ENABLED:-0}" = "1" ] && printf '%s\n' "$clang_version_output" | grep -Fq "Ubuntu clang"; then
        echo "ccache wrapper resolved to system Ubuntu clang; refusing to build with wrong compiler." >&2
        exit 1
      fi
      pre_build_ccache_stats="$(ccache -s 2>/dev/null || true)"
      printf '%s\n' "$pre_build_ccache_stats"
      echo "selected BUILD_CONFIG=$selected_build_config"
      echo "LTO=${LTO:-}"
      echo "CORESHIFT_JOBS=${CORESHIFT_JOBS:-}"
      echo "MAKEFLAGS=${MAKEFLAGS:-}"
      echo "SKIP_HEADERS_INSTALL=${SKIP_HEADERS_INSTALL:-}"
      echo "SKIP_EXT_MODULES=${SKIP_EXT_MODULES:-}"
      echo "SKIP_CP_KERNEL_HDRS=${SKIP_CP_KERNEL_HDRS:-}"
      echo "LLVM_PARALLEL_LINK_JOBS=${LLVM_PARALLEL_LINK_JOBS:-}"
      echo "LLD_PARALLEL_LINK_JOBS=${LLD_PARALLEL_LINK_JOBS:-}"
      if [ -n "${CLANG_PREBUILT_BIN:-}" ]; then
        echo "resolved CLANG_PREBUILT_BIN=$(readlink -f "$CLANG_PREBUILT_BIN" 2>/dev/null || printf "%s" "$CLANG_PREBUILT_BIN")"
      fi
      if [ -n "$jobs" ]; then
        BUILD_CONFIG="$selected_build_config" build/build.sh -j"$jobs" "$@"
      else
        BUILD_CONFIG="$selected_build_config" build/build.sh "$@"
      fi
      post_build_ccache_stats="$(ccache -s 2>/dev/null || true)"
      printf '%s\n' "$post_build_ccache_stats"
      ccache_warn_if_no_cacheable_calls "$post_build_ccache_stats" "${CORESHIFT_CCACHE_WRAPPERS_ENABLED:-0}"
      if [ -n "${CCACHE_LOGFILE:-}" ] && [ -f "$CCACHE_LOGFILE" ]; then
        echo "CCACHE_LOGFILE=$CCACHE_LOGFILE"
        if [ "${CORESHIFT_CCACHE_DEBUG:-0}" = "1" ]; then
          echo "ccache log (head):"
          head -n 5 "$CCACHE_LOGFILE" || true
          echo "ccache log (tail):"
          tail -n 5 "$CCACHE_LOGFILE" || true
        fi
      fi
    )
    ;;
  kleaf)
    if [ -z "$BAZEL_TARGET" ]; then
      echo "Profile does not define bazel_target: $PROFILE_JSON" >&2
      exit 1
    fi
    if [ ! -x "$WORKSPACE_DIR/tools/bazel" ]; then
      echo "Missing tools/bazel in workspace: $WORKSPACE_DIR" >&2
      exit 1
    fi
    (
      cd "$WORKSPACE_DIR"
      if [ -f "$WORKSPACE_DIR/common/coreshift.kleaf.fragment" ]; then
        tools/bazel run --defconfig_fragment=//common:coreshift.kleaf.fragment "$@" "$BAZEL_TARGET"
      else
        tools/bazel run "$@" "$BAZEL_TARGET"
      fi
    )
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
