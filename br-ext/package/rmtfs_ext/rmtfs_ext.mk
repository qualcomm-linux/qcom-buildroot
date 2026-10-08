################################################################################
#
# rmtfs_ext
#
# Qualcomm Remote Filesystem service. Serves the peripherals' (DSP) access to
# their persistent/EFS storage over QRTR. The ADSP protection domains need it
# to finish coming up; without it ADSP FastRPC stalls on a GLINK intent timeout
# even though the remoteproc authenticates and boots. Launched from S42rmtfs.
# Pinned to the same revision as meta-qcom rmtfs_1.3.bb (tag v1.3).
#
################################################################################

RMTFS_EXT_VERSION = b30a3eb38f9af283f18dbd3c7755653efc52c094
RMTFS_EXT_SITE = https://github.com/linux-msm/rmtfs.git
RMTFS_EXT_SITE_METHOD = git
RMTFS_EXT_LICENSE = BSD-3-Clause
RMTFS_EXT_LICENSE_FILES = LICENSE
RMTFS_EXT_DEPENDENCIES = host-qmic_ext qrtr_ext udev

# The Makefile generates qmi_rmtfs.c via "qmic" (host, on PATH from host-qmic_ext)
# and links "-lqrtr -ludev -lpthread" that it appends to LDFLAGS itself. Pass CC
# and CFLAGS only: a command-line LDFLAGS= would clobber the Makefile's "+=" and
# drop the libs. The cross CC resolves qrtr/udev from the target sysroot.
define RMTFS_EXT_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) CC="$(TARGET_CC)" CFLAGS="$(TARGET_CFLAGS)" -C $(@D)
endef

define RMTFS_EXT_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) install DESTDIR=$(TARGET_DIR) \
		prefix=/usr servicedir=/usr/lib/systemd/system rulesdir=/usr/lib/udev/rules.d
endef

$(eval $(generic-package))
