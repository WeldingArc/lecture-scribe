# Model / source manifest (recorded at download time)

| File | Source URL | Notes |
|---|---|---|
| models/ggml-large-v3-turbo-q5_0.bin | https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin | Whisper large-v3-turbo, 5-bit quantized, official whisper.cpp repo (MIT) |
| models/silero_vad_16k.npz | extracted by tools/export_silero.py from https://github.com/snakers4/silero-vad/raw/v5.1.2/src/silero_vad/data/silero_vad.onnx | Silero VAD v5.1.2 (MIT); NumPy port matches ONNX to 1.3e-6, 0/2040 decision mismatches |
| models/ggml-silero-v5.1.2.bin | https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin | Silero VAD v5.1.2 in ggml format (MIT), for v2's optional Whisper engine; 885,098 bytes, sha256 29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf (downloaded 2026-10-06) |
| whisper.cpp/ (source) | https://github.com/ggml-org/whisper.cpp (tag v1.9.4) | built locally with Metal, static |
| ui/fonts/Pretendard-{ExtraLight,Light,Regular}.otf | copied from the locally installed Pretendard family (https://github.com/orioncactus/pretendard) | SIL OFL 1.1, unmodified |
| licenses/Pretendard-OFL.txt | https://raw.githubusercontent.com/orioncactus/pretendard/main/LICENSE | Pretendard license text |
| licenses/*-MIT.txt | MIT text + copyright lines from each project's LICENSE / source headers (whisper.cpp LICENSE copied from the v1.9.4 checkout) | |
