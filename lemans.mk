################################################################################
# lemans.mk — Build system for Qualcomm SA8775P Lemans EVK (QCS9075)
#
# Produces two independent boot artifacts:
#
#   EFI path:
#     lemans/output/efi.bin    Distro FAT image updated with the new uki.efi (UKI)
#
#   Boot-image path:
#     lemans/output/tz.mbn     qtestsign-signed U-Boot SPL (tz partition image)
#     lemans/output/uefi.elf   SPL_ATF boot FIT: BL31 + OP-TEE + U-Boot proper
#                              (uefi partition image; a FIT despite the .elf name)
#
# Boot sequence: XBL → U-Boot SPL → TF-A BL31 → OP-TEE OS → U-Boot proper → Linux
# U-Boot SPL replaces TF-A BL2 as the first open-source stage.
# TF-A BL31 (Secure Monitor) remains resident at EL3 after boot.
# Signing uses qtestsign (open-source, local — no QTI CASS access required).
#
# Main targets
# ─────────────────────────────────────────────────────────────────────────────
#   all            Build OP-TEE OS, TF-A BL31, U-Boot (SPL + proper), Linux, Buildroot, and efi.bin
#   clean          Clean all components
#
#   efi            (Re)build the UKI and inject it into lemans/output/efi.bin
#   bootimage      Build and sign lemans/output/tz.mbn + uefi.elf
#
#   optee-os       Build OP-TEE OS
#   tfa            Build TF-A BL31 (Secure Monitor only — no BL2)
#   u-boot         Build U-Boot SPL (qcom_lemans_spl_defconfig → tz.mbn)
#   u-boot-proper  Build U-Boot proper (qcom_lemans_defconfig, BL33 @ 0xaf000000)
#   spl            SWIV-annotate and sign the SPL via qtestsign → tz.mbn
#   uefi           Assemble the SPL_ATF boot FIT → uefi.elf
#   linux          Build the kernel Image and device trees
#   linux-defconfig Configure the kernel (auto-invoked by linux if needed)
#   buildroot      Build the root filesystem (via common.mk)
#
#   qtestsign-fetch  Clone qtestsign (auto-invoked by spl)
#   fetch-blobs    Download QCS9100 firmware blobs directly (no Yocto build)
#   yocto          Clone meta-qcom and build the OE no-distro BSP image via kas
#   flash-yocto    Flash the complete unmodified Yocto release image (all 6 LUNs)
#   flash-loader   Flash the boot chain via QDL (stock FW from fetched blobs; tz/uefi from build)
#   flash-kernel   Flash the updated efi.bin via QDL  (efi.bin from build; LUN0 tables from blobs)
#   flash-sail     Flash the SAIL safety-island NOR image via QDL (stock blobs, self-contained)
#   flash-sail-wipe      Wipe the SAIL NOR partition tables (recovery; destroys SAIL NOR layout)
#   flash-ufs-provision  Re-provision the UFS LUN layout (recover partitions broken by a bad flash)
#   edl-package    Assemble flat image dir for Windows EDL flashing (PCATApp/QFIL)
#   edl-bootloader Assemble bootloader-only EDL package (LUN1–4, fast re-flash)
#   *-clean        Per-component clean targets
#
# Configurable variables (override on the command line or in the environment)
# ─────────────────────────────────────────────────────────────────────────────
#   LINUX_DEFCONFIG       Kernel defconfig (default: defconfig)
#   U_BOOT_DEVICE_TREE    U-Boot device tree (default: qcom/lemans-evk)
#   TF_A_FLAGS            Extra flags for the TF-A make invocation
#   LINUX_CMDLINE         Kernel command line embedded in the UKI
#   SWIV_SCRIPT           Path to swiv_build_utility.py
#   QTESTSIGN_PATH        Path to qtestsign checkout (default: $(ROOT)/qtestsign)
#   UFS_PROVISION_XML     UFS provision layout for flash-ufs-provision
#                         (default: provision_1_2.xml — grows HLOS LUN 0)
################################################################################

################################################################################
# Platform
################################################################################
PLATFORM          = lemans
OPTEE_OS_PLATFORM = qcom-lemans

################################################################################
# Compilation settings
# All worlds are AArch64-only on this platform.
################################################################################
override COMPILE_NS_USER   := 64
override COMPILE_NS_KERNEL := 64
override COMPILE_S_USER    := 64
override COMPILE_S_KERNEL  := 64

################################################################################
# OP-TEE OS settings
################################################################################
# Quiet the secure-world console. common.mk defaults CFG_TEE_CORE_LOG_LEVEL to
# 3 (DEBUG), which floods ttyMSM0 with OP-TEE trace. Drop to 1 (errors only).
# Set before the common.mk include so its ?= default does not win.
CFG_TEE_CORE_LOG_LEVEL := 1

################################################################################
# Buildroot package selection
################################################################################

# Serial console — Qualcomm MSM UART, not PL011 (overrides common.mk default)
BR2_TARGET_GENERIC_GETTY_PORT := ttyMSM0

# Networking
BR2_PACKAGE_DHCPCD  ?= y
BR2_PACKAGE_ETHTOOL ?= y
BR2_PACKAGE_XINETD  ?= y

# SSH
BR2_PACKAGE_OPENSSH           ?= y
BR2_PACKAGE_OPENSSH_SERVER    ?= y
BR2_PACKAGE_OPENSSH_KEY_UTILS ?= y

# OpenSSL CLI
BR2_PACKAGE_LIBOPENSSL_BIN ?= y

# stress-ng — CPU/thermal soak load generator. Drives the qcom-tests "CPU
# stress" option for multi-hour stability runs; the runner falls back to a
# busybox 'yes' busy-loop if this is ever disabled.
BR2_PACKAGE_STRESS_NG ?= y

# Qualcomm FastRPC test — validates the OP-TEE PAS coprocessor reset sequence.
# NOTE: upstream ships DSP skel stubs for v68/v75 only; the SA8775P CDSP is v73,
# so the bundled calculator workload may have no matching skel at runtime.
BR2_PACKAGE_FASTRPC_EXT ?= y

# QRTR userspace (libqrtr + qrtr-ns). qrtr-ns is the QMI name service the DSP
# subsystems need to register their servreg protection domains; without it the
# DSP rootPD never finishes coming up and FastRPC stalls (GLINK intent timeout).
# No systemd here, so qrtr-ns is launched from lemans/overlay/etc/init.d/.
BR2_PACKAGE_QRTR_EXT ?= y

# tqftpserv — TFTP-over-QRTR file server. The CDSP FastRPC rootPD reads its
# runtime from the apps rootfs over QRTR via this server; without it the
# fastrpc glink channel opens but the DSP never posts RX intents. Launched
# from an init script after qrtr-ns.
BR2_PACKAGE_TQFTPSERV_EXT ?= y

# Video decoder validation. v4l-utils gives v4l2-ctl for capability/format
# enumeration; GStreamer gives an end-to-end decode pipeline. The iris/venus
# codec is a V4L2 *stateful* decoder, so the elements are v4l2h264dec /
# v4l2h265dec (registered by the m2m probe), fed by h264parse/h265parse
# (videoparsers) and qtdemux (isomp4). Needs C++ (already on via the toolchain).
BR2_INSTALL_LIBSTDCPP                            ?= y
BR2_PACKAGE_LIBV4L                               ?= y
BR2_PACKAGE_LIBV4L_UTILS                         ?= y
BR2_PACKAGE_GSTREAMER1                           ?= y
BR2_PACKAGE_GST1_PLUGINS_BASE                    ?= y
# Base sub-plugins default off; videotestsrc feeds the encode test and
# videoconvertscale (videoconvert) handles the NV12 conversion the encoder needs.
BR2_PACKAGE_GST1_PLUGINS_BASE_PLUGIN_VIDEOTESTSRC     ?= y
BR2_PACKAGE_GST1_PLUGINS_BASE_PLUGIN_VIDEOCONVERTSCALE ?= y
BR2_PACKAGE_GST1_PLUGINS_GOOD                    ?= y
BR2_PACKAGE_GST1_PLUGINS_GOOD_PLUGIN_V4L2        ?= y
BR2_PACKAGE_GST1_PLUGINS_GOOD_PLUGIN_V4L2_PROBE  ?= y
BR2_PACKAGE_GST1_PLUGINS_GOOD_PLUGIN_ISOMP4      ?= y
BR2_PACKAGE_GST1_PLUGINS_BAD                     ?= y
BR2_PACKAGE_GST1_PLUGINS_BAD_PLUGIN_VIDEOPARSERS ?= y

# Root filesystem — compressed CPIO for use as initramfs
BR2_TARGET_GENERIC_ISSUE     = "OP-TEE embedded distrib for $(PLATFORM)"
BR2_TARGET_ROOTFS_CPIO       = y
BR2_TARGET_ROOTFS_CPIO_GZIP  = y
BR2_PACKAGE_BUSYBOX_WATCHDOG = y

# OP-TEE OS, TF-A BL31, Linux, U-Boot and OP-TEE are built outside of Buildroot
BR2_LINUX_KERNEL              = n
# Overlay: DSP firmware (staged by fetch-blobs, see below). The kernel is
# CONFIG_MODULES=n (see linux-defconfig), so there are no loadable modules to
# overlay.
BR2_ROOTFS_OVERLAY            = $(OVERLAY_DIR)
BR2_TARGET_ARM_TRUSTED_FIRMWARE = n
BR2_TARGET_OPTEE_OS           = n
BR2_TARGET_UBOOT              = n
BR2_PACKAGE_OPTEE_CLIENT      = n
BR2_PACKAGE_OPTEE_TEST        = n
BR2_PACKAGE_OPTEE_EXAMPLES    = n
BR2_PACKAGE_OPTEE_BENCHMARK   = n

################################################################################
# Paths to repositories
# These match the path= attributes in manifest.git/lemans.xml.
# OPTEE_OS_PATH and LINUX_PATH are already set by common.mk to the same values
# and are not repeated here.
################################################################################
TF_A_PATH      ?= $(ROOT)/arm-trusted-firmware
U-BOOT_PATH    ?= $(ROOT)/u-boot

SWIV_SCRIPT ?= $(CURDIR)/lemans/security/swiv_build_utility.py

################################################################################
# Source overlays
#
# Local DT/defconfig changes to the u-boot and linux source trees are carried
# here as patch overlays rather than committed to those repos, so the checkouts
# stay pristine.  Overlays are applied idempotently to the working tree before
# each build (already-applied overlays are skipped; conflicts abort the build).
#
#   lemans/patches/u-boot/*.patch   applied to $(U-BOOT_PATH)
#   lemans/patches/linux/*.patch    applied to $(LINUX_PATH)
################################################################################
U_BOOT_OVERLAY_DIR = $(CURDIR)/lemans/patches/u-boot
LINUX_OVERLAY_DIR  = $(CURDIR)/lemans/patches/linux

# apply-overlays: $(call apply-overlays,<repo-dir>,<overlay-dir>)
# Applies each *.patch idempotently using git-apply reverse-check to detect
# overlays that are already present.
define apply-overlays
	@set -e; \
	if [ -d "$(2)" ]; then \
		for p in $$(ls "$(2)"/*.patch 2>/dev/null | sort); do \
			if git -C "$(1)" apply --reverse --check "$$p" >/dev/null 2>&1; then \
				echo "overlay already applied: $$p"; \
			elif git -C "$(1)" apply --check "$$p" >/dev/null 2>&1; then \
				git -C "$(1)" apply "$$p" && echo "applied overlay: $$p"; \
			else \
				echo "ERROR: cannot apply overlay $$p to $(1)"; \
				exit 1; \
			fi; \
		done; \
	fi
endef

.PHONY: u-boot-overlays u-boot-overlays-revert linux-overlays linux-overlays-revert

u-boot-overlays:
	$(call apply-overlays,$(U-BOOT_PATH),$(U_BOOT_OVERLAY_DIR))

u-boot-overlays-revert:
	@for p in $$(ls "$(U_BOOT_OVERLAY_DIR)"/*.patch 2>/dev/null | sort -r); do \
		git -C "$(U-BOOT_PATH)" apply --reverse "$$p" 2>/dev/null && \
			echo "reverted overlay: $$p" || true; \
	done

linux-overlays:
	$(call apply-overlays,$(LINUX_PATH),$(LINUX_OVERLAY_DIR))

linux-overlays-revert:
	@for p in $$(ls "$(LINUX_OVERLAY_DIR)"/*.patch 2>/dev/null | sort -r); do \
		git -C "$(LINUX_PATH)" apply --reverse "$$p" 2>/dev/null && \
			echo "reverted overlay: $$p" || true; \
	done


################################################################################
# Pre-built inputs
################################################################################
BOOTAA64_EFI = $(CURDIR)/lemans/input/bootaa64.efi

include common.mk
include toolchain.mk

# common.mk passes CFG_IN_TREE_EARLY_TAS to OP-TEE on the make command line,
# which turns the platform target.mk's '+= qcom_pas/...' into a no-op. Append
# the qcom_pas PAS TA here (after the include) so it is embedded as an early TA
# and advertised on the TEE bus. qcom_pas_tee (Linux) only binds when that TA
# (cff7d191) is enumerated; without it the SA8775P PAS remoteprocs
# (adsp/cdsp/gpdsp) stay stuck in deferred probe.
CFG_IN_TREE_EARLY_TAS += qcom_pas/cff7d191-7ca0-4784-af13-48223b9a4fbe

# Buildroot rejects PATH entries containing spaces (Windows paths from WSL).
# Export a sanitized PATH for all sub-makes that invoke buildroot.
export PATH := $(shell echo "$$PATH" | tr ':' '\n' | grep -v ' ' | tr '\n' ':' | sed 's/:$$//')

################################################################################
# Top-level targets
################################################################################
.PHONY: all clean

all: optee-os tfa u-boot u-boot-proper linux buildroot efi

clean: optee-os-clean tfa-clean u-boot-clean u-boot-proper-clean linux-clean buildroot-clean

.PHONY: help
help:
	@echo "Qualcomm SA8775P Lemans EVK (QCS9075) build system"
	@echo ""
	@echo "Boot flow: XBL → U-Boot SPL (tz.mbn) → BL31 → OP-TEE → U-Boot proper → Linux"
	@echo ""
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo " MAIN TARGETS"
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo "  all            Build everything (OP-TEE, TF-A, U-Boot SPL + proper,"
	@echo "                 Linux, Buildroot) and produce efi.bin"
	@echo "  bootimage      Build the boot chain → lemans/output/"
	@echo "                   tz.mbn    signed U-Boot SPL          (tz partition)"
	@echo "                   uefi.elf  SPL_ATF FIT: BL31+OP-TEE+U-Boot (uefi part.)"
	@echo "  efi            Build kernel UKI + rootfs → lemans/output/efi.bin (LUN 0)"
	@echo "  flash-loader   Flash the boot chain via QDL (LUNs 1-5; needs bootimage)"
	@echo "  flash-kernel   Flash efi.bin via QDL (LUN 0; needs efi)"
	@echo ""
	@echo "  Typical rebuild + flash:"
	@echo "    make bootimage && make flash-loader     # boot chain"
	@echo "    make efi       && make flash-kernel     # kernel + rootfs"
	@echo ""
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo " COMPONENT TARGETS  (sub-builds invoked by the main targets)"
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo "  optee-os       Build OP-TEE OS (secure world, BL32)"
	@echo "  tfa            Build TF-A BL31 (Secure Monitor — no BL2)"
	@echo "  u-boot         Build U-Boot SPL (qcom_lemans_spl_defconfig → tz.mbn)"
	@echo "  u-boot-proper  Build U-Boot proper (qcom_lemans_defconfig, BL33 @ 0xaf000000)"
	@echo "  spl            SWIV-annotate + qtestsign the SPL → tz.mbn"
	@echo "  uefi           Assemble the SPL_ATF boot FIT → uefi.elf"
	@echo "  linux          Build kernel Image + DTBs"
	@echo "  buildroot      Build the root filesystem"
	@echo "  clean          Clean all components"
	@echo ""
	@echo "  Config/helpers: u-boot-defconfig, u-boot-proper-defconfig,"
	@echo "                  linux-defconfig, qtestsign-fetch"
	@echo "  efi-kernel-only  efi.bin with local-kernel UKI booting the on-disk"
	@echo "                   Yocto rootfs (root=PARTLABEL=rootfs); needs flash-yocto"
	@echo ""
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo " SOURCE OVERLAYS  (local u-boot/linux patches under lemans/patches/)"
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo "  u-boot-overlays / linux-overlays          Apply overlays (auto-run by builds)"
	@echo "  u-boot-overlays-revert / linux-overlays-revert  Revert overlays"
	@echo ""
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo " OTHER FLASH / EDL TARGETS"
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo "  flash-sail     Flash the SAIL safety-island NOR image via QDL (needs EDL mode)"
	@echo "                 Self-contained stock blob set from lemans/blobs (fetch-blobs)"
	@echo "                 No local build artifacts; independent of the UFS boot chain"
	@echo "  flash-sail-wipe  Wipe the SAIL NOR partition tables — RECOVERY ONLY (needs EDL mode)"
	@echo "                 Zeroes MBR + GPTs on every SAIL NOR physical partition"
	@echo "                 WARNING: destroys the SAIL NOR layout; re-run flash-sail afterward"
	@echo "  flash-ufs-provision  Re-provision the UFS LUN layout — RECOVERY ONLY"
	@echo "                 Use only when a firmware upgrade gone wrong broke the partitions"
	@echo "                 so a normal flash no longer works. Device must be in EDL mode."
	@echo "                 WARNING: reconfigures the UFS and destroys all data on it."
	@echo "                 Layout via UFS_PROVISION_XML (default: provision_1_2.xml, grows LUN 0)"
	@echo "  edl-package    Assemble flat image dir for Windows EDL flashing (PCATApp / QFIL)"
	@echo "                 Output: lemans/output/edl-package/"
	@echo "                 Contains prog_firehose_ddr.elf, all rawprogram/patch XMLs,"
	@echo "                 GPT bins, all firmware MBNs/ELFs, efi.bin, and qupv3fw.elf"
	@echo "  edl-bootloader Bootloader-only EDL package (LUN1–4: XBL, CDT, SPL, U-Boot)"
	@echo "                 Output: lemans/output/edl-bootloader/"
	@echo "                 Fast re-flash path when only OP-TEE/U-Boot changed"
	@echo ""
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo " FIRMWARE BLOB TARGETS  (alternative to 'make yocto')"
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo "  fetch-blobs    Download QCS9100 firmware blobs directly — no Yocto build needed"
	@echo "                 Sources: softwarecenter.qualcomm.com + codelinaro.org + qcom-ptool"
	@echo "                 Output: lemans/blobs/  (flash-loader/flash-kernel stage from here exclusively)"
	@echo "  fetch-blobs-clean  Remove lemans/blobs/"
	@echo ""
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo " YOCTO TARGETS"
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo "  yocto          Clone meta-qcom (if absent) and build OE no-distro BSP image via kas"
	@echo "                 Applies lemans/patches/ (adds fastrpc-tests to the image) before building"
	@echo "                 Output: yocto/build/tmp/deploy/images/iq-9075-evk/"
	@echo "                 Copy result to lemans/output/ manually before flashing"
	@echo "  flash-yocto    Flash the complete unmodified Yocto release (all 6 LUNs) via QDL"
	@echo "                 Verifies default hardware + released BSP; requires 'make yocto' first"
	@echo "  yocto-clean    Remove the cloned meta-qcom directory"
	@echo ""
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo " CLEAN TARGETS"
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo "  optee-os-clean, tfa-clean, u-boot-clean, u-boot-proper-clean, spl-clean, uefi-clean,"
	@echo "  linux-clean, buildroot-clean, efi-clean, bootimage-clean, yocto-clean,"
	@echo "  linux-firmware-clean"
	@echo ""
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo " CONFIGURABLE VARIABLES  (override on the command line or environment)"
	@echo "════════════════════════════════════════════════════════════════════════"
	@echo "  LINUX_DEFCONFIG       Kernel defconfig            (default: defconfig)"
	@echo "  U_BOOT_DEVICE_TREE    U-Boot device tree          (default: qcom/lemans-evk)"
	@echo "  LINUX_CMDLINE         Kernel command line in UKI   (default: console=ttyMSM0 …)"
	@echo "  SWIV_SCRIPT           Path to swiv_build_utility.py"
	@echo "  TF_A_FLAGS            Extra flags for TF-A make   (default: PLAT=lemans_evk SPD=opteed)"
	@echo "  QTESTSIGN_PATH        Path to qtestsign checkout (default: \$$(ROOT)/qtestsign)"
	@echo "  UFS_PROVISION_XML     UFS provision layout        (default: provision_1_2.xml)"

################################################################################
# OP-TEE OS
################################################################################
.PHONY: optee-os optee-os-clean

optee-os: optee-os-common

optee-os-clean: optee-os-clean-common

################################################################################
# U-Boot
#
# Two independent builds, each into its own output dir to keep the tree clean:
#
#   u-boot         qcom_lemans_spl_defconfig → $(U_BOOT_OUTPUT)
#                  Produces the SPL:
#                    $(U_BOOT_OUTPUT)/spl/u-boot-spl.elf  (SWIV-annotated → tz.mbn)
#                  The SPL is configured with SPL_LOAD_FIT + SPL_ATF, so at boot
#                  it reads the uefi partition as a FIT and jumps to BL31.
#                  (The proper "u-boot" this build incidentally emits is a
#                  throwaway linked at TEXT_BASE=0 and is NOT used.)
#
#   u-boot-proper  qcom_lemans_defconfig → $(U_BOOT_PROPER_OUTPUT)
#                  Produces the real U-Boot proper (BL33) linked at 0xaf000000:
#                    $(U_BOOT_PROPER_OUTPUT)/u-boot.bin  (nodtb + control dtb)
#                  This is embedded into the uefi FIT (see the 'uefi' target).
#
# BL31= and TEE= are still passed to the SPL build so its own SPL_ATF plumbing
# is configured consistently; the FIT that BL31/OP-TEE/U-Boot actually ship in
# is assembled explicitly by the 'uefi' target.
################################################################################
U_BOOT_EXPORTS      = CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"
U_BOOT_DEVICE_TREE ?= qcom/lemans-evk
# SPL build (qcom_lemans_spl_defconfig): produces the SPL that is signed into
# tz.mbn.  Its incidental "u-boot" proper is a throwaway (TEXT_BASE=0) and is
# NOT used for the uefi partition.
U_BOOT_OUTPUT       = $(U-BOOT_PATH)/.output
# U-Boot proper build (qcom_lemans_defconfig): the real BL33, linked at
# 0xaf000000.  This is what the SPL FIT (uefi partition) hands off to.
U_BOOT_PROPER_OUTPUT = $(U-BOOT_PATH)/.output-proper

BL32_BIN = $(OPTEE_OS_PATH)/out/arm/core/tee.elf
# Raw OP-TEE image (headerless pager binary linked at 0x1c300000) embedded into
# the uefi FIT as the BL32 loadable.
OPTEE_RAW_BIN = $(OPTEE_OS_PATH)/out/arm/core/tee-raw.bin

.PHONY: u-boot u-boot-defconfig u-boot-clean
.PHONY: u-boot-proper u-boot-proper-defconfig u-boot-proper-clean

u-boot-defconfig: u-boot-overlays
	mkdir -p $(U_BOOT_OUTPUT)
	$(U_BOOT_EXPORTS) $(MAKE) -C $(U-BOOT_PATH) O=$(U_BOOT_OUTPUT) \
		qcom_lemans_spl_defconfig

u-boot: u-boot-overlays
	@if [ ! -f $(U_BOOT_OUTPUT)/.config ]; then \
		mkdir -p $(U_BOOT_OUTPUT); \
		$(U_BOOT_EXPORTS) $(MAKE) -C $(U-BOOT_PATH) O=$(U_BOOT_OUTPUT) \
			qcom_lemans_spl_defconfig; \
	fi
	$(U_BOOT_EXPORTS) $(MAKE) -C $(U-BOOT_PATH) O=$(U_BOOT_OUTPUT) \
		-j$(shell nproc) DEVICE_TREE=$(U_BOOT_DEVICE_TREE) \
		BL31=$(BL31_BIN) TEE=$(BL32_BIN)

u-boot-clean:
	$(U_BOOT_EXPORTS) $(MAKE) -C $(U-BOOT_PATH) O=$(U_BOOT_OUTPUT) clean

# U-Boot proper (BL33) — built from qcom_lemans_defconfig at 0xaf000000.
# Produces u-boot.bin (nodtb + appended control dtb) which is embedded into the
# uefi FIT as the BL33 loadable.
u-boot-proper-defconfig: u-boot-overlays
	mkdir -p $(U_BOOT_PROPER_OUTPUT)
	$(U_BOOT_EXPORTS) $(MAKE) -C $(U-BOOT_PATH) O=$(U_BOOT_PROPER_OUTPUT) \
		qcom_lemans_defconfig

u-boot-proper: u-boot-overlays
	@if [ ! -f $(U_BOOT_PROPER_OUTPUT)/.config ]; then \
		mkdir -p $(U_BOOT_PROPER_OUTPUT); \
		$(U_BOOT_EXPORTS) $(MAKE) -C $(U-BOOT_PATH) O=$(U_BOOT_PROPER_OUTPUT) \
			qcom_lemans_defconfig; \
	fi
	$(U_BOOT_EXPORTS) $(MAKE) -C $(U-BOOT_PATH) O=$(U_BOOT_PROPER_OUTPUT) \
		-j$(shell nproc) DEVICE_TREE=$(U_BOOT_DEVICE_TREE)

u-boot-proper-clean:
	$(U_BOOT_EXPORTS) $(MAKE) -C $(U-BOOT_PATH) O=$(U_BOOT_PROPER_OUTPUT) clean

################################################################################
# ARM Trusted Firmware — BL31 (Secure Monitor) only
#
# Build order: optee-os → tfa
#
# BL2 is replaced by U-Boot SPL; only BL31 is built here.
# BL31 is passed to U-Boot as BL31= so the SPL FIT image carries it for
# hand-off at EL3.
#
# Generates:
#   arm-trusted-firmware/build/lemans_evk/release/bl31/bl31.elf
################################################################################
TF_A_EXPORTS = CROSS_COMPILE="$(AARCH64_CROSS_COMPILE)"
TF_A_FLAGS  ?= PLAT=lemans_evk SPD=opteed

BL31_BIN = $(TF_A_PATH)/build/lemans_evk/release/bl31/bl31.elf
# Flat BL31 image (objcopy output) embedded into the uefi FIT as the ATF firmware.
BL31_BIN_FLAT = $(TF_A_PATH)/build/lemans_evk/release/bl31.bin

.PHONY: tfa tfa-clean

tfa:
	$(TF_A_EXPORTS) $(MAKE) -C $(TF_A_PATH) -j$(shell nproc) $(TF_A_FLAGS) bl31

tfa-clean:
	$(TF_A_EXPORTS) $(MAKE) -C $(TF_A_PATH) $(TF_A_FLAGS) clean


#
# After building U-Boot, the SPL is:
#   1. Annotated with a SWIV segment via swiv_build_utility.py
#   2. Signed locally with qtestsign (open-source — no CASS access required)
#
# Intermediate files (kept in the U-Boot output directory):
#   $(U_BOOT_OUTPUT)/spl/u-boot-spl-swiv.elf  SWIV-annotated SPL ELF
#   $(U_BOOT_OUTPUT)/spl/u-boot-spl.mbn        qtestsign output
#
# Final outputs copied to lemans/output/:
#   lemans/output/tz.mbn      signed SPL (flashed to tz partition)
#
# NOTE: the uefi partition image (lemans/output/uefi.elf) is NOT produced here.
# It is a FIT assembled by the 'uefi' target below (BL31 + OP-TEE + U-Boot
# proper).  The SPL (tz.mbn) is configured with SPL_LOAD_FIT + SPL_ATF and
# expects exactly that FIT on the uefi partition.
################################################################################
QTESTSIGN_PATH ?= $(ROOT)/qtestsign

.PHONY: qtestsign-fetch
qtestsign-fetch:
	@if [ ! -d $(QTESTSIGN_PATH) ]; then \
		echo "Cloning qtestsign..."; \
		git clone https://github.com/msm8916-mainline/qtestsign $(QTESTSIGN_PATH); \
	fi

.PHONY: spl spl-clean

spl: qtestsign-fetch
	mkdir -p $(CURDIR)/lemans/output
	python3 $(SWIV_SCRIPT) \
		$(U_BOOT_OUTPUT)/spl/u-boot-spl-swiv.elf \
		$(U_BOOT_OUTPUT)/spl/u-boot-spl.elf \
		lemans
	python3 $(QTESTSIGN_PATH)/qtestsign.py -v6 tz \
		-o $(U_BOOT_OUTPUT)/spl/u-boot-spl.mbn \
		$(U_BOOT_OUTPUT)/spl/u-boot-spl-swiv.elf
	cp $(U_BOOT_OUTPUT)/spl/u-boot-spl.mbn $(CURDIR)/lemans/output/tz.mbn
	@echo "Signed SPL written to lemans/output/tz.mbn (tz partition image)"

spl-clean:
	rm -f $(CURDIR)/lemans/output/tz.mbn \
	      $(U_BOOT_OUTPUT)/spl/u-boot-spl-swiv.elf \
	      $(U_BOOT_OUTPUT)/spl/u-boot-spl.mbn

################################################################################
# uefi partition image — SPL_ATF boot FIT
#
# The SPL (tz.mbn, qcom_lemans_spl_defconfig) is built with SPL_LOAD_FIT +
# SPL_ATF.  It reads the "uefi" partition as a FIT image, loads each sub-image
# to its load address, then jumps to the ATF (BL31) firmware.  BL31 in turn
# hands off to OP-TEE (BL32) and finally U-Boot proper (BL33).
#
# The FIT therefore carries three payloads plus the U-Boot control FDT:
#   firmware  = atf    BL31           bl31.bin        @ 0x1c200000
#   loadables = uboot  U-Boot proper  u-boot.bin      @ 0xaf000000
#             = optee  OP-TEE OS      tee-raw.bin     @ 0x1c300000
#   fdt       = fdt-1  U-Boot dtb (so the SPL records the loadables into
#                      /fit-images, which is how spl_invoke_atf() discovers the
#                      OP-TEE (os="tee") and U-Boot (os="u-boot") entry points).
#
# ORDER MATTERS: "uboot" must precede "optee" in loadables.  In
# spl_load_simple_fit() the firmware (atf) is not os_takes_devicetree, so
# spl_image->fdt_addr is unset until the U-Boot loadable is processed; a
# loadable is only recorded into /fit-images once fdt_addr is set.  If OP-TEE
# came first it would not be recorded and BL31 would receive no BL32 entry.
#
# u-boot.bin (nodtb + appended control dtb) is used for BL33 rather than
# u-boot-nodtb.bin: qcom's board_fdt_blob_setup() prefers U-Boot's internal
# (appended) DTB and only falls back to a prev-stage fdt pointer — which BL31
# does not supply (it hands off with x0 = MPIDR, not an fdt) — so an embedded
# DTB guarantees U-Boot always has a valid device tree.
#
# Output: lemans/output/uefi.elf — the FIT flashed to the uefi_a/uefi_b
# partition (filename referenced by rawprogram4.xml).  Despite the .elf name it
# is a FIT (.itb); the name is kept to match the existing flash descriptors.
################################################################################
MKIMAGE       ?= $(U_BOOT_OUTPUT)/tools/mkimage
UEFI_OUTPUT    = $(CURDIR)/lemans/output/uefi.elf
UEFI_ITS       = $(CURDIR)/lemans/output/uefi.its
UBOOT_PROPER_BIN = $(U_BOOT_PROPER_OUTPUT)/u-boot.bin
UBOOT_PROPER_DTB = $(U_BOOT_PROPER_OUTPUT)/u-boot.dtb

.PHONY: uefi uefi-clean

uefi:
	mkdir -p $(CURDIR)/lemans/output
	@for f in "$(BL31_BIN_FLAT)" "$(OPTEE_RAW_BIN)" "$(UBOOT_PROPER_BIN)" \
	          "$(UBOOT_PROPER_DTB)"; do \
		if [ ! -f "$$f" ]; then \
			echo "ERROR: missing FIT input $$f"; \
			echo "       run 'make tfa optee-os u-boot-proper' first"; \
			exit 1; \
		fi; \
	done
	@echo "Generating uefi FIT source ($(UEFI_ITS))..."
	@printf '%s\n' \
	'/dts-v1/;' \
	'' \
	'/ {' \
	'	description = "Lemans uefi boot FIT (BL31 + OP-TEE + U-Boot proper)";' \
	'	#address-cells = <1>;' \
	'' \
	'	images {' \
	'		atf {' \
	'			description = "ARM Trusted Firmware BL31";' \
	'			data = /incbin/("$(BL31_BIN_FLAT)");' \
	'			type = "firmware";' \
	'			arch = "arm64";' \
	'			os = "arm-trusted-firmware";' \
	'			compression = "none";' \
	'			load = <0x1c200000>;' \
	'			entry = <0x1c200000>;' \
	'			hash-1 { algo = "sha256"; };' \
	'		};' \
	'		optee {' \
	'			description = "OP-TEE OS (BL32)";' \
	'			data = /incbin/("$(OPTEE_RAW_BIN)");' \
	'			type = "tee";' \
	'			arch = "arm64";' \
	'			os = "tee";' \
	'			compression = "none";' \
	'			load = <0x1c300000>;' \
	'			entry = <0x1c300000>;' \
	'			hash-1 { algo = "sha256"; };' \
	'		};' \
	'		uboot {' \
	'			description = "U-Boot proper (BL33)";' \
	'			data = /incbin/("$(UBOOT_PROPER_BIN)");' \
	'			type = "firmware";' \
	'			arch = "arm64";' \
	'			os = "u-boot";' \
	'			compression = "none";' \
	'			load = <0xaf000000>;' \
	'			entry = <0xaf000000>;' \
	'			hash-1 { algo = "sha256"; };' \
	'		};' \
	'		fdt-1 {' \
	'			description = "U-Boot control FDT";' \
	'			data = /incbin/("$(UBOOT_PROPER_DTB)");' \
	'			type = "flat_dt";' \
	'			arch = "arm64";' \
	'			compression = "none";' \
	'			hash-1 { algo = "sha256"; };' \
	'		};' \
	'	};' \
	'' \
	'	configurations {' \
	'		default = "conf-1";' \
	'		conf-1 {' \
	'			description = "Lemans BL31 + OP-TEE + U-Boot";' \
	'			firmware = "atf";' \
	'			loadables = "uboot", "optee";' \
	'			fdt = "fdt-1";' \
	'		};' \
	'	};' \
	'};' \
	> $(UEFI_ITS)
	$(MKIMAGE) -f $(UEFI_ITS) $(UEFI_OUTPUT)
	@echo "uefi FIT written to $(UEFI_OUTPUT)"
	@$(MKIMAGE) -l $(UEFI_OUTPUT)

uefi-clean:
	rm -f $(UEFI_OUTPUT) $(UEFI_ITS)

################################################################################
# Boot image (tz.mbn + uefi.elf)
################################################################################
.PHONY: bootimage bootimage-clean

bootimage:
	rm -f $(CURDIR)/lemans/output/tz.mbn \
	      $(CURDIR)/lemans/output/uefi.elf
	$(MAKE) optee-os
	$(MAKE) tfa
	$(MAKE) u-boot
	$(MAKE) u-boot-proper
	$(MAKE) spl
	$(MAKE) uefi

bootimage-clean: spl-clean uefi-clean tfa-clean optee-os-clean u-boot-clean u-boot-proper-clean

################################################################################
# Linux kernel
#
# linux-defconfig applies $(LINUX_DEFCONFIG), enables TEE/OP-TEE and EFI_ZBOOT,
# and disables drivers that cause probe failures on Lemans EVK.
# Auto-invoked by linux if .config is absent.
#
# Generates:
#   linux/arch/arm64/boot/Image
#   linux/arch/arm64/boot/vmlinuz.efi  (EFI_ZBOOT self-decompressing kernel)
################################################################################
LINUX_EXPORTS    = ARCH=arm64 CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"
LINUX_DEFCONFIG ?= defconfig

.PHONY: linux-defconfig linux linux-clean

linux-defconfig:
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) mrproper
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) $(LINUX_DEFCONFIG)
	$(LINUX_EXPORTS) $(LINUX_PATH)/scripts/config --file $(LINUX_PATH)/.config \
		-e TEE \
		-e OPTEE \
		-d QCOMTEE \
		-e DEVTMPFS \
		-e EFI_BOOT \
		-e EFI_ZBOOT \
		-e QCOM_FASTRPC \
		-e REMOTEPROC \
		-e QCOM_PAS \
		-e QCOM_PAS_TEE \
		-e RPMSG \
		-e RPMSG_QCOM_GLINK \
		-e RPMSG_QCOM_GLINK_SMEM \
		-e QCOM_SMEM \
		-e QCOM_SMP2P \
		-e QCOM_SMSM \
		-e QCOM_AOSS_QMP \
		-e QCOM_RPMHPD \
		-e QCOM_COMMAND_DB \
		-e QCOM_SCM \
		-e QRTR \
		-e QRTR_SMD \
		-e CMA \
		-e DMA_CMA \
		-e DMABUF_HEAPS \
		-e DMABUF_HEAPS_SYSTEM \
		-e DMABUF_HEAPS_CMA \
		-d MODULES \
		-e ARM64_64K_PAGES \
		-d ARM64_4K_PAGES
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) olddefconfig

linux: linux-overlays
	@# Generate .config from the single source of truth (linux-defconfig) so the
	@# build can never drift from it (this is why QCOMTEE / QCOM_PAS_TEE / MODULES
	@# silently regressed before).  linux-defconfig disables MODULES, which forces
	@# hidden 'default m' drivers like QCOM_PAS_TEE built-in (needed for the PAS
	@# remoteprocs to probe — they can't wait on a late-loaded module).
	@if [ ! -f $(LINUX_PATH)/.config ]; then \
		$(MAKE) linux-defconfig; \
	fi
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) -j$(shell nproc) Image vmlinuz.efi
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) -j1 dtbs

linux-clean:
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) clean

################################################################################
# UKI — Unified Kernel Image (efi.bin)
#
# Bundles the kernel, DTB, initramfs, and command line into a single EFI
# binary using ukify, then builds a fresh FAT32 image containing:
#   EFI/BOOT/bootaa64.efi   UEFI fallback boot entry (from lemans/input/)
#   EFI/Linux/uki.efi       Unified Kernel Image
#
# Host dependencies:
#   apt install systemd-ukify mtools dosfstools
#
# Generates:
#   linux/uki.efi
#   lemans/output/efi.bin   FAT32 image (EFI_BIN_SIZE)
################################################################################
LINUX_IMAGE  = $(LINUX_PATH)/arch/arm64/boot/vmlinuz.efi
LINUX_DTB    = $(LINUX_PATH)/arch/arm64/boot/dts/qcom/lemans-evk-el2.dtb
BR_INITRAMFS = $(ROOT)/out-br/images/rootfs.cpio.gz
EFI_BIN_SIZE = 512M

LINUX_CMDLINE ?= \
	console=ttyMSM0,115200 \
	qcom_scm.download_mode=1 \
	arm-smmu.disable_bypass=0 \
	clk_ignore_unused \
	pd_ignore_unused
# WORKAROUND: arm-smmu.disable_bypass=0 keeps the SMMU in bypass for stream IDs
# that have no context mapping instead of faulting them. Some peripherals on the
# SA8775P/QCS9075 Lemans EVK are not yet fully described with SMMU stream
# mappings in the device tree, so with the default (bypass disabled) their DMA
# transactions are aborted and the devices fail to initialize. Remove once the
# device tree describes all SMMU masters.

.PHONY: efi efi-clean

efi: linux buildroot linux-firmware
	rm -f $(LINUX_PATH)/uki.efi $(CURDIR)/lemans/output/efi.bin
	ukify build \
		--linux=$(LINUX_IMAGE) \
		--initrd=$(BR_INITRAMFS) \
		--cmdline='$(LINUX_CMDLINE)' \
		--efi-arch=aa64 \
		--stub=$(CURDIR)/lemans/ukify/linuxaa64.efi.stub \
		--os-release=@/etc/os-release \
		--devicetree=$(LINUX_DTB) \
		--output=$(LINUX_PATH)/uki.efi
	truncate -s $(EFI_BIN_SIZE) $(CURDIR)/lemans/output/efi.bin
	mkfs.fat -F 32 -S 4096 $(CURDIR)/lemans/output/efi.bin
	mmd -i $(CURDIR)/lemans/output/efi.bin ::/EFI
	mmd -i $(CURDIR)/lemans/output/efi.bin ::/EFI/BOOT
	mmd -i $(CURDIR)/lemans/output/efi.bin ::/EFI/Linux
	mcopy -i $(CURDIR)/lemans/output/efi.bin $(BOOTAA64_EFI) ::/EFI/BOOT/bootaa64.efi
	mcopy -i $(CURDIR)/lemans/output/efi.bin $(LINUX_PATH)/uki.efi ::/EFI/Linux/uki.efi

efi-clean:
	rm -f $(LINUX_PATH)/uki.efi $(CURDIR)/lemans/output/efi.bin

################################################################################
# efi-kernel-only — Build an efi.bin that boots the full Yocto rootfs
#
# Builds a UKI from the locally-built kernel (no initramfs) whose command line
# mounts the on-disk Yocto rootfs partition (root=PARTLABEL=rootfs) and injects
# it into a copy of the Yocto efi.bin (replacing its stock UKI). Flash the
# result with 'make flash-kernel' (efi.bin only — rootfs.img untouched).
#
# Unlike 'efi' (which boots the Buildroot initramfs from a freshly-built
# efi.bin), this reuses the Yocto efi.bin and boots the on-disk Yocto rootfs, so
# the matching Yocto rootfs.img must already be flashed (e.g. 'make flash-yocto').
#
# Based on boot.qclinux.rootfs.sh.
################################################################################
YOCTOFS_CMDLINE ?= root=PARTLABEL=rootfs rw rootwait $(LINUX_CMDLINE)

.PHONY: efi-kernel-only

efi-kernel-only: linux
	@if [ ! -f "$(YOCTO_FLASH)/efi.bin" ]; then \
		echo "ERROR: Yocto efi.bin not found at $(YOCTO_FLASH)/efi.bin"; \
		echo "       Run 'make yocto' first to build the release image."; \
		exit 1; \
	fi
	rm -f $(LINUX_PATH)/uki.efi $(CURDIR)/lemans/output/efi.bin
	ukify build \
		--linux=$(LINUX_IMAGE) \
		--cmdline='$(YOCTOFS_CMDLINE)' \
		--efi-arch=aa64 \
		--stub=$(CURDIR)/lemans/ukify/linuxaa64.efi.stub \
		--os-release=@/etc/os-release \
		--devicetree=$(LINUX_DTB) \
		--output=$(LINUX_PATH)/uki.efi
	cp $(YOCTO_FLASH)/efi.bin $(CURDIR)/lemans/output/efi.bin
	mdeltree -i $(CURDIR)/lemans/output/efi.bin ::/EFI/Linux
	mmd      -i $(CURDIR)/lemans/output/efi.bin ::/EFI/Linux
	mcopy    -i $(CURDIR)/lemans/output/efi.bin $(LINUX_PATH)/uki.efi ::/EFI/Linux/uki.efi

################################################################################
# Firmware blob location  (fetched by fetch-blobs; consumed by the flash targets)
#
# Defined here — ahead of the flash targets that list $(BLOBS_STAMP) as a
# prerequisite — because make expands prerequisites at parse time: a variable
# used in a prerequisite must already be set when the rule is read, or it
# silently expands to empty. The download URLs/SHAs live in the fetch-blobs
# section further down.
################################################################################
BLOBS_VERSION  = 00132
BLOBS_DIR      = $(CURDIR)/lemans/blobs
# Keyed to BLOBS_VERSION: bumping the version invalidates the stamp, so
# fetch-blobs (and anything depending on it, e.g. flash-loader) re-fetches the
# new drop instead of no-op'ing on a stale stamp.
BLOBS_STAMP    = $(BLOBS_DIR)/.fetch-complete-$(BLOBS_VERSION)
# SAIL (safety-island) NOR flash set — a self-contained sub-tree of the boot-
# binaries drop (own firehose, rawprogram0/patch0, and payload ELFs). Consumed
# by flash-sail; flashed in place, no staging into lemans/output/.
SAIL_NOR_DIR   = $(BLOBS_DIR)/bootbinaries/QCS9100_bootbinaries/sail_nor
# Per-physical-partition GPT/table wipe descriptors consumed by flash-sail-wipe.
# One per NOR physical partition (PHY3 has no descriptor); each zeroes the MBR +
# primary/backup GPT sectors of its partition. (rawprogram0_WIPE_PARTITIONS.xml
# is intentionally not used: it references a mis-cased "zeros_33sectorS.bin" that
# does not exist, so it is broken as shipped.)
SAIL_WIPE_XMLS = wipe_rawprogram_PHY0.xml wipe_rawprogram_PHY1.xml \
                 wipe_rawprogram_PHY2.xml wipe_rawprogram_PHY4.xml \
                 wipe_rawprogram_PHY5.xml wipe_rawprogram_PHY6.xml \
                 wipe_rawprogram_PHY7.xml

################################################################################
# Reusable recipe macros (flash / EDL packaging)
################################################################################

# stage-blobs-strict: $(call stage-blobs-strict,<file-list>)
# Copy each named file straight from lemans/blobs/ into lemans/output/,
# overwriting. Hard error (not skip) if any is missing — the flash set that the
# loader/kernel targets program must be complete.
define stage-blobs-strict
	@for f in $(1); do \
		if [ ! -f "$(BLOBS_DIR)/$$f" ]; then \
			echo "ERROR: $$f missing from $(BLOBS_DIR)"; \
			echo "       Run 'make fetch-blobs' (or 'make fetch-blobs-clean fetch-blobs' to force a refresh)"; \
			exit 1; \
		fi; \
		cp -f "$(BLOBS_DIR)/$$f" "$(CURDIR)/lemans/output/$$f"; \
	done
endef

# stage-flash-files: $(call stage-flash-files,<file-list>,<dest-dir>)
# Copy each named file into <dest-dir>, resolving from the first source that
# has it: lemans/input/ (hand-placed overrides) → YOCTO_FLASH → lemans/blobs/.
# Missing files warn and are skipped (some entries are optional per package).
define stage-flash-files
	@for f in $(1); do \
	    if   [ -f "$(CURDIR)/lemans/input/$$f" ]; then \
	        cp "$(CURDIR)/lemans/input/$$f" "$(2)/$$f"; \
	    elif [ -f "$(YOCTO_FLASH)/$$f" ]; then \
	        cp "$(YOCTO_FLASH)/$$f" "$(2)/$$f"; \
	    elif [ -f "$(BLOBS_DIR)/$$f" ]; then \
	        cp "$(BLOBS_DIR)/$$f" "$(2)/$$f"; \
	    else \
	        echo "WARNING: $$f not found — skipping (run 'make fetch-blobs' if needed)"; \
	    fi; \
	done
endef

# patch-qupfw: $(call patch-qupfw,<rawprogram4-src>,<rawprogram4-dst>)
# Populate the empty qupfw_a/qupfw_b partition entries with qupv3fw.elf so
# U-Boot can load the QUP GENI SE firmware (see flash-loader for the rationale).
define patch-qupfw
	sed '/label="qupfw_[ab]"/ s/filename=""/filename="qupv3fw.elf"/' \
	    "$(1)" > "$(2)"
endef

# strip-rootfs: $(call strip-rootfs,<rawprogram0-src>,<rawprogram0-dst>)
# Drop the rootfs.img entry so only efi.bin (LUN 0 kernel partition) is written.
define strip-rootfs
	grep -v 'filename="rootfs.img"' "$(1)" > "$(2)"
endef

################################################################################
# Flash file sets
#
# Every flash/EDL file list is built from the same pieces, so they are composed
# here from shared building blocks instead of being spelled out four times:
#
#   FIREHOSE        the DDR firehose programmer (always first)
#   BOOT_FW_FILES   LUN1–4 boot-firmware payload (XBL, CDT, AOP, OP-TEE/U-Boot's
#                   neighbours …) — identical wherever the boot chain is flashed
#   lun-tables      $(call lun-tables,<n>)  → gpt_main<n>.bin gpt_backup<n>.bin
#   lun-raw         $(call lun-raw,<n>)     → rawprogram<n>.xml
#   lun-patch       $(call lun-patch,<n>)   → patch<n>.xml
#
# The per-target lists below differ only in which LUNs they cover and whether
# they include the patch XMLs / zero-fill files — that difference is now the
# only thing each definition has to state.
################################################################################
FIREHOSE = prog_firehose_ddr.elf

# LUN1–4 boot-firmware payload, flashed by the loader and both EDL packages.
BOOT_FW_FILES = \
	xbl.elf xbl_config.elf cdt.bin \
	aop.mbn cpucp.elf devcfg_iot.mbn hypvm.mbn imagefv.elf \
	multi_image.mbn multi_image_qti.mbn \
	shrm.elf tools.fv uefi_sec.mbn XblRamdump.elf

# Zero-fill payloads. The loader needs only the 33-sector fill; the EDL packages
# ship all three (PCATApp/QFIL reference them from the unmodified rawprogram XMLs).
ZEROS_FILES = zeros_33sectors.bin zeros_1sector.bin zeros_5sectors.bin

lun-tables = gpt_main$(1).bin gpt_backup$(1).bin
lun-raw    = rawprogram$(1).xml
lun-patch  = patch$(1).xml

# flash-loader: LUN1–5 boot chain from blobs/ (no patch XMLs; one zero-fill).
LOADER_BLOB_FILES = \
	$(FIREHOSE) \
	$(foreach n,1 2 3 4 5,$(call lun-raw,$(n))) \
	$(BOOT_FW_FILES) zeros_33sectors.bin \
	$(foreach n,1 2 3 4 5,$(call lun-tables,$(n)))

# flash-kernel: LUN0 only (kernel partition tables + rawprogram + patch).
KERNEL_BLOB_FILES = \
	$(FIREHOSE) $(call lun-raw,0) $(call lun-tables,0) $(call lun-patch,0)

################################################################################
# Flash helpers
#
# Lemans (SA8775P / QCS9075) uses UFS with 6 LUNs (0–5):
#   LUN 0 (rawprogram0): efi.bin, rootfs.img
#   LUN 1 (rawprogram1): xbl.elf, xbl_config.elf
#   LUN 2 (rawprogram2): xbl.elf, xbl_config.elf (redundant copy)
#   LUN 3 (rawprogram3): cdt.bin
#   LUN 4 (rawprogram4): all main FW (tz.mbn, uefi.elf, aop, shrm, hyp, …)
#   LUN 5 (rawprogram5): GPT only (no payload files)
#
#   flash-loader   Programs LUNs 1–5 (boot chain: XBL, SPL, U-Boot proper, supporting FW).
#                  tz.mbn and uefi.elf come from lemans/output/ (built artifacts).
#                  All other files are staged straight from the fetched blob set
#                  (lemans/blobs/) into lemans/output/, overwriting — so the most
#                  recently fetched blobs are always what gets flashed.
#
#   flash-kernel   Programs LUN 0 (efi.bin only; rootfs.img is stripped out).
################################################################################
.PHONY: flash-loader flash-kernel flash-sail flash-sail-wipe

# LOADER_BLOB_FILES (defined above) is staged straight from the fetched blob set
# (lemans/blobs/, produced by fetch-blobs). NOT included: tz.mbn + uefi.elf
# (staged from lemans/output/ — the SWIV-annotated, qtestsign-signed build) and
# qupv3fw.elf (from linux-firmware). The blob rawprogram/GPT set is
# self-consistent (ptool-generated, dtb.bin stripped), so no dtb.bin is needed.
#
# flash-loader depends on the fetch stamp so the blob set always exists and,
# because the stamp is keyed to BLOBS_VERSION, is refreshed whenever the version
# is bumped. Every file is staged from lemans/blobs/ into lemans/output/
# (overwriting) so the most recently fetched blobs are unequivocally what gets
# flashed — no stale lemans/input/ or Yocto copy can shadow them. Only tz.mbn +
# uefi.elf come from the local build; they already live in lemans/output/.
# The linux-firmware prerequisite stages qupv3fw.elf (QUP GENI SE firmware for
# the qupfw_a/qupfw_b partitions) into $(FW_CLONE_DIR) — it is not part of the
# boot-binaries blob drop, so without it the qupfw slots cannot be programmed.
flash-loader: $(BLOBS_STAMP) linux-firmware
	$(call stage-blobs-strict,$(LOADER_BLOB_FILES))
	@# Program the QUP GENI SE firmware into the qupfw_a/qupfw_b partitions.
	@# U-Boot loads QUP firmware from the qupfw partition (GPT type-GUID
	@# 21d1219f-2ed1-4ab4-930a-41a16ae75f7f). The stock rawprogram4 leaves qupfw
	@# with filename="" (empty partition), so U-Boot's read_elf() fails with
	@# -EINVAL ("i2c_geni i2c@890000: Failed to read ELF: -22") and the i2c/uart/spi
	@# GENI SEs stay in invalid-proto state (GENI_SE_INVALID_PROTO=255), which
	@# storms their level interrupts (e.g. GIC 618 on i2c18) in Linux. Stage
	@# qupv3fw.elf (from linux-firmware) and patch rawprogram4 to write it into
	@# both qupfw slots.
	@if [ -f "$(FW_CLONE_DIR)/$(FW_SOC)/qupv3fw.elf" ]; then \
		cp -f "$(FW_CLONE_DIR)/$(FW_SOC)/qupv3fw.elf" "$(CURDIR)/lemans/output/qupv3fw.elf"; \
	else \
		echo "ERROR: qupv3fw.elf not found; run 'make linux-firmware' first"; \
		exit 1; \
	fi
	@echo "Patching rawprogram4 to populate qupfw_a/qupfw_b with qupv3fw.elf..."
	@$(call patch-qupfw,$(CURDIR)/lemans/output/rawprogram4.xml,$(CURDIR)/lemans/output/rawprogram4-qupfw.xml)
	@if [ ! -f "$(CURDIR)/lemans/output/tz.mbn" ]; then \
		echo "ERROR: lemans/output/tz.mbn not found — run 'make bootimage' first"; \
		echo "       (the signed U-Boot SPL is the tz partition image)"; \
		exit 1; \
	fi
	@if [ ! -f "$(CURDIR)/lemans/output/uefi.elf" ]; then \
		echo "ERROR: lemans/output/uefi.elf not found — run 'make bootimage' first"; \
		echo "       (U-Boot proper, loaded by the SPL at 0xaf000000)"; \
		exit 1; \
	fi
	cd $(CURDIR)/lemans/output && \
		qdl --debug prog_firehose_ddr.elf \
		    rawprogram1.xml rawprogram2.xml rawprogram3.xml \
		    rawprogram4-qupfw.xml rawprogram5.xml

# KERNEL_BLOB_FILES (defined above) is staged from the fetched blob set. efi.bin
# is NOT here — it comes from lemans/output/ (the 'make efi' UKI); rootfs.img is
# stripped from the rawprogram so only the kernel partition is written.
#
# Mirrors flash-loader: stage straight from lemans/blobs/ into lemans/output/
# (overwriting) so the most recently fetched blobs are what flashes, and depend
# on the version-keyed stamp so a BLOBS_VERSION bump re-fetches. efi.bin is left
# as 'make efi' wrote it and flashed from lemans/output/.
flash-kernel: $(BLOBS_STAMP)
	$(call stage-blobs-strict,$(KERNEL_BLOB_FILES))
	@# Kernel-only rawprogram0: drop the rootfs.img entry so only efi.bin (LUN 0
	@# kernel partition) is written; regenerated every run to track fresh blobs.
	@echo "Generating rawprogram0-only-kernel.xml (efi only, no rootfs)..."
	@$(call strip-rootfs,$(CURDIR)/lemans/output/rawprogram0.xml,$(CURDIR)/lemans/output/rawprogram0-only-kernel.xml)
	@if [ ! -f "$(CURDIR)/lemans/output/efi.bin" ]; then \
		echo "ERROR: lemans/output/efi.bin not found — run 'make efi' first"; \
		echo "       (the UKI kernel image written to LUN 0)"; \
		exit 1; \
	fi
	cd $(CURDIR)/lemans/output && \
		qdl --debug prog_firehose_ddr.elf rawprogram0-only-kernel.xml patch0.xml

################################################################################
# flash-sail — Flash the SAIL (safety-island) NOR image.
#
# The SAIL subsystem boots from its own NOR flash, wholly independent of the UFS
# boot chain that flash-loader/flash-kernel program. $(SAIL_NOR_DIR) is a
# self-contained flash set inside the fetched blob drop: its own DDR firehose
# programmer, rawprogram0.xml, patch0.xml, and payload ELFs (sailhyp.elf,
# sailsw1.elf, GPT bins). Nothing here comes from the local build, so — unlike
# flash-loader/flash-kernel — there is no staging into lemans/output/; qdl runs
# straight from the blob directory, exactly as flash-yocto does.
#
# Depends on $(BLOBS_STAMP) so the set is fetched and, being version-keyed,
# refreshed on a BLOBS_VERSION bump. Device must be in EDL mode.
flash-sail: $(BLOBS_STAMP)
	@if [ ! -f "$(SAIL_NOR_DIR)/prog_firehose_ddr.elf" ]; then \
		echo "ERROR: SAIL NOR blob set not found at $(SAIL_NOR_DIR)"; \
		echo "       Run 'make fetch-blobs' (or 'make fetch-blobs-clean fetch-blobs' to force a refresh)"; \
		exit 1; \
	fi
	cd $(SAIL_NOR_DIR) && \
		qdl --debug prog_firehose_ddr.elf rawprogram0.xml patch0.xml

################################################################################
# flash-sail-wipe — Wipe the SAIL NOR partition tables (recovery).
#
# Zeroes the MBR + primary/backup GPT sectors of every SAIL NOR physical
# partition ($(SAIL_WIPE_XMLS)), invalidating the whole on-NOR layout. Use to
# recover a SAIL NOR whose partition tables were left inconsistent by a bad
# flash, before re-running 'make flash-sail'. Device must be in EDL mode.
#
# WARNING: destroys the SAIL NOR partition layout and all data on it.
#
# The wipe descriptors reference zeros_5sectors.bin (present here) and
# zeros_33sectors.bin (NOT shipped in sail_nor — it lives in lemans/blobs/), so
# qdl is given --include $(BLOBS_DIR) to resolve the latter without copying it
# into the vendor tree. rawprogram0_WIPE_PARTITIONS.xml is deliberately avoided
# (broken "zeros_33sectorS.bin" reference — see SAIL_WIPE_XMLS).
flash-sail-wipe: $(BLOBS_STAMP)
	@if [ ! -f "$(SAIL_NOR_DIR)/prog_firehose_ddr.elf" ]; then \
		echo "ERROR: SAIL NOR blob set not found at $(SAIL_NOR_DIR)"; \
		echo "       Run 'make fetch-blobs' (or 'make fetch-blobs-clean fetch-blobs' to force a refresh)"; \
		exit 1; \
	fi
	@if [ ! -f "$(BLOBS_DIR)/zeros_33sectors.bin" ]; then \
		echo "ERROR: zeros_33sectors.bin not found in $(BLOBS_DIR)"; \
		echo "       Run 'make fetch-blobs' (or 'make fetch-blobs-clean fetch-blobs' to force a refresh)"; \
		exit 1; \
	fi
	cd $(SAIL_NOR_DIR) && \
		qdl --debug --include . --include $(BLOBS_DIR) \
		    prog_firehose_ddr.elf $(SAIL_WIPE_XMLS)

################################################################################
# flash-ufs-provision — Re-provision the UFS LUN layout (recover a broken UFS)
#
# Use ONLY when a firmware upgrade / flash gone wrong has broken the on-device
# partition (LUN) layout, so that a normal 'make flash-loader'/'make flash-kernel'
# no longer succeeds. This is a recovery step, not part of a routine flash.
# Provisioning rewrites the UFS unit descriptors / LUN layout, so it DESTROYS
# ALL DATA on the device.
#
# The board must be in EDL (Emergency Download) mode. Procedure follows the
# IQ-9075 EVK FAQ: load the DDR firehose programmer and apply a provision XML.
#
#   qdl --storage ufs prog_firehose_ddr.elf <provision XML>
#
# provision.zip (CodeLinaro) ships two layouts:
#   provision_1_2.xml  grows HLOS LUN 0 to fill the disk (default — LUN 0 is
#                      where this build writes efi.bin + rootfs.img)
#   provision_1_1.xml  grows User LUN 7 instead; larger NHLOS LUNs
# Override with:  make flash-ufs-provision UFS_PROVISION_XML=provision_1_1.xml
#
# prog_firehose_ddr.elf is resolved from lemans/input/, the Yocto deploy dir, or
# lemans/blobs/ (this recovery target keeps that fallback; flash-loader/flash-kernel
# themselves stage strictly from lemans/blobs/); the copy bundled inside
# provision.zip is ignored.
################################################################################
PROVISION_URL     = https://artifacts.codelinaro.org/artifactory/codelinaro-le/Qualcomm_Linux/QCS9100/provision.zip
PROVISION_SHA256  = 2fa0cac052d56333d04da5ccdda69c696f652e586cb19aa051dc93999c8464ea
PROVISION_ZIP     = $(BLOBS_DIR)/provision.zip
PROVISION_DIR     = $(BLOBS_DIR)/provision
UFS_PROVISION_XML ?= provision_1_2.xml

.PHONY: flash-ufs-provision

flash-ufs-provision:
	@# Resolve the DDR firehose programmer (input/ → Yocto → blobs/ fallback).
	@if [ ! -f "$(CURDIR)/lemans/input/prog_firehose_ddr.elf" ]; then \
		if [ -f "$(YOCTO_FLASH)/prog_firehose_ddr.elf" ]; then \
			echo "Copying prog_firehose_ddr.elf from Yocto flash directory..."; \
			cp "$(YOCTO_FLASH)/prog_firehose_ddr.elf" "$(CURDIR)/lemans/input/prog_firehose_ddr.elf"; \
		elif [ -f "$(BLOBS_DIR)/prog_firehose_ddr.elf" ]; then \
			echo "Copying prog_firehose_ddr.elf from blobs directory..."; \
			cp "$(BLOBS_DIR)/prog_firehose_ddr.elf" "$(CURDIR)/lemans/input/prog_firehose_ddr.elf"; \
		else \
			echo "ERROR: prog_firehose_ddr.elf not found in lemans/input/, $(YOCTO_FLASH), or $(BLOBS_DIR)"; \
			echo "       Run 'make fetch-blobs' or 'make yocto', or copy it manually to lemans/input/"; \
			exit 1; \
		fi; \
	fi
	@# Fetch + verify + unpack the provision XMLs (curl/sha256/unzip as fetch-blobs).
	@mkdir -p $(PROVISION_DIR)
	@if [ ! -f "$(PROVISION_ZIP)" ]; then \
		echo "Downloading UFS provision layouts..."; \
		curl --retry 5 -s -S -L $(PROVISION_URL) -o $(PROVISION_ZIP) || \
			{ rm -f $(PROVISION_ZIP); exit 1; }; \
	fi
	@echo "$(PROVISION_SHA256)  $(PROVISION_ZIP)" | sha256sum -c
	@unzip -q -o $(PROVISION_ZIP) -d $(PROVISION_DIR)
	@if [ ! -f "$(PROVISION_DIR)/$(UFS_PROVISION_XML)" ]; then \
		echo "ERROR: $(UFS_PROVISION_XML) not found in provision.zip"; \
		echo "       Available layouts:"; \
		ls $(PROVISION_DIR)/*.xml | sed 's,.*/,           ,'; \
		exit 1; \
	fi
	@echo ""
	@echo "WARNING: UFS provisioning reconfigures the LUN layout and DESTROYS ALL"
	@echo "         DATA on the device.  The board must be in EDL mode."
	@echo "         Applying layout: $(UFS_PROVISION_XML)"
	@echo ""
	cp $(CURDIR)/lemans/input/prog_firehose_ddr.elf \
	   $(PROVISION_DIR)/$(UFS_PROVISION_XML) \
	   $(CURDIR)/lemans/output/
	cd $(CURDIR)/lemans/output && \
		qdl --debug --storage ufs prog_firehose_ddr.elf $(UFS_PROVISION_XML)

################################################################################
# fetch-blobs — Download QCS9100 firmware blobs directly (no Yocto build)
#
# Replicates what 'make yocto' downloads, without running the full OE build.
# All artifacts are publicly accessible — no Qualcomm account required.
#
# Sources:
#   softwarecenter.qualcomm.com  — boot binaries zip (XBL, AOP, firehose, …)
#   artifacts.codelinaro.org     — CDT (Customer Device Tree) blob
#   github.com/qualcomm-linux/qcom-ptool — GPT tables + rawprogram XMLs
#     (pre-generated files committed under platforms/iq-9075-evk/)
#
# The CDT file is extracted from the zip as cdt_rb8_core_kit.bin and installed
# as cdt.bin, matching what the Yocto image assembly step produces.
#
# Output: lemans/blobs/ — flat directory, same file names as YOCTO_FLASH.
################################################################################
BOOTBIN_URL    = https://softwarecenter.qualcomm.com/nexus/generic/product/chip/tech-package/QCS9100_bootbinaries.1.0/qcs9100_bootbinaries.1.0-test-device-public/$(BLOBS_VERSION)/QCS9100_bootbinaries_$(BLOBS_VERSION).zip
BOOTBIN_SHA256 = be297c4356c82704fac61eceb65c3308d53c635e8a9fe154b509787fdf12f9db

CDT_URL        = https://artifacts.codelinaro.org/artifactory/codelinaro-le/Qualcomm_Linux/QCS9100/cdt/rb8_core_kit.zip
CDT_SHA256     = a252244f800d7c9e15883e12935af4113f9f2ecba6490e46cd9b943169f15bfa
CDT_FILE       = cdt_rb8_core_kit.bin

PTOOL_REPO     = https://github.com/qualcomm-linux/qcom-ptool.git
PTOOL_DIR      = $(BLOBS_DIR)/qcom-ptool
PTOOL_PLATFORM = iq-9075-evk

# DSP firmware staged into a buildroot overlay, following the meta-qcom layout.
# Two distinct sets are needed for the FastRPC/PAS validation:
#
#   1. Remoteproc images (cdsp0/cdsp1/adsp/gpdsp*.mbn): loaded by the kernel
#      from /lib/firmware/qcom/sa8775p/ per the DTS firmware-name — this load is
#      what triggers the OP-TEE PAS authenticate/reset path.  Upstream
#      linux-firmware ships these as flat files for sa8775p, so we sparse-check
#      out qcom/sa8775p and copy the *.mbn/*.jsn into the overlay.
#
#   2. DSP runtime (fastrpc_shell* + skels): the PD runtime FastRPC pushes to
#      the DSP, plus a conf.d yaml mapping the DT model -> DSP_LIBRARY_PATH.
#      Sourced from linux-msm/dsp-binaries and installed (pruned to this board)
#      to /usr/share/qcom/sa8775p/Qualcomm/SA8775P-RIDE/dsp/ + conf.d.  The
#      upstream conf.d covers "Lemans Ride"/"SA8775P Ride" but not the EVK board
#      this build targets, so an extra mapping is added from lemans/dsp-conf.d/.
FW_REPO        = https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
# Pin the DSP firmware to the linux-firmware revision the meta-qcom BSP ships
# rather than tracking HEAD, so the staged sa8775p DSP firmware matches the
# validated Qualcomm BSP and does not change underneath us. HEAD (commit
# 3bfa40a, 2026-06-07) carries a newer drop (cdsp0.mbn DSP.AT.1.0.1-00201,
# md5 d270aff2); meta-qcom pins 664f8b6 (2026-02-13, cdsp0.mbn
# DSP.AT.1.0.1-00196, md5 74a618b6).
FW_SRCREV      = 664f8b6adeba
FW_SOC         = qcom/sa8775p
# Venus/iris video-codec firmware. The video-codec@aa00000 node has no
# "qcom,sa8775p-iris" entry in the iris driver's match table, so it binds via
# its fallback compatible "qcom,sm8550-iris" (sm8550_data) and loads VPU3.0
# firmware from the flat qcom/vpu/ path (vpu30_p4.mbn -> vpu30_p4_s7.mbn),
# not the per-SoC qcom/sa8775p/ dir. meta-qcom stages all of qcom/vpu; do the
# same so request_firmware() finds whichever vpu*.mbn the driver asks for.
FW_VPU         = qcom/vpu
FW_CLONE_DIR   = $(BLOBS_DIR)/linux-firmware
DSP_REPO       = https://github.com/linux-msm/dsp-binaries.git
DSP_TAG        = 20260519
DSP_CLONE_DIR  = $(BLOBS_DIR)/dsp-binaries
DSP_BOARD      = SA8775P-RIDE
OVERLAY_DIR    = $(CURDIR)/lemans/overlay
FW_DEST_DIR    = $(OVERLAY_DIR)/lib/firmware/$(FW_SOC)
FW_VPU_DEST    = $(OVERLAY_DIR)/lib/firmware/$(FW_VPU)
DSP_SHARE_DIR  = $(OVERLAY_DIR)/usr/share/qcom

.PHONY: fetch-blobs fetch-blobs-clean

# Ensure the overlay directory exists so the buildroot rootfs assembly never
# fails on a missing BR2_ROOTFS_OVERLAY entry when firmware has not been fetched.
$(OVERLAY_DIR):
	@mkdir -p $(OVERLAY_DIR)

buildroot: linux-firmware | $(OVERLAY_DIR)

# linux-firmware — stage upstream linux-firmware into the buildroot overlay:
#   /lib/firmware/$(FW_SOC)  — per-SoC DSP/remoteproc + QUP blobs
#   /lib/firmware/$(FW_VPU)  — venus/iris video-codec firmware (vpu*.mbn)
# Standalone target, independent of fetch-blobs; 'buildroot' (and hence 'efi')
# depends on it so the firmware is baked into the rootfs/UKI regardless of when
# (or whether) fetch-blobs runs.
.PHONY: linux-firmware linux-firmware-clean
linux-firmware: | $(OVERLAY_DIR)
	@mkdir -p $(BLOBS_DIR)
	@if [ ! -d $(FW_CLONE_DIR)/.git ]; then \
		echo "Cloning linux-firmware (sparse: $(FW_SOC) $(FW_VPU))..."; \
		git clone --filter=blob:none $(FW_REPO) $(FW_CLONE_DIR) && \
		git -C $(FW_CLONE_DIR) sparse-checkout init; \
	fi
	@# Ensure both the per-SoC DSP dir and the shared video-codec dir are in the
	@# sparse checkout. Run unconditionally so pre-existing clones (which only
	@# had $(FW_SOC)) pick up $(FW_VPU) too; sparse-checkout set is idempotent.
	@git -C $(FW_CLONE_DIR) sparse-checkout set $(FW_SOC) $(FW_VPU)
	@# Pin to FW_SRCREV (fetch it if the local clone does not have it yet).
	@git -C $(FW_CLONE_DIR) checkout -q $(FW_SRCREV) 2>/dev/null || \
	 { git -C $(FW_CLONE_DIR) fetch -q origin && \
	   git -C $(FW_CLONE_DIR) checkout -q $(FW_SRCREV); }
	@mkdir -p $(FW_DEST_DIR)
	@cp -a $(FW_CLONE_DIR)/$(FW_SOC)/*.mbn $(FW_CLONE_DIR)/$(FW_SOC)/*.jsn \
	       $(FW_CLONE_DIR)/$(FW_SOC)/*.elf $(FW_DEST_DIR)/
	@# Venus/iris video-codec firmware. cp -a preserves the vpu30_p4.mbn ->
	@# vpu30_p4_s7.mbn symlinks the iris driver resolves via request_firmware().
	@mkdir -p $(FW_VPU_DEST)
	@cp -a $(FW_CLONE_DIR)/$(FW_VPU)/. $(FW_VPU_DEST)/
	@echo "linux-firmware staged in $(FW_DEST_DIR)/ and $(FW_VPU_DEST)/ (pinned $(FW_SRCREV))"

# linux-firmware-clean — remove the cloned linux-firmware repo and the firmware
# staged into the buildroot overlay (per-SoC + video-codec dirs).
linux-firmware-clean:
	rm -rf $(FW_CLONE_DIR) $(FW_DEST_DIR) $(FW_VPU_DEST)

fetch-blobs: $(BLOBS_STAMP)

$(BLOBS_STAMP):
	@mkdir -p $(BLOBS_DIR)
	@# ── Boot binaries ─────────────────────────────────────────────────────────
	@# Firmware ELFs/MBNs/FVs — excludes gpt/zeros (from ptool) and
	@# uefi.elf/tz.mbn (replaced by our own build artifacts).
	@if [ ! -f $(BLOBS_DIR)/QCS9100_bootbinaries_$(BLOBS_VERSION).zip ]; then \
		echo "Downloading QCS9100 boot binaries..."; \
		curl --retry 5 -s -S -L $(BOOTBIN_URL) \
			-o $(BLOBS_DIR)/QCS9100_bootbinaries_$(BLOBS_VERSION).zip || \
			{ rm -f $(BLOBS_DIR)/QCS9100_bootbinaries_$(BLOBS_VERSION).zip; exit 1; }; \
	fi
	@echo "$(BOOTBIN_SHA256)  $(BLOBS_DIR)/QCS9100_bootbinaries_$(BLOBS_VERSION).zip" | sha256sum -c
	@unzip -q -o $(BLOBS_DIR)/QCS9100_bootbinaries_$(BLOBS_VERSION).zip \
		-d $(BLOBS_DIR)/bootbinaries
	@find $(BLOBS_DIR)/bootbinaries -maxdepth 2 \
		\( -name '*.elf' -o -name '*.mbn' -o -name '*.fv' -o -name '*.bin' \
		   -o -name '*.melf' -o -name '*.lzma' -o -name '*.xz' \) \
		! -name 'gpt_*.bin' ! -name 'zeros_*.bin' \
		! -name 'uefi.elf'  ! -name 'tz.mbn' \
		-exec cp -f {} $(BLOBS_DIR)/ \;
	@# ── CDT blob only ─────────────────────────────────────────────────────────
	@# The CDT zip also contains rawprogram3/gpt3/firehose, but those are NOT
	@# used by Yocto — only the cdt*.bin is extracted.  GPT and rawprogram files
	@# for all LUNs (including LUN3) come from qcom-ptool below.
	@if [ ! -f $(BLOBS_DIR)/rb8_core_kit.zip ]; then \
		echo "Downloading CDT (rb8_core_kit)..."; \
		curl --retry 5 -s -S -L $(CDT_URL) \
			-o $(BLOBS_DIR)/rb8_core_kit.zip || \
			{ rm -f $(BLOBS_DIR)/rb8_core_kit.zip; exit 1; }; \
	fi
	@echo "$(CDT_SHA256)  $(BLOBS_DIR)/rb8_core_kit.zip" | sha256sum -c
	@unzip -q -o $(BLOBS_DIR)/rb8_core_kit.zip \
		$(CDT_FILE) -d $(BLOBS_DIR)/cdt
	@cp $(BLOBS_DIR)/cdt/$(CDT_FILE) $(BLOBS_DIR)/cdt.bin
	@# ── Partition tables: GPT bins + rawprogram XMLs via qcom-ptool ───────────
	@# qcom-ptool has no pre-generated files — partitions.conf must be processed
	@# with gen_partition (conf→XML) then ptool (XML→GPT bins + rawprogram XMLs).
	@if [ ! -d $(PTOOL_DIR) ]; then \
		echo "Cloning qcom-ptool..."; \
		git clone --depth=1 $(PTOOL_REPO) $(PTOOL_DIR); \
	fi
	@if [ ! -x $(PTOOL_DIR)/.venv/bin/qcom-ptool ]; then \
		echo "Installing qcom-ptool into venv..."; \
		python3 -m venv $(PTOOL_DIR)/.venv; \
		$(PTOOL_DIR)/.venv/bin/pip install -q $(PTOOL_DIR); \
	fi
	@PTOOL=$(PTOOL_DIR)/.venv/bin/qcom-ptool; \
	PLAT_DIR=$(PTOOL_DIR)/platforms/$(PTOOL_PLATFORM)/ufs; \
	if [ ! -d "$$PLAT_DIR" ]; then \
		echo "ERROR: platform '$(PTOOL_PLATFORM)/ufs' not found in qcom-ptool repo"; \
		echo "       Available: $$(ls $(PTOOL_DIR)/platforms/)"; \
		exit 1; \
	fi; \
	$$PTOOL gen_partition -i "$$PLAT_DIR/partitions.conf" -o "$$PLAT_DIR/partitions.xml"; \
	(cd "$$PLAT_DIR" && $$PTOOL ptool -x partitions.xml); \
	find "$$PLAT_DIR" \
		\( -name 'gpt_*.bin' -o -name 'rawprogram*.xml' \
		   -o -name 'patch*.xml' -o -name 'zeros_*.bin' \) \
		-exec cp -f {} $(BLOBS_DIR)/ \;
	@# ── Strip dtb.bin from rawprogram4.xml ──────────────────────────────────
	@# dtb.bin is a Yocto-built FAT32 image of kernel DTBs.  It is not publicly
	@# available and is not needed for UKI-based boot (DTB is embedded in uki.efi).
	@# Removing its entries prevents QDL from failing on a missing file.
	@sed -i '/filename="dtb\.bin"/d' $(BLOBS_DIR)/rawprogram4.xml
	@# Remoteproc/QUP firmware (qcom/sa8775p) is staged by the standalone
	@# 'linux-firmware' target (a prerequisite of buildroot), not here.
	@# ── DSP runtime (fastrpc_shell + skels) → rootfs overlay ────────────────
	@# Clone linux-msm/dsp-binaries at the pinned tag and install ONLY this
	@# board's files (via the repo's install.sh, which maps the versioned source
	@# dirs into dsp/{adsp,cdsp,...} and pulls licenses from WHENCE), plus the
	@# conf.d yamls that map the DT model -> DSP_LIBRARY_PATH.
	@if [ ! -d $(DSP_CLONE_DIR)/.git ]; then \
		echo "Cloning dsp-binaries ($(DSP_TAG))..."; \
		git clone --depth=1 --branch $(DSP_TAG) $(DSP_REPO) $(DSP_CLONE_DIR); \
	fi
	@mkdir -p $(DSP_SHARE_DIR)/conf.d
	@cd $(DSP_CLONE_DIR) && \
		grep '^Install:.*$(DSP_BOARD)' config.txt > .board-config.txt && \
		./scripts/install.sh .board-config.txt $(DSP_SHARE_DIR)
	@install -m 0644 $(DSP_CLONE_DIR)/conf.d/*.yaml $(DSP_SHARE_DIR)/conf.d/
	@# Add the EVK board mapping the upstream conf.d does not cover.
	@install -m 0644 $(CURDIR)/lemans/dsp-conf.d/lemans-evk.yaml $(DSP_SHARE_DIR)/conf.d/
	@echo "DSP runtime staged in $(DSP_SHARE_DIR)/ (board: $(DSP_BOARD))"
	@touch $(BLOBS_STAMP)
	@echo "Blobs ready in $(BLOBS_DIR)/"

fetch-blobs-clean:
	@# Remove only generated staging — NOT $(OVERLAY_DIR) itself, which also
	@# holds version-controlled overlay files (etc/init.d/*, usr/bin/qcom-tests).
	rm -rf $(BLOBS_DIR) $(FW_DEST_DIR) $(FW_VPU_DEST) $(DSP_SHARE_DIR)

################################################################################
# Yocto / kas — OE no-distro BSP image for iq-9075-evk
#
# Clones meta-qcom (if not already present), applies the local patches in
# lemans/patches/ (currently: add fastrpc-tests to the iq-9075-evk image), and
# builds the Qualcomm BSP image via kas (meta-qcom BSP + OE no-distro build).
#
# Generates:
#   build/tmp/deploy/images/iq-9075-evk/
#
# NOTE: flash-yocto flashes directly from $(YOCTO_FLASH) (the .qcomflash dir).
#       flash-loader/flash-kernel do NOT read from here — they stage stock
#       firmware strictly from lemans/blobs/ (make fetch-blobs).
################################################################################
META_QCOM_DIR  ?= $(CURDIR)/yocto/meta-qcom
YOCTO_DEPLOY    = $(CURDIR)/yocto/build/tmp/deploy/images/iq-9075-evk
YOCTO_FLASH     = $(YOCTO_DEPLOY)/core-image-base-iq-9075-evk.rootfs.qcomflash

# Local meta-qcom patches (lemans/patches/meta-qcom/*.patch) applied to the
# fresh clone before building. 0001 pulls the fastrpc recipe's -tests subpackage
# (fastrpc_test + DSP skels) into the iq-9075-evk image so the FastRPC/PAS DSP
# path can be validated; it is not yet upstream, so we carry it here and apply
# it in the 'yocto' target.
META_QCOM_PATCH_DIR = $(CURDIR)/lemans/patches/meta-qcom

.PHONY: yocto flash-yocto yocto-clean

yocto:
	@echo "WARNING: this build fetches and compiles a full Yocto stack."
	@echo "         It can take several hours depending on your machine and network."
	@echo "         For build issues consult: https://github.com/qualcomm-linux/meta-qcom/blob/main/README.md"
	@echo ""
	@if [ ! -d $(META_QCOM_DIR) ]; then \
		mkdir yocto; \
		git clone https://github.com/qualcomm-linux/meta-qcom $(META_QCOM_DIR); \
	fi
	@# Apply local meta-qcom patches not yet upstream (idempotent: already-applied
	@# patches are skipped; a patch that neither applies nor is present aborts —
	@# meta-qcom may have diverged, refresh the patch).
	$(call apply-overlays,$(META_QCOM_DIR),$(META_QCOM_PATCH_DIR))
	KAS_BUILD_DIR=$(CURDIR)/yocto/build kas build yocto/meta-qcom/ci/iq-9075-evk.yml
	mkdir -p $(CURDIR)/yocto/images
	ln -sfn $(YOCTO_FLASH) $(CURDIR)/yocto/images/iq-9075-evk.qcomflash
	@echo ""
	@echo "Yocto build complete."
	@echo ""
	@echo "Flash artifacts are at:"
	@echo "  $(YOCTO_DEPLOY)"
	@echo ""
	@echo "You must manually copy them to lemans/output/ before flashing:"
	@echo "  cp -r $(YOCTO_DEPLOY)/. $(CURDIR)/lemans/output/"
	@echo ""

# flash-yocto — Flash the complete, unmodified Yocto release image (all 6 LUNs).
#
# Programs the pristine $(YOCTO_FLASH) qcomflash directory as-is — bootloader,
# firmware, efi.bin and rootfs.img — to verify the default hardware against the
# released BSP.  No local build artifacts are substituted.
#
# NOTE: this overwrites whatever 'make flash-loader' / 'make flash-kernel'
# installed.  Re-run those afterward to restore your custom build.
flash-yocto:
	@if [ ! -f "$(YOCTO_FLASH)/prog_firehose_ddr.elf" ]; then \
		echo "ERROR: Yocto flash image not found at $(YOCTO_FLASH)"; \
		echo "       Run 'make yocto' first to build the release image."; \
		exit 1; \
	fi
	cd $(YOCTO_FLASH) && \
		qdl --debug prog_firehose_ddr.elf \
		    rawprogram0.xml rawprogram1.xml rawprogram2.xml \
		    rawprogram3.xml rawprogram4.xml rawprogram5.xml \
		    patch0.xml patch1.xml patch2.xml patch3.xml patch4.xml patch5.xml

yocto-clean:
	rm -rf $(META_QCOM_DIR)

################################################################################
# edl-package — Flat image directory for Windows EDL flashing (PCATApp / QFIL)
#
# Assembles every file that PCATApp or QFIL needs into a single flat directory:
#   lemans/output/edl-package/
#
# File resolution order (EDL packaging only):
#   lemans/input/  →  YOCTO_FLASH  →  BLOBS_DIR
#
# After running this target, copy the directory to your Windows machine and:
#   PCATApp: File → Load XML → select rawprogram0.xml (or rawprogram4.xml, …)
#   QFIL:    Flat Build → browse to edl-package/ → select rawprogram XMLs
#
# The firehose programmer (prog_firehose_ddr.elf) is included so the tool can
# load it automatically when the device is in EDL (9008) mode.
#
# Two variants of rawprogram4.xml are produced:
#   rawprogram4.xml          — original (qupfw slots empty)
#   rawprogram4-qupfw.xml    — qupfw_a/b filled with qupv3fw.elf (recommended)
# Use rawprogram4-qupfw.xml when flashing LUN4 to avoid GENI SE boot storms.
################################################################################
EDL_PKG_DIR = $(CURDIR)/lemans/output/edl-package

# Everything PCATApp/QFIL needs for a full LUN0–5 flash, resolved from
# input/ → YOCTO_FLASH → blobs/. All partition tables + rawprogram + patch XMLs,
# the boot-firmware payload and every zero-fill file.
EDL_PKG_FILES = \
	$(FIREHOSE) \
	$(foreach n,0 1 2 3 4 5,$(call lun-raw,$(n)) $(call lun-patch,$(n)) $(call lun-tables,$(n))) \
	$(BOOT_FW_FILES) $(ZEROS_FILES)

.PHONY: edl-package edl-package-clean

edl-package:
	@mkdir -p $(EDL_PKG_DIR)
	@# ── Resolve every required file into the package directory ─────────────────
	$(call stage-flash-files,$(EDL_PKG_FILES),$(EDL_PKG_DIR))
	@# ── Built artifacts: tz.mbn (signed SPL), uefi.elf, efi.bin ────────────
	@for f in tz.mbn uefi.elf efi.bin; do \
	    if [ -f "$(CURDIR)/lemans/output/$$f" ]; then \
	        cp "$(CURDIR)/lemans/output/$$f" "$(EDL_PKG_DIR)/$$f"; \
	    elif [ -f "$(CURDIR)/lemans/input/$$f" ]; then \
	        cp "$(CURDIR)/lemans/input/$$f" "$(EDL_PKG_DIR)/$$f"; \
	    else \
	        echo "WARNING: $$f not found in lemans/output/ or lemans/input/ — run 'make all' first"; \
	    fi; \
	done
	@# ── QUP GENI SE firmware (qupv3fw.elf) ───────────────────────────────────
	@if   [ -f "$(CURDIR)/lemans/input/qupv3fw.elf" ]; then \
	    cp "$(CURDIR)/lemans/input/qupv3fw.elf" "$(EDL_PKG_DIR)/qupv3fw.elf"; \
	elif [ -f "$(FW_CLONE_DIR)/$(FW_SOC)/qupv3fw.elf" ]; then \
	    cp "$(FW_CLONE_DIR)/$(FW_SOC)/qupv3fw.elf" "$(EDL_PKG_DIR)/qupv3fw.elf"; \
	elif [ -f "$(YOCTO_FLASH)/qupv3fw.elf" ]; then \
	    cp "$(YOCTO_FLASH)/qupv3fw.elf" "$(EDL_PKG_DIR)/qupv3fw.elf"; \
	else \
	    echo "WARNING: qupv3fw.elf not found — run 'make linux-firmware' or 'make fetch-blobs'"; \
	fi
	@# ── rawprogram4: backup original, promote qupfw variant as default ────────
	@if [ -f "$(EDL_PKG_DIR)/rawprogram4.xml" ]; then \
	    mv "$(EDL_PKG_DIR)/rawprogram4.xml" "$(EDL_PKG_DIR)/rawprogram4.xml.backup"; \
	    $(call patch-qupfw,$(EDL_PKG_DIR)/rawprogram4.xml.backup,$(EDL_PKG_DIR)/rawprogram4.xml); \
	fi
	@# ── rawprogram0: backup original, promote kernel-only variant as default ──
	@if [ -f "$(EDL_PKG_DIR)/rawprogram0.xml" ]; then \
	    mv "$(EDL_PKG_DIR)/rawprogram0.xml" "$(EDL_PKG_DIR)/rawprogram0.xml.backup"; \
	    $(call strip-rootfs,$(EDL_PKG_DIR)/rawprogram0.xml.backup,$(EDL_PKG_DIR)/rawprogram0.xml); \
	fi
	@echo ""
	@echo "EDL package assembled at: $(EDL_PKG_DIR)/"
	@echo ""
	@echo "Copy the entire directory to your Windows machine, then point PCATApp at:"
	@echo "  Programmer: prog_firehose_ddr.elf"
	@echo "  XMLs:       rawprogram0.xml rawprogram1.xml rawprogram2.xml"
	@echo "              rawprogram3.xml rawprogram4.xml rawprogram5.xml"
	@echo "              patch0.xml"

edl-package-clean:
	rm -rf $(EDL_PKG_DIR)

################################################################################
# edl-bootloader — Minimal EDL package: bootloaders only (no efi.bin/rootfs)
#
# Flashes LUN1–4 only:
#   LUN1/2: XBL, XBL config
#   LUN3:   CDT
#   LUN4:   tz.mbn, uefi.elf, aop, shrm, hyp, devcfg, cpucp, imagefv, …
#
# This is the fast re-flash path when only OP-TEE/U-Boot changed.
# efi.bin (LUN0) and persist (LUN5) are untouched.
#
# OP-TEE is rebuilt with full debug logging (LOG_LEVEL=4, DEBUG=1) so that
# secure-world traces are visible over the UART during bring-up.  The
# production build (LOG_LEVEL=1) is restored afterward so that lemans/output/
# is left in the standard quiet state.
################################################################################
EDL_BL_DIR = $(CURDIR)/lemans/output/edl-bootloader

# Bootloader-only set (LUN1–4): partition tables + rawprogram + patch XMLs, the
# boot-firmware payload and zero-fill files. Resolved from input/ → YOCTO_FLASH
# → blobs/. No LUN0 (kernel) or LUN5 (persist).
EDL_BL_FILES = \
	$(FIREHOSE) \
	$(foreach n,1 2 3 4,$(call lun-raw,$(n)) $(call lun-patch,$(n)) $(call lun-tables,$(n))) \
	$(BOOT_FW_FILES) $(ZEROS_FILES)

.PHONY: edl-bootloader edl-bootloader-clean

edl-bootloader:
	@echo "Building OP-TEE with debug flags for edl-bootloader..."
	$(MAKE) optee-os CFG_TEE_CORE_LOG_LEVEL=4 DEBUG=1 CFG_DEBUG_INFO=y
	$(MAKE) u-boot
	$(MAKE) spl
	@mkdir -p $(EDL_BL_DIR)
	$(call stage-flash-files,$(EDL_BL_FILES),$(EDL_BL_DIR))
	@# Copy the debug-built tz.mbn (signed SPL) and uefi.elf into the package
	cp $(CURDIR)/lemans/output/tz.mbn     $(EDL_BL_DIR)/tz.mbn
	cp $(CURDIR)/lemans/output/uefi.elf $(EDL_BL_DIR)/uefi.elf
	@# Restore production OP-TEE build (LOG_LEVEL=1) and re-sign SPL
	@echo "Restoring production OP-TEE build (LOG_LEVEL=1)..."
	$(MAKE) optee-os
	$(MAKE) tfa
	$(MAKE) u-boot
	$(MAKE) spl
	@# qupv3fw.elf + patch rawprogram4 to populate qupfw_a/b
	@if   [ -f "$(CURDIR)/lemans/input/qupv3fw.elf" ]; then \
	    cp "$(CURDIR)/lemans/input/qupv3fw.elf" "$(EDL_BL_DIR)/qupv3fw.elf"; \
	elif [ -f "$(FW_CLONE_DIR)/$(FW_SOC)/qupv3fw.elf" ]; then \
	    cp "$(FW_CLONE_DIR)/$(FW_SOC)/qupv3fw.elf" "$(EDL_BL_DIR)/qupv3fw.elf"; \
	elif [ -f "$(YOCTO_FLASH)/qupv3fw.elf" ]; then \
	    cp "$(YOCTO_FLASH)/qupv3fw.elf" "$(EDL_BL_DIR)/qupv3fw.elf"; \
	else \
	    echo "WARNING: qupv3fw.elf not found — run 'make linux-firmware'"; \
	fi
	@if [ -f "$(EDL_BL_DIR)/rawprogram4.xml" ]; then \
	    mv "$(EDL_BL_DIR)/rawprogram4.xml" "$(EDL_BL_DIR)/rawprogram4.xml.backup"; \
	    $(call patch-qupfw,$(EDL_BL_DIR)/rawprogram4.xml.backup,$(EDL_BL_DIR)/rawprogram4.xml); \
	fi
	@echo ""
	@echo "EDL bootloader package assembled at: $(EDL_BL_DIR)/"
	@echo ""
	@echo "Copy the entire directory to your Windows machine, then point PCATApp at:"
	@echo "  Programmer: prog_firehose_ddr.elf"
	@echo "  XMLs:       rawprogram1.xml rawprogram2.xml rawprogram3.xml rawprogram4.xml"
	@echo "              patch1.xml patch2.xml patch3.xml patch4.xml"

edl-bootloader-clean:
	rm -rf $(EDL_BL_DIR)
