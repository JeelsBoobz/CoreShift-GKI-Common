#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Links CLANG_PREBUILT_BIN into the workspace at the versioned path expected
# by build.sh (prebuilts/clang/host/linux-x86/clang-<version>/).
# When prebuilts/clang/host/linux-x86 already exists (normal repo sync),
# replaces just the versioned subdir so the override wins over the built-in.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: link-clang-prebuilt.sh <workspace-dir>" >&2
  exit 1
fi

WORKSPACE_DIR="$1"
CLANG_PREBUILT_BIN="${CLANG_PREBUILT_BIN:-}"

if [ -z "$CLANG_PREBUILT_BIN" ]; then
  echo "CLANG_PREBUILT_BIN not set; cannot link clang prebuilt." >&2
  exit 1
fi

if [ ! -d "$CLANG_PREBUILT_BIN" ]; then
  echo "CLANG_PREBUILT_BIN not found: $CLANG_PREBUILT_BIN" >&2
  exit 1
fi

# Resolve CLANG_VERSION from workspace build.config.constants
CLANG_VERSION=""
while IFS= read -r constants_file; do
  if [ -f "$constants_file" ]; then
    v=$(grep -E '^CLANG_VERSION=' "$constants_file" | cut -d= -f2 | tr -d '[:space:]' | head -1)
    if [ -n "$v" ]; then
      CLANG_VERSION="$v"
      break
    fi
  fi
done < <(find "$WORKSPACE_DIR" -maxdepth 3 -name 'build.config.constants' 2>/dev/null)

if [ -z "$CLANG_VERSION" ]; then
  echo "Could not determine CLANG_VERSION from workspace build.config.constants." >&2
  exit 1
fi

# CLANG_PREBUILT_BIN points to the bin/ dir; toolchain root is one level up
TOOLCHAIN_ROOT="$(cd "$CLANG_PREBUILT_BIN/.." && pwd)"
DEST="$WORKSPACE_DIR/prebuilts/clang/host/linux-x86/clang-$CLANG_VERSION"
mkdir -p "$(dirname "$DEST")"
ln -sfn "$TOOLCHAIN_ROOT" "$DEST"

echo "Linked clang $CLANG_VERSION: $TOOLCHAIN_ROOT → $DEST"
