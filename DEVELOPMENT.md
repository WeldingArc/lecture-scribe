# Development

This repo holds two generations of the app:

- **v2 (current, macOS 26+ and iOS/iPadOS 26+)** — native Swift apps on Apple's on-device SpeechAnalyzer,
  sharing the engine, the session library and the UI: `app/`, `app/ios/`, `ui/`, `project.yml`, `scripts/build_v2.sh`.
- **v1 (macOS 14.2–15)** — Swift shell + Python engine + whisper.cpp: `native/`, `backend.py`,
  `models/`, `tools/`, `tests/`, `scripts/build_release.sh`. Released as
  [v1.0.0](https://github.com/WeldingArc/lecture-transcriber/releases/tag/v1.0.0); notes [below](#v1-legacy).

`ui/index.html` is shared: both engines speak the same JSON events to it.

## v2

### Layout

```
app/Audio.swift          audio sources → 16 kHz mono Int16: Core Audio process tap (Mac system audio),
                         microphone (iPhone/iPad), media files
app/Recognizer.swift     SpeechAnalyzer with two SpeechTranscribers (ko-KR + en-US) and the English-quote rescue;
                         `SpeechRecognizer`, the interface every speech engine implements
app/Whisper.swift        Mac: the optional engines — Whisper (whisper.cpp, large-v3 turbo), Qwen3-ASR and Parakeet
                         (transcribe.cpp): the engine table, model download/check/remove (`ModelStore`) and the
                         recognizer (Silero VAD segmenter, v1's language and hallucination rules, Qwen3's re-reads)
app/WhisperBridge.h      whisper.cpp's and transcribe.cpp's C APIs for Swift (headers from the build scripts below)
app/Engine.swift         sessions, files (.txt, .wav → .m4a), keywords, settings, crash recovery, log
app/Library.swift        기록: lists/opens/renames/deletes sessions (a .txt + its .m4a = one session)
app/Player.swift         plays a session's recording (seek, ±15 s, speed; iOS lock-screen controls)
app/Bridge.swift         page ↔ app commands shared by both apps; `Platform` = what each app does differently
app/Slides.swift         슬라이드 PDF: frame signatures, the slide detector, the per-session collector, video-file
                         extraction, the PDF (slide + what was said per page)
app/CameraFinder.swift   슬라이드 PDF: finds the lecturer's camera (where pixels keep changing while the rest holds
                         still) — left out of slide comparisons and outlined on the live preview
app/ScreenSlides.swift   Mac: the lecture window via SCContentSharingPicker + SCStream (2 fps)
app/main.swift           Mac: AppKit window + WKWebView, menus, CLI test modes
app/ios/App.swift        iPhone/iPad: SwiftUI scene + WKWebView, share sheet, document picker, mic permission
app/ios/Info.plist, Assets.xcassets, PrivacyInfo.xcprivacy
                         iOS app settings (background audio, Files app sharing), icon, privacy manifest
app/Info.plist           usage descriptions, macOS 26 minimum (build settings fill in the $(…) variables)
app/LectureScribe.entitlements
                         App Sandbox: Downloads read-write, user-selected read-only,
                         network.client (WKWebView; the optional model downloads),
                         device.audio-input (the process tap)
app/make_icon.swift      renders the app icon (`swift app/make_icon.swift out` → out.png)
project.yml              XcodeGen spec → LectureScribe.xcodeproj (gitignored): targets LectureScribe (Mac) and
                         LectureScribeiOS (iPhone/iPad), same bundle id → one App Store listing
docs/appstore/           App Store screenshots and listing text
tools/shot.swift         renders the UI offscreen with WebKit → PNG (App Store screenshots)
tools/frames.swift       renders an animation frame by frame (the 슬라이드 PDF demo); tools/make_gif.py → GIF
tools/make_marketing.sh  marketing screenshots (tools/marketing.html: label + headline + pitch over each screen, KO/EN)
scripts/build_whisper.sh builds whisper.cpp (pinned tag) as portable static libraries → vendor/whisper/ (not committed)
scripts/build_transcribe.sh  builds transcribe.cpp (pinned tag) into one self-contained dylib, its ggml private →
                         vendor/transcribe/ (not committed); build_v2.sh puts it in Contents/Frameworks
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

Downloaded engines: `LECTURE_ENGINE=whisper|qwen3|parakeet` (instead of the saved choice), `LECTURE_LANGUAGE=ko|en`,
`LECTURE_MODEL_DIR=<dir>` (the model files plus `ggml-silero-v5.1.2.bin` — make it of hard links: the app deletes files
that fail their checksum), `LECTURE_MODEL_URL=<url>` + `build/v2/LectureScribe --download-engine ID` (the in-app
download from a local server: `python3 -m http.server 8977 --directory models`; `--download-whisper` still works),
`LECTURE_DEBUG=1` (the runtimes' logs, per-piece timings and Qwen3's re-reads in app.log).

Hooks (environment variables): `LECTURE_OUT_DIR`, `LECTURE_AUTOSTART=1`, `LECTURE_AUTOSTOP=<sec>`,
`LECTURE_FAKE_INPUT=<file>` (the file streamed in real time instead of system audio — silent),
`LECTURE_DEV_DIR=<checkout>` (UI from the checkout), `LECTURE_DEBUG=1` (English-phrase decisions on
stderr), `LECTURE_TEST_OPEN=library|<session>|trash:<session>|delete:<session>` (the page opens 기록 or a
session; `trash:` deletes and undoes it, `delete:` deletes it — the page logs what it rendered),
`LECTURE_TEST_QUIT=<sec>` (logs the 녹음 menu as it reads then, then ⌘Q) with `LECTURE_TEST_QUIT_ANSWER=quit|cancel`
(answers the warning 3 s later). CLI: `--live <sec> --pause-at <sec> --pause-for <sec>` pauses a test recording.

The UI runs in a normal browser as a demo (no sound): `ui/index.html?shot`, `?shot=saved|keywords|library|detail|playing|slides|find`
for still frames (`slides`: recording with 슬라이드 PDF, the camera outlined; `find`: ⌘F in a session, `&q=` the word), `&ios` for the iPhone wording. Screenshots: `swiftc -O tools/shot.swift -o /tmp/shot`, then
`/tmp/shot "file://$PWD/ui/index.html?shot=library" library.png 1440 900`. The 슬라이드 PDF demo GIF: `swiftc -O tools/frames.swift -o /tmp/frames`,
`/tmp/frames "file://$PWD/ui/index.html?shot=slidesdemo" /tmp/f 720 660 22 10 __renderDemo`, then
`python3 tools/make_gif.py /tmp/f docs/slides-demo.gif 600 1.75` (1.75 = the page's `DEMO_SPEED`). Marketing screenshots
(App Store and README; a feature label, a headline and a line of pitch over each screen, Korean and English):
`tools/make_marketing.sh` → `docs/appstore/marketing/{ko,en}/*.jpg` (template `tools/marketing.html`; the captions are in the script). Logs: `~/Library/Containers/io.github.joshichoi.lecture-scribe/Data/Library/Application Support/LectureScribe/logs/app.log`.

### Speech engines (설정 › 음성 인식)

The page draws whatever engines the app lists, so another platform (a Windows build with WebView2, say) can offer
its own through the same messages:

- app → page `{"ev":"engines","current":"apple","busy":false,"list":[{"id","name","model","desc","state":"absent|downloading|ready|failed","progress","verifying","bytes","removable","error","languages"}]}`
  (`languages`: the lecture languages an engine writes — Parakeet only "en"; for a Korean lecture the status line and
  설정's footer show Apple as in use, and the chosen Parakeet row says Apple writes the Korean lecture)
- page → app `engineSelect` / `engineDownload` / `engineCancel` / `engineRemove` with `{"engine": id}`
- 강의 언어 (`settings.language`: ko | en, main screen): the lecture's main language. Apple: the main language's
  transcriber writes the transcript and the previews; for an English lecture a Korean aside (a run of Hangul tokens
  from the Korean transcriber, mean confidence ≥ 0.6) replaces the English model's words only where those were unsure
  (mean < 0.5) or absent. Whisper: the main language replaces "ko" in every rule (short pieces, rescue, language ID).
- Apple, Korean lecture: the Korean model writes English speech as Latin words, often confidently — an accented English
  lecture recorded in Korean mode doubled every word ("welcome welcome back. back."). Under an accepted English phrase
  its Latin guesses go: tokens without Hangul overlapping the phrase ±0.15 s by more than half or ending inside it (a
  line's first token often starts in the silence before it), and any run of them that touches the phrase, within 1.5 s
  of it (the two models' word times drift by up to \~1.2 s at a quote's edges) — also on the neighbouring line. A Korean
  word is never dropped, however unsure (unsure Hangul at a quote's edges was real speech: "꼭", "라는", "보세요.").
  A phrase doesn't start with punctuation or with an unsure word stretched over the Korean before it ("Tell,(0.35)"
  0.36–2.64). A Korean word far longer than its letters take to say (> 0.5 s + 0.5 s per syllable) was stretched over
  speech it didn't write: a phrase only such words cover is still accepted — but only if the English model heard every
  word of it surely (≥ 0.5). Its unsure words there are as often its guesses at the Korean around the quote ("Only(0.58)
  to(0.22) result(0.09)…") as real words ("Stay(0.21)", "All(0.29)"), and Apple's confidences vary run to run: every
  threshold tried for trimming them flipped between splicing invented English in and cutting real words off (rounds
  11–12), so such a quote stays lost, as before. Words that Korean speech covers split a phrase into separate quotes.
  The stretched word goes to the side of the quote with time enough to say it (0.15 s a syllable); if both (or neither)
  have, after it — Apple stretches the word after a quote back far more often. (Guessing from the English model's
  unsure words put "바나나입니다." before "All models are wrong…" every time: they are often its guesses at Korean words
  Apple dropped, and they arrive in later results.) Two words glued across a quote — after the last full stop that has
  more of the token after it ("뜻입니다.마셜", "말입니다.베이죠.") or before a copula after 은/는 ("문장은입니다.", not
  "고양이입니다") — are split when each part fits on its side. A quote stays in
  one piece: a Korean word whose place falls inside it goes to the nearer edge, in order. Lines keep Apple's spacing
  between words that still follow each other and never start with punctuation. Measured against the previous build
  (same clips, Apple varies run to run): the 5-accent English clip in Korean mode lost all doubling; quotes come back in
  place on quotes, quotes_live, t3, t2, t6, k13, k15, n1, mixB/mixE (CER t3 18% → 2.5%, t6 50% → 23%, k13 74% → 0%, k15
  66% → 0%, n1 57% → 2%); z5, k5, k10, k11, n4 are unchanged (their quotes have unsure words and stay lost); lecture,
  long1, long2, short, t4, t5, t5b unchanged within Apple's spread. A mechanical check (every Hangul word Apple wrote
  appears, in order, in the line; no doubled words; no leading punctuation) passed on 126 lines of 66 runs, and 476
  recorded Apple outputs (both modes) replayed through this logic and the previous release's (round 13's replay
  harness: identical input, no run-to-run noise) lost no Hangul word; every other difference is a rescued quote, a
  removed duplicate or Korean-model Latin garbage, or (English lecture) an unsure English guess next to an accepted
  aside. Known limits:
  besides those unsure quotes, Apple loses a quote the English model splits into two-word pieces, one whose first word
  is stretched over Korean with no other cue, one glued into a long Korean token ("말해볼게요.거북이에요."); a token that
  merges the words before and after a quote is placed whole ("알고양입니다.").
- Apple, English lecture: a Korean aside replaces the English model's words where those were unsure (unchanged from the
  previous build — refusing long runs without a sentence ending, to stop English spelled out in Hangul, dropped casual
  asides like "자 다들 잘 들어 오늘 출석 단어 바나나 우유 꼭 적어 둬" and was taken out). On the aside's own line the
  English words mostly under it go, as before; on a neighbouring line only unsure ones (< 0.5) — an aside the Korean
  model ended with "…굿 땡큐." must not take "Good question." and "Thank you." with it — and barely heard words (< 0.3)
  touching an aside go anywhere ("Yeah(0.09)" before "자 여기까지 이해되셨나요?"). Known
  limits (as before): Apple's Korean model often doesn't produce a Korean remark in an English lecture at all (short ones
  most often: "오늘 출석 단어는 무지개예요." → nothing), an aside whose first word Apple stretches back over confident
  English is dropped, and heavily Korean-accented English can come out in Hangul in either mode — the 강의 언어 "?"
  says so and points to Qwen3-ASR.
- an engine implements `SpeechRecognizer` (16 kHz mono Int16 in; `Line`s out — previews replaced by finals with the
  same id, an empty final withdraws a preview) and `Engine.makeRecognizer` picks it.

Whisper (Mac): only the runtime is compiled in (\~3.4 MB, `-D WHISPER`); the model (574 MB) and Silero VAD
(0.9 MB) come from Hugging Face on request into Application Support/LectureScribe/Models, are checked against their
SHA-256, and can be removed. whisper.cpp v1.9.4 is built with `GGML_NATIVE=OFF` (an M2-tuned build can crash on
an M1). The first load compiles the Metal shaders (\~20–40 s; macOS caches the result, but an update can make it compile
again), so the download ends with a warm-up, and when Whisper is the chosen engine each new build warms up once in the
background at launch; after that a load takes \~0.7 s. Per piece: \~2–9 s on a busy M2 (beam 5, plus a second encode for the
Korean/English check on finals ≥ 2.5 s). Live, it skips previews and the language check while it is behind, so it
catches up rather than drifting — but under GPU contention one decode took \~10 s and the lag reached \~13 s (drained
\~12 s after 정지), and in continuous speech a final lands \~20–25 s after its piece starts (22 s cap; previews fill the
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

Qwen3-ASR 1.7B and Parakeet 0.6B (Mac) run through [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)
v0.3.1 (MIT), built into one dylib in Contents/Frameworks that exports only `transcribe_*`: it carries its own ggml,
which linked statically next to whisper.cpp's would collide. Models: Q5_K_M GGUFs from handy-computer's Hugging Face
repos (1517 MB, 541 MB), pinned by commit and SHA-256 like Whisper's. Licenses: Qwen3-ASR Apache-2.0; Parakeet the
NVIDIA Open Model License (the GGUF repo's "cc-by-4.0" label is wrong — the model card and the GGUF's own metadata say
nvidia-open-model-license), shipped in Contents/Resources/licenses with NVIDIA's notice. The voice detector file is
shared (one copy; removing an engine keeps it while another engine has it — a ready engine's size shows what 삭제 frees),
one download runs at a time, progress counts only what is missing, and the checksum frees each 8 MB chunk as it goes (it used to hold a 1.5 GB model in memory: 1.57 GB
peak → 53 MB). Same pipeline as Whisper (VAD pieces, previews, Apple takeover and checksum check when a model can't
load); the first load compiles Metal shaders (up to a minute: Qwen3/Parakeet \~40 s, Whisper \~20 s on an M2), hence the
same warm-up. An English-only engine
downloaded while 강의 언어 is 한국어 doesn't push aside an engine that writes Korean (Qwen3-ASR stays chosen, a notice
says how to pick Parakeet for English lectures); chosen anyway, its row says Apple's recognizer writes the Korean lecture.

Qwen3 identifies each piece's language itself and writes both languages as spoken. Told the language, it drops or spells
out in Hangul the English words of a Korean piece, and can even translate ("Time is money." → "타임은 돈이다"; told
English, an English lecture's Korean aside it had taken for Japanese came out "Then, we will continue."), so a reading
with a language hint is kept only for a piece it took for a third language (or wrote with kana or Chinese
characters): read again in the lecture's language — noise and accents make it name any language (kept as it was, noisy
English came out in Thai script, a French reading dropped "Let's review."); a real quote in a third language may then
come out in the lecture's language, rare in these lectures. In an English lecture, a piece Qwen3 itself took for
Japanese or Chinese (a tag other than ko/en, written with kana or Chinese characters) is read as Korean and that reading
kept — in these lectures it is almost always a Korean aside ("クラン継続かけます。" for "그럼 계속하겠습니다.", "苏哲，内伊卡金内。"
for "숙제 내일까지 내."; read as English they came out translated or invented) — unless it is katakana alone, English the
way Japanese writes loanwords ("ハッピーバースデー。", which read as Korean became "하피 버스 데이"). A piece Qwen3 took for
English that contains a Chinese term ("rely on 关系") is read again as English, which leaves it as it was. Its failure modes — measured, all on pieces holding two utterances, all depending on where the
piece was cut (shifting a cut by 0.2 s flips them): a piece taken for the other language comes out translated
("다음 표현을 들어보세요. Actions speak…" → "Next, listen to the following. Actions…"), or its other-language utterance is
left out (the Korean intro before an English quote, Korean asides in an English lecture, an English term inside a Korean
sentence: "말씀하신 는 공유지의 비극"). So a final written in one script whose re-read in the other language finds a
sentence of it (a Korean sentence ending or two Korean words — "출석 단어는 사과." has no ending —, or three English
words), or a Korean final with a particle standing alone (는,
을, 를, 라는, 이라는 — not 이란: "미국과 이란 사이" is Iran), is read again in two halves split at its longest pause
(≥ 0.16 s with ≥ 0.5 s of speech on either side; for a stranded particle its quietest moment), at most twice — and the
halves are kept only if they bring back words of the missing language. Korean: added with no English word lost (casual
endings too: "수박 주스 꼭 메모해 둬"), or in place of English — often the first reading's translation of the aside ("This
is what comes up in the exam" → "이건 시험에 나옵니다.") — only as a clear Korean sentence: a formal ending (니다 요 죠 까)
or two words with particles (은 는 을 를 에 에서 에게 께 한테 야); told Korean, Qwen3 spells English out ("룩 에터 판다.",
"굿모닝 에브리원", and "파파야" ends like "사과야"). English: added, or in place of Hangul — in a Korean lecture about as many
words (a quote first spelled out: "프레티스 메이스 퍼펙트" → "Practice makes perfect"), in an English lecture any number
(that Korean was a reading of English speech). Otherwise the first reading stays (cut in a word, a correct reading can
come out worse: "높아 파지고"). A re-read can still lose a word next to the cut (t7: "네," before "Time is money" went). Cost: about 1.6–2× decode time (lecture.aiff: 17 s for 65 s of audio on an M2; the 5-accent
English clip: 30 s for 124 s); live, the re-reads are skipped while ≥ 3 s behind. Measured (CER): lecture 1.0%, long1
2.4%, long2 1.3%, t3 3.7%, t4 5.8%, t5b 18.6%; quotes_live: all 7 quotes and the 8 Korean intros; mixed_lang, the mix
clips, longq, quotes, t6, t7 and the verifier's n1–n4, q1, q3, q5 verbatim or nearly (names may come out in Latin
letters: "Steve Jobs의"); the 5-accent English clip near-verbatim, even the Korean-accented voice; English mode keeps the
Korean asides (en_lecture_ko_asides 3/3, an attendance sentence Apple loses; the round-11 casual asides e2/e4/e5 0% CER). Known limits: very noisy short Korean
pieces can come out as invented English (t5: "The area is just a bit.", "On now." for 없나요?; CER 74% vs Apple 56%) —
Qwen3 reports no confidence, and its reading told Korean can't be trusted instead (see "Time is money."); likewise a
short Korean aside in an unclear (robotic) voice in an English lecture, heard as English as a whole ("다음 문제로
넘어갈게요." → "So one zero number, okay?") or dropped (an attendance sentence in tr2, in every build); in an English
lecture, Japanese speech itself — a Japanese quote, Japanese fillers in accented English — comes out as Korean (the
Japanese-or-Chinese rule above; rare in these lectures); a casual Korean aside that the first reading translated stays
translated unless its re-read is a clear Korean sentence; a Latin phrase
("Carpe diem") can be left out; a short English line in a Korean voice can come out in Hangul ("Any questions so far?" →
"N E Q S 천슬소파"); a one-word Korean aside in an English lecture comes out romanized ("muzikae"). Parakeet writes
English only: Korean speech is left out or comes out as made-up English ("자, 질문 있는 사람 있나요?" → "I'm not sure if
I can do"), so a Korean lecture uses Apple's recognizer with a notice; \~0.02–0.03 × real time on an M2, weaker than
Qwen3 on strong accents (v9g_english CER 22% vs 6.9%). Fun-ASR-MLT-Nano (also transcribe.cpp) was tried and left out:
it keeps one language per piece — a Korean passage's English quotes and an English one's Korean asides vanish — and
with its text normalization on it stops after the first sentence.

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
- Recordings: a 16 kHz WAV while recording, then AAC (32 kbit/s) in MPEG-4 — written to a hidden `.NAME.part.m4a` and
  checked against the WAV's length before it replaces it. AVAudioFile takes the container from the file name: 2.0–2.2
  wrote to `.NAME.m4a.part` and so made CAF files named .m4a (they play on a Mac, not everywhere).
- 기록 rows show 이름 변경 and 삭제 buttons (and ⋯ / right-click: 열기 · 이름 변경 · 공유 · Finder에서 보기 · 삭제); ⌘⌫ deletes.
  Dialogs make the rest of the page inert, focus 취소 first and give focus back (to the redrawn row, or the next one).
- 일시정지 (live only, `pauseRec`/`resumeRec`, event `paused` with the paused total): the sound is dropped — not recognized,
  not recorded, not on the clock — and the first buffer after pausing becomes 1.5 s of silence for both the recognizer
  and the recording, so the sentence before the break ends there and the transcript's times stay the recording's
  times. Slide frames are ignored meanwhile. The page's clock leaves the paused time out.
- 글 편집 (`saveLines`: the page sends every line; `linesSaved`): the transcript is written again — header, lines, the
  중요 문장 tail made again — and the recording is untouched; a slide PDF keeps its text. An emptied line is removed.
  ⌘F in a session marks every match (`find`), Return / ⇧Return step through them.
- Quitting (Mac) while recording or transcribing asks first (취소 is the default); on 종료 the session is saved, then the
  app quits. ⌘Q while only saving waits for the save (`.terminateLater`). Never answer a pending ⌘Q from inside a
  `DispatchQueue.main` block: the save it waits for runs on the main queue too (that deadlocked).
  The 녹음 menu (⌘R start/stop, ⌘P pause, ⌘O file, ⇧⌘C copy) and 편집 › 찾기 (⌘F) send `command` events to the page.
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
  screen for less than \~2.5 s live or \~3 s in a file can be missed.
  Known limits: a single changed character in body text (one revised digit in a table cell) is usually invisible at
  this resolution, so the page keeps the earlier version (several characters are caught); if a player's controls or a
  notification are showing at the very moment a slide changes, the page includes them and the slide can get a second
  page when they hide; a cursor that appears before any pointer has been seen moving can make an extra page; a video
  in a slide that takes about half the picture can give the slide a second page when it stops on another frame; a
  slide that only adds to the previous one is kept as a build step; a pale table highlight, an animated area that
  settles into a static figure under the same title, the last strokes of pen annotation, a fly-in build's last bullet
  in file mode, slides right after a full-window video, and push/zoom transitions with a camera can be missed or late.
  Found by verify9 (52 new scenes; v4 passes 77/104 runs, v3 49/104): a cursor slowly tracing a line (60–160 px/s) is
  learned as a moving area and can hide a bullet that appears there within \~6 s, or a whole slide in a busy Zoom view;
  title-only or one-line slide changes less than \~8–9 s apart in the same place are taken for captions; returns are
  duplicated when captions run inside a browser player or a cursor rests on a photo/gradient slide; player controls
  appearing up to \~2.5 s after a change give the slide a second page; automatic fly-in builds, growing charts, pen
  annotation or a busy chat right after a change date the page 1–4 s late; a resting position under \~7.5 s after a
  scroll can be missed live; switching speaker panels with cameras off, or camera insets ≥ \~200 px from the edges, add a
  page. Separately, a recognizer line that starts with leading silence can put its first sentence on the previous page.
  Harnesses: verify7 (138 scenarios: 124 pass; v3 115, v2 79), verify6 (40-slide mixed and 60-slide real decks, all
  caught; 14 misses+dups over 45 scenarios), the verify8 adversarial set (64: 49 pass; v3 28), and end-to-end on
  lecture videos with `LECTURE_SLIDES=1` (`build/v2/LectureScribe --transcribe lecture.mp4`).
- The lecturer's camera (`app/CameraFinder.swift`, fed the detector's 320×180 signature): a \~96-column cell grid in
  which each cell keeps a score of how often it changed lately (fading over 20 s); a frame in which most of the
  picture changed at once teaches nothing. A patch that keeps changing, stays compact and lasts — near an edge, or still
  going across a slide change (a GIF in a slide stops with its slide) — is the camera; its box is snapped out to the
  inset's straight edges and kept 45 s while the lecturer sits still. With no camera nothing is marked. Its tiles (5 % of
  a tile inside the box plus a small margin: the edge bleeds into the next tile when the frame is shrunk) are left out
  of every comparison, and stay out 6 s after the camera leaves them (it may have jumped to another corner). While
  recording with 슬라이드 PDF the page shows the frame (a 480 px JPEG about once a second, `slidePreview`) with the camera
  outlined, at the bottom left; hidden under 760 px wide. Against 2.2.0: the W scenes 9 → 12 of 36 (a camera at the top
  right while bullets build: 8 pages → the right 4), the corner-camera scenes 1–2 fewer extra pages each, verify9 one
  wrong final picture fewer; verify7, verify6 and verify8 unchanged. One W scene (a cursor wandering around each
  change, live) gets a duplicate page — the same scene already did from a file.
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
  identical to the ONNX graph within 1.3e-6, \~0.2 ms per 32 ms frame. ONNX Runtime is deliberately
  not used — its macOS builds collect telemetry by default, even with `disable_telemetry_events()`.
- Everything is built for macOS 14.2 (the build fails if any binary needs a newer macOS, and Metal APIs
  from macOS 15+ must be weak-linked).

- whisper large-v3-turbo q5_0 via whisper-server: \~1.4–1.8 s per request regardless of clip length
  (encoder-bound). `no_language_probabilities` is essential (otherwise 2× slower); reduced
  `audio_ctx` breaks turbo. Beam 5 costs \~+0.2 s and is used for finals; live previews are greedy
  and only run when the GPU is idle.
- The segmenter cuts at pauses (needs 1.2 s / 0.6 s / 0.3 s of silence for segments < 4 s / < 12 s /
  ≥ 12 s; hard cap 22 s at the quietest frame).
- Finals ≥ 2.5 s auto-detect Korean/English; when that disagrees with the lecture's majority language
  the sentence is decoded both ways and the more confident reading wins. Shorter finals and previews
  use the majority language — a misdetected short Korean phrase would otherwise come back as an
  English *translation*. Confidence thresholds alone cannot separate English quotes from Korean.
- The Core Audio tap delivers no samples at all while nothing is playing (and before the permission
  is granted), so the "no sound" watchdog is wall-clock based.
- The model unloads after 10 idle minutes and reloads in \~2 s.
- Rebuilding `App.swift` changes the ad-hoc signature, so macOS asks for the System Audio Recording
  permission again.

### App ↔ engine protocol

One JSON object per line. Page/app → engine (stdin): `start`, `stop`, `file {path}`,
`settings {keywords?, timestamps?}`, `retry`, `shutdown`. Engine → page (stdout): `engine {state:
loading|downloading|ready|error}`, `rec {state: recording|finishing|idle}`, `seg {id, t, text, final}`,
`level`, `progress`, `saved`, `settings`, `notice`.
