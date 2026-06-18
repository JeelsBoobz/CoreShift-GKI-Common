#!/usr/bin/env python3
"""
Resolve the kernel sync matrix for sync-kernel-source.yml.

Reads configs/kernel-sync.json, queries upstream ACK and the mirror for
existing branches, then outputs JSON to stdout:

  {
    "sync_matrix":    {"include": [{"ack_branch": "..."}]},
    "prune_branches": ["..."],
    "sync_count":     N,
    "prune_count":    N
  }

Environment variables:
  UPSTREAM_URL   ACK remote URL (default: android.googlesource.com/kernel/common)
  MIRROR_REMOTE  mirror git remote name or URL (default: origin)
"""

import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

UPSTREAM_URL = os.environ.get(
    "UPSTREAM_URL", "https://android.googlesource.com/kernel/common"
)
MIRROR_REMOTE = os.environ.get("MIRROR_REMOTE", "origin")

# Matches: android16-6.12-2026-06
RELEASE_RE = re.compile(
    r"refs/heads/(android(\d+)-(\d+\.\d+)-(\d{4})-(\d{2}))$"
)


def ls_remote(target: str) -> list[str]:
    result = subprocess.run(
        ["git", "ls-remote", "--heads", target],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.splitlines()


def parse_release_branches(lines: list[str], family_set: set[str]) -> dict:
    """Return {family: [(year, month, branch), ...]} for known families."""
    by_family: dict[str, list] = defaultdict(list)
    for line in lines:
        m = RELEASE_RE.search(line)
        if not m:
            continue
        branch      = m.group(1)
        android_ver = m.group(2)
        kernel_ver  = m.group(3)
        year        = m.group(4)
        month       = m.group(5)
        family = f"android{android_ver}-{kernel_ver}"
        if family in family_set:
            by_family[family].append((year, month, branch))
    return by_family


def main() -> None:
    config_path = Path(__file__).parent.parent / "configs" / "kernel-sync.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))

    retention: int        = int(config.get("release_branch_retention", 10))
    lts_branches: list    = config["lts_branches"]
    kernel_families: list = config["kernel_families"]
    family_set            = set(kernel_families)

    # ── Discover release branches from upstream ───────────────────────────
    try:
        upstream_lines = ls_remote(UPSTREAM_URL)
    except subprocess.CalledProcessError as exc:
        print(f"error: failed to query upstream: {exc}", file=sys.stderr)
        sys.exit(1)

    upstream_by_family = parse_release_branches(upstream_lines, family_set)

    # ── Build the sync list ───────────────────────────────────────────────
    sync_branches: list[str] = list(lts_branches)
    keep_release: set[str]   = set()

    for family in kernel_families:
        # Sort descending by (year, month) — lexicographic order is correct
        # for zero-padded YYYY-MM strings.
        releases = sorted(upstream_by_family.get(family, []), reverse=True)
        for _, _, branch in releases[:retention]:
            sync_branches.append(branch)
            keep_release.add(branch)

    # ── Discover existing release branches in mirror (for pruning) ────────
    try:
        mirror_lines = ls_remote(MIRROR_REMOTE)
    except subprocess.CalledProcessError:
        # Mirror may be empty on first run or unreachable; prune nothing.
        mirror_lines = []

    existing_mirror_release = {
        m.group(1)
        for line in mirror_lines
        if (m := RELEASE_RE.search(line))
        # Only manage families listed in config; never touch unmanaged branches.
        and f"android{m.group(2)}-{m.group(3)}" in family_set
    }

    prune_branches = sorted(existing_mirror_release - keep_release)

    # ── Emit result ───────────────────────────────────────────────────────
    result = {
        "sync_matrix":    {"include": [{"ack_branch": b} for b in sync_branches]},
        "prune_branches": prune_branches,
        "sync_count":     len(sync_branches),
        "prune_count":    len(prune_branches),
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
