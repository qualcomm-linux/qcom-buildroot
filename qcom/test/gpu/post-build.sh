#!/bin/bash
# SPDX-License-Identifier: BSD-2-Clause
#
# The GPU stack (Mesa RustiCL, TensorFlow Lite) pulls in LLVM, Clang,
# libclc, SPIRV-Tools, the SPIRV-LLVM-Translator, the Vulkan headers and
# FlatBuffers, whose packages also install their developer tools and data.
# The rootfs is the initramfs, so remove what nothing on the target uses:
# RustiCL links libLLVM, libclang-cpp, libLLVMSPIRVLib and libSPIRV-Tools
# (core, opt, link) and loads only libclc's SPIR-V libraries.
set -eu
T=${TARGET_DIR:?}

# libclc: every target's bitcode; keep spirv-mesa3d-.spv, spirv64-mesa3d-.spv
find "$T/usr/share/clc" -name '*.bc' -delete 2>/dev/null || true
# Clang: the C API library and the analyzer tools
rm -rf "$T"/usr/lib/libclang.so* "$T/usr/bin/diagtool" "$T/usr/bin/hmaptool" \
	"$T/usr/bin/intercept-build" "$T/usr/bin/analyze-build" "$T/usr/bin/scan-build-py" \
	"$T"/usr/libexec/intercept-c* "$T"/usr/libexec/analyze-c* \
	"$T/usr/lib/libscanbuild" "$T/usr/lib/libear"
# LLVM: LTO and remarks libraries, opt-viewer
rm -rf "$T"/usr/lib/libLTO.so* "$T"/usr/lib/libRemarks.so* "$T/usr/share/opt-viewer"
# SPIRV-Tools and SPIRV-LLVM-Translator command line tools
rm -f "$T"/usr/bin/spirv-* "$T/usr/bin/llvm-spirv" \
	"$T"/usr/lib/libSPIRV-Tools-diff.so "$T"/usr/lib/libSPIRV-Tools-lint.so \
	"$T"/usr/lib/libSPIRV-Tools-reduce.so "$T"/usr/lib/libSPIRV-Tools-shared.so
# Vulkan API registry (generator scripts and XML), FlatBuffers compiler
rm -rf "$T/usr/share/vulkan/registry" "$T/usr/bin/flatc"

if [ -e "$T/etc/OpenCL/vendors/rusticl.icd" ]; then
	for f in usr/share/clc/spirv-mesa3d-.spv usr/share/clc/spirv64-mesa3d-.spv; do
		[ -f "$T/$f" ] || { echo "post-build: $f missing" >&2; exit 1; }
	done
fi
