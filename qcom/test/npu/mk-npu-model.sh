#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# mk-npu-model.sh <output dir>: the model the inference test runs, built from
# pinned public inputs into <output dir> (the image's /usr/share/npu-qnn/model):
#   - MobileNetV2 from the ONNX model zoo (fp32, Apache-2.0) and its labels;
#   - seven public domain or CC0 images from Wikimedia Commons;
#   - the Qualcomm AI Runtime (QAIRT) SDK from Qualcomm's download URL, used
#     on this host only (its license does not allow redistributing it on its
#     own): qairt-converter makes the fp32 DLC the QNN CPU backend runs,
#     qairt-quantizer the 8-bit DLC (per-channel weights, calibrated on the
#     images) the HTP runs, and the x86 qnn-net-run gives the CPU and HTP
#     simulation outputs the test compares the board's with. Nothing from the
#     SDK goes into <output dir>;
#   - the same model for TensorFlow Lite (fp32, NHWC input), for the CPU
#     (XNNPACK) and GPU delegate runs: onnxsim fixes the batch to 1 and folds
#     the shape computation, onnx2tf converts, LiteRT on this host gives the
#     reference outputs (Python 3.12, requirements-tflite.txt).
# Every download is checked against its pinned hash. The converters need an
# x86_64 Linux host, libc++1, libc++abi1 and libatomic1; Python 3.10 and the
# packages of requirements.txt come from uv. NPU_CACHE (default
# ~/.cache/qcom-buildroot-npu) keeps the downloads between builds.
set -eu
out=${1:?usage: mk-npu-model.sh <output dir>}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
cache=${NPU_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/qcom-buildroot-npu}
mkdir -p "$cache"
cache=$(cd "$cache" && pwd)

[ "$(uname -m)" = x86_64 ] || { echo "mk-npu-model.sh: the QAIRT converters need an x86_64 host" >&2; exit 1; }

QAIRT_VERSION=2.42.0.251225
# Hexagon architectures of the boards' NSPs (QCS6490 v68, SA8775P v73,
# QCS8275 v75)
HTP_ARCHS="v68 v73 v75"
QAIRT_URL=https://softwarecenter.qualcomm.com/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/$QAIRT_VERSION/v$QAIRT_VERSION.zip
QAIRT_SHA256=1a744ed72a813fc9dd4a29e31b1685f784786102fd45414d74915bb3351ae321
UV_URL=https://github.com/astral-sh/uv/releases/download/0.12.22/uv-x86_64-unknown-linux-gnu.tar.gz
UV_SHA256=b9980552309f09c15172b8be828555e375097f16deb459795ce7bfd200380f0b
ONNX_URL=https://github.com/onnx/models/raw/main/validated/vision/classification/mobilenet/model/mobilenetv2-12.onnx
ONNX_SHA256=c0c3f76d93fa3fd6580652a45618618a220fced18babf65774ed169de0432ad5
SYNSET_URL=https://raw.githubusercontent.com/onnx/models/main/validated/vision/classification/synset.txt
SYNSET_SHA256=acf75ef0abe89694b19056e0796401068b459c457baa30335f240c7692857355
COMMONS=https://upload.wikimedia.org/wikipedia/commons
# <name> <Commons path> <sha1 of the original file, as Commons lists it>
IMAGES="carrier 2/2d/USS_Nimitz_%28CVN-68%29.jpg e69b94a88b4f8bb663dcc3b0fe25b4b8eeb90cb6
hopper a/ad/Commodore_Grace_M._Hopper%2C_USN_%28covered%29.jpg 335af644bc1ce8d4397b6b20d6a64bb533ab554c
monarch 3/39/Monarch_Butterfly_%2851295575497%29.jpg e81cc101e106762a6f25302d15caeac63815e5c9
pizza 1/11/Pepperoni_and_mushroom_pizza_-_Massachusetts.jpg 6687dc7f715d799e421e677fcbbd364d4cb3060f
retriever f/fd/Golden_Retriever_Chewing_A_Stick.jpg fb8bbd2f598e5c6557a983f45e55212cf8fb44fc
shuttle 2/2a/Space_Shuttle_Atlantis_launches_from_KSC_on_STS-132_side_view.jpg 1a6360e883343c10c01c16b5cc1d836248614eba
warplane 6/66/F-16_Fighting_Falcon.jpg 91897cd49ca99f5468a5d009879cd13712cd3375"

# fetch <url> <file> <sha256|sha1> <hash>: download once, check the hash
fetch() {
	if [ ! -f "$2" ] || ! echo "$4  $2" | "$3sum" -c --quiet 2>/dev/null; then
		curl -fsSL --retry 5 -A "qcom-buildroot npu-model" -o "$2.part" "$1"
		mv "$2.part" "$2"
	fi
	echo "$4  $2" | "$3sum" -c --quiet
}

fetch "$QAIRT_URL" "$cache/qairt-$QAIRT_VERSION.zip" sha256 "$QAIRT_SHA256"
fetch "$UV_URL" "$cache/uv.tar.gz" sha256 "$UV_SHA256"
fetch "$ONNX_URL" "$cache/mobilenetv2-12.onnx" sha256 "$ONNX_SHA256"
fetch "$SYNSET_URL" "$cache/synset.txt" sha256 "$SYNSET_SHA256"
mkdir -p "$cache/img"
echo "$IMAGES" | while read -r n p sha1; do
	fetch "$COMMONS/$p" "$cache/img/$n.jpg" sha1 "$sha1"
done

sdk=$cache/qairt/$QAIRT_VERSION
if [ ! -x "$sdk/bin/x86_64-linux-clang/qairt-converter" ]; then
	rm -rf "$cache/qairt"
	unzip -q "$cache/qairt-$QAIRT_VERSION.zip" -d "$cache" \
		"qairt/$QAIRT_VERSION/bin/x86_64-linux-clang/*" \
		"qairt/$QAIRT_VERSION/lib/x86_64-linux-clang/*" \
		"qairt/$QAIRT_VERSION/lib/python/*" \
		"qairt/$QAIRT_VERSION/share/*"
fi
uv=$cache/uv-x86_64-unknown-linux-gnu/uv
[ -x "$uv" ] || tar -xzf "$cache/uv.tar.gz" -C "$cache"
export UV_CACHE_DIR=$cache/uv-cache UV_PYTHON_INSTALL_DIR=$cache/uv-python
venv=$cache/venv
if [ ! -x "$venv/bin/python" ] || ! cmp -s "$here/requirements.txt" "$venv/requirements.txt"; then
	rm -rf "$venv"
	"$uv" venv -q --python 3.10.22 "$venv"
	VIRTUAL_ENV=$venv "$uv" pip install -q -r "$here/requirements.txt"
	cp "$here/requirements.txt" "$venv/requirements.txt"
fi

tvenv=$cache/venv-tflite
if [ ! -x "$tvenv/bin/python" ] || ! cmp -s "$here/requirements-tflite.txt" "$tvenv/requirements.txt"; then
	rm -rf "$tvenv"
	"$uv" venv -q --python 3.12.15 "$tvenv"
	VIRTUAL_ENV=$tvenv "$uv" pip install -q -r "$here/requirements-tflite.txt"
	cp "$here/requirements-tflite.txt" "$tvenv/requirements.txt"
fi

work=$cache/work
rm -rf "$work" && mkdir -p "$work"
cp -r "$cache/img" "$work/img"
cp "$cache/mobilenetv2-12.onnx" "$cache/synset.txt" "$work/"
export QNN_SDK_ROOT=$sdk SNPE_ROOT=$sdk PYTHONPATH=$sdk/lib/python
export PATH=$venv/bin:$sdk/bin/x86_64-linux-clang:$PATH
# The converters' Python modules link libpython3.10.so.
pylib=$("$venv/bin/python" -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))')
export LD_LIBRARY_PATH=$sdk/lib/x86_64-linux-clang:$pylib
L=$sdk/lib/x86_64-linux-clang
python "$here/model.py" prep "$work"
# TensorFlow Lite, outside the QAIRT environment (its libraries and Python
# path are for the 3.10 tools). onnx2tf checks its output against ONNX
# Runtime and fails on a mismatch (-ewo -efot).
T="env -u LD_LIBRARY_PATH -u PYTHONPATH PATH=$tvenv/bin:/usr/bin:/bin HOME=$cache"
$T onnxsim "$work/mobilenetv2-12.onnx" "$work/sim.onnx" \
	--overwrite-input-shape input:1,3,224,224 > "$work/onnxsim.log" 2>&1 ||
	{ tail -20 "$work/onnxsim.log"; exit 1; }
$T onnx2tf -i "$work/sim.onnx" -o "$work/tflite" -ewo -efot \
	> "$work/onnx2tf.log" 2>&1 || { tail -20 "$work/onnx2tf.log"; exit 1; }
cp "$work/tflite/sim_float32.tflite" "$work/mobilenet_v2_fp32.tflite"
$T python "$here/model.py" tflite "$work" > "$work/tflite.log" 2>&1 ||
	{ tail -20 "$work/tflite.log"; exit 1; }
qairt-converter --input_network "$work/mobilenetv2-12.onnx" \
	--source_model_input_shape input 1,3,224,224 \
	--source_model_input_layout input NCHW \
	--output_path "$work/mobilenet_v2_fp32.dlc" > "$work/converter.log" 2>&1 ||
	{ tail -20 "$work/converter.log"; exit 1; }
# Per-tensor weights bring the logit cosine of the HTP against the CPU down
# to 0.944 on the x86 HTP simulation; per-channel weights keep it at 0.989
# or more.
qairt-quantizer --input_dlc "$work/mobilenet_v2_fp32.dlc" \
	--input_list "$work/inputs.txt" --use_per_channel_quantization \
	--output_dlc "$work/mobilenet_v2_int8.dlc" > "$work/quantizer.log" 2>&1 ||
	{ tail -20 "$work/quantizer.log"; exit 1; }
qnn-net-run --backend "$L/libQnnCpu.so" --model "$L/libQnnModelDlc.so" \
	--dlc_path "$work/mobilenet_v2_fp32.dlc" --input_list "$work/inputs.txt" \
	--output_dir "$work/host-cpu" > "$work/host-cpu.log" 2>&1 ||
	{ tail -20 "$work/host-cpu.log"; exit 1; }
# The x86 HTP simulation follows one Hexagon architecture (v68 unless the
# backend extensions name another), and the 8-bit outputs of v68 and v73/v75
# differ: one reference per architecture the boards have.
for arch in $HTP_ARCHS; do
	printf '{"devices": [{"dsp_arch": "%s", "soc_model": 0}]}\n' "$arch" > "$work/htp-$arch.json"
	printf '{"backend_extensions": {"shared_library_path": "%s", "config_file_path": "%s"}}\n' \
		"$L/libQnnHtpNetRunExtensions.so" "$work/htp-$arch.json" > "$work/htp-$arch-config.json"
	qnn-net-run --backend "$L/libQnnHtp.so" --model "$L/libQnnModelDlc.so" \
		--dlc_path "$work/mobilenet_v2_int8.dlc" --input_list "$work/inputs.txt" \
		--config_file "$work/htp-$arch-config.json" \
		--output_dir "$work/host-htp-$arch" > "$work/host-htp-$arch.log" 2>&1 ||
		{ tail -20 "$work/host-htp-$arch.log"; exit 1; }
done
{
	echo "npu-qnn model: MobileNetV2 (ImageNet, 1000 classes), built by qcom-buildroot qcom/test/npu/mk-npu-model.sh"
	echo
	echo "Model: $ONNX_URL (sha256 $ONNX_SHA256),"
	echo "  ONNX model zoo, MobileNet v2-1.0-fp32, opset 12, license Apache-2.0; labels: the zoo's synset.txt."
	echo "Conversion: Qualcomm AI Runtime (QAIRT) $QAIRT_VERSION on x86_64:"
	echo "  mobilenet_v2_fp32.dlc  qairt-converter, input NCHW float32, output 1000 logits (QNN CPU backend)"
	echo "  mobilenet_v2_int8.dlc  qairt-quantizer --use_per_channel_quantization, calibrated on the inputs (QNN HTP)"
	echo "TensorFlow Lite: onnxsim (batch 1, shapes folded) and onnx2tf 2.6.9 on x86_64:"
	echo "  mobilenet_v2_fp32.tflite  input NHWC float32 (inputs-nhwc/), output 1000 logits (XNNPACK, GPU delegate)"
	echo "Inputs: shorter side to 256 (bilinear), center crop 224, RGB in [0,1], ImageNet mean/std, NCHW float32."
	echo "expected.txt: the ONNX Runtime fp32 top-1, each image's label."
	echo "host-cpu/: the x86 qnn-net-run CPU backend outputs; host-htp-<arch>/: the x86 HTP simulation of each Hexagon architecture."
	echo "host-tflite/: the x86 LiteRT outputs of the TensorFlow Lite model."
	echo
	echo "Images (Wikimedia Commons, $COMMONS/<path>; sha1 of the original):"
	echo "$IMAGES" | while read -r n p sha1; do echo "  $n $p $sha1"; done
	echo "  carrier, hopper, monarch, shuttle, warplane: public domain (US government works); pizza, retriever: CC0"
} > "$work/README"
rm -rf "$out" && mkdir -p "$out"
HTP_ARCHS="$HTP_ARCHS" python "$here/model.py" bundle "$work" "$out"
echo "npu-qnn model in $out: $(wc -l < "$out/MANIFEST.sha256") files"
