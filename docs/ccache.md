# Ccache

## Current behavior

CoreShift uses stock Ubuntu `ccache`. It does not download a custom ccache fork.

For `google_build_sh`, CoreShift uses wrapper symlinks so `clang`, `clang++`, `gcc`, `g++`, `cc`, and `c++` resolve through `ccache` before the repo-synced toolchains in `PATH` when wrapper setup succeeds.

## Wrapper approach

- Wrappers are only enabled when a repo/AOSP clang is found in the prepared workspace.
- CoreShift tries to wrap the clang selected by the active build config first.
- If the selected repo clang cannot run because compatibility libraries are missing, wrappers are disabled and the build continues without ccache interception.

## Repo/AOSP clang requirement

The wrapper must resolve to repo/AOSP clang, not the host Ubuntu clang.

If no repo clang is found, wrapper mode is disabled.

## Cache hit expectations

- The first run is expected to miss heavily.
- Repeated builds on the same profile, source revision, toolchain content, and relevant flags should improve hits.
- Stable paths help; CoreShift supports `CCACHE_BASEDIR` and `CCACHE_NOHASHDIR`.

## Common miss reasons

- Source revision changed
- Toolchain content changed
- Relevant compiler flags changed
- Compiler path bypassed ccache wrappers
- Build backend invoked the real compiler path directly

## Debug mode

Debug logging is supported with `CORESHIFT_CCACHE_DEBUG=1`.

Examples:

```bash
CORESHIFT_CCACHE_DEBUG=1 ./scripts/setup-ccache.sh
./scripts/build-kernel.sh android13-5.15-lts --build-env CORESHIFT_CCACHE_DEBUG=1
```

When debug mode is enabled through `build-kernel.sh` and no `CCACHE_LOGFILE` is already set, the build flow defaults it to:

```text
.work/<profile>/ccache.log
```

## Quick checks

- `ccache -s`
- `ccache --show-config`
- Confirm the wrapper path is actually in use
- Confirm the selected build backend did not bypass wrapper resolution

