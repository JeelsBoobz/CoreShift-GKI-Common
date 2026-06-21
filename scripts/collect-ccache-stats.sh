#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

# Parse ccache -s output and emit hit_rate + direct_rate to GITHUB_OUTPUT
# and a table row to GITHUB_STEP_SUMMARY.
# Handles both ccache 3.x and 4.x stat formats.

if ! command -v ccache >/dev/null 2>&1; then
  echo "ccache not found; skipping stats collection" >&2
  exit 0
fi

stats="$(ccache -s 2>/dev/null || true)"
echo "$stats"

parse_count() {
  local pattern="$1"
  echo "$stats" | grep -i "$pattern" | grep -oE '[0-9]+' | head -1 || echo "0"
}

parse_ratio() {
  local pattern="$1"
  echo "$stats" | grep -i "$pattern" | grep -oE '[0-9]+\.[0-9]+\s*%' | head -1 \
    | tr -d ' ' || true
}

hit_rate=""
direct_rate=""

# ccache 4.x: "Hits:   N  (N%)"  "Direct:  N  (N%)"
if echo "$stats" | grep -qi "^Hits:"; then
  hits=$(parse_count "^Hits:")
  direct=$(parse_count "^  Direct:")
  misses=$(parse_count "^Misses:")
  total=$(( hits + misses ))
  if [ "$total" -gt 0 ]; then
    hit_pct=$(( hits * 100 / total ))
    hit_rate="${hit_pct}%"
  fi
  if [ "$total" -gt 0 ]; then
    direct_pct=$(( direct * 100 / total ))
    direct_rate="${direct_pct}%"
  fi
fi

# ccache 3.x: "cache hit (direct)" / "cache miss"
if [ -z "$hit_rate" ] && echo "$stats" | grep -qi "cache hit"; then
  direct=$(parse_count "cache hit (direct)")
  preprocessed=$(parse_count "cache hit (preprocessed)")
  misses=$(parse_count "cache miss")
  hits=$(( direct + preprocessed ))
  total=$(( hits + misses ))
  if [ "$total" -gt 0 ]; then
    hit_pct=$(( hits * 100 / total ))
    direct_pct=$(( direct * 100 / total ))
    hit_rate="${hit_pct}%"
    direct_rate="${direct_pct}%"
  fi
fi

hit_rate="${hit_rate:-N/A}"
direct_rate="${direct_rate:-N/A}"

echo "ccache_hit_rate=$hit_rate"
echo "ccache_direct_rate=$direct_rate"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "ccache_hit_rate=$hit_rate"     >> "$GITHUB_OUTPUT"
  echo "ccache_direct_rate=$direct_rate" >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<EOF

| **ccache Hit Rate** | $hit_rate |
| **ccache Direct Rate** | $direct_rate |
EOF
fi
