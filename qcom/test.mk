################################################################################
# qcom/test.mk: the root filesystem the open boot stack test suite needs
#
# The suite is the open-boot-stack plan of test-definitions
# (automated/linux/*, run by flash-lava-test). Each Qualcomm board makefile
# includes this file after common.mk, so every board's rootfs carries what
# the tests need and the board makefile only describes the board.
#
#   TEST        y (default): put the packages of the tests in QCOM_TESTS in
#               the rootfs; n: leave them out (xtest stays: common.mk
#               selects it)
#   QCOM_TESTS  the tests to provide for (default: QCOM_TESTS_ALL); a board
#               can narrow it to what its plan runs
#
# What each test needs on a BusyBox rootfs, from its script:
#   boot-fingerprint, boot-handoff, cpu-features, kernel-health, maxcpus,
#   memtest, remoteproc-smoke, remoteproc-restart
#               nothing beyond BusyBox (kernel options and firmware come
#               from the board)
#   cpufreq-policy, cpu-hotplug
#               stress-ng (the load phase; skipped without it)
#   fastrpc     fastrpc_test (fastrpc)
#   optee-xtest xtest and tee-supplicant (optee_test_ext, optee_client_ext)
#   alsa-dsp-restart
#               aplay and amixer (alsa-utils)
#   memtester   memtester
#   kvm-unit-tests
#               the KVM unit tests for kvmtool in /opt/kvm-unit-tests, with
#               lkvm and bash (kvm_unit_tests_ext)
#   kvm-guest   lkvm, socat (kvmtool reads console input from a terminal
#               only) and the guest in /opt/kvm-guest (kvm_guest_ext)
# Tests whose tool is missing report skip, except optee-xtest and memtester,
# which fail, and kvm-unit-tests, which reports nothing (its runner then
# tries to fetch and build a copy).
################################################################################
TEST ?= y

QCOM_TESTS_ALL = boot-fingerprint boot-handoff cpu-features cpu-hotplug \
		 cpufreq-policy kernel-health maxcpus memtest remoteproc-smoke \
		 remoteproc-restart fastrpc optee-xtest alsa-dsp-restart \
		 memtester kvm-unit-tests kvm-guest
QCOM_TESTS ?= $(QCOM_TESTS_ALL)

ifeq ($(TEST),y)
# qcom-test <test>...: non-empty if QCOM_TESTS names any of them
qcom-test = $(filter $(1),$(QCOM_TESTS))

ifneq ($(call qcom-test,cpufreq-policy cpu-hotplug),)
BR2_PACKAGE_STRESS_NG ?= y
endif

ifneq ($(call qcom-test,fastrpc),)
BR2_PACKAGE_FASTRPC_EXT ?= y
endif

ifneq ($(call qcom-test,optee-xtest),)
BR2_PACKAGE_OPTEE_TEST_EXT ?= y
endif

ifneq ($(call qcom-test,alsa-dsp-restart),)
BR2_PACKAGE_ALSA_UTILS        ?= y
BR2_PACKAGE_ALSA_UTILS_APLAY  ?= y
BR2_PACKAGE_ALSA_UTILS_AMIXER ?= y
endif

ifneq ($(call qcom-test,memtester),)
BR2_PACKAGE_MEMTESTER ?= y
endif

ifneq ($(call qcom-test,kvm-unit-tests kvm-guest),)
BR2_PACKAGE_KVMTOOL ?= y
endif

# run_tests.sh is bash, which Buildroot offers only with
# BUSYBOX_SHOW_OTHERS.
ifneq ($(call qcom-test,kvm-unit-tests),)
BR2_PACKAGE_BUSYBOX_SHOW_OTHERS ?= y
BR2_PACKAGE_KVM_UNIT_TESTS_EXT  ?= y
endif

ifneq ($(call qcom-test,kvm-guest),)
BR2_PACKAGE_SOCAT         ?= y
BR2_PACKAGE_KVM_GUEST_EXT ?= y
endif

endif
