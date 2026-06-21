#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Generate a CoreShift local manifest overlay from a resolved ACK manifest."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from xml.etree import ElementTree
from xml.sax.saxutils import escape


VALID_OVERLAY_MODES = {"safe", "aggressive"}
VALID_OVERLAY_POLICY_KEYS = {"safe", "aggressive"}
VALID_OVERLAY_MODE_KEYS = {"remove_projects"}
LEGACY_TRIM_FIELD = "manifest" "_trim"
LEGACY_OVERLAY_FIELD = "overlay" "_manifest"
LEGACY_PROFILE_REMOVE_FIELD = "remove_projects"
LEGACY_KEEP_FIELD = "keep" "_patterns"


@dataclass(frozen=True)
class Project:
    name: str
    path: str


@dataclass(frozen=True)
class OverlayModePolicy:
    remove_projects: list[str]


@dataclass(frozen=True)
class OverlayPolicy:
    safe: OverlayModePolicy
    aggressive: OverlayModePolicy


@dataclass(frozen=True)
class ProfileConfig:
    name: str
    manifest_branch: str
    kernel_source_branch: str
    build_config: str
    bazel_target: str | None
    manifest_overlay: str
    manifest_overlay_mode: str
    overlay_policy: OverlayPolicy


@dataclass(frozen=True)
class Decision:
    project: Project
    reason: str


def fail(message: str) -> None:
    raise SystemExit(message)


def dedupe_keep_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def parse_csv_list(value: str | None) -> list[str]:
    if not value:
        return []
    parts = [entry.strip() for entry in value.split(",")]
    return dedupe_keep_order([entry for entry in parts if entry])


def validate_string_list(value: object, field_name: str, source: Path) -> list[str]:
    if not isinstance(value, list):
        fail(f"{source}: field {field_name!r} must be a list of non-empty strings")
    result: list[str] = []
    for entry in value:
        if not isinstance(entry, str) or not entry:
            fail(f"{source}: field {field_name!r} must contain only non-empty strings")
        result.append(entry)
    return dedupe_keep_order(result)


def load_json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{path}: invalid JSON: {exc}")


def load_overlay_policy(path: Path) -> OverlayPolicy:
    data = load_json(path)
    if not isinstance(data, dict):
        fail(f"{path}: top-level JSON value must be an object")

    unknown_modes = sorted(set(data.keys()) - VALID_OVERLAY_POLICY_KEYS)
    if unknown_modes:
        fail(f"{path}: unknown overlay modes: {', '.join(unknown_modes)}")

    missing_modes = [mode for mode in ("safe", "aggressive") if mode not in data]
    if missing_modes:
        fail(f"{path}: missing overlay modes: {', '.join(missing_modes)}")

    modes: dict[str, OverlayModePolicy] = {}
    for mode_name in ("safe", "aggressive"):
        mode_value = data[mode_name]
        if not isinstance(mode_value, dict):
            fail(f"{path}: overlay mode {mode_name!r} must be an object")

        unknown_fields = sorted(set(mode_value.keys()) - VALID_OVERLAY_MODE_KEYS)
        if unknown_fields:
            fail(
                f"{path}: overlay mode {mode_name!r} contains unknown fields: "
                f"{', '.join(unknown_fields)}"
            )

        remove_projects = validate_string_list(
            mode_value.get("remove_projects"), f"{mode_name}.remove_projects", path
        )
        modes[mode_name] = OverlayModePolicy(remove_projects=remove_projects)

    return OverlayPolicy(safe=modes["safe"], aggressive=modes["aggressive"])


def load_profile(profile_path: Path) -> ProfileConfig:
    profile = load_json(profile_path)
    if not isinstance(profile, dict):
        fail(f"{profile_path}: top-level JSON value must be an object")

    if LEGACY_TRIM_FIELD in profile:
        fail(f"{profile_path}: legacy field {LEGACY_TRIM_FIELD!r} is not supported")
    if LEGACY_OVERLAY_FIELD in profile:
        fail(f"{profile_path}: legacy field {LEGACY_OVERLAY_FIELD!r} is not supported")
    if LEGACY_KEEP_FIELD in profile:
        fail(
            f"{profile_path}: profile-level field {LEGACY_KEEP_FIELD!r} is not supported"
        )
    if LEGACY_PROFILE_REMOVE_FIELD in profile:
        fail(
            f"{profile_path}: profile-level field {LEGACY_PROFILE_REMOVE_FIELD!r} is not supported; "
            "remove lists live in manifests/overlays/*.json"
        )

    required = (
        "name",
        "manifest_branch",
        "manifest_overlay",
        "manifest_overlay_mode",
        "kernel_source_branch",
        "build_config",
        "bazel_target",
    )
    for field in required:
        if field not in profile:
            fail(f"{profile_path}: missing required field {field!r}")

    def required_string(field: str) -> str:
        value = profile.get(field)
        if not isinstance(value, str) or not value:
            fail(f"{profile_path}: field {field!r} must be a non-empty string")
        return value

    manifest_overlay = required_string("manifest_overlay")
    if not manifest_overlay.endswith(".json"):
        fail(f"{profile_path}: field 'manifest_overlay' must end with .json")
    overlay_path = Path(manifest_overlay)
    if overlay_path.is_absolute():
        fail(f"{profile_path}: field 'manifest_overlay' must be repo-relative")
    if len(overlay_path.parts) < 3 or overlay_path.parts[:2] != ("manifests", "overlays"):
        fail(f"{profile_path}: field 'manifest_overlay' must stay under manifests/overlays/")

    repo_root = profile_path.resolve().parent.parent
    resolved_overlay = (repo_root / overlay_path).resolve()
    overlays_root = (repo_root / "manifests" / "overlays").resolve()
    try:
        resolved_overlay.relative_to(overlays_root)
    except ValueError:
        fail(f"{profile_path}: field 'manifest_overlay' must stay under manifests/overlays/")
    if not resolved_overlay.is_file():
        fail(f"{profile_path}: manifest_overlay file not found: {manifest_overlay}")

    manifest_overlay_mode = profile.get("manifest_overlay_mode")
    if manifest_overlay_mode not in VALID_OVERLAY_MODES:
        allowed = ", ".join(sorted(VALID_OVERLAY_MODES))
        fail(f"{profile_path}: field 'manifest_overlay_mode' must be one of: {allowed}")

    bazel_target = profile.get("bazel_target")
    if bazel_target is not None and (not isinstance(bazel_target, str) or not bazel_target):
        fail(f"{profile_path}: field 'bazel_target' must be a non-empty string or null")

    return ProfileConfig(
        name=required_string("name"),
        manifest_branch=required_string("manifest_branch"),
        kernel_source_branch=required_string("kernel_source_branch"),
        build_config=required_string("build_config"),
        bazel_target=bazel_target,
        manifest_overlay=manifest_overlay,
        manifest_overlay_mode=str(manifest_overlay_mode),
        overlay_policy=load_overlay_policy(resolved_overlay),
    )


def read_resolved_manifest(workspace: Path) -> list[Project]:
    with tempfile.NamedTemporaryFile(
        prefix="coreshift-resolved-manifest-",
        suffix=".xml",
        delete=False,
    ) as handle:
        manifest_path = Path(handle.name)

    try:
        result = subprocess.run(
            ["repo", "manifest", "-o", str(manifest_path)],
            cwd=workspace,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            stderr = result.stderr.strip() or result.stdout.strip() or "unknown repo manifest failure"
            fail(f"repo manifest failed in {workspace}: {stderr}")
        try:
            root = ElementTree.parse(manifest_path).getroot()
        except ElementTree.ParseError as exc:
            fail(f"resolved manifest is not valid XML: {exc}")
    finally:
        manifest_path.unlink(missing_ok=True)

    projects: list[Project] = []
    seen_names: set[str] = set()
    for node in root.findall(".//project"):
        name = node.get("name")
        if not name or name in seen_names:
            continue
        seen_names.add(name)
        projects.append(Project(name=name, path=node.get("path") or name))
    return projects


def overlay_lines(remove_names: list[str]) -> str:
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', "<manifest>"]
    for name in remove_names:
        lines.append(f'  <remove-project name="{escape(name)}" />')
    lines.append("</manifest>")
    return "\n".join(lines) + "\n"


def decide_projects(
    projects: list[Project],
    remove_names: list[str],
    mode: str,
) -> tuple[int, list[Decision]]:
    remove_set = set(remove_names)
    removed: list[Decision] = []
    kept_count = 0
    for project in projects:
        if project.name in remove_set:
            removed.append(Decision(project=project, reason=f"explicit {mode} remove"))
        else:
            kept_count += 1
    return kept_count, removed


def write_report(
    report_path: Path,
    profile: ProfileConfig,
    total_projects: int,
    policy: OverlayModePolicy,
    extra_remove_projects: list[str],
    kept_count: int,
    removed: list[Decision],
) -> None:
    lines = [
        f"profile name: {profile.name}",
        f"manifest branch: {profile.manifest_branch}",
        f"kernel source branch: {profile.kernel_source_branch}",
        f"build_config: {profile.build_config}",
        f"bazel_target: {profile.bazel_target or ''}",
        f"manifest_overlay: {profile.manifest_overlay}",
        f"manifest_overlay_mode: {profile.manifest_overlay_mode}",
        f"selected overlay policy mode: {profile.manifest_overlay_mode}",
        f"total project count: {total_projects}",
        f"overlay remove_projects: {json.dumps(policy.remove_projects)}",
        f"extra remove projects: {json.dumps(extra_remove_projects)}",
        f"kept project count: {kept_count}",
        "",
        "removed projects:",
    ]
    for decision in removed:
        lines.append(f"- {decision.project.name} [{decision.project.path}] :: {decision.reason}")
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Generate a CoreShift manifest overlay from a resolved ACK manifest"
    )
    parser.add_argument("--profile-json", required=True, help="Path to the profile JSON")
    parser.add_argument("--workspace", required=True, help="Initialized repo workspace path")
    parser.add_argument("--output", required=True, help="Output overlay XML path")
    parser.add_argument(
        "--extra-remove-projects",
        default="",
        help="Comma-separated extra project names to remove for this run only",
    )
    parser.add_argument(
        "--manifest-overlay-mode-override",
        default="",
        help="Override the profile's manifest_overlay_mode (safe or aggressive)",
    )
    args = parser.parse_args(argv)

    profile_path = Path(args.profile_json).resolve()
    workspace = Path(args.workspace).resolve()
    output_path = Path(args.output).resolve()
    report_path = workspace / "manifest-trim-report.txt"

    if not profile_path.is_file():
        fail(f"profile JSON not found: {profile_path}")
    if not workspace.is_dir():
        fail(f"workspace directory not found: {workspace}")
    if not (workspace / ".repo").is_dir():
        fail(f"workspace is not an initialized repo checkout: {workspace}")

    profile = load_profile(profile_path)
    mode_override = args.manifest_overlay_mode_override
    if mode_override:
        if mode_override not in VALID_OVERLAY_MODES:
            allowed = ", ".join(sorted(VALID_OVERLAY_MODES))
            fail(f"--manifest-overlay-mode-override must be one of: {allowed}")
        profile = ProfileConfig(
            name=profile.name,
            manifest_branch=profile.manifest_branch,
            kernel_source_branch=profile.kernel_source_branch,
            build_config=profile.build_config,
            bazel_target=profile.bazel_target,
            manifest_overlay=profile.manifest_overlay,
            manifest_overlay_mode=mode_override,
            overlay_policy=profile.overlay_policy,
        )
    extra_remove_projects = parse_csv_list(args.extra_remove_projects)
    projects = read_resolved_manifest(workspace)
    policy = getattr(profile.overlay_policy, profile.manifest_overlay_mode)
    remove_names = dedupe_keep_order(policy.remove_projects + extra_remove_projects)
    kept_count, removed = decide_projects(projects, remove_names, profile.manifest_overlay_mode)
    remove_project_names = dedupe_keep_order([decision.project.name for decision in removed])

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(overlay_lines(remove_project_names), encoding="utf-8")
    write_report(
        report_path,
        profile=profile,
        total_projects=len(projects),
        policy=policy,
        extra_remove_projects=extra_remove_projects,
        kept_count=kept_count,
        removed=removed,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
