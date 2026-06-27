#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Links the host rustup stable toolchain into the workspace at the path
# expected by the Kleaf/Bazel build system (prebuilts/rust/linux-x86/<ver>/).
# Called by build-kernel.sh when prebuilts/rust is absent from the workspace
# (e.g. removed by the aggressive manifest overlay).

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: link-rust-prebuilt.sh <workspace-dir>" >&2
  exit 1
fi

WORKSPACE_DIR="$1"

if [ -e "$WORKSPACE_DIR/prebuilts/rust" ]; then
  echo "prebuilts/rust already present in workspace, skipping link."
  exit 0
fi

command -v rustc >/dev/null 2>&1 || {
  echo "rustc not found in PATH; cannot link Rust prebuilt." >&2
  exit 1
}

RUST_VER=$(rustc --version | awk '{print $2}')
TOOLCHAIN_BIN=$(command -v rustc)
TOOLCHAIN_ROOT=$(cd "$(dirname "$TOOLCHAIN_BIN")/.." && pwd)

DEST="$WORKSPACE_DIR/prebuilts/rust/linux-x86/$RUST_VER"
mkdir -p "$(dirname "$DEST")"
ln -sfn "$TOOLCHAIN_ROOT" "$DEST"

echo "Linked Rust $RUST_VER: $TOOLCHAIN_ROOT → $DEST"
