# Development

## Layout

```
native/lecture-tap.swift   system-audio helper: Core Audio process tap → 16 kHz mono float32 on stdout
                           (`--file PATH` decodes any audio/video file the same way)
native/App.swift           app shell: AppKit window + WKWebView, spawns the engine, relays JSON lines
native/Info.plist          NSAudioCaptureUsageDescription etc. (bundle id set by the build script)
native/make_icon.swift     renders the app icon
backend.py                 engine: Silero VAD (NumPy) segmenter → whisper-server (Metal) → events + files
models/silero_vad_16k.npz  Silero VAD v5 weights (tools/export_silero.py extracts them from the official ONNX)
ui/index.html              the whole UI; opened in a normal browser it runs a demo (`?shot` = still frame)
scripts/build_release.sh   self-contained .app + dist/LectureScribe-mac.zip
scripts/install.sh         end-user installer (latest GitHub release)
tests/                     headless drivers, failure scenarios, test-audio generator
```

## Build

Requirements: Apple Silicon Mac, Xcode Command Line Tools, `cmake`, `git`, [`uv`](https://docs.astral.sh/uv/).

```bash
scripts/build_release.sh          # → build/release/강의 받아쓰기.app and dist/LectureScribe-mac.zip
```

The script builds whisper.cpp (pinned tag, Metal, static), the two Swift binaries and the icon,
embeds a trimmed CPython 3.11 with NumPy (pre-compiled; the app runs Python with
`-I -B` so nothing is ever written inside the signed bundle), signs everything ad hoc and zips it.
The Whisper model is not bundled: the app downloads it on first launch into
`~/Library/Application Support/LectureScribe/models` and verifies its SHA-256.

## Develop without rebuilding

```bash
uv venv --python 3.11 .venv && uv pip install --python .venv/bin/python numpy
scripts/build_release.sh          # once, for bin/
open --env LECTURE_DEV_DIR="$PWD" "build/release/강의 받아쓰기.app"
```

With `LECTURE_DEV_DIR` the app runs `backend.py`, `ui/` and `.venv` from the checkout, and keeps the
model and logs in the checkout's `models/` and `logs/`.

## Tests

```bash
tests/make_test_audio.sh                                        # generates the test audio (macOS voices)
LECTURE_OUT_DIR=/tmp/out .venv/bin/python tests/drive_backend.py file tests/lecture.aiff
.venv/bin/python tests/scenarios.py /tmp/scenarios              # failure paths, ≈ 4 min
```

`drive_backend.py` expects the hidden test words 코끼리 and 푸른 하늘 은하수 in the transcript.
`scenarios.py` covers: Korean → English quote → short Korean phrase (nothing may be translated),
whisper-server killed mid-lecture, quitting while saving, and an accidental start/stop.

Engine hooks (environment variables, for tests): `LECTURE_OUT_DIR`, `LECTURE_AUTOSTART=1`,
`LECTURE_AUTOSTOP=<sec>`, `LECTURE_AUTOSTART_ONCE=<flag file>`, `LECTURE_TAP_BIN=tests/fake_tap.py`
with `FAKE_TAP_FILES=a.aiff:b.wav` (real-time file stream instead of system audio),
`LECTURE_IDLE_UNLOAD=<sec>`, `LECTURE_MODEL_URL/SHA256/SIZE`, `LECTURE_DEBUG=1` (transcript text in
logs). Installer: `LECTURE_ZIP_URL`, `LECTURE_INSTALL_DIR`, `LECTURE_NO_OPEN=1`. `kill -USR1 <engine pid>` dumps all thread stacks into `backend.log`.

## Engine notes (measured on an M2 MacBook Air)

- Voice activity detection is Silero VAD v5 re-implemented in NumPy (`SileroVAD` in backend.py):
  identical to the ONNX graph within 1.3e-6, ~0.2 ms per 32 ms frame. ONNX Runtime is deliberately
  not used — its macOS builds collect telemetry by default, even with `disable_telemetry_events()`.
- Everything is built for macOS 14.2 (the build fails if any binary needs a newer macOS, and Metal APIs
  from macOS 15+ must be weak-linked).

- whisper large-v3-turbo q5_0 via whisper-server: ~1.4–1.8 s per request regardless of clip length
  (encoder-bound). `no_language_probabilities` is essential (otherwise 2× slower); reduced
  `audio_ctx` breaks turbo. Beam 5 costs ~+0.2 s and is used for finals; live previews are greedy
  and only run when the GPU is idle.
- The segmenter cuts at pauses (needs 1.2 s / 0.6 s / 0.3 s of silence for segments < 4 s / < 12 s /
  ≥ 12 s; hard cap 22 s at the quietest frame).
- Finals ≥ 2.5 s auto-detect Korean/English; when that disagrees with the lecture's majority language
  the sentence is decoded both ways and the more confident reading wins. Shorter finals and previews
  use the majority language — a misdetected short Korean phrase would otherwise come back as an
  English *translation*. Confidence thresholds alone cannot separate English quotes from Korean.
- The Core Audio tap delivers no samples at all while nothing is playing (and before the permission
  is granted), so the "no sound" watchdog is wall-clock based.
- The model unloads after 10 idle minutes and reloads in ~2 s.
- Rebuilding `App.swift` changes the ad-hoc signature, so macOS asks for the System Audio Recording
  permission again.

## App ↔ engine protocol

One JSON object per line. Page/app → engine (stdin): `start`, `stop`, `file {path}`,
`settings {keywords?, timestamps?}`, `retry`, `shutdown`. Engine → page (stdout): `engine {state:
loading|downloading|ready|error}`, `rec {state: recording|finishing|idle}`, `seg {id, t, text, final}`,
`level`, `progress`, `saved`, `settings`, `notice`.
