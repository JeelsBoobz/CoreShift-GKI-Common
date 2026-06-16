# Manifest workspace

## ACK manifest design

CoreShift uses the Android ACK manifest as the base workspace definition. It runs `repo init` first, then generates `.repo/local_manifests/coreshift-overlay.xml` from the resolved manifest before `repo sync`.

## Ownership model

- `profiles/*.json` selects `manifest_overlay` and `manifest_overlay_mode`
- `manifests/overlays/*.json` owns `safe` and `aggressive` explicit remove lists
- `scripts/generate-manifest-overlay.py` reads the resolved manifest and writes `.repo/local_manifests/coreshift-overlay.xml`
- `.repo/local_manifests/coreshift-overlay.xml` is generated runtime output only

Profile example:

```json
{
  "manifest_overlay": "manifests/overlays/android16-6.12-lts.json",
  "manifest_overlay_mode": "safe"
}
```

Overlay policy example:

```json
{
  "safe": {
    "remove_projects": ["kernel/common"]
  },
  "aggressive": {
    "remove_projects": ["kernel/common"]
  }
}
```

`manifests/overlays/default.json` is the baseline safe policy. Profile-specific overlay JSON files start from the same conservative rules and can be tuned later.

## `kernel/common` handling

- CoreShift removes `kernel/common` from the manifest-driven checkout
- CoreShift then clones the requested `kernel/common` branch separately into `common/`

This keeps manifest branch selection and `kernel/common` branch selection under explicit CoreShift control.

## Overlay modes

- `safe`: remove only the overlay policy `safe.remove_projects`
- `aggressive`: remove only the overlay policy `aggressive.remove_projects`

Current profiles all use safe mode. Aggressive mode is experimental and is enabled only by editing the profile JSON.

Every setup run writes `manifest-trim-report.txt` in the workspace root with project counts, removed projects, the selected overlay policy, and any temporary extra remove overrides.

## Test workflow overrides

Normal builds do not expose manifest trim flags.

`Test-Manifest-Trim.yml` accepts temporary comma-separated overrides:

- `extra_remove_projects`

Those inputs apply only to the workflow run. If they prove stable, copy the working rules into `manifests/overlays/<profile>.json`, not into the profile JSON.

## Why repo sync still matters

Removing `kernel/common` from the overlay does not make sync instant.

`repo sync` still pulls the other manifest projects needed by the build, including the Kleaf, build, and prebuilt/toolchain pieces used by both `google_build_sh` and Kleaf workflows.

Kleaf-backed profiles should be treated carefully because they may still need build, prebuilt, Rust, and Bazel-related manifest projects.

## Default sync tuning

Current defaults in `scripts/setup-manifest-workspace.sh`:

- `CORESHIFT_REPO_JOBS=4`
- `CORESHIFT_REPO_DEPTH=1`
- `CORESHIFT_REPO_PARTIAL_CLONE=1`
- `CORESHIFT_REPO_CLONE_FILTER=blob:none`

CoreShift updates the upstream repo launcher into `$HOME/.local/bin/repo` by default and prefers that path over `/usr/bin/repo`.
Repo verification stays enabled by default. `CORESHIFT_REPO_NO_VERIFY=1` exists only as an escape hatch.
`CORESHIFT_UPDATE_REPO_LAUNCHER=0` must be exported before running `./scripts/install-build-tools.sh`.

## Tuning knobs

You can tune manifest setup with:

- `CORESHIFT_REPO_JOBS`
- `CORESHIFT_REPO_DEPTH`
- `CORESHIFT_REPO_PARTIAL_CLONE`
- `CORESHIFT_REPO_CLONE_FILTER`
- `CORESHIFT_REPO_NO_VERIFY`

`CORESHIFT_REPO_*` and `CORESHIFT_REPO_NO_VERIFY` can be passed through `./scripts/build-kernel.sh` with `--build-env KEY=VALUE`.

```bash
./scripts/build-kernel.sh android16-6.12-lts \
  --build-env CORESHIFT_REPO_JOBS=2 \
  --build-env CORESHIFT_REPO_PARTIAL_CLONE=0 \
  --build-env CORESHIFT_REPO_CLONE_FILTER=blob:none
```
