################################################################################
#
# kvm_unit_tests_ext
#
# kvm-unit-tests for kvmtool, installed with run_tests.sh in /opt/kvm-unit-tests
# (where test-definitions' kvm-unit-tests test looks for a prebuilt copy).
# Buildroot's kvm-unit-tests package installs standalone tests for QEMU and,
# in 2025.05, is not available for a Cortex-A53 target. kvmtool support in
# run_tests.sh is new in v2025-07-31.
#
################################################################################

KVM_UNIT_TESTS_EXT_VERSION = 2026-04-17
KVM_UNIT_TESTS_EXT_SOURCE = kvm-unit-tests-v$(KVM_UNIT_TESTS_EXT_VERSION).tar.bz2
KVM_UNIT_TESTS_EXT_SITE = https://gitlab.com/kvm-unit-tests/kvm-unit-tests/-/archive/v$(KVM_UNIT_TESTS_EXT_VERSION)
KVM_UNIT_TESTS_EXT_LICENSE = GPL-2.0, LGPL-2.0
KVM_UNIT_TESTS_EXT_LICENSE_FILES = COPYRIGHT LICENSE

KVM_UNIT_TESTS_EXT_DEST = /opt/kvm-unit-tests

# No stack decoding on the target (it needs python3 and addr2line). The run
# scripts read HOST (the machine the tests run on, which configure takes
# from the build machine) and the errata file from config.mak at run time.
define KVM_UNIT_TESTS_EXT_CONFIGURE_CMDS
	cd $(@D) && ./configure \
		--arch=arm64 \
		--processor="$(GCC_TARGET_CPU)" \
		--cross-prefix="$(TARGET_CROSS)" \
		--target=kvmtool \
		--disable-pretty-print-stacks \
		--disable-werror
	sed -i -e 's|^HOST=.*|HOST=aarch64|' \
		-e 's|^ERRATATXT=.*|ERRATATXT=$(KVM_UNIT_TESTS_EXT_DEST)/errata.txt|' \
		$(@D)/config.mak
endef

define KVM_UNIT_TESTS_EXT_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)
	echo v$(KVM_UNIT_TESTS_EXT_VERSION) > $(@D)/build-head
endef

define KVM_UNIT_TESTS_EXT_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)$(KVM_UNIT_TESTS_EXT_DEST)/arm
	cp -a $(@D)/scripts $(TARGET_DIR)$(KVM_UNIT_TESTS_EXT_DEST)/
	$(INSTALL) -m 0755 $(@D)/run_tests.sh $(TARGET_DIR)$(KVM_UNIT_TESTS_EXT_DEST)/
	$(INSTALL) -m 0644 -t $(TARGET_DIR)$(KVM_UNIT_TESTS_EXT_DEST) \
		$(@D)/config.mak $(@D)/errata.txt $(@D)/build-head
	$(INSTALL) -m 0755 $(@D)/arm/run $(TARGET_DIR)$(KVM_UNIT_TESTS_EXT_DEST)/arm/
	$(INSTALL) -m 0644 -t $(TARGET_DIR)$(KVM_UNIT_TESTS_EXT_DEST)/arm \
		$(@D)/arm/unittests.cfg $(@D)/arm/*.flat
endef

$(eval $(generic-package))
