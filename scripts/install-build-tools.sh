#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

LOCAL_BIN="$HOME/.local/bin"
LOCAL_REPO="$LOCAL_BIN/repo"
REPO_LAUNCHER_URL="https://storage.googleapis.com/git-repo-downloads/repo"
CORESHIFT_UPDATE_REPO_LAUNCHER="${CORESHIFT_UPDATE_REPO_LAUNCHER:-1}"

APT_PACKAGES=(
  git
  curl
  ca-certificates
  python3
  make
  bc
  bison
  flex
  rsync
  unzip
  zip
  binutils
  tar
  zstd
  xz-utils
  file
  openssl
  libssl-dev
  libelf-dev
  dwarves
  gcc-aarch64-linux-gnu
  libc6-dev-arm64-cross
  linux-libc-dev-arm64-cross
  ccache
)

if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get is required to install host build tooling on this system" >&2
  exit 1
fi

mkdir -p "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$PATH"

sudo apt-get update
if [ "${CORESHIFT_APT_UPGRADE:-0}" = "1" ]; then
  sudo apt-get upgrade -y
fi
sudo apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"
sudo apt-get install -y --no-install-recommends libncurses5 libtinfo5 || true
sudo apt-get install -y --no-install-recommends libncurses6 libtinfo6 || true

if [ "$CORESHIFT_UPDATE_REPO_LAUNCHER" != "0" ]; then
  curl -fsSL "$REPO_LAUNCHER_URL" -o "$LOCAL_REPO"
  chmod +x "$LOCAL_REPO"
  hash -r
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$LOCAL_BIN" >> "$GITHUB_PATH"
fi

required_tools=(
  git
  curl
  python3
  repo
  make
  bc
  bison
  flex
  rsync
  zstd
  ccache
  zip
  unzip
  strings
)

for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool missing after installation: $tool" >&2
    exit 1
  fi
done

if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
  echo "Warning: aarch64-linux-gnu-gcc not found after installation" >&2
fi

if [ ! -f /usr/aarch64-linux-gnu/include/sys/time.h ]; then
  echo "Warning: /usr/aarch64-linux-gnu/include/sys/time.h not found after installation" >&2
fi

if [ ! -f /usr/aarch64-linux-gnu/include/sys/ioctl.h ]; then
  echo "Warning: /usr/aarch64-linux-gnu/include/sys/ioctl.h not found after installation" >&2
fi

if [ ! -f /usr/aarch64-linux-gnu/include/sys/types.h ]; then
  echo "Warning: /usr/aarch64-linux-gnu/include/sys/types.h not found after installation" >&2
fi

ldconfig -p | grep 'libncurses.so.5' || true
ldconfig -p | grep 'libtinfo.so.5' || true

echo "Installed host tool versions:"
git --version
python3 --version
make --version | head -n 1
echo "repo launcher: $(command -v repo)"
repo --version || true
aarch64-linux-gnu-gcc --version | head -n 1 || true
pahole --version || true
zstd --version || true
ccache --version | head -n 1 || true
