# GitHub Actions workflows

## Main build workflows

### `Build.yml`

- Single selected profile build
- Exposes the main user-facing workflow inputs
- Supports private fragment injection
- Supports build environment passthrough

### `Build-All.yml`

- Vanilla-only baseline matrix across supported profiles
- Does not build BBG or KSU variants

### `Build-Variants.yml`

- Uses the JSON profile/variant matrix from `scripts/resolve-build-matrix.py`
- Builds only allowed profile/variant pairs

## Artifact behavior

- GitHub Actions uploads AK3 zip artifacts and CoreShift log zip artifacts separately
- Log artifacts include build command output, manifest reports, generated overlay XML, patch logs, generated fragments, and selected profile/variant metadata
- The workflows do not upload raw workspace trees as normal build artifacts

## CI build environment

- CI installs host tools with `scripts/install-build-tools.sh`
- CI configures ccache
- CI adds aggressive 24 GB swap on GitHub-hosted runners
- All workflows opt into Node.js 24 for JavaScript actions with `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true`
- This avoids Node.js 20 deprecation annotations while keeping the current action pins unchanged

## Utility workflows

The repo also contains utility workflows outside the main build trio, including:

- `sync-kernel-source.yml`
- `validate-manifest-workspace.yml`
- `Test-Manifest-Trim.yml`

They support branch sync, repo validation, and manifest workspace validation rather than end-user kernel packaging.

## `Test-Manifest-Trim.yml`

- Tests manifest init, generated overlay creation, and repo sync only
- Does not compile kernels
- Does not package AK3
- Uploads manifest log artifacts separately from manifest report and overlay artifacts
- Has no mode input
- Accepts `extra_remove_projects` only for temporary test runs
- Stable keep/remove rules should be promoted into `manifests/overlays/<profile>.json` after a successful manifest test
