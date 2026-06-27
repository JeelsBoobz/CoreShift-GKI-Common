#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Validate CoreShift ACK profile definitions."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_BRANCHES = (
    "android11-5.4",
    "android12-5.4",
    "android12-5.10",
    "android13-5.10",
    "android13-5.15",
    "android14-5.15",
    "android14-6.1",
    "android15-6.6",
)

REQUIRED_FIELDS = (
    "name",
    "manifest_branch",
    "manifest_overlay",
    "manifest_overlay_mode",
    "kernel_source_branch",
    "build_config",
    "bazel_target",
)

VALID_LTO_VALUES = ("full", "thin", "none", "default")
VALID_OVERLAY_MODES = ("safe", "aggressive")
VALID_OVERLAY_POLICY_KEYS = ("safe", "aggressive")
VALID_OVERLAY_MODE_KEYS = ("remove_projects",)
LEGACY_TRIM_FIELD = "manifest" "_trim"
LEGACY_OVERLAY_FIELD = "overlay" "_manifest"
LEGACY_KEEP_FIELD = "keep" "_patterns"
LEGACY_PROFILE_REMOVE_FIELD = "remove_projects"


def fail(message: str) -> None:
    raise SystemExit(message)


def load_json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{path}: invalid JSON: {exc}")


def validate_string_list(path: Path, value: object, field: str) -> None:
    if not isinstance(value, list):
        fail(f"{path}: field {field!r} must be a list of non-empty strings")
    for entry in value:
        if not isinstance(entry, str) or not entry:
            fail(f"{path}: field {field!r} must contain only non-empty strings")


def validate_overlay_policy(path: Path) -> None:
    data = load_json(path)
    if not isinstance(data, dict):
        fail(f"{path}: top-level JSON value must be an object")

    unknown_modes = sorted(set(data.keys()) - set(VALID_OVERLAY_POLICY_KEYS))
    if unknown_modes:
        fail(f"{path}: unknown overlay modes: {', '.join(unknown_modes)}")

    missing_modes = [mode for mode in VALID_OVERLAY_POLICY_KEYS if mode not in data]
    if missing_modes:
        fail(f"{path}: missing overlay modes: {', '.join(missing_modes)}")

    for mode in VALID_OVERLAY_POLICY_KEYS:
        mode_value = data[mode]
        if not isinstance(mode_value, dict):
            fail(f"{path}: overlay mode {mode!r} must be an object")

        unknown_mode_keys = sorted(set(mode_value.keys()) - set(VALID_OVERLAY_MODE_KEYS))
        if unknown_mode_keys:
            fail(
                f"{path}: overlay mode {mode!r} contains unknown fields: "
                f"{', '.join(unknown_mode_keys)}"
            )

        if "remove_projects" not in mode_value:
            fail(f"{path}: overlay mode {mode!r} is missing required field 'remove_projects'")
        validate_string_list(path, mode_value["remove_projects"], f"{mode}.remove_projects")


def validate_profile(path: Path, repo_root: Path) -> str:
    data = load_json(path)
    if not isinstance(data, dict):
        fail(f"{path}: top-level JSON value must be an object")

    if LEGACY_TRIM_FIELD in data:
        fail(
            f"{path}: legacy field {LEGACY_TRIM_FIELD!r} is not supported; "
            "profiles must select manifest_overlay JSON policies instead"
        )
    if LEGACY_OVERLAY_FIELD in data:
        fail(
            f"{path}: legacy field {LEGACY_OVERLAY_FIELD!r} is not supported; "
            "use manifest_overlay"
        )
    if LEGACY_KEEP_FIELD in data:
        fail(
            f"{path}: profile-level field {LEGACY_KEEP_FIELD!r} is not supported"
        )
    if LEGACY_PROFILE_REMOVE_FIELD in data:
        fail(
            f"{path}: profile-level field {LEGACY_PROFILE_REMOVE_FIELD!r} is not supported; "
            "remove lists live in manifests/overlays/*.json"
        )

    missing = [field for field in REQUIRED_FIELDS if field not in data]
    if missing:
        fail(f"{path}: missing required fields: {', '.join(missing)}")

    for field in ("name", "manifest_branch", "kernel_source_branch", "build_config"):
        value = data[field]
        if not isinstance(value, str) or not value:
            fail(f"{path}: field {field!r} must be a non-empty string")

    bazel_target = data["bazel_target"]
    if bazel_target is not None and (not isinstance(bazel_target, str) or not bazel_target):
        fail(f"{path}: field 'bazel_target' must be a non-empty string or null")

    lto = data.get("lto")
    if lto is not None and lto not in VALID_LTO_VALUES:
        allowed = ", ".join(VALID_LTO_VALUES)
        fail(f"{path}: field 'lto' must be one of: {allowed}")

    manifest_overlay = data["manifest_overlay"]
    if not isinstance(manifest_overlay, str) or not manifest_overlay:
        fail(f"{path}: field 'manifest_overlay' must be a non-empty string")
    if not manifest_overlay.endswith(".json"):
        fail(f"{path}: field 'manifest_overlay' must end with .json")

    overlay_path = Path(manifest_overlay)
    if overlay_path.is_absolute():
        fail(f"{path}: field 'manifest_overlay' must be a repo-relative path under manifests/overlays/")
    overlay_parts = overlay_path.parts
    if len(overlay_parts) < 3 or overlay_parts[0] != "manifests" or overlay_parts[1] != "overlays":
        fail(f"{path}: field 'manifest_overlay' must stay under manifests/overlays/")
    resolved_overlay = (repo_root / overlay_path).resolve()
    overlays_root = (repo_root / "manifests" / "overlays").resolve()
    try:
        resolved_overlay.relative_to(overlays_root)
    except ValueError:
        fail(f"{path}: field 'manifest_overlay' must stay under manifests/overlays/")
    if not resolved_overlay.is_file():
        fail(f"{path}: manifest_overlay file not found: {manifest_overlay}")
    validate_overlay_policy(resolved_overlay)

    manifest_overlay_mode = data["manifest_overlay_mode"]
    if manifest_overlay_mode not in VALID_OVERLAY_MODES:
        allowed = ", ".join(VALID_OVERLAY_MODES)
        fail(f"{path}: field 'manifest_overlay_mode' must be one of: {allowed}")

    name = data["name"]
    manifest_branch = data["manifest_branch"]
    kernel_source_branch = data["kernel_source_branch"]

    if path.stem != name:
        fail(f"{path}: file name must match profile name {name!r}")

    if name not in EXPECTED_BRANCHES:
        fail(f"{path}: unexpected profile name {name!r}")

    expected_manifest_branch = f"common-{name}"
    if manifest_branch != expected_manifest_branch:
        fail(
            f"{path}: manifest_branch {manifest_branch!r} must equal "
            f"{expected_manifest_branch!r}"
        )

    if kernel_source_branch not in EXPECTED_BRANCHES:
        fail(f"{path}: unexpected kernel_source_branch {kernel_source_branch!r}")

    if name != kernel_source_branch:
        fail(
            f"{path}: name {name!r} must match kernel_source_branch "
            f"{kernel_source_branch!r}"
        )

    return name


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    profiles_dir = repo_root / "profiles"

    if not profiles_dir.is_dir():
        fail(f"profiles directory not found: {profiles_dir}")

    files = sorted(profiles_dir.glob("*.json"))
    if not files:
        fail(f"no profile JSON files found in {profiles_dir}")

    seen = {validate_profile(path, repo_root) for path in files}
    expected = set(EXPECTED_BRANCHES)

    missing = sorted(expected - seen)
    extra = sorted(seen - expected)

    if missing:
        fail(f"missing expected profiles: {', '.join(missing)}")
    if extra:
        fail(f"unexpected profiles present: {', '.join(extra)}")

    print(f"Validated {len(files)} profiles in {profiles_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
