# CoreShift ACK workspace

JSON-driven Android Common Kernel/GKI workspace builder for multiple ACK LTS branches.

Intended for repeatable ACK/GKI kernel builds and CI templates, not ROM building.

## Features

- Manifest-based ACK workspace setup
- Profile-specific manifest workspace policy
- Profile-driven branch and build backend selection
- `google_build_sh` and Kleaf support
- Private Kconfig fragment support
- Profile-aware LTO
- Optional BBG, KernelSU, KOWSU (KOWX712 fork), KernelSU-Next, KernelSU SUSFS, and Droidspaces GKI support
- AnyKernel3 packaging
- Kernel mirror with LTS and monthly date branches
- GitHub Actions workflows for LTS, date branch, and custom kernel source builds

## Quick start

```bash
git clone https://github.com/CoreShiftD/CoreShift-GKI-Common.git
cd CoreShift-GKI-Common
./scripts/install-build-tools.sh
./scripts/build-kernel.sh android12-5.10-lts
```

Build a variant:

```bash
./scripts/build-kernel.sh android12-5.10-lts --variant ksu-bbg
./scripts/build-kernel.sh android12-5.10-lts --variant kowsu-susfs-bbg
./scripts/build-kernel.sh android12-5.10-lts --variant ksu-next-susfs
```

Build from a date branch:

```bash
./scripts/build-kernel.sh android15-6.6-lts \
  --build-env KERNEL_SOURCE_BRANCH_OVERRIDE=android15-6.6-2026-06
```

Build from a custom kernel source:

```bash
./scripts/build-kernel.sh android15-6.6-lts \
  --build-env KERNEL_COMMON_URL=https://github.com/your/kernel.git \
  --build-env KERNEL_SOURCE_BRANCH_OVERRIDE=your-branch
```

Enable Droidspaces on a GKI profile:

```bash
./scripts/build-kernel.sh android15-6.6-lts \
  --build-env DROIDSPACES_ENABLE=1
```

Use a local private fragment:

```bash
cp configs/fragments/private.fragment.example private.fragment
```

## GitHub Actions

| Workflow | Purpose |
|---|---|
| `Build kernel` (`Build.yml`) | Unified build — choose source (lts / date / custom), kernel version, and variant |
| `Build variants` (`Build-Variants.yml`) | Build all variants or a specific one; builds both LTS and date branch per version |
| `Sync kernel common branches` (`sync-kernel-source.yml`) | Mirror LTS and monthly date branches from upstream ACK |
| `Test-Manifest-Trim.yml` | Manifest workspace policy test only |
| `validate-manifest-workspace.yml` | Validate manifest workspace without building |

## Supported profiles

| Profile | LTO | Variants |
|---|---|---|
| `android11-5.4` | `full` | `vanilla`, `bbg` |
| `android12-5.4` | `full` | `vanilla`, `bbg` |
| `android12-5.10` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg`, `kowsu`, `kowsu-bbg`, `kowsu-susfs`, `kowsu-susfs-bbg`, `ksu-next`, `ksu-next-bbg`, `ksu-next-susfs`, `ksu-next-susfs-bbg` |
| `android13-5.10` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg`, `kowsu`, `kowsu-bbg`, `kowsu-susfs`, `kowsu-susfs-bbg`, `ksu-next`, `ksu-next-bbg`, `ksu-next-susfs`, `ksu-next-susfs-bbg` |
| `android13-5.15` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg`, `kowsu`, `kowsu-bbg`, `kowsu-susfs`, `kowsu-susfs-bbg`, `ksu-next`, `ksu-next-bbg`, `ksu-next-susfs`, `ksu-next-susfs-bbg` |
| `android14-5.15` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg`, `kowsu`, `kowsu-bbg`, `kowsu-susfs`, `kowsu-susfs-bbg`, `ksu-next`, `ksu-next-bbg`, `ksu-next-susfs`, `ksu-next-susfs-bbg` |
| `android14-6.1` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg`, `kowsu`, `kowsu-bbg`, `kowsu-susfs`, `kowsu-susfs-bbg`, `ksu-next`, `ksu-next-bbg`, `ksu-next-susfs`, `ksu-next-susfs-bbg` |
| `android15-6.6` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg`, `kowsu`, `kowsu-bbg`, `kowsu-susfs`, `kowsu-susfs-bbg`, `ksu-next`, `ksu-next-bbg`, `ksu-next-susfs`, `ksu-next-susfs-bbg` |

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release history.

## Documentation

- [Profiles](docs/profiles.md)
- [Build guide](docs/build.md)
- [GitHub Actions workflows](docs/workflows.md)
- [Config fragments](docs/config-fragments.md)
- [Variants](docs/variants.md)
- [AnyKernel3 packaging](docs/packaging-ak3.md)
- [Ccache](docs/ccache.md)
- [Manifest workspace](docs/manifest-workspace.md)
- [Troubleshooting](docs/troubleshooting.md)

## Credits

- [WildKernels](https://github.com/WildKernels) — ccache configuration patterns and workflow design referenced for the ccache implementation in this project.

## Scope and non-goals

CoreShift builds ACK/GKI kernel artifacts and AnyKernel3 zip outputs.

- Device-specific `boot.img` or `vendor_boot.img` packaging remains separate.
- SUSFS is experimental and only available through KernelSU, KOWSU, and KernelSU-Next variants.
- This is not a ROM builder.
