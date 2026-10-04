#!/usr/bin/env python3
"""Extracts the 16 kHz weights of Silero VAD v5 from its official ONNX file into
models/silero_vad_16k.npz, which backend.py runs with plain NumPy (no ONNX Runtime).

    uv run --with onnx --with numpy tools/export_silero.py silero_vad.onnx models/silero_vad_16k.npz

Source model: https://github.com/snakers4/silero-vad/raw/v5.1.2/src/silero_vad/data/silero_vad.onnx (MIT)
"""
import sys

import numpy as np
import onnx
from onnx import numpy_helper

src, dst = sys.argv[1], sys.argv[2]
graph = onnx.load(src).graph
branch = next(a.g for n in graph.node if n.op_type == "If" for a in n.attribute if a.name == "then_branch")
prefix = "If_0_then_branch__Inline_0__"          # the sr == 16000 branch
c = {n.output[0].replace(prefix, ""): numpy_helper.to_array(a.t)
     for n in branch.node if n.op_type == "Constant" for a in n.attribute if a.name == "value"}
np.savez(dst,
         stft_basis=c["stft.forward_basis_buffer"][:, 0, :],
         **{f"enc{i}_w": c[f"encoder.{i}.reparam_conv.weight"] for i in range(4)},
         **{f"enc{i}_b": c[f"encoder.{i}.reparam_conv.bias"] for i in range(4)},
         lstm_w_ih=c["decoder.rnn.weight_ih"], lstm_w_hh=c["decoder.rnn.weight_hh"],
         lstm_b_ih=c["decoder.rnn.bias_ih"], lstm_b_hh=c["decoder.rnn.bias_hh"],
         out_w=c["decoder.decoder.2.weight"], out_b=np.atleast_1d(c["decoder.decoder.2.bias"]))
print("wrote", dst)
