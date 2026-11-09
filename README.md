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
make -f lemans.mk flash-bootimage  # bootloader chain (first-time / after TF-A change)
make -f lemans.mk flash-uki        # EFI partition only (kernel/initramfs iteration)
```

## Firmware blobs

Both `flash-bootimage` and `flash-uki` need Qualcomm-proprietary firmware
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

## Test packages

The root filesystem carries what the open boot stack test suite
(test-definitions, `automated/linux/*`) needs, from `qcom/test.mk`, which
every Qualcomm board includes: xtest, alsa-utils, memtester, kvmtool with the
KVM unit tests and a KVM guest, idregs-arm64, Mesa with egl-readback, OpenCL
and TensorFlow Lite with tflite-run, and FFmpeg with the video test streams.
They are built with `TEST=y`; the default is `TEST=n`, which leaves them out
(except xtest, which `common.mk` selects). `QCOM_TESTS` narrows them to the
tests a board runs. The `qcom-tests` runner and what it drives (stress-ng,
fastrpc, v4l2-ctl, GStreamer) are built whatever `TEST` is. The header of
`qcom/test.mk` lists what each test needs.

`XEN=y` adds what the plan's optional Xen tests need in dom0, whatever
`TEST` is: the Xen toolstack (xl, xenstored, xenconsoled, xen-init-dom0),
built from `XEN_PATH` (default `$(ROOT)/xen`), which must be the tree of the
hypervisor the board boots, and the test guest in `/opt/xen-guest`
(a small Linux LTS kernel with Xen guest, FF-A and OP-TEE support, and a
BusyBox initramfs).

On Lemans, `XEN=y` also boots Xen: the kernel gets Xen dom0 support and the
FF-A transport, the getty moves to `/dev/console` (hvc0 under Xen), `make
xen` builds `xen.efi` from `XEN_PATH` with `lemans/xen/xen.config`, and `make
uki` puts it on the ESP as `EFI/BOOT/bootaa64.efi` with its configuration
(`bootaa64.cfg`), the kernel `Image`, the initramfs and the DTB, so U-Boot's
EFI boot starts Xen and Xen starts dom0. The firmware must run OP-TEE as the
FF-A SPMC (TF-A `SPD=spmd`, OP-TEE `CFG_CORE_SEL1_SPMC=y`): dom0 and the
guests reach OP-TEE through Xen's FF-A mediator.

Building them needs, besides the usual host tools, a host `ffmpeg` with
libx264, libx265 and libvpx (the video test streams). Proprietary SDKs are
never part of the image: the inference test gets the Qualcomm AI Runtime
from its job, and its model too, unless `QCOM_TEST_INFERENCE_MODEL=y` builds
the model into the rootfs (this downloads the SDK to convert the model on the
build host, and needs an x86_64 host with `libc++1`, `libc++abi1` and
`libatomic1`).

## Documentation

HTML documentation for each platform is in `docs/`. Open `docs/index.html` as the
landing page: a board portal that links to each platform's self-contained deck
(`docs/lemans/` and `docs/kodiak/`), covering overview, quick start, and the
build/flash/boot deep dive per board.

## Further reading

- [OP-TEE documentation](https://optee.readthedocs.io)
- [Qualcomm Platform Docs](https://qualcomm-linux.github.io/qcom-buildroot/)
