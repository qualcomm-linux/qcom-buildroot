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
#   boot-fingerprint, boot-handoff, kernel-health, maxcpus, memtest,
#   remoteproc-smoke, remoteproc-restart
#               nothing beyond BusyBox (kernel options and firmware come
#               from the board)
#   cpufreq-policy, cpu-hotplug
#               stress-ng (the load phase; skipped without it)
#   cpu-features
#               idregs-arm64 (idregs_arm64_ext); without it the test builds
#               it, which needs a compiler on the target, or skips
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
#   qcom-tests  the interactive runner /usr/bin/qcom-tests (FastRPC calls, a
#               V4L2 codec round trip, a CPU soak): fastrpc_test, stress-ng,
#               v4l2-ctl and GStreamer with the V4L2 codec elements
#   gpu-render  egl-readback (egl_readback_ext) on Mesa freedreno with EGL,
#               OpenGL ES and GBM
#   video-codec ffmpeg with the V4L2 mem2mem decoders and encoders, and the
#               reference streams with the MD5s of their software decode in
#               /usr/share/video-codec
#   inference   fastrpc (QNN HTP), tflite-run (tflite_run_ext) on
#               TensorFlow Lite with XNNPACK and the GPU delegate, OpenCL from
#               Mesa RustiCL, clinfo; with QCOM_TEST_INFERENCE_MODEL=y the
#               MobileNetV2 model with its inputs and reference outputs in
#               /usr/share/npu-qnn/model (qcom/test/npu/mk-npu-model.sh)
# Tests whose tool is missing report skip, except optee-xtest and memtester,
# which fail, and kvm-unit-tests, which reports nothing (its runner then
# tries to fetch and build a copy).
################################################################################
TEST ?= y

QCOM_TESTS_ALL = boot-fingerprint boot-handoff cpu-features cpu-hotplug \
		 cpufreq-policy kernel-health maxcpus memtest remoteproc-smoke \
		 remoteproc-restart fastrpc optee-xtest alsa-dsp-restart \
		 memtester kvm-unit-tests kvm-guest gpu-render \
		 video-codec inference qcom-tests
QCOM_TESTS ?= $(QCOM_TESTS_ALL)

ifeq ($(TEST),y)
# qcom-test <test>...: non-empty if QCOM_TESTS names any of them
qcom-test = $(filter $(1),$(QCOM_TESTS))

ifneq ($(call qcom-test,cpufreq-policy cpu-hotplug qcom-tests),)
BR2_PACKAGE_STRESS_NG ?= y
endif

ifneq ($(call qcom-test,cpu-features),)
BR2_PACKAGE_IDREGS_ARM64_EXT ?= y
endif

ifneq ($(call qcom-test,fastrpc inference qcom-tests),)
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

# GStreamer runs the V4L2 mem2mem codec (v4l2h264enc, v4l2h264dec), fed by
# videotestsrc and videoconvertscale on the encode side and by qtdemux
# (isomp4) and h264parse/h265parse (videoparsers) on the decode side.
ifneq ($(call qcom-test,qcom-tests),)
BR2_ROOTFS_OVERLAY += $(CURDIR)/qcom/test/overlay
BR2_INSTALL_LIBSTDCPP                                  ?= y
BR2_PACKAGE_LIBV4L                                     ?= y
BR2_PACKAGE_LIBV4L_UTILS                               ?= y
BR2_PACKAGE_GSTREAMER1                                 ?= y
BR2_PACKAGE_GST1_PLUGINS_BASE                          ?= y
BR2_PACKAGE_GST1_PLUGINS_BASE_PLUGIN_VIDEOTESTSRC      ?= y
BR2_PACKAGE_GST1_PLUGINS_BASE_PLUGIN_VIDEOCONVERTSCALE ?= y
BR2_PACKAGE_GST1_PLUGINS_GOOD                          ?= y
BR2_PACKAGE_GST1_PLUGINS_GOOD_PLUGIN_V4L2              ?= y
BR2_PACKAGE_GST1_PLUGINS_GOOD_PLUGIN_V4L2_PROBE        ?= y
BR2_PACKAGE_GST1_PLUGINS_GOOD_PLUGIN_ISOMP4            ?= y
BR2_PACKAGE_GST1_PLUGINS_BAD                           ?= y
BR2_PACKAGE_GST1_PLUGINS_BAD_PLUGIN_VIDEOPARSERS       ?= y
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

################################################################################
# Video codec userspace (video-codec)
#
# FFmpeg with only what the test runs: the H.264, HEVC and VP9 V4L2 mem2mem
# decoders and the H.264 and HEVC encoders, the software decoders that
# check a hardware encode, testsrc2 (lavfi, whose frames reach ffmpeg as
# wrapped_avframe packets), the psnr filter, framemd5 and the raw H.264,
# HEVC and IVF formats. The reference streams and the per-frame MD5 of
# their software decode go to /usr/share/video-codec
# (qcom/test/video/mk-video-streams.sh, which needs a host ffmpeg with
# libx264, libx265 and libvpx).
#
# qcom/test/video/buildroot-patches/*.patch are applied in order to the
# Buildroot tree before it builds; one that reverses cleanly is already
# applied and is skipped.
#   0001  FFmpeg 7.1.2 instead of 6.1.2: at the end of the input the 6.1
#         ffmpeg tool holds every frame the decoder returns until it has
#         drained, so a V4L2 decoder that needs a CAPTURE buffer back to
#         finish never does (venus, H.264)
################################################################################
ifneq ($(call qcom-test,video-codec),)
BR2_PACKAGE_FFMPEG           ?= y
BR2_PACKAGE_FFMPEG_FFMPEG    ?= y
BR2_PACKAGE_FFMPEG_SWSCALE   ?= y
BR2_PACKAGE_FFMPEG_ENCODERS  ?= "rawvideo wrapped_avframe h264_v4l2m2m hevc_v4l2m2m"
BR2_PACKAGE_FFMPEG_DECODERS  ?= "rawvideo wrapped_avframe h264 hevc vp9 h264_v4l2m2m hevc_v4l2m2m vp9_v4l2m2m"
BR2_PACKAGE_FFMPEG_MUXERS    ?= "framemd5 h264 hevc null rawvideo"
BR2_PACKAGE_FFMPEG_DEMUXERS  ?= "h264 hevc ivf rawvideo"
BR2_PACKAGE_FFMPEG_PARSERS   ?= "h264 hevc vp9"
BR2_PACKAGE_FFMPEG_BSFS      ?= "h264_mp4toannexb hevc_mp4toannexb vp9_superframe_split"
BR2_PACKAGE_FFMPEG_PROTOCOLS ?= "file pipe"
BR2_PACKAGE_FFMPEG_FILTERS   ?= "buffer buffersink format null nullsink psnr scale testsrc2"
BR2_PACKAGE_FFMPEG_INDEVS    ?= n
BR2_PACKAGE_FFMPEG_OUTDEVS   ?= n
# configure fails if the V4L2 mem2mem support cannot be built, rather than
# leaving it out; lavfi is the input device testsrc2 needs.
BR2_PACKAGE_FFMPEG_EXTRACONF ?= "--enable-v4l2-m2m --enable-indev=lavfi"

QCOM_TEST_VIDEO_STREAMS_DIR ?= $(ROOT)/out/video-streams
BR2_ROOTFS_OVERLAY          += $(QCOM_TEST_VIDEO_STREAMS_DIR)

QCOM_TEST_VIDEO_STREAMS = $(QCOM_TEST_VIDEO_STREAMS_DIR)/usr/share/video-codec

.PHONY: test-video-streams test-video-streams-clean
test-video-streams: $(QCOM_TEST_VIDEO_STREAMS)/README

$(QCOM_TEST_VIDEO_STREAMS)/README: $(CURDIR)/qcom/test/video/mk-video-streams.sh
	$< $(QCOM_TEST_VIDEO_STREAMS)

test-video-streams-clean:
	rm -rf $(QCOM_TEST_VIDEO_STREAMS_DIR)

QCOM_TEST_VIDEO_BR_PATCHES = $(sort $(wildcard $(CURDIR)/qcom/test/video/buildroot-patches/*.patch))

.PHONY: test-video-buildroot-patches
test-video-buildroot-patches:
	@for p in $(QCOM_TEST_VIDEO_BR_PATCHES); do \
		if git -C $(ROOT)/buildroot apply -R --check $$p 2>/dev/null; then \
			echo "buildroot: $${p##*/} already applied"; \
		else \
			echo "buildroot: applying $${p##*/}"; \
			git -C $(ROOT)/buildroot apply $$p || exit 1; \
		fi; \
	done

buildroot: test-video-streams test-video-buildroot-patches
endif

################################################################################
# Inference model (inference)
#
# MobileNetV2 as two QAIRT DLCs (fp32 for the QNN CPU backend, 8-bit for the
# HTP) and as TensorFlow Lite, seven public domain or CC0 test images
# preprocessed to the model input, the expected classes and the x86
# reference outputs, in /usr/share/npu-qnn/model. qcom/test/npu/mk-npu-model.sh
# builds it from pinned public inputs; the QAIRT SDK it converts with is
# fetched from Qualcomm and used on the build host only, never put in the
# image (the test gets the QAIRT runtime from the LAVA job). Building the
# model needs an x86_64 host.
#
# The model is an input of the inference test (MODEL_DIR), which a job can
# supply like the QAIRT SDK, and making it fetches that proprietary SDK, so
# it is opt-in: QCOM_TEST_INFERENCE_MODEL=y puts it in the rootfs. Without
# it the image still has every runtime the test drives (TensorFlow Lite with
# XNNPACK and the GPU delegate, OpenCL, fastrpc, tflite-run).
################################################################################
QCOM_TEST_INFERENCE_MODEL ?= n

ifeq ($(QCOM_TEST_INFERENCE_MODEL),y)
ifneq ($(call qcom-test,inference),)
QCOM_TEST_NPU_MODEL_DIR ?= $(ROOT)/out/npu-model
BR2_ROOTFS_OVERLAY      += $(QCOM_TEST_NPU_MODEL_DIR)

QCOM_TEST_NPU_MODEL = $(QCOM_TEST_NPU_MODEL_DIR)/usr/share/npu-qnn/model

.PHONY: test-npu-model test-npu-model-clean
test-npu-model: $(QCOM_TEST_NPU_MODEL)/MANIFEST.sha256

$(QCOM_TEST_NPU_MODEL)/MANIFEST.sha256: $(wildcard $(CURDIR)/qcom/test/npu/*)
	NPU_CACHE=$(ROOT)/out/npu-cache $(CURDIR)/qcom/test/npu/mk-npu-model.sh \
		$(QCOM_TEST_NPU_MODEL)

test-npu-model-clean:
	rm -rf $(QCOM_TEST_NPU_MODEL_DIR) $(ROOT)/out/npu-cache

buildroot: test-npu-model
endif
endif

endif
