"""Convert the BirdNET v2.4 SavedModel to Core ML and check it matches TensorFlow.

Usage:
    python tools/convert_birdnet.py <dir containing V2.4/> <output dir>

Get the model files from https://huggingface.co/sammlapp/BirdNET_v2.4 (CC BY-NC-SA 4.0).
Tested with Python 3.11, tensorflow 2.15, coremltools 8.3, numpy < 2.

BirdNET's mel-spectrogram layers run tf.signal.stft and then cast the complex result
to float32, which keeps only the real part. Core ML has no complex tensors, so the
RFFT + Cast pair is rewritten as a batched matmul with a cosine DFT matrix:
Re(rfft(x))[k] = sum_n x[n] * cos(2*pi*k*n/N). The result is numerically the same.
"""
import shutil
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import tensorflow as tf
from tensorflow.python.framework.convert_to_constants import convert_variables_to_constants_v2

SAMPLES = 144_000  # 3 s at 48 kHz


def cosine_dft(n: int) -> np.ndarray:
    k = np.arange(n // 2 + 1)
    t = np.arange(n)
    return np.cos(2 * np.pi * np.outer(t, k) / n).astype(np.float32)  # [n, n/2+1]


def replace_rfft(graph_def: tf.compat.v1.GraphDef) -> tf.compat.v1.GraphDef:
    nodes = {n.name: n for n in graph_def.node}
    out = tf.compat.v1.GraphDef()
    out.CopyFrom(graph_def)
    replaced = 0
    for node in out.node:
        if node.op != "RFFT":
            continue
        length = int(tf.make_ndarray(nodes[node.input[1]].attr["value"].tensor)[0])
        const_name = node.name + "/cos_dft"
        const = out.node.add()
        const.name = const_name
        const.op = "Const"
        const.attr["dtype"].type = tf.float32.as_datatype_enum
        const.attr["value"].tensor.CopyFrom(tf.make_tensor_proto(cosine_dft(length)))

        frames = node.input[0]
        node.Clear()
        node.name = const_name.rsplit("/cos_dft", 1)[0]
        node.op = "BatchMatMulV2"
        node.input.extend([frames, const_name])
        node.attr["T"].type = tf.float32.as_datatype_enum
        node.attr["adj_x"].b = False
        node.attr["adj_y"].b = False
        replaced += 1

    # The complex -> float Cast after each RFFT is now a no-op.
    rfft_names = {n.name for n in graph_def.node if n.op == "RFFT"}
    for node in out.node:
        if node.op == "Cast" and node.input and node.input[0] in rfft_names:
            node.op = "Identity"
            for key in list(node.attr.keys()):
                del node.attr[key]
            node.attr["T"].type = tf.float32.as_datatype_enum
    assert replaced == 2, f"expected 2 RFFT nodes, found {replaced}"
    return out


def main(src: Path, out: Path) -> None:
    v24 = src / "V2.4"
    out.mkdir(parents=True, exist_ok=True)

    saved = tf.saved_model.load(str(v24 / "BirdNET_GLOBAL_6K_V2.4_Model"))
    fn = saved.signatures["basic"]
    frozen = convert_variables_to_constants_v2(fn)
    graph_def = replace_rfft(frozen.graph.as_graph_def())
    in_name = frozen.inputs[0].name.split(":")[0]
    out_name = frozen.outputs[0].name.split(":")[0]

    mlmodel = ct.convert(
        graph_def,
        source="tensorflow",
        inputs=[ct.TensorType(name=in_name, shape=(1, SAMPLES), dtype=np.float32)],
        outputs=[ct.TensorType(name=out_name)],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
    )
    mlmodel.short_description = "BirdNET v2.4: 3 s of 48 kHz mono audio -> 6522 class logits"
    mlmodel.license = "CC BY-NC-SA 4.0 (BirdNET, Cornell Lab of Ornithology / Chemnitz University of Technology)"
    mlmodel.author = "BirdNET team; converted for MMT"

    spec = mlmodel.get_spec()
    ml_in = spec.description.input[0].name
    ml_out = spec.description.output[0].name
    path = out / "BirdNET.mlpackage"
    if path.exists():
        shutil.rmtree(path)
    mlmodel.save(str(path))

    # Compare against the original TensorFlow model on a chirp + noise signal.
    t = np.arange(SAMPLES) / 48_000
    x = (0.3 * np.sin(2 * np.pi * (3000 + 800 * np.sin(2 * np.pi * 4 * t)) * t)
         + 0.02 * np.random.default_rng(0).standard_normal(SAMPLES)).astype(np.float32)[None]
    ref = fn(inputs=tf.constant(x))["scores"].numpy()[0]
    got = mlmodel.predict({ml_in: x})[ml_out][0]
    print("Core ML input/output:", ml_in, ml_out)
    print("max abs diff:", float(np.max(np.abs(ref - got))))
    print("TF top5:    ", np.argsort(ref)[::-1][:5], np.sort(ref)[::-1][:5])
    print("CoreML top5:", np.argsort(got)[::-1][:5], np.sort(got)[::-1][:5])

    shutil.copy(v24 / "BirdNET_GLOBAL_6K_V2.4_Labels.txt", out / "BirdNET_Labels.txt")


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
