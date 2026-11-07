################################################################################
#
# xen_guest_ext
#
# A small Xen guest in /opt/xen-guest for the Xen tests of the suite
# (test-definitions automated/linux/xen):
#   Image                 Linux LTS, allnoconfig plus linux.config: Xen
#                         guest with the hvc0 console, the FF-A transport
#                         and the OP-TEE driver, initramfs
#   initramfs.cpio.gz     init (prints the ready and TEE lines, stays up),
#                         /sbin/poweroff (prints the poweroff line),
#                         BusyBox and its libraries from the target
#
################################################################################

XEN_GUEST_EXT_VERSION = 6.18.54
XEN_GUEST_EXT_SOURCE = linux-$(XEN_GUEST_EXT_VERSION).tar.xz
XEN_GUEST_EXT_SITE = https://cdn.kernel.org/pub/linux/kernel/v6.x
XEN_GUEST_EXT_LICENSE = GPL-2.0
XEN_GUEST_EXT_LICENSE_FILES = COPYING
XEN_GUEST_EXT_DEPENDENCIES = busybox host-bison host-flex

XEN_GUEST_EXT_DEST = /opt/xen-guest
XEN_GUEST_EXT_MAKE_OPTS = \
	ARCH=arm64 \
	CROSS_COMPILE="$(TARGET_CROSS)" \
	HOSTCC="$(HOSTCC)"
XEN_GUEST_EXT_CONFIGS = $(shell sed -n 's/^CONFIG_\([A-Z0-9_]*\)=y$$/\1/p' \
	$(XEN_GUEST_EXT_PKGDIR)/linux.config)
# The initramfs is staged as the KVM test guest's is.
XEN_GUEST_EXT_INITRAMFS_SH = $(BR2_EXTERNAL_OPTEE_PATH)/package/kvm_guest_ext/initramfs.sh

define XEN_GUEST_EXT_CONFIGURE_CMDS
	$(TARGET_MAKE_ENV) KCONFIG_ALLCONFIG=$(XEN_GUEST_EXT_PKGDIR)/linux.config \
		$(MAKE) -C $(@D) $(XEN_GUEST_EXT_MAKE_OPTS) allnoconfig
	for c in $(XEN_GUEST_EXT_CONFIGS); do \
		grep -qx "CONFIG_$$c=y" $(@D)/.config || \
		{ echo "xen_guest_ext: CONFIG_$$c is not set"; exit 1; }; \
	done
endef

define XEN_GUEST_EXT_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(XEN_GUEST_EXT_MAKE_OPTS) Image
	$(XEN_GUEST_EXT_INITRAMFS_SH) $(TARGET_READELF) "$(TARGET_STRIP) --strip-unneeded" \
		$(TARGET_DIR) $(XEN_GUEST_EXT_PKGDIR)/init $(@D)/initramfs \
		> $(@D)/initramfs.list
	printf 'dir /sbin 0755 0 0\nfile /sbin/poweroff %s 0755 0 0\n' \
		$(XEN_GUEST_EXT_PKGDIR)/poweroff >> $(@D)/initramfs.list
	$(@D)/usr/gen_init_cpio $(@D)/initramfs.list > $(@D)/initramfs.cpio
	gzip -9nf $(@D)/initramfs.cpio
endef

define XEN_GUEST_EXT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/arch/arm64/boot/Image \
		$(TARGET_DIR)$(XEN_GUEST_EXT_DEST)/Image
	$(INSTALL) -D -m 0644 $(@D)/initramfs.cpio.gz \
		$(TARGET_DIR)$(XEN_GUEST_EXT_DEST)/initramfs.cpio.gz
endef

$(eval $(generic-package))
