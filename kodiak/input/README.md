# kodiak/input — Pre-built and flash input files

This directory holds pre-built binaries and flash support files that are not
produced by the build system and must be placed here manually before use.

## Pre-built binaries

| File | Description |
|------|-------------|
| `bootaa64.efi` | UEFI fallback boot entry, injected into `efi.bin` by the `efi` target |

## Flash dependencies

The `flash-loader` and `flash-efi` make targets resolve each required file
in priority order:

1. `kodiak/input/` — manually placed or previously auto-copied
2. Yocto deploy directory (`yocto/build/tmp/deploy/images/rb3gen2-core-kit/core-image-base-rb3gen2-core-kit.rootfs.qcomflash/`)
3. `kodiak/blobs/` — populated by `make fetch-blobs`

The target exits with an error naming the missing file if none of the three
locations has it.

### Obtaining the flash support files

**Fast (minutes):** run `make fetch-blobs`. This downloads the QCM6490 boot
binaries and CDT from public Qualcomm/CodeLinaro URLs, installs
[qcom-ptool](https://github.com/qualcomm-linux/qcom-ptool) into a local venv,
and generates the GPT tables and rawprogram XMLs for the `qcs6490-rb3gen2`
platform. Output goes to `kodiak/blobs/`; flash targets pick it up automatically.

**Full BSP (hours):** run `make yocto`. Builds a complete Yocto/OE image via
`kas`. Use this when you need the full BSP rather than just the flash blobs.

---

### `make flash-loader` (full partition flash)

Flashes the complete boot partition layout: XBL, TZ, UEFI, GPT tables, and
sidecar firmware.  Requires `kodiak/output/tz.mbn` and `kodiak/output/uefi.elf`
to already exist — build them first with `make loader`.

QDL is invoked as:
```
qdl --debug prog_firehose_ddr.elf rawprogram4.xml rawprogram1.xml rawprogram2.xml
```

Files resolved from `kodiak/input/` (auto-copied from Yocto or `kodiak/blobs/` if absent):

| File | Source | Description |
|------|--------|-------------|
| `prog_firehose_ddr.elf` | boot binaries | Firehose programmer loaded by QDL over EDL |
| `rawprogram1.xml` | qcom-ptool | Partition flashing script — LUN 1 (XBL boot LUN A) |
| `rawprogram2.xml` | qcom-ptool | Partition flashing script — LUN 2 (XBL boot LUN B) |
| `rawprogram4.xml` | qcom-ptool | Partition flashing script — LUN 4 (firmware) |
| `gpt_main1.bin` | qcom-ptool | Primary GPT — LUN 1 |
| `gpt_backup1.bin` | qcom-ptool | Backup GPT — LUN 1 |
| `gpt_main2.bin` | qcom-ptool | Primary GPT — LUN 2 |
| `gpt_backup2.bin` | qcom-ptool | Backup GPT — LUN 2 |
| `gpt_main4.bin` | qcom-ptool | Primary GPT — LUN 4 |
| `gpt_backup4.bin` | qcom-ptool | Backup GPT — LUN 4 |
| `zeros_33sectors.bin` | qcom-ptool | Zero-fill blob for apdp partition |
| `xbl.elf` | boot binaries | Qualcomm XBL bootloader |
| `xbl_config.elf` | boot binaries | XBL configuration |
| `aop.mbn` | boot binaries | Always-on processor firmware |
| `cpucp.elf` | boot binaries | CPU control processor firmware |
| `devcfg.mbn` | boot binaries | Device configuration |
| `hypvm.mbn` | boot binaries | Hypervisor VM firmware |
| `imagefv.elf` | boot binaries | Image firmware volume |
| `multi_image.mbn` | boot binaries | Multi-image partition descriptor |
| `qupv3fw.elf` | boot binaries | QUP v3 firmware |
| `shrm.elf` | boot binaries | Shared resource manager firmware |
| `tools.fv` | boot binaries | Tools firmware volume |
| `uefi_sec.mbn` | boot binaries | UEFI security firmware |
| `XblRamdump.elf` | boot binaries | XBL ramdump handler |

> **Note:** `tz.mbn` and `uefi.elf` are also flashed to LUN 4 but come from
> `kodiak/output/` (built by `make loader`), not from this directory.
>
> `dtb.bin` (device tree FAT32 image) is referenced in the partition layout but
> is **not flashed** — its entries are stripped from `rawprogram4.xml` by
> `make fetch-blobs` because the DTB is already embedded in `uki.efi`.

---

### `make flash-efi` (EFI partition only)

Flashes `efi.bin` into the EFI partition without touching other partitions.
Requires `kodiak/output/efi.bin` — build it first with `make efi`.

`rawprogram0-only-kernel.xml` is derived from `rawprogram0.xml` at flash time
by keeping only the efi partition entry; it is generated automatically if absent.

QDL is invoked as:
```
qdl --debug prog_firehose_ddr.elf rawprogram0-only-kernel.xml patch0.xml
```

Files resolved from `kodiak/input/` (auto-copied from Yocto or `kodiak/blobs/` if absent):

| File | Source | Description |
|------|--------|-------------|
| `prog_firehose_ddr.elf` | boot binaries | Firehose programmer loaded by QDL over EDL |
| `rawprogram0.xml` | qcom-ptool | Full LUN 0 script (source for the kernel-only variant) |
| `gpt_main0.bin` | qcom-ptool | Primary GPT — LUN 0 (HLOS) |
| `gpt_backup0.bin` | qcom-ptool | Backup GPT — LUN 0 |
| `patch0.xml` | qcom-ptool | GPT patch script — LUN 0 |
