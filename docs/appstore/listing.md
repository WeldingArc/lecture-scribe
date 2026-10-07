# App Store Connect — 강의 받아쓰기 (copy & paste)

| Field | Value |
|---|---|
| Name | 강의 받아쓰기 |
| Subtitle | 한 마디도 놓치지 않는 실시간 받아쓰기 |
| Name (English localization) | Lecture Transcriber |
| Subtitle (English) | Every word, live and on-device |
| Bundle ID | io.github.joshichoi.lecture-scribe |
| SKU | lecture-scribe-mac |
| Primary language | Korean |
| Category | Productivity (secondary: Education) |
| Price | Free |
| Age rating | 4+ (answer "No/None" to every question) |
| Copyright | 2026 JoshiChoi |
| Support URL | https://github.com/WeldingArc/lecture-transcriber/issues |
| Marketing URL | https://github.com/WeldingArc/lecture-transcriber |
| Privacy Policy URL | https://github.com/WeldingArc/lecture-transcriber/blob/main/PRIVACY.md |
| App Privacy | Data Not Collected |
| Encryption | No (ITSAppUsesNonExemptEncryption = NO in Info.plist) |
| Screenshots (2880×1800), in this order | docs/appstore/live.png, library.png, detail.png, saved.png, keywords.png |

## Promotional text
강의를 틀고 시작만 누르세요. Mac 안에서 바로 받아 적고, 강의마다 녹음과 글을 ‘기록’에 모아 줘요. 인터넷 전송 없음 · 무료.

## Keywords
받아쓰기,강의,자막,녹취,음성인식,필기,온라인강의,녹음,전사,요약,줌,런어스,대학생,STT,메모

## Description
강의 받아쓰기는 Mac에서 재생되는 온라인 강의의 말소리를 실시간으로 받아 적어 주는 앱이에요.

■ 이렇게 써요
런어스·유튜브·줌 등으로 강의를 틀고 [시작]만 누르면, Mac에서 나오는 소리를 그대로 받아 문장 단위로 받아 적어요. 마이크를 쓰지 않아서 이어폰을 껴도, 주변이 시끄러워도 괜찮아요.

■ 주요 기능
• 말하는 대로 글자가 바로 나타나는 실시간 받아쓰기
• 기록 — 강의마다 녹음과 받아 적은 글이 한곳에. 문장을 누르면 그 부분부터 다시 들려줘요
• ‘중요 문장’은 기록 맨 위에 모아 보여 주고, 이름 바꾸기·검색·공유도 돼요
• 텍스트(.txt)와 녹음(.m4a)은 다운로드 폴더의 ‘강의기록’에도 그대로 저장돼요
• 1.5배·2배속 재생도 따라가요
• [전체 복사] 한 번이면 ChatGPT·Claude 같은 AI에 붙여 넣어 요약·정리
• 영어로 말하는 부분은 영어 그대로 적어요 (일부러 번역하지 않아요)
• 음성 인식 엔진 선택 — 기본은 Apple, 원하면 공개 모델 Qwen3-ASR(약 1.5GB, 한국어·영어가 섞인 강의에 강해요)·Whisper(약 575MB)·Parakeet(약 540MB, 영어 강의 전용)를 한 번 내려받아 Mac 안에서 써요
• 중요 문장 표시 — ‘출석’, ‘시험’, ‘과제’ 같은 단어가 나온 문장에 밑줄을 긋고 파일 끝에 따로 모아 줘요. 단어는 직접 바꿀 수 있어요
• 녹음·영상 파일을 끌어다 놓아도 받아 적어요 (재생 시간보다 훨씬 빨리)
• 슬라이드 PDF — 강의 자료가 없을 때, 슬라이드가 바뀔 때마다 한 장씩 모아 그동안 한 말과 함께 PDF로 만들어요 (보여 줄 강의 창은 직접 골라요)

■ 개인정보
음성 인식은 Apple의 온디바이스 음성 인식으로 Mac 안에서만 처리돼요. 소리와 글은 어디에도 전송되지 않고, 계정도 필요 없어요.

■ 알아 두세요
• macOS 26 이상, Apple Silicon(M1 이상) Mac
• 처음 [시작]을 누를 때 ‘시스템 오디오 녹음’ 권한을 허용해 주세요
• 개인 공부용으로 만들었어요. 강의 녹음이나 녹취록을 다른 사람과 공유하면 저작권 문제가 될 수 있어요

오픈소스(MIT)예요: https://github.com/WeldingArc/lecture-transcriber

## What's New (2.1)
• 강의 언어를 고를 수 있어요 — 한국어 / English (시작 버튼 아래)
• 새 음성 인식 엔진(선택, 내려받기): Qwen3-ASR — 한국어와 영어가 섞인 강의, 억양이 강한 영어에 가장 정확해요 · Parakeet — 영어 강의 전용, 빠르고 가벼워요
• 영어로 말하는 강의를 한국어 강의로 받아 적을 때 단어가 두 번씩 적히던 문제를 고쳤어요
• 한국어 문장 사이의 영어 인용을 더 많이, 제자리에 받아 적어요
• 슬라이드 PDF 설명 애니메이션이 더 빨라졌어요
• 첫 화면이 앱이 하는 일을 그림으로 보여 줘요

## What's New (2.0)
• Apple 온디바이스 음성 인식으로 새로 만들었어요 — AI 모델을 따로 내려받을 필요가 없어요
• 새로운 ‘기록’ — 강의마다 녹음과 받아 적은 글을 한곳에서 보고 들을 수 있어요
• 슬라이드 PDF — 슬라이드를 자동으로 모아 한 말과 함께 PDF로
• 말하는 대로 글자가 바로 나타나요
• 영어 구간은 영어 그대로 받아 적어요

## Notes for App Review (English)
Lecture Transcriber transcribes the audio that is playing on the Mac (e.g. an online lecture in a browser) in real time, entirely on-device, using Apple's SpeechAnalyzer/SpeechTranscriber (ko-KR, plus en-US to keep English quotes in English). Optionally (Settings › 음성 인식) the user can download an open speech model — Whisper large-v3-turbo (~575 MB), Qwen3-ASR 1.7B (~1.5 GB) or Parakeet 0.6B (English only, ~540 MB), from huggingface.co — and transcribe with it instead, also entirely on-device. The main screen's 강의 언어 switch (한국어 / English) sets the lecture's main language. No account, no server, no network use for content.

How to test:
1. Launch the app and wait for "준비됨" (Ready).
2. Play any video with speech (Korean works best; English is also transcribed) in Safari or another app.
3. Click the round button (시작 / Start). macOS asks for "System Audio Recording" permission (NSAudioCaptureUsageDescription) — allow it.
4. Text appears live. Click it again (정지 / Stop): a .txt transcript and .m4a recording are saved to ~/Downloads/강의기록. "전체 복사" copies the whole transcript.
5. "기록" (Library) lists every session; open one to see its transcript with the recording — click any sentence to play from there.
6. You can also drag an audio/video file onto the window (or use 파일 불러오기) to transcribe it.
7. Optional: Settings (⌘,) › 음성 인식 › Whisper, Qwen3-ASR or Parakeet › "내려받기 · …MB" downloads that model (checked against its SHA-256); it is then selected, and the next recording uses it. "삭제" removes it again. (Parakeet transcribes English only: with 강의 언어 set to 한국어 the app uses Apple's recognizer and says so, and a Parakeet download then doesn't replace an already chosen engine that writes Korean.)
8. Optional "슬라이드 PDF" checkbox: when recording starts, macOS's own content-sharing picker (SCContentSharingPicker) asks which window to watch; the app captures only that window, about twice a second, to detect slide changes and builds a PDF of the slides with the transcript. Nothing leaves the Mac, and no Screen Recording permission is requested.

Entitlements:
- com.apple.security.device.audio-input: required to read the Core Audio process tap (AudioHardwareCreateProcessTap) that captures the system's audio output. The app never opens the microphone.
- com.apple.security.files.downloads.read-write: saves transcripts and recordings to ~/Downloads/강의기록.
- com.apple.security.files.user-selected.read-only: reads a file the user picks or drops to transcribe it.
- com.apple.security.network.client: needed by the WKWebView that renders the app's local interface, and for the optional, user-initiated download of speech model files (Whisper, Qwen3-ASR, Parakeet) from huggingface.co (plain HTTPS GET requests). No user data is ever sent.
