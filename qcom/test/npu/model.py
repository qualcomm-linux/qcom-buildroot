#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""model.py: the host side of the inference test model, run by mk-npu-model.sh.

  model.py prep <work>    preprocess <work>/img/*.jpg to <work>/prep/<name>.raw
                          (MobileNetV2 input: shorter side to 256, bilinear,
                          center crop 224, RGB in [0,1], ImageNet mean/std,
                          NCHW float32) and run the fp32 ONNX model with ONNX
                          Runtime: <work>/prep/<name>.ref.raw holds its logits
  model.py tflite <work>  for <work>/mobilenet_v2_fp32.tflite (onnx2tf, NHWC
                          input): <work>/prep/<name>.nhwc.raw, the inputs in
                          its layout, and <work>/host-tflite/Result_<i>/
                          output.raw, its LiteRT outputs (Python 3.12 venv)
  model.py bundle <work> <out>
                          check the references and write the bundle to <out>:
                          the DLCs, the TensorFlow Lite model, the inputs
                          (NCHW for the DLCs, NHWC for the TFLite model),
                          expected.txt (each image's ONNX Runtime top-1,
                          which must be its label in IMAGES), labels.txt,
                          the x86 QNN CPU outputs, the HTP simulation outputs
                          of each architecture in HTP_ARCHS, the LiteRT
                          outputs, model.env, README and MANIFEST.sha256
"""
import hashlib
import os
import sys

import numpy as np

MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
# name: (ImageNet class, license, author); URLs and hashes in mk-npu-model.sh
IMAGES = {
    "carrier": (403, "public domain", "United States Navy"),
    "hopper": (652, "public domain", "James S. Davis, United States Navy"),
    "monarch": (323, "public domain", "U.S. Fish and Wildlife Service"),
    "pizza": (963, "CC0", "Wikimedia Commons contributor"),
    "retriever": (207, "CC0", "Wikimedia Commons contributor"),
    "shuttle": (812, "public domain", "NASA/Tony Gray and Tom Farrar"),
    "warplane": (895, "public domain", "United States Air Force"),
}
NAMES = sorted(IMAGES)


def preprocess(path):
    from PIL import Image
    im = Image.open(path).convert("RGB")
    w, h = im.size
    s = 256.0 / min(w, h)
    im = im.resize((max(256, round(w * s)), max(256, round(h * s))), Image.BILINEAR)
    w, h = im.size
    left, top = (w - 224) // 2, (h - 224) // 2
    im = im.crop((left, top, left + 224, top + 224))
    a = (np.asarray(im, dtype=np.float32) / 255.0 - MEAN) / STD
    return np.ascontiguousarray(a.transpose(2, 0, 1)[None]).astype(np.float32)


def prep(work):
    import onnxruntime as ort
    os.makedirs(os.path.join(work, "prep"), exist_ok=True)
    sess = ort.InferenceSession(os.path.join(work, "mobilenetv2-12.onnx"),
                                providers=["CPUExecutionProvider"])
    iname = sess.get_inputs()[0].name
    with open(os.path.join(work, "inputs.txt"), "w") as lst:
        for n in NAMES:
            x = preprocess(os.path.join(work, "img", n + ".jpg"))
            x.tofile(os.path.join(work, "prep", n + ".raw"))
            sess.run(None, {iname: x})[0].reshape(-1).astype(np.float32).tofile(
                os.path.join(work, "prep", n + ".ref.raw"))
            lst.write(os.path.join(work, "prep", n + ".raw") + "\n")


def tflite(work):
    from ai_edge_litert.interpreter import Interpreter
    it = Interpreter(model_path=os.path.join(work, "mobilenet_v2_fp32.tflite"))
    it.allocate_tensors()
    i, o = it.get_input_details()[0], it.get_output_details()[0]
    if list(i["shape"]) != [1, 224, 224, 3] or list(o["shape"]) != [1, 1000]:
        sys.exit("tflite: input %s, output %s" % (list(i["shape"]), list(o["shape"])))
    for k, n in enumerate(NAMES):
        x = np.fromfile(os.path.join(work, "prep", n + ".raw"), dtype=np.float32)
        x = np.ascontiguousarray(x.reshape(1, 3, 224, 224).transpose(0, 2, 3, 1))
        x.tofile(os.path.join(work, "prep", n + ".nhwc.raw"))
        it.set_tensor(i["index"], x)
        it.invoke()
        d = os.path.join(work, "host-tflite", "Result_%d" % k)
        os.makedirs(d, exist_ok=True)
        it.get_tensor(o["index"]).reshape(-1).astype(np.float32).tofile(
            os.path.join(d, "output.raw"))


def bundle(work, out):
    labels = [l.split(" ", 1)[1].strip() for l in open(os.path.join(work, "synset.txt"))]
    files = {}
    expected = []
    for i, n in enumerate(NAMES):
        ref = np.fromfile(os.path.join(work, "prep", n + ".ref.raw"), dtype=np.float32)
        top = int(ref.argmax())
        if top != IMAGES[n][0]:
            sys.exit("%s: ONNX Runtime top-1 %d, label %d" % (n, top, IMAGES[n][0]))
        for kind in ["cpu", "tflite"] + ["htp-" + a for a in os.environ["HTP_ARCHS"].split()]:
            o = np.fromfile(os.path.join(work, "host-" + kind, "Result_%d" % i, "output.raw"),
                            dtype=np.float32)
            if int(o.argmax()) != top:
                sys.exit("%s: x86 %s top-1 %d, expected %d" % (n, kind, int(o.argmax()), top))
            files["host-%s/%s.raw" % (kind, n)] = o.tobytes()
        # the conversion keeps the model: LiteRT against ONNX Runtime
        t = np.frombuffer(files["host-tflite/%s.raw" % n], dtype=np.float32)
        if float(np.abs(t - ref).max()) > 1e-3:
            sys.exit("%s: LiteRT differs from ONNX Runtime by %g" % (n, float(np.abs(t - ref).max())))
        expected.append("%s %d %s" % (n, top, labels[top]))
        files["inputs/%s.raw" % n] = open(os.path.join(work, "prep", n + ".raw"), "rb").read()
        files["inputs-nhwc/%s.raw" % n] = open(os.path.join(work, "prep", n + ".nhwc.raw"), "rb").read()
    files["expected.txt"] = ("\n".join(expected) + "\n").encode()
    files["labels.txt"] = ("\n".join(labels) + "\n").encode()
    for d in ("mobilenet_v2_fp32.dlc", "mobilenet_v2_int8.dlc", "mobilenet_v2_fp32.tflite"):
        files[d] = open(os.path.join(work, d), "rb").read()
    files["model.env"] = (b"MODEL_NAME=mobilenet_v2\n"
                          b"CPU_DLC=mobilenet_v2_fp32.dlc\nHTP_DLC=mobilenet_v2_int8.dlc\n"
                          b"TFLITE=mobilenet_v2_fp32.tflite\nTFLITE_INPUTS=inputs-nhwc\n")
    files["README"] = open(os.path.join(work, "README"), "rb").read()
    os.makedirs(out, exist_ok=True)
    for k, v in files.items():
        os.makedirs(os.path.dirname(os.path.join(out, k)) or out, exist_ok=True)
        open(os.path.join(out, k), "wb").write(v)
    with open(os.path.join(out, "MANIFEST.sha256"), "w") as m:
        for k in sorted(files):
            m.write("%s  %s\n" % (hashlib.sha256(files[k]).hexdigest(), k))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "prep":
        prep(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "tflite":
        tflite(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "bundle":
        bundle(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
