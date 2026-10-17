################################################################################
#
# idregs_arm64_ext
#
# idregs-arm64 for test-definitions' cpu-features test, built from its
# source in the test-definitions tree (automated/linux/cpu-features) and
# installed in /usr/bin, where the test looks for it. It is a static nolibc
# binary built against nolibc and the arm64 UAPI headers, both from a Linux
# release tarball (the toolchain's kernel headers lack linux/mount.h, which
# nolibc includes).
#
################################################################################

IDREGS_ARM64_EXT_VERSION = 4ddcfe81845497eb602d458dbe9a3066eb5e56b5
IDREGS_ARM64_EXT_SITE = https://github.com/EmbeddedAndroid/test-definitions.git
IDREGS_ARM64_EXT_SITE_METHOD = git
IDREGS_ARM64_EXT_LICENSE = BSD-2-Clause
IDREGS_ARM64_EXT_LICENSE_FILES = automated/linux/cpu-features/idregs.c

IDREGS_ARM64_EXT_LINUX_VERSION = 6.18.54
IDREGS_ARM64_EXT_LINUX = linux-$(IDREGS_ARM64_EXT_LINUX_VERSION)
IDREGS_ARM64_EXT_EXTRA_DOWNLOADS = \
	https://cdn.kernel.org/pub/linux/kernel/v6.x/$(IDREGS_ARM64_EXT_LINUX).tar.xz

define IDREGS_ARM64_EXT_BUILD_CMDS
	$(call suitable-extractor,$(IDREGS_ARM64_EXT_LINUX).tar.xz) \
		$(IDREGS_ARM64_EXT_DL_DIR)/$(IDREGS_ARM64_EXT_LINUX).tar.xz | \
		$(TAR) -x -C $(@D)
	$(MAKE) -C $(@D)/$(IDREGS_ARM64_EXT_LINUX) ARCH=arm64 HOSTCC="$(HOSTCC)" \
		INSTALL_HDR_PATH=$(@D)/uapi headers_install
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/automated/linux/cpu-features \
		CROSS_COMPILE="$(TARGET_CROSS)" \
		NOLIBC=$(@D)/$(IDREGS_ARM64_EXT_LINUX)/tools/include/nolibc \
		UAPI=$(@D)/uapi/include idregs-arm64
endef

define IDREGS_ARM64_EXT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/automated/linux/cpu-features/idregs-arm64 \
		$(TARGET_DIR)/usr/bin/idregs-arm64
endef

$(eval $(generic-package))
