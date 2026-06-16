# Build guide

## One-command local build

Install host tools:

```bash
./scripts/install-build-tools.sh
```

Build a profile:

```bash
./scripts/build-kernel.sh android12-5.10-lts
```

Build a profile with a variant:

```bash
./scripts/build-kernel.sh android12-5.10-lts --variant ksu-bbg
./scripts/build-kernel.sh android12-5.10-lts --variant ksu-susfs
./scripts/build-kernel.sh android12-5.10-lts --variant ksu-susfs-bbg
```

Pin a SUSFS ref:

```bash
./scripts/build-kernel.sh android12-5.10-lts --variant ksu-susfs \
  --build-env SUSFS_REF=<branch-or-commit>
```

Enable Droidspaces support on a GKI profile:

```bash
./scripts/build-kernel.sh android15-6.6-lts \
  --build-env DROIDSPACES_ENABLE=1
```

Select a different pre-6.12 SYSVIPC kABI slot if needed:

```bash
./scripts/build-kernel.sh android13-5.15-lts \
  --build-env DROIDSPACES_ENABLE=1 \
  --build-env DROIDSPACES_SYSVIPC_KABI_SLOT=3_4_5
```

## `build-kernel.sh` usage

```bash
scripts/build-kernel.sh <profile-name> [--workspace DIR] [--mode auto|google_build_sh|kleaf] [--variant VARIANT] [--skip-setup] [--clean] [--skip-ak3] [--no-commit-workspace] [--disable-defconfig-check on|off] [--disable-kmi-check on|off] [--build-env KEY=VALUE] [-- EXTRA_BUILD_ARGS...]
```

The script resolves the profile, prepares or reuses `.work/<profile>`, sets up the manifest workspace unless `--skip-setup` is used, applies feature fragments, runs the selected build backend, collects artifacts into `dist/<profile>/`, and packages an AnyKernel3 zip unless `--skip-ak3` is used.

## Local `private.fragment`

Copy the example and edit locally:

```bash
cp configs/fragments/private.fragment.example private.fragment
```

`private.fragment` lives at repo root, is gitignored, and is layered into the generated workspace fragments during setup.

## Installing host tooling

`./scripts/install-build-tools.sh` installs the normal Ubuntu build packages, Arm64 cross-libc headers, `ccache`, and the upstream `repo` launcher in `$HOME/.local/bin/repo`.

## Build environment passthrough

`--build-env KEY=VALUE` passes values through to the build flow. Common examples include:

- `LTO=full`
- `KSU_REF=<commit-or-tag>`
- `BBG_REF=<commit-or-tag>`
- `SUSFS_REF=<branch-or-commit>`
- `DROIDSPACES_ENABLE=1`
- `DROIDSPACES_SYSVIPC_KABI_SLOT=6_7_8`
- `CORESHIFT_REPO_JOBS=2`
- `CORESHIFT_REPO_PARTIAL_CLONE=0`
- `CORESHIFT_REPO_CLONE_FILTER=blob:none`
- `USE_CCACHE=1`

The workflows also expose `build_env` input in `Build.yml` for advanced per-run overrides.

## Droidspaces GKI support

`DROIDSPACES_ENABLE=1` runs `scripts/apply-droidspaces-gki-support.sh` against the prepared workspace before the normal feature hooks. The helper is opt-in, supports GKI kernels only, selects the upstream patch set from kernel version, updates `common/arch/arm64/configs/gki_defconfig` idempotently, and only adds the required IPC symbol exports for 6.12+ kernels.

The pre-6.12 `SYSVIPC` patch defaults to `DROIDSPACES_SYSVIPC_KABI_SLOT=6_7_8`. Supported override values are `1_2_3`, `3_4_5`, and `6_7_8`.

## Private-build escape hatches

`build-kernel.sh` exposes:

- `--disable-defconfig-check on|off`
- `--disable-kmi-check on|off`

These are explicit private-build escape hatches. They do not guarantee ABI stability or device safety.

## 5.4 UAPI sysroot behavior

For `android*-5.4-lts` profiles, the build flow patches `common/usr/include/Makefile` in the prepared workspace so UAPI header tests can see target libc headers through `UAPI_SYSROOT_CFLAGS`.

The default sysroot points at:

```text
/usr/aarch64-linux-gnu/include
```

You can override it explicitly if needed:

```bash
./scripts/build-kernel.sh android12-5.4-lts \
  --build-env 'UAPI_SYSROOT_CFLAGS=--target=aarch64-linux-gnu -isystem /custom/sysroot/include'
```

## Swap helper

For memory-heavy local builds:

```bash
./scripts/add-swap.sh 24
```
