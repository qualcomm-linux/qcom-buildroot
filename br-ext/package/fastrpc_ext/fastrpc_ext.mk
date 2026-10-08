################################################################################
#
# fastrpc_ext
#
# Qualcomm FastRPC userspace library + fastrpc_test, used to validate the
# OP-TEE PAS coprocessor (CDSP) load/reset sequences.
#
# The autotools build installs:
#   /usr/bin/fastrpc_test                       the test binary
#   /usr/lib/fastrpc_test/lib*.so               CPU-side stub libraries
#   /usr/share/fastrpc_test/{v68,v75}/*_skel.so DSP skeleton stubs
# The stub/skel search paths are compiled into the binary (-Dtestlibdir /
# -Dtestdspdir), so no extra install hook or runtime configuration is needed.
#
# Pinned to the same commit as meta-qcom fastrpc_1.0.5.bb (tag v1.0.5).
#
################################################################################

FASTRPC_EXT_VERSION = 29851fde11d4e2a4ce221536485d0f7d46ffca30
FASTRPC_EXT_SITE = https://github.com/qualcomm/fastrpc.git
FASTRPC_EXT_SITE_METHOD = git
FASTRPC_EXT_LICENSE = BSD-3-Clause-Clear
FASTRPC_EXT_LICENSE_FILES = LICENSE.txt
FASTRPC_EXT_AUTORECONF = YES
FASTRPC_EXT_DEPENDENCIES = host-pkgconf libyaml libbsd

$(eval $(autotools-package))
