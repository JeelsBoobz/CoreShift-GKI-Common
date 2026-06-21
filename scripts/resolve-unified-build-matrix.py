#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""
Resolve unified build matrix for Build.yml.

Env vars:
  SOURCE_TYPE:    lts | date | custom
  KERNEL_VERSION: android15-6.6 | ... | all
  VARIANT:        vanilla | bbg | ... | all
  CUSTOM_URL:     git URL (source_type=custom only)
  CUSTOM_BRANCH:  branch/tag/commit (source_type=custom only)

Calls resolve-build-matrix.py for per-profile variant compatibility,
then patches each entry with source-type overrides.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SOURCE_TYPE    = os.environ["SOURCE_TYPE"]
KERNEL_VERSION = os.environ["KERNEL_VERSION"]
VARIANT        = os.environ["VARIANT"]
CUSTOM_URL     = os.environ.get("CUSTOM_URL", "")
CUSTOM_BRANCH  = os.environ.get("CUSTOM_BRANCH", "")

ALL_VERSIONS = [
    "android15-6.6",
    "android14-6.1",
    "android14-5.15",
    "android13-5.15",
    "android13-5.10",
    "android12-5.10",
    "android12-5.4",
    "android11-5.4",
]
DATE_VERSIONS = [v for v in ALL_VERSIONS if not v.endswith("-5.4")]

RELEASE_RE = re.compile(r"refs/heads/(android(\d+)-(\d+\.\d+)-(\d{4})-(\d{2}))$")


def resolve_versions() -> list[str]:
    if KERNEL_VERSION == "all":
        return DATE_VERSIONS if SOURCE_TYPE == "date" else list(ALL_VERSIONS)
    if SOURCE_TYPE == "date" and KERNEL_VERSION in ("android11-5.4", "android12-5.4"):
        print(f"error: no date branches for {KERNEL_VERSION} (pre-GKI 5.4)", file=sys.stderr)
        sys.exit(1)
    return [KERNEL_VERSION]


def get_date_branch_map(versions: list[str]) -> dict[str, str]:
    now = datetime.now(tz=timezone.utc)
    current_ym = (f"{now.year:04d}", f"{now.month:02d}")
    result = subprocess.run(
        ["git", "ls-remote", "--heads", "origin"],
        capture_output=True, text=True, check=True,
    )
    family_set = set(versions)
    by_family: dict[str, list[tuple[str, str, str]]] = {}
    for line in result.stdout.splitlines():
        m = RELEASE_RE.search(line)
        if not m:
            continue
        branch, av, kv, year, month = m.groups()
        fam = f"android{av}-{kv}"
        if fam not in family_set or (year, month) > current_ym:
            continue
        by_family.setdefault(fam, []).append((year, month, branch))
    result_map: dict[str, str] = {}
    for fam, candidates in by_family.items():
        candidates.sort(reverse=True)
        result_map[fam] = candidates[0][2]
    return result_map


def get_variant_entries(profile: str) -> list[dict]:
    script = Path(__file__).parent / "resolve-build-matrix.py"
    cmd = ["python3", str(script), "--profile", profile]
    if VARIANT != "all":
        cmd += ["--variant", VARIANT]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"warning: {profile}: {result.stderr.strip()}", file=sys.stderr)
        return []
    return json.loads(result.stdout)["include"]


def main() -> None:
    versions = resolve_versions()

    date_branch_map: dict[str, str] = {}
    if SOURCE_TYPE == "date":
        date_branch_map = get_date_branch_map(versions)
        for ver in versions:
            if ver not in date_branch_map:
                print(f"warning: no date branch found for {ver}, skipping", file=sys.stderr)

    if SOURCE_TYPE == "custom" and (not CUSTOM_URL or not CUSTOM_BRANCH):
        print("error: CUSTOM_URL and CUSTOM_BRANCH required for source_type=custom", file=sys.stderr)
        sys.exit(1)

    includes: list[dict] = []
    for ver in versions:
        profile = ver + "-lts"
        kernel_common_url = ""
        kernel_source_branch_override = ""
        label = profile

        if SOURCE_TYPE == "date":
            if ver not in date_branch_map:
                continue
            kernel_source_branch_override = date_branch_map[ver]
            label = date_branch_map[ver]
        elif SOURCE_TYPE == "custom":
            kernel_common_url = CUSTOM_URL
            kernel_source_branch_override = CUSTOM_BRANCH

        for entry in get_variant_entries(profile):
            includes.append({
                **entry,
                "label": label,
                "artifact_name": f"ak3-{label}-{entry['variant']}",
                "kernel_common_url": kernel_common_url,
                "kernel_source_branch_override": kernel_source_branch_override,
            })

    print(json.dumps({"matrix": {"include": includes}, "count": len(includes)}))


if __name__ == "__main__":
    main()
