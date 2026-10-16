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
#   gpu-render  egl-readback (egl_readback_ext) on Mesa freedreno with EGL,
#               OpenGL ES and GBM
#   inference   (GPU and CPU entries) tflite-run (tflite_run_ext) on
#               TensorFlow Lite with XNNPACK and the GPU delegate, OpenCL from
#               Mesa RustiCL, clinfo
# Tests whose tool is missing report skip, except optee-xtest and memtester,
# which fail, and kvm-unit-tests, which reports nothing (its runner then
# tries to fetch and build a copy).
################################################################################
TEST ?= y

QCOM_TESTS_ALL = boot-fingerprint boot-handoff cpu-features cpu-hotplug \
		 cpufreq-policy kernel-health maxcpus memtest remoteproc-smoke \
		 remoteproc-restart fastrpc optee-xtest alsa-dsp-restart \
		 memtester kvm-unit-tests kvm-guest gpu-render
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

################################################################################
# GPU userspace (gpu-render, inference)
#
# The GPU firmware (SQE microcode, GMU firmware) comes from the board
# makefile; the EL2 device trees disable the zap shader, so none is needed.
# The rootfs is an initramfs: qcom/test/gpu/post-build.sh removes the
# developer tools and data the GPU packages install that nothing on the
# target uses (other libclc targets, libclang, the SPIRV tools, the Vulkan
# registry, flatc).
#
# qcom/test/gpu/buildroot-patches/*.patch are applied in order to the
# Buildroot tree (common.xml pins 2025.05) before it builds. The last patch
# that reverses cleanly marks the end of what is already applied (a later
# patch can change the context of an earlier one, so earlier ones need not
# reverse); the patches after it are applied.
#   0001  Mesa 25.1.8 from Buildroot 2025.08 (Mesa 25.0 does not know the
#         Adreno 623)
#   0002  opencl-headers and
#   0003  opencl-icd-loader, from Buildroot 2025.08
#   0004  Mesa RustiCL from Buildroot 2025.08
#   0005  RustiCL on freedreno
#   0006  the TensorFlow Lite GPU delegate (OpenCL backend)
#   0007  XNNPACK on AArch64 (TensorFlow Lite's CPU path)
#   0008  SPIRV-Headers and SPIRV-Tools 1.3.280.0 (2024.1, which Mesa's
#         OpenCL C compiler needs) and a SPIRV-LLVM-Translator v15 that
#         builds against them
#   0009  the TensorFlow Lite GPU delegate aligns image pitch in pixels, as
#         OpenCL defines it (it divides by the bytes per pixel on Adreno,
#         which Mesa RustiCL rejects once it offers images on buffers)
#   0010  rust-bindgen 0.72.0 from Buildroot 2025.08 (Mesa 25.2 RustiCL
#         needs 0.71.1 or newer)
#   0011  Mesa 25.2.8: the first series whose freedreno knows the Adreno
#         702, so every board shares one Mesa
# An existing output directory keeps the Mesa it built without OpenCL:
# make mesa3d-dirclean there after enabling inference.
################################################################################
ifneq ($(call qcom-test,gpu-render inference),)
BR2_PACKAGE_MESA3D                          ?= y
BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_FREEDRENO ?= y
BR2_PACKAGE_MESA3D_OPENGL_EGL               ?= y
BR2_PACKAGE_MESA3D_OPENGL_ES                ?= y
BR2_PACKAGE_MESA3D_GBM                      ?= y
BR2_PACKAGE_LIBDRM                          ?= y
BR2_ROOTFS_POST_BUILD_SCRIPT                += $(CURDIR)/qcom/test/gpu/post-build.sh

QCOM_TEST_GPU_BR_PATCHES ?= $(sort $(wildcard $(CURDIR)/qcom/test/gpu/buildroot-patches/*.patch))

.PHONY: test-gpu-buildroot-patches
test-gpu-buildroot-patches:
	@n=0; i=0; \
	for p in $(QCOM_TEST_GPU_BR_PATCHES); do \
		i=$$((i + 1)); \
		git -C $(ROOT)/buildroot apply -R --check $$p 2>/dev/null && n=$$i; \
	done; \
	i=0; \
	for p in $(QCOM_TEST_GPU_BR_PATCHES); do \
		i=$$((i + 1)); \
		if [ $$i -le $$n ]; then \
			echo "buildroot: $${p##*/} already applied"; \
		else \
			echo "buildroot: applying $${p##*/}"; \
			git -C $(ROOT)/buildroot apply $$p || exit 1; \
		fi; \
	done

buildroot: test-gpu-buildroot-patches
endif

ifneq ($(call qcom-test,gpu-render),)
BR2_PACKAGE_EGL_READBACK_EXT ?= y
endif

ifneq ($(call qcom-test,inference),)
BR2_PACKAGE_MESA3D_LLVM         ?= y
BR2_PACKAGE_MESA3D_OPENCL       ?= y
BR2_PACKAGE_MESA3D_RUSTICL      ?= y
BR2_PACKAGE_CLINFO              ?= y
BR2_PACKAGE_TENSORFLOW_LITE     ?= y
BR2_PACKAGE_TENSORFLOW_LITE_GPU ?= y
BR2_PACKAGE_TFLITE_RUN_EXT      ?= y
endif

endif
