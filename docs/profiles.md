# Profiles

## Supported profiles

- `android11-5.4-lts`
- `android12-5.4-lts`
- `android12-5.10-lts`
- `android13-5.10-lts`
- `android13-5.15-lts`
- `android14-5.15-lts`
- `android14-6.1-lts`
- `android15-6.6-lts`
- `android16-6.12-lts`

## Profile JSON schema

Each profile JSON under `profiles/` defines:

- `name`
- `manifest_branch`
- `manifest_overlay`
- `manifest_overlay_mode`
- `kernel_source_branch`
- `build_config`
- `bazel_target`
- `lto`

Current profiles use `name == kernel_source_branch` and `manifest_branch == common-<name>`.
Every current profile declares `manifest_overlay`, `manifest_overlay_mode`, and `lto` explicitly.

Profiles select the manifest workspace policy. They do not carry keep/remove arrays directly.

## Manifest overlay selection

`manifest_overlay` points to a JSON policy under `manifests/overlays/`.

`manifest_overlay_mode` selects which policy block to apply:

- `safe`
- `aggressive`

Every current profile uses `manifest_overlay_mode: "safe"`.

Example:

```json
{
  "manifest_overlay": "manifests/overlays/android16-6.12-lts.json",
  "manifest_overlay_mode": "safe"
}
```

## Overlay policy schema

Overlay policy files live under `manifests/overlays/` and own the keep/remove rules:

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

- `safe` removes only `remove_projects`
- `aggressive` also removes only `remove_projects`, using a larger explicit list when needed
- Temporary experiment results from `Test-Manifest-Trim.yml` should be promoted into the overlay JSON, not the profile JSON

## LTO values

Allowed `lto` values are:

- `full`
- `thin`
- `none`
- `default`

## Current policy

- Every current profile declares `lto` explicitly.
- All current profiles use `full` LTO except `android16-6.12-lts`, which uses `thin`.
- `android16-6.12-lts` rejects full-LTO override paths because full LTO broke the Kleaf `rust_binder.ko` output.
- Every current profile selects a profile-specific overlay JSON and currently uses safe mode.
- `manifests/overlays/default.json` is the baseline safe policy for the overlay model.
