# OP-TEE build.git

This repository is a **temporary fork** of the [OP-TEE build.git](https://github.com/OP-TEE/build)
project — the upstream build system for OP-TEE on open hardware platforms. It extends that build
system to support Qualcomm platforms so that Qualcomm developers can work on TZ open firmware using
the same tooling and workflows used across the OP-TEE ecosystem. The fork is temporary: the work
here is intended to be upstreamed to the public [OP-TEE repositories](https://github.com/OP-TEE/)
and retired once merged.

Build system for OP-TEE on Qualcomm platforms.  Each platform has its own
top-level makefile and subdirectory.

## Supported platforms

| Platform | SoC | Board | Makefile |
|----------|-----|-------|----------|
| Lemans | QCS9100 | Qualcomm IQ-9075 EVK | `lemans.mk` |
| Kodiak | QCM6490 | Qualcomm RB3 Gen2 | `kodiak.mk` |

## Quick start

```sh
# Build everything
make -f lemans.mk all

# Get Qualcomm firmware blobs for flashing (pick one):
make -f lemans.mk fetch-blobs   # fast: direct download (minutes)
make -f lemans.mk yocto         # full OE/Yocto BSP build (hours)

# Flash
make -f lemans.mk flash-loader  # bootloader chain (first-time / after TF-A change)
make -f lemans.mk flash-kernel  # EFI partition only (kernel/initramfs iteration)
```

## Firmware blobs

Both `flash-loader` and `flash-kernel` need Qualcomm-proprietary firmware
binaries (XBL, AOP, firehose programmer, GPT tables, rawprogram XMLs).
These are resolved in priority order:

1. `{platform}/input/` — manually placed files
2. Yocto deploy directory — if `make yocto` has been run
3. `{platform}/blobs/` — populated by `make fetch-blobs`

`make fetch-blobs` downloads the boot binaries and CDT directly from public
Qualcomm/CodeLinaro URLs and generates partition tables via
[qcom-ptool](https://github.com/qualcomm-linux/qcom-ptool).
No Qualcomm account is required; the download takes a few minutes.

See `{platform}/input/README.md` for the full file-by-file breakdown.

## Documentation

HTML documentation for each platform is in `docs/`. Open `docs/index.html` as the
landing page (overview, quick start, and the Lemans build/flash/boot deep dive).

## Further reading

- [OP-TEE documentation](https://optee.readthedocs.io)
- [Qualcomm Platform Docs](https://ldts.github.io/qcom-buildroot/)
