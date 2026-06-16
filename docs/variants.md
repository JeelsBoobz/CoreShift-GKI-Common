# Variants

## JSON-driven variant model

Variant behavior is defined by:

- `configs/variants.json`
- `configs/profile-variants.json`

`configs/variants.json` describes variant names, feature lists, and AK3 suffixes. `configs/profile-variants.json` controls which variants are enabled on each profile.

## Implemented variants

- `vanilla`
- `bbg`
- `ksu`
- `ksu-bbg`
- `ksu-susfs`
- `ksu-susfs-bbg`

## Feature integration

- BBG is integrated through the upstream Baseband-guard `setup.sh`.
- KernelSU is integrated through the upstream KernelSU `kernel/setup.sh`.
- SUSFS is experimental, requires KernelSU, and is integrated from Simonpunk GitLab: `https://gitlab.com/simonpunk/susfs4ksu.git`.
- SUSFS config is generated from the selected Simonpunk patch and resulting Kconfig symbols.
- CoreShift enables every discovered `KSU_SUSFS*` symbol in `common/features.fragment`.
- SUSFS variants are enabled only on profiles that already support KernelSU.

Feature application order is:

1. `ksu`
2. `susfs`
3. `bbg`

## 5.4 policy

- BBG is enabled on supported 5.4 profiles.
- KSU is disabled by default on 5.4 because current KernelSU `main` includes `linux/pgtable.h`, which is missing on the tested 5.4 ACK common trees.
- SUSFS remains disabled on 5.4 while KSU is disabled there.

Users experimenting with 5.4 KSU can edit `configs/profile-variants.json` locally and pin `KSU_REF` to a known-good branch or commit.

## Pinning feature refs

Examples:

```bash
./scripts/build-kernel.sh android13-5.15-lts --variant ksu --build-env KSU_REF=<commit-or-tag>
./scripts/build-kernel.sh android13-5.15-lts --variant bbg --build-env BBG_REF=<commit-or-tag>
./scripts/build-kernel.sh android13-5.15-lts --variant ksu-susfs --build-env SUSFS_REF=<branch-or-commit>
```

If `SUSFS_REF` is unset, CoreShift first checks `configs/susfs-refs.json`, then probes likely official branch names for the selected Android release and kernel version.

SUSFS config is variant-owned. It is written to `common/features.fragment`, not `configs/fragments/coreshift.fragment` or repo-root `private.fragment`.

## Feature Git metadata policy

- KernelSU, SUSFS, and Baseband-guard remain temporary Git checkouts during build.
- Those directories are excluded from the prepared workspace commit.
- `KernelSU/.git`, `SUSFS/.git`, and `Baseband-guard/.git` are kept during build for version metadata.
- Staged gitlinks and submodule-like `160000` entries are refused.
