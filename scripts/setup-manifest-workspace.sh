#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-manifest-workspace.sh <profile-json> <workspace-dir>

Initializes an ACK workspace from https://android.googlesource.com/kernel/manifest,
generates .repo/local_manifests/coreshift-overlay.xml after repo init,
syncs the manifest checkout, then clones the requested kernel/common
source branch into common/.
EOF
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 1
fi

for tool in git python3 repo; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_JSON="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORKSPACE_DIR="$2"
MANIFEST_URL="https://android.googlesource.com/kernel/manifest"
KERNEL_COMMON_URL="https://android.googlesource.com/kernel/common"
CORESHIFT_REPO_JOBS="${CORESHIFT_REPO_JOBS:-4}"
CORESHIFT_REPO_DEPTH="${CORESHIFT_REPO_DEPTH:-1}"
CORESHIFT_REPO_PARTIAL_CLONE="${CORESHIFT_REPO_PARTIAL_CLONE:-1}"
CORESHIFT_REPO_CLONE_FILTER="${CORESHIFT_REPO_CLONE_FILTER:-blob:none}"
CORESHIFT_REPO_NO_VERIFY="${CORESHIFT_REPO_NO_VERIFY:-0}"

if [ ! -f "$PROFILE_JSON" ]; then
  echo "Profile not found: $PROFILE_JSON" >&2
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
if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
  mkdir -p "$CORESHIFT_LOG_DIR"
  manifest_workspace_log="$CORESHIFT_LOG_DIR/manifest-workspace.log"
else
  manifest_workspace_log=""
fi

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

echo "Workspace setup:"
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
if [ -n "$manifest_workspace_log" ]; then
  {
    echo "Workspace setup:"
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
  } > "$manifest_workspace_log"
fi

(
  cd "$WORKSPACE_DIR"

  if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
    repo_init_log="$CORESHIFT_LOG_DIR/repo-init.log"
    repo_sync_log="$CORESHIFT_LOG_DIR/repo-sync.log"
    : > "$repo_init_log"
    : > "$repo_sync_log"
  else
    repo_init_log="$(mktemp)"
    repo_sync_log="$(mktemp)"
  fi
  cleanup_logs() {
    if [ -z "${CORESHIFT_LOG_DIR:-}" ]; then
      rm -f "$repo_init_log" "$repo_sync_log"
    fi
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
    --output "$OVERLAY_OUTPUT"

  echo "  generated overlay manifest path: $OVERLAY_OUTPUT"
  echo "  manifest report path: $MANIFEST_TRIM_REPORT"
  if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
    cp "$OVERLAY_OUTPUT" "$CORESHIFT_LOG_DIR/coreshift-overlay.xml"
    cp "$MANIFEST_TRIM_REPORT" "$CORESHIFT_LOG_DIR/manifest-trim-report.txt"
    {
      echo "generated overlay manifest path: $OVERLAY_OUTPUT"
      echo "manifest report path: $MANIFEST_TRIM_REPORT"
    } >> "$CORESHIFT_LOG_DIR/manifest-workspace.log"
  fi

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

  rm -rf common
  git clone --depth=1 --branch "$KERNEL_SOURCE_BRANCH" "$KERNEL_COMMON_URL" common
)
