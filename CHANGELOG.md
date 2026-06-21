# Changelog

## v0.1.0-pre1 (2026-06-21)

First pre-release. Establishes the full variant matrix including KOWSU and KernelSU-Next alongside the existing KernelSU baseline.

### Added

- **KOWSU variant family** (`kowsu`, `kowsu-bbg`, `kowsu-susfs`, `kowsu-susfs-bbg`) — KOWX712/KernelSU fork with kprobe-based syscall hooking. SUSFS integration uses a local fixup patch (`patches/ksu/kowsu/`) that adapts the SUSFS sucompat functions to the kprobe calling convention.
- **KernelSU-Next variant family** (`ksu-next`, `ksu-next-bbg`, `ksu-next-susfs`, `ksu-next-susfs-bbg`) — pershoot/KernelSU-Next. SUSFS variants use the `dev-susfs` branch which pre-integrates SUSFS; the upstream SUSFS kernel patch step is skipped for those variants.
- **Unified build workflow** (`Build.yml`) — single entry point for all source types (lts / date / custom), kernel versions, and variants via dynamic matrix resolution.
- **`Build variants` workflow** (`Build-Variants.yml`) — builds LTS and latest date branch for any kernel version / variant combination.
- **Date branch kernel source support** — `KERNEL_SOURCE_BRANCH_OVERRIDE` selects a monthly ACK snapshot (e.g. `android15-6.6-2026-06`) independently of the LTS profile.
- **Custom kernel source support** — `KERNEL_COMMON_URL` + `KERNEL_SOURCE_BRANCH_OVERRIDE` point any profile at a custom git repository.
- **Droidspaces GKI support** — `DROIDSPACES_ENABLE=1` applies Droidspaces patches and config before the normal feature chain.
- **Local SUSFS override patches** — per-version kernel fixup patches under `patches/susfs/<android-version>/` handle upstream SUSFS hunk failures on specific ACK trees.
- **Clang override and ccache wrappers** — aggressive ccache integration with in-place clang wrappers and configurable cache size.
- **AK3 release upload** — build workflows upload AnyKernel3 zips alongside a separate CoreShift log artifact.
- **Mozilla Public License 2.0** — all scripts are now MPL-2.0 licensed.

### Known issues

- `android15-6.6` date branches: SUSFS upstream patch may produce `mm/rmap.c` rejects on some 2026-04 / newer date snapshots. A local fixup patch for `mm/rmap.c` is not yet included; use the LTS branch for `android15-6.6` SUSFS builds in the meantime.
- 5.4 profiles (`android11-5.4`, `android12-5.4`) do not support any KernelSU variant. See [Troubleshooting](docs/troubleshooting.md).
- SUSFS is experimental across all variants. Simonpunk patch compatibility is not guaranteed for every ACK date branch.
