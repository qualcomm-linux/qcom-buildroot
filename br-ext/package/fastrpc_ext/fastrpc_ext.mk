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
# Tag v1.0.8. v1.0.7 and later pass the RPC poll mode the QNN HTP backend
# requests on Hexagon v69 and later to the kernel (FASTRPC_IOCTL_SET_OPTION);
# v1.0.6 and later install the daemons in /usr/sbin.
#
################################################################################

FASTRPC_EXT_VERSION = d247519650fe5cb16de6c78edaa95bcc4be25073
FASTRPC_EXT_SITE = https://github.com/qualcomm/fastrpc.git
FASTRPC_EXT_SITE_METHOD = git
FASTRPC_EXT_LICENSE = BSD-3-Clause-Clear
FASTRPC_EXT_LICENSE_FILES = LICENSE.txt
FASTRPC_EXT_AUTORECONF = YES
FASTRPC_EXT_DEPENDENCIES = host-pkgconf libyaml libbsd

$(eval $(autotools-package))
