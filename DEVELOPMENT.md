# Development

This repo holds two generations of the app:

- **v2 (current, macOS 26+ and iOS/iPadOS 26+)** — native Swift apps on Apple's on-device SpeechAnalyzer,
  sharing the engine, the session library and the UI: `app/`, `app/ios/`, `ui/`, `project.yml`, `scripts/build_v2.sh`.
- **v1 (macOS 14.2–15)** — Swift shell + Python engine + whisper.cpp: `native/`, `backend.py`,
  `models/`, `tools/`, `tests/`, `scripts/build_release.sh`. Released as
  [v1.0.0](https://github.com/WeldingArc/lecture-scribe/releases/tag/v1.0.0); notes [below](#v1-legacy).

`ui/index.html` is shared: both engines speak the same JSON events to it.

## v2

### Layout

```
app/Audio.swift          audio sources → 16 kHz mono Int16: Core Audio process tap (Mac system audio),
                         microphone (iPhone/iPad), media files
app/Recognizer.swift     SpeechAnalyzer with two SpeechTranscribers (ko-KR + en-US) and the English-quote rescue;
                         `SpeechRecognizer`, the interface every speech engine implements
app/Whisper.swift        Mac: the optional Whisper engine (whisper.cpp, large-v3 turbo) — model download/check/remove
                         and the recognizer (Silero VAD segmenter, v1's language and hallucination rules)
app/WhisperBridge.h      whisper.cpp's C API for Swift (headers from scripts/build_whisper.sh)
app/Engine.swift         sessions, files (.txt, .wav → .m4a), keywords, settings, crash recovery, log
app/Library.swift        기록: lists/opens/renames/deletes sessions (a .txt + its .m4a = one session)
app/Player.swift         plays a session's recording (seek, ±15 s, speed; iOS lock-screen controls)
app/Bridge.swift         page ↔ app commands shared by both apps; `Platform` = what each app does differently
app/Slides.swift         슬라이드 PDF: frame signatures, the slide detector, the per-session collector, video-file
                         extraction, the PDF (slide + what was said per page)
app/ScreenSlides.swift   Mac: the lecture window via SCContentSharingPicker + SCStream (2 fps)
app/main.swift           Mac: AppKit window + WKWebView, menus, CLI test modes
app/ios/App.swift        iPhone/iPad: SwiftUI scene + WKWebView, share sheet, document picker, mic permission
app/ios/Info.plist, Assets.xcassets, PrivacyInfo.xcprivacy
                         iOS app settings (background audio, Files app sharing), icon, privacy manifest
app/Info.plist           usage descriptions, macOS 26 minimum (build settings fill in the $(…) variables)
app/LectureScribe.entitlements
                         App Sandbox: Downloads read-write, user-selected read-only,
                         network.client (WKWebView; the optional Whisper model download),
                         device.audio-input (the process tap)
app/make_icon.swift      renders the app icon (`swift app/make_icon.swift out` → out.png)
project.yml              XcodeGen spec → LectureScribe.xcodeproj (gitignored): targets LectureScribe (Mac) and
                         LectureScribeiOS (iPhone/iPad), same bundle id → one App Store listing
docs/appstore/           App Store screenshots and listing text
tools/shot.swift         renders the UI offscreen with WebKit → PNG (App Store screenshots)
tools/frames.swift       renders an animation frame by frame (the 슬라이드 PDF demo); tools/make_gif.py → GIF
scripts/build_whisper.sh builds whisper.cpp (pinned tag) as portable static libraries → vendor/whisper/ (not committed)
```

### Build

```bash
scripts/build_v2.sh                 # ad-hoc signed → build/v2/강의 받아쓰기.app, dist/v2/LectureScribe-mac.zip
SIGN_ID="Developer ID Application: NAME (TEAMID)" scripts/build_v2.sh     # for GitHub, then notarize:
xcrun notarytool submit dist/v2/LectureScribe-mac.zip --keychain-profile PROFILE --wait
xcrun stapler staple "build/v2/강의 받아쓰기.app"                           # and zip again
```

The script needs only the Command Line Tools. For signed builds and the App Store use Xcode
(`brew install xcodegen && xcodegen generate`, then `scripts/xcode_release.sh github|appstore`).
The iPhone/iPad app builds only through the Xcode project:

```bash
xcodebuild -project LectureScribe.xcodeproj -scheme LectureScribeiOS -destination 'generic/platform=iOS Simulator' build
```

### Test

`build/v2/LectureScribe` is the same program without the bundle — and without the sandbox — so it can
read test files anywhere:

```bash
build/v2/LectureScribe --transcribe some-lecture.m4a      # JSON lines on stdout, files in LECTURE_OUT_DIR
build/v2/LectureScribe --live 30                          # 30 s of system audio
```

Whisper: `LECTURE_ENGINE=whisper` (instead of the saved choice), `LECTURE_MODEL_DIR=<dir>` (where the model is, e.g.
`models/` of a v1 checkout), `LECTURE_MODEL_URL=<url>` + `build/v2/LectureScribe --download-whisper` (the in-app
download from a local server: `python3 -m http.server 8977 --directory models`), `LECTURE_DEBUG=1` (whisper.cpp's log
and per-piece timings in app.log).

Hooks (environment variables): `LECTURE_OUT_DIR`, `LECTURE_AUTOSTART=1`, `LECTURE_AUTOSTOP=<sec>`,
`LECTURE_FAKE_INPUT=<file>` (the file streamed in real time instead of system audio — silent),
`LECTURE_DEV_DIR=<checkout>` (UI from the checkout), `LECTURE_DEBUG=1` (English-phrase decisions on
stderr), `LECTURE_TEST_OPEN=library|<session>|trash:<session>|delete:<session>` (the page opens 기록 or a
session; `trash:` deletes and undoes it, `delete:` deletes it — the page logs what it rendered).

The UI runs in a normal browser as a demo (no sound): `ui/index.html?shot`, `?shot=saved|keywords|library|detail|playing`
for still frames, `&ios` for the iPhone wording. Screenshots: `swiftc -O tools/shot.swift -o /tmp/shot`, then
`/tmp/shot "file://$PWD/ui/index.html?shot=library" library.png 1440 900`. The 슬라이드 PDF demo GIF: `swiftc -O tools/frames.swift -o /tmp/frames`,
`/tmp/frames "file://$PWD/ui/index.html?shot=slidesdemo" /tmp/f 720 660 22 10 __renderDemo`, then
`python3 tools/make_gif.py /tmp/f docs/slides-demo.gif 600`. Logs: `~/Library/Containers/io.github.joshichoi.lecture-scribe/Data/Library/Application Support/LectureScribe/logs/app.log`.

### Speech engines (설정 › 음성 인식)

The page draws whatever engines the app lists, so another platform (a Windows build with WebView2, say) can offer
its own through the same messages:

- app → page `{"ev":"engines","current":"apple","busy":false,"list":[{"id","name","model","desc","state":"absent|downloading|ready|failed","progress","verifying","bytes","removable","error"}]}`
- page → app `engineSelect` / `engineDownload` / `engineCancel` / `engineRemove` with `{"engine": id}`
- an engine implements `SpeechRecognizer` (16 kHz mono Int16 in; `Line`s out — previews replaced by finals with the
  same id, an empty final withdraws a preview) and `Engine.makeRecognizer` picks it.

Whisper (Mac): only the runtime is compiled in (~3.4 MB, `-D WHISPER`); the model (574 MB) and Silero VAD
(0.9 MB) come from Hugging Face on request into Application Support/LectureScribe/Models, are checked against their
SHA-256, and can be removed. whisper.cpp v1.9.4 is built with `GGML_NATIVE=OFF` (an M2-tuned build can crash on
an M1). The first load compiles the Metal shaders (~20–40 s; macOS caches the result, but an update can make it compile
again), so the download ends with a warm-up, and when Whisper is the chosen engine each new build warms up once in the
background at launch; after that a load takes ~0.7 s. Per piece: ~2–9 s on a busy M2 (beam 5, plus a second encode for the
Korean/English check on finals ≥ 2.5 s). Live, it skips previews and the language check while it is behind, so it
catches up rather than drifting — but under GPU contention one decode took ~10 s and the lag reached ~13 s (drained
~12 s after 정지), and in continuous speech a final lands ~20–25 s after its piece starts (22 s cap; previews fill the
gap). Files are read at most 30 s ahead of decoding. Previews are always decoded as Korean (a language check would
double their GPU work), so a long English quote can show a Korean paraphrase in grey for a few seconds before its final
replaces it. A short piece the Korean pass wrote in English anyway is read again as English (the Korean pass drops or
capitalises English words); one Korean can't make sense of becomes English only if Whisper's language identification
is ≥ 0.9 sure it is English (forced into English, unclear Korean comes out as invented English). whisper.cpp keeps that
probability to itself, so it is read from its log line "auto-detected language: en (p = …)" (vendored v1.9.4). Speech the voice detector heard but
no decoded segment covers — Whisper's segment times stretch over what it left out, so each segment's start is
estimated from its length (6 syllables/s for the first segment, 5 after it) — is decoded again with language
identification: English is put in only when Whisper is ≥ 0.9 sure it is English (measured: real quotes 0.98–1.00;
already-transcribed Korean of a slow speaker, misidentified, 0.24–0.62 — it comes out as invented English), Korean only
where Whisper's own timing shows a gap, never text already in the transcript, and not where a segment already has
English words (it heard that speech, if poorly). Known limit: a very
short English reply the Korean pass writes as fluent Korean ("Good question." → "좋은 질문") stays Korean — checking
every short piece's language would cost a GPU pass each. After a model fails to load, the app quits with `_exit`
(ggml's teardown would abort on the half-made Metal state). If the model can't be
loaded at all, Apple's recognizer takes over the session with all the audio buffered so far, and the files are checked
against their SHA-256 — damaged ones are removed, so 설정 offers 다시 시도.

### Engine notes (measured on an M2 MacBook Air)

- SpeechAnalyzer runs 66–97× real time on files. The ko-KR and en-US models are installed by macOS
  through `AssetInventory`; on most Macs they are already there.
- The Korean model writes English speech as low-confidence Latin gibberish (dropped: Latin-only words
  under 0.6 confidence). The English transcriber listens to the same audio; its phrases are spliced in
  by time when they have ≥ 3 words, a mean confidence ≥ 0.45, and less than 25% of their duration
  overlaps confident Korean words. Overlap is measured as intersection duration — word edges jitter by
  tens of milliseconds, so "touches a Korean word" rejects real quotes.
- Sandboxed, the process tap needs `com.apple.security.device.audio-input` as well as
  `NSAudioCaptureUsageDescription`; without the entitlement it delivers silence and no error.
- `AudioDeviceStart` blocks while the permission prompt is on screen, so capture starts off the main thread.
- The tap delivers no samples while nothing plays, so the "no sound" watchdog is wall-clock based (20 s).
- WKWebView in the sandbox needs `com.apple.security.network.client`, even for local pages.
- Ad-hoc signatures change with every build, and macOS then asks for System Audio Recording again;
  certificate-signed builds keep the permission.
- 기록 deletes are undoable: a deleted session waits in Application Support/LectureScribe/Deleted, then
  (Mac) moves to the Trash after 15 s — a sandboxed app can put files in the Trash but not take them out —
  or (iPhone/iPad, no Trash) is removed after 3 days.
- Slide detection: 320×180 grayscale signatures, judged per pixel against each 20×20 tile's own background:
  *added* ink, *removed* ink, *faded* (paler on the same side of the background) or *altered*. Each new picture is
  compared with the current slide's fullest picture, and changed pixels are grouped into 8-connected patches. Only
  added (≥ 20 px or ≥ 2 patches) = a build step: the page keeps the fuller picture. Only removed (≥ 30 px) = an earlier
  step. Ink both erased and added somewhere (a revised number, a corrected code line) = a new slide, never a build.
  Ignored, and merged into the reference picture so they can't pile up: a pointer (a compact mark that moved; one that
  only appears or vanishes counts as a pointer only if one was seen moving in the last 30 s — looked for where nothing
  is known to move, so a camera beside it doesn't hide it), the lecturer's camera (a compact patch within a tile of a
  corner other than the top-left), captions (a band of ≤ 2 rows whose text is replaced) and a chat column (right
  third) when they recur in the same spot within 8 s, subtitles in the bottom rows, and a clock (a small change in a
  clock place, or a tile that ticked twice within 6 s). A band or column that changed away from the title area must
  stay 5.5 s before it becomes a page (a player's controls, a notification). Tiles that change in ≥ 2 consecutive
  frames (a camera, several participants' cameras, a video in the slide, a gesturing presenter) are ignored until they
  have been still for 6 s — never a moving pointer's path, and nothing from a transition: a fade (every frame a blend
  of before and after), a pass through black, or a scroll (the largest patch shifted) teaches nothing. Masked areas are
  merged only while they cover less than half the frame. Revisits match the same picture, the camera, a pointer resting
  elsewhere (at most two compact groups of marks, each only vanished or only appeared, while a pointer has been about),
  a ticking timer, subtitles, or an earlier step of a stored slide (the current slide included). A page is dated to
  when its slide appeared — back over frames that show it with only a pointer elsewhere — not to when it was decided;
  live frames are timed by the audio clock. Files use 1 frame/s with a 1 s settle (live: 2 fps, 1.5 s), so a slide on
  screen for less than ~2.5 s live or ~3 s in a file can be missed.
  Known limits: a single changed character in body text (one revised digit in a table cell) is usually invisible at
  this resolution, so the page keeps the earlier version (several characters are caught); if a player's controls or a
  notification are showing at the very moment a slide changes, the page includes them and the slide can get a second
  page when they hide; a cursor that appears before any pointer has been seen moving can make an extra page; a video
  in a slide that takes about half the picture can give the slide a second page when it stops on another frame; a
  slide that only adds to the previous one is kept as a build step; a pale table highlight, an animated area that
  settles into a static figure under the same title, the last strokes of pen annotation, a fly-in build's last bullet
  in file mode, slides right after a full-window video, and push/zoom transitions with a camera can be missed or late.
  Found by verify9 (52 new scenes; v4 passes 77/104 runs, v3 49/104): a cursor slowly tracing a line (60–160 px/s) is
  learned as a moving area and can hide a bullet that appears there within ~6 s, or a whole slide in a busy Zoom view;
  title-only or one-line slide changes less than ~8–9 s apart in the same place are taken for captions; returns are
  duplicated when captions run inside a browser player or a cursor rests on a photo/gradient slide; player controls
  appearing up to ~2.5 s after a change give the slide a second page; automatic fly-in builds, growing charts, pen
  annotation or a busy chat right after a change date the page 1–4 s late; a resting position under ~7.5 s after a
  scroll can be missed live; switching speaker panels with cameras off, or camera insets ≥ ~200 px from the edges, add a
  page. Separately, a recognizer line that starts with leading silence can put its first sentence on the previous page.
  Harnesses: verify7 (138 scenarios: 124 pass; v3 115, v2 79), verify6 (40-slide mixed and 60-slide real decks, all
  caught; 14 misses+dups over 45 scenarios), the verify8 adversarial set (64: 49 pass; v3 28), and end-to-end on
  lecture videos with `LECTURE_SLIDES=1` (`build/v2/LectureScribe --transcribe lecture.mp4`).
- iPhone/iPad: the microphone session is `.playAndRecord` + `.mixWithOthers`, recording continues with the
  screen locked (background audio) and resumes after calls; the page is reloaded and the state replayed if
  iOS reclaims the web view in the background.

## v1 (legacy)

### Layout

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

### Build

Requirements: Apple Silicon Mac, Xcode Command Line Tools, `cmake`, `git`, [`uv`](https://docs.astral.sh/uv/).

```bash
scripts/build_release.sh          # → build/release/강의 받아쓰기.app and dist/LectureScribe-mac.zip
```

The script builds whisper.cpp (pinned tag, Metal, static), the two Swift binaries and the icon,
embeds a trimmed CPython 3.11 with NumPy (pre-compiled; the app runs Python with
`-I -B` so nothing is ever written inside the signed bundle), signs everything ad hoc and zips it.
The Whisper model is not bundled: the app downloads it on first launch into
`~/Library/Application Support/LectureScribe/models` and verifies its SHA-256.

### Develop without rebuilding

```bash
uv venv --python 3.11 .venv && uv pip install --python .venv/bin/python numpy
scripts/build_release.sh          # once, for bin/
open --env LECTURE_DEV_DIR="$PWD" "build/release/강의 받아쓰기.app"
```

With `LECTURE_DEV_DIR` the app runs `backend.py`, `ui/` and `.venv` from the checkout, and keeps the
model and logs in the checkout's `models/` and `logs/`.

### Tests

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

### Engine notes (measured on an M2 MacBook Air)

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

### App ↔ engine protocol

One JSON object per line. Page/app → engine (stdin): `start`, `stop`, `file {path}`,
`settings {keywords?, timestamps?}`, `retry`, `shutdown`. Engine → page (stdout): `engine {state:
loading|downloading|ready|error}`, `rec {state: recording|finishing|idle}`, `seg {id, t, text, final}`,
`level`, `progress`, `saved`, `settings`, `notice`.
