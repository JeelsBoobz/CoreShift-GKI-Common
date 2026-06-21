# Troubleshooting

## 5.4 UAPI sysroot and header tests

5.4 profiles can still run UAPI header tests that need target libc headers.

CoreShift patches the prepared workspace so those tests can use `UAPI_SYSROOT_CFLAGS`, with the default sysroot pointing at `/usr/aarch64-linux-gnu/include`.

## BBG `CONFIG_LSM` / `baseband_guard`

BBG writes variant-owned config into `common/features.fragment` and ensures `CONFIG_LSM` includes `baseband_guard`.

If you hand-edit fragment inputs around BBG, do not remove that token from the effective LSM list.

## KSU / KOWSU / KSU-Next on 5.4

5.4 does not enable any KernelSU variant by default because current KernelSU `main` includes `linux/pgtable.h`, which is missing on the tested 5.4 ACK common trees. This applies equally to `ksu`, `kowsu`, and `ksu-next`.

## SUSFS

SUSFS requires a KernelSU variant. Use `ksu-susfs`, `kowsu-susfs`, or `ksu-next-susfs` (with optional `-bbg` suffix). A raw `susfs` feature without a KernelSU variant is rejected.

If SUSFS patching fails, check for patch rejects, a wrong branch/ref, or a missing `CONFIG_KSU_SUSFS` symbol after patching. Pin a known-good Simonpunk ref with `SUSFS_REF` when automatic branch resolution picks no compatible branch.

CoreShift scans the selected Simonpunk patch files and resulting Kconfig files, then writes every discovered `KSU_SUSFS*` symbol to `common/features.fragment`. SUSFS config is variant-owned, not part of `configs/fragments/coreshift.fragment` or repo-root `private.fragment`.

If expected SUSFS symbols are missing, verify the selected SUSFS branch/ref and patch set. Use `SUSFS_REF` to pin a known-good Simonpunk branch/ref.

If a `-susfs-bbg` variant fails, test the `-susfs` variant first so SUSFS and BBG failures are isolated.

## KOWSU

KOWSU uses KOWX712/KernelSU whose default branch is `master`, not `main`. CoreShift handles this automatically — do not set `KSU_REF=main` for KOWSU builds.

KOWSU SUSFS integration applies a local fixup patch (`patches/ksu/kowsu/`) after the upstream SUSFS patch. If the KOWSU SUSFS patch fails, the upstream SUSFS patch for the selected kernel version may have changed. Check `patches/susfs/*.log` and `*.rej` files in the build log artifact.

## KernelSU-Next SUSFS

KernelSU-Next SUSFS variants (`ksu-next-susfs`, `ksu-next-susfs-bbg`) clone the `dev-susfs` branch of pershoot/KernelSU-Next instead of the default branch. The upstream SUSFS kernel patch is skipped because `dev-susfs` pre-integrates SUSFS. Only the local kernel fixup patches and SUSFS config symbol scan still run.

To override the branch: `--build-env KSU_NEXT_SUSFS_REF=<branch>`.

## Build log artifacts

Every build workflow uploads a separate CoreShift logs artifact next to the AK3 artifact. The log zip includes `build-kernel.log`, manifest reports, generated overlay XML, patch logs, generated fragments, selected profile/variant metadata, workspace diagnostics, and reject files when present.

For SUSFS failures, inspect `patches/susfs/*.log`, `susfs-config-symbols.txt`, and any included `*.rej` files.

For manifest policy issues, inspect `manifest-trim-report.txt` and `coreshift-overlay.xml`.

## `KSU_GIT_VERSION` warning

CoreShift keeps `KernelSU/.git` during build on purpose so KernelSU version metadata remains available.

If version metadata is missing, inspect whether the prepared workspace lost the KernelSU git directory unexpectedly.

## Ccache zero-hit quick checks

If `ccache -s` shows no cacheable compiler calls:

- Confirm wrapper setup actually enabled
- Confirm the selected backend is using the wrapper path
- Confirm the chosen repo/AOSP clang exists and is runnable
- Confirm repeated builds are using the same profile, source revision, and relevant flags

## Aggressive overlay failures

If aggressive overlay policy breaks `repo sync` or the later kernel build:

- Switch that profile `manifest_overlay_mode` back to `safe`
- Safe mode is the supported current policy
- Aggressive mode is experimental
- Run `Test-Manifest-Trim.yml` with `extra_remove_projects` only when you need to validate a larger explicit remove list
- Inspect `manifest-trim-report.txt`
- Promote working rules into `manifests/overlays/<profile>.json`
