################################################################################
#
# kvm_guest_ext
#
# A small KVM guest in /opt/kvm-guest for the kvm-guest test:
#   Image                 Linux LTS, allnoconfig plus linux.config: virtio
#                         console over PCI or MMIO, initramfs, PSCI power off
#   initramfs.cpio.gz     init (prints a ready line, runs a shell on the
#                         console), BusyBox and its libraries from the target
#
################################################################################

KVM_GUEST_EXT_VERSION = 6.18.54
KVM_GUEST_EXT_SOURCE = linux-$(KVM_GUEST_EXT_VERSION).tar.xz
KVM_GUEST_EXT_SITE = https://cdn.kernel.org/pub/linux/kernel/v6.x
KVM_GUEST_EXT_LICENSE = GPL-2.0
KVM_GUEST_EXT_LICENSE_FILES = COPYING
KVM_GUEST_EXT_DEPENDENCIES = busybox host-bison host-flex

KVM_GUEST_EXT_DEST = /opt/kvm-guest
KVM_GUEST_EXT_MAKE_OPTS = \
	ARCH=arm64 \
	CROSS_COMPILE="$(TARGET_CROSS)" \
	HOSTCC="$(HOSTCC)"
KVM_GUEST_EXT_CONFIGS = $(shell sed -n 's/^CONFIG_\([A-Z0-9_]*\)=y$$/\1/p' \
	$(KVM_GUEST_EXT_PKGDIR)/linux.config)

define KVM_GUEST_EXT_CONFIGURE_CMDS
	$(TARGET_MAKE_ENV) KCONFIG_ALLCONFIG=$(KVM_GUEST_EXT_PKGDIR)/linux.config \
		$(MAKE) -C $(@D) $(KVM_GUEST_EXT_MAKE_OPTS) allnoconfig
	for c in $(KVM_GUEST_EXT_CONFIGS); do \
		grep -qx "CONFIG_$$c=y" $(@D)/.config || \
		{ echo "kvm_guest_ext: CONFIG_$$c is not set"; exit 1; }; \
	done
endef

# gen_init_cpio is built with the kernel (usr/), and makes the device node
# without root. The target files are stripped at target-finalize, after this
# package, so initramfs.sh strips its copies.
define KVM_GUEST_EXT_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(KVM_GUEST_EXT_MAKE_OPTS) Image
	$(KVM_GUEST_EXT_PKGDIR)/initramfs.sh $(TARGET_READELF) "$(TARGET_STRIP) --strip-unneeded" \
		$(TARGET_DIR) $(KVM_GUEST_EXT_PKGDIR)/init $(@D)/initramfs \
		> $(@D)/initramfs.list
	$(@D)/usr/gen_init_cpio $(@D)/initramfs.list > $(@D)/initramfs.cpio
	gzip -9nf $(@D)/initramfs.cpio
endef

define KVM_GUEST_EXT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/arch/arm64/boot/Image \
		$(TARGET_DIR)$(KVM_GUEST_EXT_DEST)/Image
	$(INSTALL) -D -m 0644 $(@D)/initramfs.cpio.gz \
		$(TARGET_DIR)$(KVM_GUEST_EXT_DEST)/initramfs.cpio.gz
endef

$(eval $(generic-package))
