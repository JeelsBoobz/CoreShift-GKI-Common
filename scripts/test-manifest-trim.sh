#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: test-manifest-trim.sh <profile-json> <workspace-dir> [--extra-remove-projects CSV]

Initializes an ACK manifest workspace, generates a local overlay from the
profile-selected overlay JSON plus optional test-only extra remove-project overrides, syncs the
manifest checkout, and writes manifest-trim-report.txt without building.
EOF
}

if [ "$#" -lt 2 ]; then
  usage >&2
  exit 1
fi

PROFILE_JSON="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORKSPACE_DIR="$2"
shift 2

EXTRA_REMOVE_PROJECTS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --extra-remove-projects)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --extra-remove-projects" >&2
        exit 1
      fi
      EXTRA_REMOVE_PROJECTS="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for tool in git python3 repo; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_URL="https://android.googlesource.com/kernel/manifest"
CORESHIFT_REPO_JOBS="${CORESHIFT_REPO_JOBS:-4}"
CORESHIFT_REPO_DEPTH="${CORESHIFT_REPO_DEPTH:-1}"
CORESHIFT_REPO_PARTIAL_CLONE="${CORESHIFT_REPO_PARTIAL_CLONE:-1}"
CORESHIFT_REPO_CLONE_FILTER="${CORESHIFT_REPO_CLONE_FILTER:-blob:none}"
CORESHIFT_REPO_NO_VERIFY="${CORESHIFT_REPO_NO_VERIFY:-0}"

eval "$(
  python3 - "$PROFILE_JSON" <<'PY'
import json
import shlex
import sys

profile_path = sys.argv[1]
with open(profile_path, encoding="utf-8") as fh:
    profile = json.load(fh)

required_strings = (
    "manifest_branch",
    "manifest_overlay",
    "manifest_overlay_mode",
    "kernel_source_branch",
)
for field in required_strings:
    value = profile.get(field)
    if not isinstance(value, str) or not value:
        raise SystemExit(
            f"{profile_path}: profile field {field!r} must be a non-empty string"
        )
    print(f"{field.upper()}={shlex.quote(value)}")
PY
)"

mkdir -p "$WORKSPACE_DIR"
WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"

repo_launcher_version() {
  local version_output=""
  version_output="$(repo version 2>/dev/null | head -n 1 || true)"
  if [ -n "$version_output" ]; then
    printf '%s\n' "$version_output"
    return 0
  fi
  version_output="$(repo --version 2>/dev/null | head -n 1 || true)"
  if [ -n "$version_output" ]; then
    printf '%s\n' "$version_output"
    return 0
  fi
  printf 'unknown\n'
}

case "$CORESHIFT_REPO_PARTIAL_CLONE" in
  1)
    repo_partial_clone_enabled=1
    repo_partial_clone_label="on"
    ;;
  *)
    repo_partial_clone_enabled=0
    repo_partial_clone_label="off"
    ;;
esac

echo "Manifest trim test:"
echo "  repo launcher path: $(command -v repo)"
echo "  repo launcher version: $(repo_launcher_version)"
echo "  manifest branch: $MANIFEST_BRANCH"
echo "  kernel source branch: $KERNEL_SOURCE_BRANCH"
echo "  manifest overlay policy path: $MANIFEST_OVERLAY"
echo "  manifest overlay mode: $MANIFEST_OVERLAY_MODE"
echo "  repo jobs: $CORESHIFT_REPO_JOBS"
echo "  partial clone: $repo_partial_clone_label"
echo "  clone filter: $CORESHIFT_REPO_CLONE_FILTER"
echo "  workspace path: $WORKSPACE_DIR"

(
  cd "$WORKSPACE_DIR"

  repo_init_log="$(mktemp)"
  repo_sync_log="$(mktemp)"
  cleanup_logs() {
    rm -f "$repo_init_log" "$repo_sync_log"
  }
  trap cleanup_logs EXIT

  if [ -e .repo ] && [ ! -d .repo ]; then
    echo "Workspace has a non-directory .repo entry: $WORKSPACE_DIR/.repo" >&2
    exit 1
  fi

  repo_init_base_args=(
    -u "$MANIFEST_URL"
    -b "$MANIFEST_BRANCH"
    --depth="$CORESHIFT_REPO_DEPTH"
  )
  repo_init_optional_args=()
  if [ "$repo_partial_clone_enabled" -eq 1 ]; then
    repo_init_optional_args+=(
      --partial-clone
      --clone-filter="$CORESHIFT_REPO_CLONE_FILTER"
    )
  fi
  if [ "$CORESHIFT_REPO_NO_VERIFY" = "1" ]; then
    echo "repo verification disabled by CORESHIFT_REPO_NO_VERIFY=1"
    repo_init_optional_args+=(--no-repo-verify)
  fi

  if ! repo init \
    "${repo_init_base_args[@]}" \
    "${repo_init_optional_args[@]}" 2>&1 | tee "$repo_init_log"
  then
    if grep -Eqi 'no such option|unknown option|unrecognized arguments|invalid option' "$repo_init_log"; then
      echo "repo init retrying without optional flags"
      repo init "${repo_init_base_args[@]}" 2>&1 | tee "$repo_init_log"
    else
      exit 1
    fi
  fi

  echo "initialized repo version:"
  repo version || true

  mkdir -p .repo/local_manifests
  OVERLAY_OUTPUT="$WORKSPACE_DIR/.repo/local_manifests/coreshift-overlay.xml"
  MANIFEST_TRIM_REPORT="$WORKSPACE_DIR/manifest-trim-report.txt"

  python3 "$SCRIPT_DIR/generate-manifest-overlay.py" \
    --profile-json "$PROFILE_JSON" \
    --workspace "$WORKSPACE_DIR" \
    --output "$OVERLAY_OUTPUT" \
    --extra-remove-projects "$EXTRA_REMOVE_PROJECTS"

  echo "  generated overlay manifest path: $OVERLAY_OUTPUT"
  echo "  manifest report path: $MANIFEST_TRIM_REPORT"

  repo_sync_base_args=(
    -c
    --fail-fast
    --no-clone-bundle
    --no-tags
    -j "$CORESHIFT_REPO_JOBS"
  )
  repo_sync_optional_args=(
    --optimized-fetch
    --prune
  )

  if ! repo sync \
    "${repo_sync_base_args[@]}" \
    "${repo_sync_optional_args[@]}" 2>&1 | tee "$repo_sync_log"
  then
    if grep -Eqi 'no such option|unknown option|unrecognized arguments|invalid option' "$repo_sync_log"; then
      echo "repo sync retrying without optional flags"
      repo sync "${repo_sync_base_args[@]}" 2>&1 | tee "$repo_sync_log"
    else
      exit 1
    fi
  fi
)
