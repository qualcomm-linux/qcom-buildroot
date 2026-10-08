################################################################################
#
# qmic_ext  (host tool)
#
# QMI interface compiler. rmtfs generates its QMI stubs at build time with
# "qmic -k < qmi_rmtfs.qmi", so qmic must be on the build host PATH. Host-only
# package, pulled in as a build dependency of rmtfs_ext. Pinned to the same
# revision as meta-qcom qmic-native.
#
################################################################################

QMIC_EXT_VERSION = 815dd495eb087b3b3ea02a8ed43716efac43db1c
QMIC_EXT_SITE = https://github.com/linux-msm/qmic.git
QMIC_EXT_SITE_METHOD = git
QMIC_EXT_LICENSE = BSD-3-Clause
QMIC_EXT_LICENSE_FILES = LICENSE

define HOST_QMIC_EXT_BUILD_CMDS
	$(HOST_MAKE_ENV) $(MAKE) CC="$(HOSTCC)" -C $(@D)
endef

# qmic's "install" target uses DESTDIR + prefix; install into $(HOST_DIR) so the
# binary lands on the build PATH ($(HOST_DIR)/bin) for rmtfs_ext's codegen.
define HOST_QMIC_EXT_INSTALL_CMDS
	$(HOST_MAKE_ENV) $(MAKE) -C $(@D) install prefix=$(HOST_DIR)
endef

$(eval $(host-generic-package))
