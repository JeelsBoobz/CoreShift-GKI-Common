# Config fragments

## Core fragment files

- `configs/fragments/coreshift.fragment`
- Repo-root `private.fragment`
- `common/lto.fragment`
- `common/features.fragment`
- `common/private.fragment`
- `common/private.required`
- `common/coreshift.kleaf.fragment`

## Ownership model

- `configs/fragments/coreshift.fragment`: CoreShift baseline
- Repo-root `private.fragment`: user-owned local input
- `common/lto.fragment`: profile-owned generated output
- `common/features.fragment`: variant-owned generated output

Additional generated helpers:

- `common/private.fragment`: generated merge of CoreShift baseline plus optional repo-root `private.fragment`
- `common/private.required`: generated copy used by fragment-consuming helper logic
- `common/coreshift.kleaf.fragment`: generated Kleaf-facing fragment file

## Layering model

`google_build_sh` merges:

1. Base defconfig
2. `common/private.fragment`
3. `common/lto.fragment`
4. `common/features.fragment`

Kleaf consumes `common/coreshift.kleaf.fragment`, which is generated during workspace prep and refreshed after feature application.

## Notes

- `coreshift.fragment` stays branch-neutral and retains the filesystem defaults.
- Repo-root `private.fragment` is local and layered last relative to the baseline fragment.
- `android16-6.12-lts` intentionally rejects full-LTO override paths such as `CONFIG_LTO_CLANG_FULL=y` in repo-root `private.fragment`.

