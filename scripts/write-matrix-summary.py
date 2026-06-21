#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Render a readable GitHub Actions matrix summary."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROFILE_RE = re.compile(r"^android(\d+)-(\d+)\.(\d+)-lts$")


def fail(message: str) -> "None":
    raise SystemExit(message)


def load_json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"missing required file: {path}")
    except json.JSONDecodeError as exc:
        fail(f"{path}: invalid JSON: {exc}")


def markdown_escape(text: object) -> str:
    return str(text).replace("|", "\\|")


def profile_backend(profile_data: dict[str, object]) -> str:
    return "kleaf" if profile_data.get("bazel_target") else "google_build_sh"


def profile_sort_key(profile: str) -> tuple[int, int, int, str]:
    match = PROFILE_RE.fullmatch(profile)
    if not match:
        return (sys.maxsize, sys.maxsize, sys.maxsize, profile)
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)), profile)


def load_profiles(profiles_dir: Path) -> dict[str, dict[str, object]]:
    profiles: dict[str, dict[str, object]] = {}
    for path in sorted(profiles_dir.glob("*.json")):
        data = load_json(path)
        if not isinstance(data, dict):
            fail(f"{path}: top-level JSON value must be an object")
        name = data.get("name")
        if not isinstance(name, str) or not name:
            fail(f"{path}: field 'name' must be a non-empty string")
        profiles[name] = data
    if not profiles:
        fail(f"no profile JSON files found in {profiles_dir}")
    return profiles


def main() -> int:
    if len(sys.argv) != 2:
        fail("usage: scripts/write-matrix-summary.py <matrix-json-path>")

    matrix_path = Path(sys.argv[1]).resolve()
    matrix_data = load_json(matrix_path)
    if not isinstance(matrix_data, dict):
        fail(f"{matrix_path}: top-level JSON value must be an object")

    entries = matrix_data.get("include")
    if not isinstance(entries, list):
        fail(f"{matrix_path}: field 'include' must be a list")

    repo_root = Path(__file__).resolve().parent.parent
    profiles = load_profiles(repo_root / "profiles")

    ordered_profiles: list[str] = []
    profile_variants: dict[str, list[str]] = {}
    all_variants: set[str] = set()

    for entry in entries:
        if not isinstance(entry, dict):
            fail(f"{matrix_path}: matrix entries must be objects")
        profile = entry.get("profile")
        variant = entry.get("variant")
        if not isinstance(profile, str) or not isinstance(variant, str):
            fail(f"{matrix_path}: matrix entries must contain string profile and variant fields")
        if profile not in profiles:
            fail(f"{matrix_path}: unknown profile {profile!r}")
        if profile not in profile_variants:
            ordered_profiles.append(profile)
            profile_variants[profile] = []
        if variant not in profile_variants[profile]:
            profile_variants[profile].append(variant)
        all_variants.add(variant)

    ordered_profiles.sort(key=profile_sort_key)
    variant_order_by_profile = {
        profile: {variant: index for index, variant in enumerate(variants)}
        for profile, variants in profile_variants.items()
    }
    ordered_entries = sorted(
        entries,
        key=lambda entry: (
            profile_sort_key(entry["profile"]),
            variant_order_by_profile[entry["profile"]][entry["variant"]],
        ),
    )

    print("# Build matrix")
    print()
    print(f"**Total jobs:** {len(entries)}  ")
    print(f"**Profiles:** {len(ordered_profiles)}  ")
    print(f"**Variants:** {len(all_variants)}  ")
    print()
    print("## By profile")
    print()
    print("| Profile | Backend | LTO | Variants |")
    print("| --- | --- | --- | --- |")
    for profile in ordered_profiles:
        profile_data = profiles[profile]
        backend = profile_backend(profile_data)
        lto = profile_data.get("lto") or "default"
        variants = ", ".join(profile_variants[profile])
        print(
            f"| {markdown_escape(profile)} | {markdown_escape(backend)} | "
            f"{markdown_escape(lto)} | {markdown_escape(variants)} |"
        )

    print()
    print("## Jobs")
    print()
    print("| # | Profile | Variant |")
    print("| ---: | --- | --- |")
    for index, entry in enumerate(ordered_entries, start=1):
        profile = entry["profile"]
        variant = entry["variant"]
        print(f"| {index} | {markdown_escape(profile)} | {markdown_escape(variant)} |")

    print()
    print("<details>")
    print("<summary>Raw matrix JSON</summary>")
    print()
    print("```json")
    print(json.dumps(matrix_data, indent=2))
    print("```")
    print("</details>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
