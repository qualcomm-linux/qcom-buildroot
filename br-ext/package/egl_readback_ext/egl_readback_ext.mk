################################################################################
#
# egl_readback_ext
#
# egl-readback (src/egl-readback.c): headless GPU check that renders on the
# msm render node, reads the pixels back and checks them.
#
################################################################################

EGL_READBACK_EXT_VERSION = 1.0
EGL_READBACK_EXT_SITE = $(BR2_EXTERNAL_OPTEE_PATH)/package/egl_readback_ext/src
EGL_READBACK_EXT_SITE_METHOD = local
EGL_READBACK_EXT_LICENSE = BSD-2-Clause
EGL_READBACK_EXT_DEPENDENCIES = host-pkgconf libdrm libegl libgles libgbm

define EGL_READBACK_EXT_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Wall \
		-o $(@D)/egl-readback $(@D)/egl-readback.c \
		$$($(PKG_CONFIG_HOST_BINARY) --cflags --libs egl glesv2 gbm libdrm)
endef

define EGL_READBACK_EXT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/egl-readback $(TARGET_DIR)/usr/bin/egl-readback
endef

$(eval $(generic-package))
