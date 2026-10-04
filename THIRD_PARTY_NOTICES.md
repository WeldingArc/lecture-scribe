# Third-party notices

강의 받아쓰기 is MIT-licensed (see `LICENSE`). It bundles or downloads the open-source components
below. Their license texts ship inside the app: `Contents/Resources/licenses/` (copies of the files in
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
