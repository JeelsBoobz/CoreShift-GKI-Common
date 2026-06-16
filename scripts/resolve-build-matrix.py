#!/usr/bin/env python3
"""Resolve profile and variant compatibility into a GitHub Actions matrix."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


VARIANT_NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
FEATURE_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
AK3_SUFFIX_RE = re.compile(r"^[A-Z0-9]+(?:-[A-Z0-9]+)*$")
FEATURE_SUFFIXES = {
    "ksu": "KSU",
    "susfs": "SUSFS",
    "bbg": "BBG",
}
FEATURE_DISPLAY_ORDER = tuple(FEATURE_SUFFIXES)


def fail(message: str) -> "None":
    raise SystemExit(message)


def load_json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"missing required file: {path}")
    except json.JSONDecodeError as exc:
        fail(f"{path}: invalid JSON: {exc}")


def load_profile_names(profiles_dir: Path) -> list[str]:
    files = sorted(profiles_dir.glob("*.json"))
    if not files:
        fail(f"no profile JSON files found in {profiles_dir}")

    names: list[str] = []
    for path in files:
        data = load_json(path)
        if not isinstance(data, dict):
            fail(f"{path}: top-level JSON value must be an object")
        name = data.get("name")
        if not isinstance(name, str) or not name:
            fail(f"{path}: field 'name' must be a non-empty string")
        if path.stem != name:
            fail(f"{path}: file name must match profile name {name!r}")
        names.append(name)

    return names


def load_variants(path: Path) -> dict[str, dict[str, object]]:
    data = load_json(path)
    if not isinstance(data, dict):
        fail(f"{path}: top-level JSON value must be an object")

    raw_variants = data.get("variants")
    if not isinstance(raw_variants, dict) or not raw_variants:
        fail(f"{path}: field 'variants' must be a non-empty object")

    variants: dict[str, dict[str, object]] = {}
    for variant_name, definition in raw_variants.items():
        if not isinstance(variant_name, str) or not VARIANT_NAME_RE.fullmatch(variant_name):
            fail(f"{path}: invalid variant name {variant_name!r}")
        if not isinstance(definition, dict):
            fail(f"{path}: variant {variant_name!r} must be an object")

        description = definition.get("description")
        if not isinstance(description, str) or not description:
            fail(f"{path}: variant {variant_name!r} must define a non-empty string description")

        features = definition.get("features")
        if not isinstance(features, list):
            fail(f"{path}: variant {variant_name!r} field 'features' must be a list")
        seen_features: set[str] = set()
        for feature in features:
            if not isinstance(feature, str) or not FEATURE_RE.fullmatch(feature):
                fail(f"{path}: variant {variant_name!r} has invalid feature {feature!r}")
            if feature not in FEATURE_SUFFIXES:
                fail(f"{path}: variant {variant_name!r} has unknown feature {feature!r}")
            if feature in seen_features:
                fail(f"{path}: variant {variant_name!r} repeats feature {feature!r}")
            seen_features.add(feature)

        ordered_features = [feature for feature in FEATURE_DISPLAY_ORDER if feature in seen_features]
        if features != ordered_features:
            fail(
                f"{path}: variant {variant_name!r} features must follow display order "
                f"{', '.join(FEATURE_DISPLAY_ORDER)}"
            )
        if "susfs" in seen_features and "ksu" not in seen_features:
            fail(f"{path}: variant {variant_name!r} cannot enable 'susfs' without 'ksu'")

        ak3_suffixes = definition.get("ak3_suffixes")
        if not isinstance(ak3_suffixes, list):
            fail(f"{path}: variant {variant_name!r} field 'ak3_suffixes' must be a list")
        for suffix in ak3_suffixes:
            if not isinstance(suffix, str) or not AK3_SUFFIX_RE.fullmatch(suffix):
                fail(f"{path}: variant {variant_name!r} has invalid AK3 suffix {suffix!r}")

        expected_suffixes = [FEATURE_SUFFIXES[feature] for feature in features]
        if ak3_suffixes != expected_suffixes:
            fail(
                f"{path}: variant {variant_name!r} ak3_suffixes must match feature display order "
                f"{expected_suffixes!r}"
            )

        variants[variant_name] = {
            "description": description,
            "features": features,
            "ak3_suffixes": ak3_suffixes,
        }

    vanilla = variants.get("vanilla")
    if vanilla is None:
        fail(f"{path}: variant 'vanilla' must exist")
    if vanilla["features"] != [] or vanilla["ak3_suffixes"] != []:
        fail(f"{path}: variant 'vanilla' must have empty features and empty ak3_suffixes")
    if "bbg" not in variants:
        fail(f"{path}: variant 'bbg' must exist")

    return variants


def load_profile_variants(path: Path, profile_names: list[str], variants: dict[str, dict[str, object]]) -> dict[str, list[str]]:
    data = load_json(path)
    if not isinstance(data, dict):
        fail(f"{path}: top-level JSON value must be an object")

    raw_profiles = data.get("profiles")
    if not isinstance(raw_profiles, dict) or not raw_profiles:
        fail(f"{path}: field 'profiles' must be a non-empty object")

    profile_name_set = set(profile_names)
    resolved: dict[str, list[str]] = {}

    for profile_name, allowed_variants in raw_profiles.items():
        if profile_name not in profile_name_set:
            fail(f"{path}: profile {profile_name!r} is not defined in profiles/")
        if not isinstance(allowed_variants, list) or not allowed_variants:
            fail(f"{path}: profile {profile_name!r} must map to a non-empty variant list")

        seen: set[str] = set()
        normalized: list[str] = []
        for variant_name in allowed_variants:
            if not isinstance(variant_name, str):
                fail(f"{path}: profile {profile_name!r} contains a non-string variant entry")
            if variant_name not in variants:
                fail(f"{path}: profile {profile_name!r} references unknown variant {variant_name!r}")
            if variant_name not in seen:
                normalized.append(variant_name)
                seen.add(variant_name)

        if "vanilla" not in seen:
            fail(f"{path}: profile {profile_name!r} must include 'vanilla'")

        resolved[profile_name] = normalized

    missing_profiles = sorted(profile_name_set - set(resolved))
    if missing_profiles:
        fail(f"{path}: missing variant compatibility entries for profiles: {', '.join(missing_profiles)}")

    return resolved


def build_entries(
    profile_names: list[str],
    variants: dict[str, dict[str, object]],
    profile_variants: dict[str, list[str]],
    requested_profile: str | None,
    requested_variant: str | None,
) -> list[dict[str, str]]:
    if requested_profile is not None and requested_profile not in profile_variants:
        fail(f"unknown profile: {requested_profile}")
    if requested_variant is not None and requested_variant not in variants:
        fail(f"unknown variant: {requested_variant}")

    if requested_profile is not None and requested_variant is not None:
        allowed = profile_variants[requested_profile]
        if requested_variant not in allowed:
            fail(f"variant {requested_variant!r} is not allowed for profile {requested_profile!r}")

    selected_profiles = profile_names if requested_profile is None else [requested_profile]
    entries: list[dict[str, str]] = []

    for profile_name in selected_profiles:
        for variant_name in profile_variants[profile_name]:
            if requested_variant is not None and variant_name != requested_variant:
                continue

            definition = variants[variant_name]
            features = ",".join(definition["features"])
            ak3_suffixes = ",".join(definition["ak3_suffixes"])

            entries.append(
                {
                    "profile": profile_name,
                    "variant": variant_name,
                    "features": features,
                    "ak3_suffixes": ak3_suffixes,
                    "artifact_name": f"ak3-{profile_name}-{variant_name}",
                }
            )

    return entries


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", help="Restrict matrix output to a single profile")
    parser.add_argument("--variant", help="Restrict matrix output to a single variant")
    parser.add_argument("--all-profiles", action="store_true", help="Explicitly include all profiles")
    parser.add_argument("--all-variants", action="store_true", help="Explicitly include all allowed variants")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    profiles_dir = repo_root / "profiles"
    variants_path = repo_root / "configs" / "variants.json"
    profile_variants_path = repo_root / "configs" / "profile-variants.json"

    profile_names = load_profile_names(profiles_dir)
    variants = load_variants(variants_path)
    profile_variants = load_profile_variants(profile_variants_path, profile_names, variants)

    requested_profile = args.profile if args.profile or not args.all_profiles else None
    requested_variant = args.variant if args.variant or not args.all_variants else None

    entries = build_entries(profile_names, variants, profile_variants, requested_profile, requested_variant)
    json.dump({"include": entries}, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
