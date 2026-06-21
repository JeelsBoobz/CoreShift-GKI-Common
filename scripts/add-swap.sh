#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

SIZE_GB="${1:-24}"
AGGRESSIVE_MODE="${2:-}"
SWAPFILE="/swapfile"

usage() {
  echo "Usage: $0 [size-gb] [--aggressive]" >&2
}

show_diagnostics() {
  free -h
  swapon --show
  cat /proc/meminfo | grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' || true
  sysctl vm.swappiness vm.vfs_cache_pressure vm.page-cluster || true
}

set_sysctl_if_supported() {
  local key="$1"
  local value="$2"

  sudo sysctl -w "${key}=${value}" || true
}

if ! [[ "$SIZE_GB" =~ ^[0-9]+$ ]] || [ "$SIZE_GB" -le 0 ]; then
  echo "Swap size must be a positive integer number of GiB: $SIZE_GB" >&2
  exit 1
fi

if [ -n "$AGGRESSIVE_MODE" ] && [ "$AGGRESSIVE_MODE" != "--aggressive" ]; then
  usage
  exit 1
fi

if [ "$#" -gt 2 ]; then
  usage
  exit 1
fi

echo "Swap diagnostics before setup:"
show_diagnostics

if sudo test -e "$SWAPFILE"; then
  echo "Removing existing $SWAPFILE"
  sudo swapoff "$SWAPFILE" || true
  sudo rm -f "$SWAPFILE"
fi

echo "Creating ${SIZE_GB}G swap at $SWAPFILE"

if ! sudo fallocate -l "${SIZE_GB}G" "$SWAPFILE"; then
  echo "fallocate failed, falling back to dd"
  sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SIZE_GB * 1024)) status=progress
fi

sudo chmod 600 "$SWAPFILE"
sudo mkswap "$SWAPFILE"

if [ "$AGGRESSIVE_MODE" = "--aggressive" ]; then
  sudo swapon --priority 100 "$SWAPFILE"
else
  sudo swapon "$SWAPFILE"
fi

if ! swapon --show --noheadings | grep -Fq "$SWAPFILE"; then
  echo "Failed to enable swap at $SWAPFILE" >&2
  exit 1
fi

if [ "$AGGRESSIVE_MODE" = "--aggressive" ]; then
  set_sysctl_if_supported vm.swappiness 80
  set_sysctl_if_supported vm.vfs_cache_pressure 200
  set_sysctl_if_supported vm.page-cluster 0
fi

echo "Swap diagnostics after setup:"
show_diagnostics
