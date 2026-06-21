#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-kernel.sh <profile-name> [--workspace DIR] [--mode auto|google_build_sh|kleaf] [--variant VARIANT] [--skip-setup] [--clean] [--skip-ak3] [--no-commit-workspace] [--disable-defconfig-check on|off] [--disable-kmi-check on|off] [--build-env KEY=VALUE] [-- EXTRA_BUILD_ARGS...]

Builds an ACK/GKI kernel for the named profile using the manifest workspace helpers.

Defaults:
  workspace: .work/<profile-name>
  mode: auto
  artifacts: dist/<profile-name>
EOF
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 1
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

PROFILE_NAME="$1"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_JSON="$REPO_ROOT/profiles/$PROFILE_NAME.json"
WORKSPACE_DIR="$REPO_ROOT/.work/$PROFILE_NAME"
ARTIFACT_DIR="$REPO_ROOT/dist/$PROFILE_NAME"
MODE="auto"
VARIANT="vanilla"
SKIP_SETUP=0
CLEAN=0
SKIP_AK3=0
NO_COMMIT_WORKSPACE=0
DISABLE_DEFCONFIG_CHECK="off"
DISABLE_KMI_CHECK="off"
BUILD_ENV=()
BUILD_ENV_KEYS=()
USER_BUILD_ENV_KEYS=()
DEFAULT_BUILD_ENV_KEYS=()
PASSTHROUGH_BUILD_ENV_KEYS=()
USER_SET_UAPI_SYSROOT_CFLAGS=0
USER_SET_LTO=0
USER_LTO_VALUE=""
EXTRA_ARGS=()
PROFILE_LTO="full"
EFFECTIVE_LTO=""
has_build_env_key() {
  local wanted="$1"
  local existing_key
  for existing_key in "${BUILD_ENV_KEYS[@]}"; do
    if [ "$existing_key" = "$wanted" ]; then
      return 0
    fi
  done
  return 1
}

add_default_build_env() {
  local key="$1"
  local value="$2"
  if has_build_env_key "$key"; then
    return 0
  fi
  BUILD_ENV+=("$key=$value")
  BUILD_ENV_KEYS+=("$key")
  DEFAULT_BUILD_ENV_KEYS+=("$key")
}

append_passthrough_build_env_if_unset() {
  local key="$1"
  local value="${!key:-}"
  if [ -z "$value" ]; then
    return 0
  fi
  if has_build_env_key "$key"; then
    return 0
  fi
  BUILD_ENV+=("$key=$value")
  BUILD_ENV_KEYS+=("$key")
  PASSTHROUGH_BUILD_ENV_KEYS+=("$key")
}

build_env_enabled() {
  local value="${1:-}"
  case "$value" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
  esac
  return 1
}

get_build_env_value() {
  local wanted="$1"
  local entry
  local value=""
  for entry in "${BUILD_ENV[@]}"; do
    if [ "${entry%%=*}" = "$wanted" ]; then
      value="${entry#*=}"
    fi
  done
  printf '%s\n' "$value"
}

export_build_env_key_if_set() {
  local key="$1"
  if has_build_env_key "$key"; then
    export "$key=$(get_build_env_value "$key")"
  fi
}

print_key_section() {
  local label="$1"
  shift
  if [ "$#" -gt 0 ]; then
    echo "  $label:"
    local key
    for key in "$@"; do
      echo "    $key"
    done
  else
    echo "  $label: none"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --workspace" >&2
        exit 1
      fi
      WORKSPACE_DIR="$2"
      shift 2
      ;;
    --mode)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --mode" >&2
        exit 1
      fi
      MODE="$2"
      shift 2
      ;;
    --variant)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --variant" >&2
        exit 1
      fi
      VARIANT="$2"
      shift 2
      ;;
    --skip-setup)
      SKIP_SETUP=1
      shift
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --skip-ak3)
      SKIP_AK3=1
      shift
      ;;
    --no-commit-workspace)
      NO_COMMIT_WORKSPACE=1
      shift
      ;;
    --disable-defconfig-check)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --disable-defconfig-check" >&2
        exit 1
      fi
      DISABLE_DEFCONFIG_CHECK="$2"
      shift 2
      ;;
    --disable-kmi-check)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --disable-kmi-check" >&2
        exit 1
      fi
      DISABLE_KMI_CHECK="$2"
      shift 2
      ;;
    --build-env)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --build-env" >&2
        exit 1
      fi
      if [[ "$2" != *=* ]]; then
        echo "Invalid --build-env value, expected KEY=VALUE: $2" >&2
        exit 1
      fi
      build_env_key="${2%%=*}"
      build_env_value="${2#*=}"
      if ! [[ "$build_env_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Invalid --build-env key: $build_env_key" >&2
        exit 1
      fi
      if [ "$build_env_key" = "CORESHIFT_MANIFEST""_TRIM" ]; then
        echo "Manifest workspace policy is controlled by profile JSON and manifests/overlays/*.json. Edit $PROFILE_JSON or the selected overlay policy instead of passing a trim build-env override." >&2
        exit 1
      fi
      BUILD_ENV+=("$2")
      BUILD_ENV_KEYS+=("$build_env_key")
      USER_BUILD_ENV_KEYS+=("$build_env_key")
      if [ "$build_env_key" = "UAPI_SYSROOT_CFLAGS" ]; then
        USER_SET_UAPI_SYSROOT_CFLAGS=1
      fi
      if [ "$build_env_key" = "LTO" ]; then
        USER_SET_LTO=1
        USER_LTO_VALUE="$build_env_value"
      fi
      shift 2
      ;;
    --)
      shift
      EXTRA_ARGS=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$MODE" in
  auto|google_build_sh|kleaf)
    ;;
  *)
    echo "Unsupported build mode: $MODE" >&2
    usage >&2
    exit 1
    ;;
esac

case "$DISABLE_DEFCONFIG_CHECK" in
  on|off)
    ;;
  *)
    echo "Unsupported value for --disable-defconfig-check: $DISABLE_DEFCONFIG_CHECK" >&2
    exit 1
    ;;
esac

case "$DISABLE_KMI_CHECK" in
  on|off)
    ;;
  *)
    echo "Unsupported value for --disable-kmi-check: $DISABLE_KMI_CHECK" >&2
    exit 1
    ;;
esac

if [ ! -f "$PROFILE_JSON" ]; then
  echo "Profile not found: $PROFILE_JSON" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || {
  echo "Missing required tool: python3" >&2
  exit 1
}

python3 "$REPO_ROOT/scripts/validate-profiles.py"

mapfile -t profile_build_fields < <(
  python3 - "$PROFILE_JSON" <<'PY'
import json
import sys

profile_path = sys.argv[1]

with open(profile_path, encoding="utf-8") as fh:
    profile = json.load(fh)

for field in ("build_config", "bazel_target"):
    value = profile.get(field)
    if value is None:
        print("")
    elif isinstance(value, str) and value:
        print(value)
    else:
        raise SystemExit(
            f"{profile_path}: profile field {field!r} must be a non-empty string or null"
        )

lto = profile.get("lto", "full")
if lto not in {"full", "thin", "none", "default"}:
    raise SystemExit(
        f"{profile_path}: profile field 'lto' must be one of: full, thin, none, default"
    )
print(lto)
PY
)

BUILD_CONFIG="${profile_build_fields[0]:-}"
BAZEL_TARGET="${profile_build_fields[1]:-}"
PROFILE_LTO="${profile_build_fields[2]:-full}"
EFFECTIVE_LTO="$PROFILE_LTO"

if [ "$USER_SET_LTO" -eq 1 ]; then
  EFFECTIVE_LTO="$USER_LTO_VALUE"
fi


matrix_json="$(
  python3 "$REPO_ROOT/scripts/resolve-build-matrix.py" \
    --profile "$PROFILE_NAME" \
    --variant "$VARIANT"
)"
mapfile -t variant_fields < <(
  python3 - "$matrix_json" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
entries = data.get("include", [])
if len(entries) != 1:
    raise SystemExit("expected exactly one resolved profile/variant entry")
entry = entries[0]
print(entry["variant"])
print(entry["features"])
print(entry["ak3_suffixes"])
PY
)

RESOLVED_VARIANT="${variant_fields[0]:-}"
CORESHIFT_FEATURES_VALUE="${variant_fields[1]:-}"
CORESHIFT_AK3_SUFFIXES_VALUE="${variant_fields[2]:-}"

export CORESHIFT_VARIANT="$RESOLVED_VARIANT"
export CORESHIFT_FEATURES="$CORESHIFT_FEATURES_VALUE"
export CORESHIFT_AK3_SUFFIXES="$CORESHIFT_AK3_SUFFIXES_VALUE"

for reserved_variant_key in CORESHIFT_VARIANT CORESHIFT_FEATURES CORESHIFT_AK3_SUFFIXES; do
  if has_build_env_key "$reserved_variant_key"; then
    echo "--build-env must not set reserved variant key: $reserved_variant_key" >&2
    exit 1
  fi
done

BUILD_ENV+=("CORESHIFT_VARIANT=$RESOLVED_VARIANT")
BUILD_ENV_KEYS+=("CORESHIFT_VARIANT")
DEFAULT_BUILD_ENV_KEYS+=("CORESHIFT_VARIANT")
BUILD_ENV+=("CORESHIFT_FEATURES=$CORESHIFT_FEATURES_VALUE")
BUILD_ENV_KEYS+=("CORESHIFT_FEATURES")
DEFAULT_BUILD_ENV_KEYS+=("CORESHIFT_FEATURES")
BUILD_ENV+=("CORESHIFT_AK3_SUFFIXES=$CORESHIFT_AK3_SUFFIXES_VALUE")
BUILD_ENV_KEYS+=("CORESHIFT_AK3_SUFFIXES")
DEFAULT_BUILD_ENV_KEYS+=("CORESHIFT_AK3_SUFFIXES")

case "$PROFILE_NAME" in
  android*-5.4-lts)
    is_54_profile=1
    ;;
  *)
    is_54_profile=0
    ;;
esac

for tool in git repo; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

mkdir -p "$(dirname "$WORKSPACE_DIR")" "$(dirname "$ARTIFACT_DIR")"

if [ "$CLEAN" -eq 1 ]; then
  rm -rf "$WORKSPACE_DIR" "$ARTIFACT_DIR"
fi

if [ "$SKIP_SETUP" -eq 0 ]; then
  for setup_env_key in \
    CORESHIFT_REPO_JOBS \
    CORESHIFT_REPO_DEPTH \
    CORESHIFT_REPO_PARTIAL_CLONE \
    CORESHIFT_REPO_CLONE_FILTER \
    CORESHIFT_REPO_NO_VERIFY \
    KERNEL_COMMON_URL \
    KERNEL_SOURCE_BRANCH_OVERRIDE \
    CORESHIFT_MANIFEST_OVERLAY_MODE
  do
    export_build_env_key_if_set "$setup_env_key"
  done
  "$REPO_ROOT/scripts/setup-manifest-workspace.sh" "$PROFILE_JSON" "$WORKSPACE_DIR"
elif [ ! -d "$WORKSPACE_DIR" ]; then
  echo "Workspace not found with --skip-setup: $WORKSPACE_DIR" >&2
  exit 1
fi

WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"

if [ ! -d "$WORKSPACE_DIR/.repo" ]; then
  echo "Workspace is not a repo manifest checkout: $WORKSPACE_DIR" >&2
  exit 1
fi

"$REPO_ROOT/scripts/prepare-private-fragment.sh" "$PROFILE_JSON" "$WORKSPACE_DIR"

for passthrough_key in \
  CCACHE_DIR \
  CCACHE_MAXSIZE \
  CCACHE_BASEDIR \
  CCACHE_NOHASHDIR \
  CCACHE_COMPILERCHECK \
  CCACHE_IGNOREOPTIONS \
  CCACHE_COMPRESSION \
  CCACHE_COMPRESSION_LEVEL \
  CCACHE_DIRECT \
  CCACHE_FILE_CLONE \
  CCACHE_INODE_CACHE \
  CCACHE_UMASK \
  CCACHE_SLOPPINESS \
  CCACHE_LOGFILE \
  CCACHE_WRAPPER_DIR \
  CCACHE_PATH \
  CORESHIFT_CCACHE_DEBUG \
  CORESHIFT_REPO_JOBS \
  CORESHIFT_REPO_DEPTH \
  CORESHIFT_REPO_PARTIAL_CLONE \
  CORESHIFT_REPO_CLONE_FILTER \
  CORESHIFT_REPO_NO_VERIFY \
  BBG_REPO \
  BBG_REF \
  KSU_REPO \
  KSU_REF \
  SUSFS_REPO \
  SUSFS_REF \
  DROIDSPACES_ENABLE \
  DROIDSPACES_REPO \
  DROIDSPACES_REF \
  DROIDSPACES_SYSVIPC_KABI_SLOT \
  USE_CCACHE
do
  append_passthrough_build_env_if_unset "$passthrough_key"
done

resolve_mode() {
  if [ "$MODE" != "auto" ]; then
    printf '%s\n' "$MODE"
    return 0
  fi

  if [ -n "${BUILD_CONFIG:-}" ]; then
    if [ -x "$WORKSPACE_DIR/build/build.sh" ] && [ -f "$WORKSPACE_DIR/$BUILD_CONFIG" ]; then
      printf '%s\n' "google_build_sh"
      return 0
    fi

    if [ -n "${BAZEL_TARGET:-}" ] && [ -x "$WORKSPACE_DIR/tools/bazel" ]; then
      printf '%s\n' "kleaf"
      return 0
    fi

    printf '%s\n' "google_build_sh"
    return 0
  fi

  if [ -n "${BAZEL_TARGET:-}" ]; then
    printf '%s\n' "kleaf"
    return 0
  fi

  echo "Profile does not define a usable build mode: $PROFILE_JSON" >&2
  exit 1
}

SELECTED_MODE="$(resolve_mode)"
EFFECTIVE_JOBS=""
BUILD_CONFIG_OVERRIDE_VALUE=""
EFFECTIVE_BUILD_CONFIG=""

if [ "$SELECTED_MODE" = "google_build_sh" ]; then
  if [ -f "$WORKSPACE_DIR/common/build.config.coreshift.gki.aarch64" ]; then
    BUILD_CONFIG_OVERRIDE_VALUE="common/build.config.coreshift.gki.aarch64"
  fi
  EFFECTIVE_BUILD_CONFIG="${BUILD_CONFIG_OVERRIDE_VALUE:-$BUILD_CONFIG}"
  add_default_build_env "SKIP_MRPROPER" "1"
  add_default_build_env "SKIP_CP_KERNEL_HDRS" "1"
  add_default_build_env "SKIP_UNSTRIPPED_MODULES" "1"
  add_default_build_env "SKIP_DEBUG_INFO" "1"
  add_default_build_env "SKIP_EXT_MODULES" "1"
  add_default_build_env "SKIP_HEADERS_INSTALL" "1"
  add_default_build_env "CORESHIFT_JOBS" "4"
  add_default_build_env "MAKEFLAGS" "-j4"
  if [ "$EFFECTIVE_LTO" = "full" ]; then
    add_default_build_env "LLVM_PARALLEL_LINK_JOBS" "1"
    add_default_build_env "LLD_PARALLEL_LINK_JOBS" "1"
  fi
  EFFECTIVE_JOBS="$(get_build_env_value "CORESHIFT_JOBS")"
fi

for feature_env_key in \
  BBG_REPO \
  BBG_REF \
  KSU_REPO \
  KSU_REF \
  SUSFS_REPO \
  SUSFS_REF \
  DROIDSPACES_ENABLE \
  DROIDSPACES_REPO \
  DROIDSPACES_REF \
  DROIDSPACES_SYSVIPC_KABI_SLOT
do
  if has_build_env_key "$feature_env_key"; then
    export "$feature_env_key=$(get_build_env_value "$feature_env_key")"
  fi
done

if [ "$is_54_profile" -eq 1 ]; then
  "$REPO_ROOT/scripts/patch-54-uapi-sysroot.sh" "$WORKSPACE_DIR"
  echo "Applied 5.4 UAPI sysroot patch"
  if [ "$USER_SET_UAPI_SYSROOT_CFLAGS" -eq 0 ]; then
    if [ ! -f /usr/aarch64-linux-gnu/include/sys/time.h ]; then
      echo "Warning: /usr/aarch64-linux-gnu/include/sys/time.h is missing; install-build-tools.sh should install libc6-dev-arm64-cross, and 5.4 header tests may still fail without it" >&2
    fi
    if [ ! -f /usr/aarch64-linux-gnu/include/sys/ioctl.h ]; then
      echo "Warning: /usr/aarch64-linux-gnu/include/sys/ioctl.h is missing; install-build-tools.sh should install libc6-dev-arm64-cross, and 5.4 header tests may still fail without it" >&2
    fi
    if [ ! -f /usr/aarch64-linux-gnu/include/sys/types.h ]; then
      echo "Warning: /usr/aarch64-linux-gnu/include/sys/types.h is missing; install-build-tools.sh should install libc6-dev-arm64-cross, and 5.4 header tests may still fail without it" >&2
    fi
    add_default_build_env "UAPI_SYSROOT_CFLAGS" "--target=aarch64-linux-gnu -isystem /usr/aarch64-linux-gnu/include"
    echo "Auto-added UAPI_SYSROOT_CFLAGS for 5.4 header tests: /usr/aarch64-linux-gnu/include"
  fi
fi

if build_env_enabled "${DROIDSPACES_ENABLE:-0}"; then
  "$REPO_ROOT/scripts/apply-droidspaces-gki-support.sh" "$WORKSPACE_DIR"
fi

"$REPO_ROOT/scripts/apply-features.sh" "$WORKSPACE_DIR" "$CORESHIFT_FEATURES_VALUE" "$PROFILE_NAME"

if [ "$DISABLE_DEFCONFIG_CHECK" = "on" ]; then
  "$REPO_ROOT/scripts/disable-defconfig-check.sh" "$WORKSPACE_DIR"
fi

if [ "$DISABLE_KMI_CHECK" = "on" ]; then
  "$REPO_ROOT/scripts/disable-kmi-check.sh" "$WORKSPACE_DIR"
fi

if [ "$SELECTED_MODE" = "google_build_sh" ] && command -v ccache >/dev/null 2>&1; then
  # Export CLANG_PREBUILT_BIN into the environment before sourcing the ccache
  # wrapper setup so it can be picked up as the highest-priority clang candidate
  # (e.g. when a custom clang tarball was downloaded and set via --build-env).
  if has_build_env_key "CLANG_PREBUILT_BIN"; then
    export CLANG_PREBUILT_BIN="$(get_build_env_value "CLANG_PREBUILT_BIN")"
  fi
  # shellcheck source=/dev/null
  . "$REPO_ROOT/scripts/setup-ccache-wrappers.sh" "$WORKSPACE_DIR" "$EFFECTIVE_BUILD_CONFIG"
  append_passthrough_build_env_if_unset "CORESHIFT_CCACHE_WRAPPERS_ENABLED"
  if [ "${CORESHIFT_CCACHE_WRAPPERS_ENABLED:-0}" = "1" ]; then
    append_passthrough_build_env_if_unset "CCACHE_WRAPPER_DIR"
    append_passthrough_build_env_if_unset "CCACHE_PATH"
    echo "google_build_sh compiler diagnostics:"
    command -v clang
    clang --version | head -n 1 || true
    ccache -s || true
  else
    echo "ccache wrappers disabled; continuing without compiler interception."
  fi
fi

if [ "$NO_COMMIT_WORKSPACE" -eq 0 ]; then
  "$REPO_ROOT/scripts/commit-workspace-changes.sh" "$WORKSPACE_DIR"
else
  echo "Skipping workspace commit because --no-commit-workspace was requested."
fi

if has_build_env_key "CORESHIFT_CCACHE_DEBUG" && ! has_build_env_key "CCACHE_LOGFILE"; then
  add_default_build_env "CCACHE_LOGFILE" "$WORKSPACE_DIR/ccache.log"
fi

run_cmd=(
  "$REPO_ROOT/scripts/run-manifest-build.sh"
  "$PROFILE_JSON"
  "$WORKSPACE_DIR"
  "$SELECTED_MODE"
  "${EXTRA_ARGS[@]}"
)

env_cmd=(
  "OUT_DIR=$WORKSPACE_DIR/out"
  "DIST_DIR=$WORKSPACE_DIR/dist"
  "BUILD_CONFIG_OVERRIDE=$BUILD_CONFIG_OVERRIDE_VALUE"
)

if [ "${#BUILD_ENV[@]}" -gt 0 ]; then
  env "${BUILD_ENV[@]}" "${env_cmd[@]}" "${run_cmd[@]}"
else
  env "${env_cmd[@]}" "${run_cmd[@]}"
fi

"$REPO_ROOT/scripts/collect-artifacts.sh" "$PROFILE_NAME" "$WORKSPACE_DIR" "$ARTIFACT_DIR"

if [ "$SKIP_AK3" -eq 0 ]; then
  "$REPO_ROOT/scripts/package-ak3.sh" "$PROFILE_NAME" "$WORKSPACE_DIR" "$ARTIFACT_DIR"
else
  echo "Skipping AnyKernel3 packaging because --skip-ak3 was requested."
fi

echo
echo "Build summary:"
echo "  profile: $PROFILE_NAME"
echo "  variant: $RESOLVED_VARIANT"
echo "  workspace: $WORKSPACE_DIR"
echo "  build mode: $SELECTED_MODE"
echo "  artifacts: $ARTIFACT_DIR"
if [ -f "$ARTIFACT_DIR/ak3-zip-path.txt" ]; then
  echo "  ak3 zip: $(cat "$ARTIFACT_DIR/ak3-zip-path.txt")"
fi
if [ -n "$BUILD_CONFIG_OVERRIDE_VALUE" ]; then
  echo "  build config override: $BUILD_CONFIG_OVERRIDE_VALUE"
fi
echo "  effective LTO: ${EFFECTIVE_LTO:-}"
if [ "$SELECTED_MODE" = "google_build_sh" ]; then
  echo "  effective jobs: ${EFFECTIVE_JOBS:-}"
fi
print_key_section "user build env" "${USER_BUILD_ENV_KEYS[@]}"
print_key_section "default build env" "${DEFAULT_BUILD_ENV_KEYS[@]}"
print_key_section "passthrough build env" "${PASSTHROUGH_BUILD_ENV_KEYS[@]}"
