################################################################################
#
# tflite_run_ext
#
# tflite-run for test-definitions' inference test, built from its source in
# the test-definitions tree (automated/linux/inference) against Buildroot's
# tensorflow-lite: XNNPACK on the CPU or the GPU delegate, leaving out the
# one tensorflow-lite was built without.
#
################################################################################

TFLITE_RUN_EXT_VERSION = 4ddcfe81845497eb602d458dbe9a3066eb5e56b5
TFLITE_RUN_EXT_SITE = https://github.com/EmbeddedAndroid/test-definitions.git
TFLITE_RUN_EXT_SITE_METHOD = git
TFLITE_RUN_EXT_LICENSE = BSD-2-Clause
TFLITE_RUN_EXT_LICENSE_FILES = automated/linux/inference/tflite-run.cc
TFLITE_RUN_EXT_DEPENDENCIES = tensorflow-lite

# CXXFLAGS and LDFLAGS go in the environment: the Makefile appends to them.
TFLITE_RUN_EXT_MAKE_OPTS = \
	CXX="$(TARGET_CXX)" \
	$(if $(BR2_PACKAGE_TENSORFLOW_LITE_GPU),,NO_GPU=1) \
	$(if $(BR2_PACKAGE_XNNPACK),,NO_XNNPACK=1)

define TFLITE_RUN_EXT_BUILD_CMDS
	$(TARGET_MAKE_ENV) CXXFLAGS="$(TARGET_CXXFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)" \
		$(MAKE) -C $(@D)/automated/linux/inference \
		$(TFLITE_RUN_EXT_MAKE_OPTS) tflite-run
endef

define TFLITE_RUN_EXT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/automated/linux/inference/tflite-run \
		$(TARGET_DIR)/usr/bin/tflite-run
endef

$(eval $(generic-package))
