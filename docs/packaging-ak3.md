# AnyKernel3 packaging

## Source

AnyKernel3 is cloned from:

```text
https://github.com/DikyVinus/AnyKernel3.git
```

The default ref is `master` unless `AK3_REF` is overridden.

## Output naming

The packager derives a kernel version string from the built `Image` when possible and always prefixes the suffix list with `CoreShift`.

Current suffix mapping:

- `vanilla` -> `CoreShift`
- `bbg` -> `CoreShift-BBG`
- `ksu` -> `CoreShift-KSU`
- `ksu-bbg` -> `CoreShift-KSU-BBG`

Output is written to:

```text
dist/<profile>/<kernel-version>-<suffixes>.zip
```

## Included files

- Raw `Image` at the zip root
- `ikconfig.txt` copied from the selected final `.config`

`ikconfig.txt` is also copied into the artifact directory next to the packaged zip.

## Requirements and behavior

- Packaging requires a raw `Image`
- `Image.gz` or `Image.lz4` are not repacked as a fallback
- `--skip-ak3` disables AnyKernel3 packaging

## CI artifact uploads

The GitHub Actions build workflows upload only the generated AnyKernel3 zip artifacts.

