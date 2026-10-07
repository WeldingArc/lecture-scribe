# Third-party notices

강의 받아쓰기 is MIT-licensed (see `LICENSE`).

## v2 (current, macOS 26+)

Speech recognition is Apple's on-device SpeechAnalyzer, part of macOS (macOS itself installs the speech models
it needs). The Mac app also contains the small runtimes of the optional engines — whisper.cpp (Whisper) and
transcribe.cpp (Qwen3-ASR, Parakeet); their models and the voice detector are downloaded only when the user asks for
them in 설정 › 음성 인식. License texts ship in `Contents/Resources/licenses/`.

| Component | Use | License (text) |
|---|---|---|
| [Pretendard](https://github.com/orioncactus/pretendard) — © Kil Hyung-jin | UI font, unmodified | SIL Open Font License 1.1 (`licenses/Pretendard-OFL.txt`) |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) v1.9.4 — © The ggml authors | Mac: the optional Whisper engine, compiled in (Metal) | MIT (`licenses/whisper.cpp-MIT.txt`) |
| [Whisper large-v3-turbo](https://github.com/openai/whisper) — © OpenAI; ggml conversion from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) | Mac: model weights, downloaded on request (not bundled) | MIT (`licenses/openai-whisper-MIT.txt`) |
| [Silero VAD](https://github.com/snakers4/silero-vad) v5.1.2 — © Silero Team; ggml conversion from [ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad) | Mac: voice detection for the optional engines, downloaded with the first one | MIT (`licenses/silero-vad-MIT.txt`) |
| [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) v0.3.1 — © The transcribe.cpp authors; includes ggml and miniz | Mac: runtime for Qwen3-ASR and Parakeet (`Contents/Frameworks/libtranscribe.dylib`, Metal) | MIT (`licenses/transcribe.cpp-MIT.txt`, `licenses/transcribe.cpp-third-party.md`) |
| llamafile sgemm (tinyBLAS) — © 2024 Mozilla Foundation; part of the ggml inside transcribe.cpp | Mac: CPU matrix math in `libtranscribe.dylib` | MIT (`licenses/llamafile-sgemm-MIT.txt`) |
| [Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) — © Alibaba Cloud (Qwen team); GGUF conversion from [handy-computer](https://huggingface.co/handy-computer/Qwen3-ASR-1.7B-gguf) | Mac: model weights, downloaded on request (not bundled) | Apache-2.0 (`licenses/Qwen3-ASR-Apache-2.0.txt`) |
| [parakeet-unified-en-0.6b](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) — NVIDIA Corporation; converted to GGUF and quantized (Q5_K_M) by [handy-computer](https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf) | Mac: model weights, downloaded on request (not bundled). Licensed by NVIDIA Corporation under the NVIDIA Open Model License | NVIDIA Open Model License (`licenses/Parakeet-NVIDIA-Open-Model-License.txt`) |

## v1 (macOS 14.2–15, [release v1.0.0](https://github.com/WeldingArc/lecture-transcriber/releases/tag/v1.0.0))

v1 bundles or downloads the open-source components below. Their license texts ship inside the app: `Contents/Resources/licenses/` (copies of the files in
this repo's `licenses/` folder), NumPy's `numpy-*.dist-info/LICENSE.txt`, and
`Contents/Resources/python/lib/python3.11/LICENSE.txt` for CPython and the libraries built into it.

| Component | Use | License (text) |
|---|---|---|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) v1.9.4 — © The ggml authors | speech recognition engine (`whisper-server`, built with Metal) | MIT (`licenses/whisper.cpp-MIT.txt`) |
| [cpp-httplib](https://github.com/yhirose/cpp-httplib) 0.20 — © Yuji Hirose | HTTP server compiled into `whisper-server` | MIT (`licenses/cpp-httplib-MIT.txt`) |
| [JSON for Modern C++](https://github.com/nlohmann/json) 3.11 — © Niels Lohmann | JSON compiled into `whisper-server` | MIT (`licenses/nlohmann-json-MIT.txt`) |
| [Whisper large-v3-turbo](https://github.com/openai/whisper) — © OpenAI; ggml conversion from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) | model weights, downloaded on first launch | MIT (`licenses/openai-whisper-MIT.txt`) |
| [Silero VAD](https://github.com/snakers4/silero-vad) v5.1.2 — © Silero Team | voice activity detection; weights extracted with `tools/export_silero.py` and run in NumPy | MIT (`licenses/silero-vad-MIT.txt`) |
| [NumPy](https://numpy.org) 2.4 | audio arrays, the VAD network | BSD-3-Clause (in its dist-info) |
| [CPython 3.11](https://www.python.org) via [python-build-standalone](https://github.com/astral-sh/python-build-standalone) | embedded runtime for the engine | PSF License; bundled libraries under their own licenses (its `LICENSE.txt`) |
| [Pretendard](https://github.com/orioncactus/pretendard) — © Kil Hyung-jin | UI font, unmodified | SIL Open Font License 1.1 (`licenses/Pretendard-OFL.txt`) |
