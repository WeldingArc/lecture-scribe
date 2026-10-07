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
| Marketing screenshots (2880×1800, upload these) | Korean store: docs/appstore/marketing/ko/01-live.jpg, 02-key-sentences.jpg, 03-slides.jpg, 04-library.jpg, 05-find.jpg, 06-privacy.jpg · English store: the same names in docs/appstore/marketing/en/ (a headline and a line of pitch over each screen; re-render with `tools/make_marketing.sh`) |
| Screenshots (2880×1800), in this order | docs/appstore/screenshots/01-start.png, 02-live.png, 03-library.png, 04-playback.png, 05-saved.png, 06-slide-pdf.png, 07-settings.png (demo data only; re-render with tools/shot.swift and `?shot=start / (none) / library / playing / saved / slidesdemo&t=19.5 / settings` at 1440×900; the 2.0 set is kept in docs/appstore/*.png) |

## Promotional text
강의를 틀고 시작만 누르면 됩니다. Mac 안에서 바로 받아 적고, 강의마다 녹음과 글을 ‘기록’에 모아 줍니다. 인터넷 전송 없음 · 무료.

## Keywords
받아쓰기,강의,자막,녹취,음성인식,필기,온라인강의,녹음,전사,요약,줌,런어스,대학생,STT,메모

## Description
강의 받아쓰기는 Mac에서 재생되는 온라인 강의의 말소리를 실시간으로 받아 적어 주는 앱입니다.

■ 사용 방법
런어스·유튜브·줌 등으로 강의를 틀고 [시작]만 누르면, Mac에서 나오는 소리를 그대로 받아 문장 단위로 받아 적습니다. 마이크를 사용하지 않으므로 이어폰을 껴도, 주변이 시끄러워도 괜찮습니다.

■ 주요 기능
• 말하는 대로 글자가 바로 나타나는 실시간 받아쓰기
• 기록 — 강의마다 녹음과 받아 적은 글이 한곳에. 문장을 누르면 그 부분부터 다시 들려줍니다
• ‘중요 문장’은 기록 맨 위에 모아 보여 주고, 기록마다 보이는 버튼으로 이름 변경·삭제를 바로 할 수 있습니다
• ⌘F로 기록 안에서 단어를 찾고, 잘못 들린 단어는 [글 편집]으로 바로 고칩니다
• 쉬는 시간에는 [일시정지] — 그동안의 소리는 녹음하지 않고, [계속]을 누르면 이어서 받아 적습니다
• 텍스트(.txt)와 녹음(.m4a)은 다운로드 폴더의 ‘강의기록’에도 그대로 저장됩니다
• 1.5배·2배속 재생도 따라갑니다
• [전체 복사] 한 번이면 ChatGPT·Claude 같은 AI에 붙여 넣어 요약·정리
• 영어로 말하는 부분은 영어 그대로 적습니다 (일부러 번역하지 않습니다)
• 음성 인식 엔진 선택 — 기본은 Apple, 원하면 공개 모델 Qwen3-ASR(약 1.5GB, 한국어·영어가 섞인 강의에 강합니다)·Whisper(약 575MB)·Parakeet(약 540MB, 영어 강의 전용)를 한 번 내려받아 Mac 안에서 사용합니다
• 중요 문장 표시 — ‘출석’, ‘시험’, ‘과제’ 같은 단어가 나온 문장에 밑줄을 긋고 파일 끝에 따로 모아 줍니다. 단어는 직접 바꿀 수 있습니다
• 녹음·영상 파일을 끌어다 놓아도 받아 적습니다 (재생 시간보다 훨씬 빨리)
• 슬라이드 PDF — 강의 자료가 없을 때, 슬라이드가 바뀔 때마다 한 장씩 모아 그동안 한 말과 함께 PDF로 만듭니다 (보여 줄 강의 창은 직접 선택합니다). 강의자 카메라는 스스로 찾아 테두리로 표시하고 슬라이드 인식에서 제외합니다

■ 개인정보
음성 인식은 Apple의 온디바이스 음성 인식으로 Mac 안에서만 처리됩니다. 소리와 글은 어디에도 전송되지 않고, 계정도 필요 없습니다.

■ 참고 사항
• macOS 26 이상, Apple Silicon(M1 이상) Mac
• 처음 [시작]을 누를 때 ‘시스템 오디오 녹음’ 권한을 허용하십시오

■ 이용 안내 및 면책
강의 받아쓰기는 개인 학습을 돕기 위한 도구입니다.
• 녹음하거나 받아 적은 강의, 슬라이드, 녹취록의 저작권은 강의자와 학교 등 원저작권자에게 있습니다.
• 녹음 파일, 녹취록, 슬라이드 PDF는 본인의 학습 용도로만 사용하십시오. 다른 사람에게 공유·배포하거나 인터넷에 게시하면 저작권 침해가 될 수 있습니다.
• 녹음하기 전에 해당 수업의 녹음·녹화 규정과 강의자의 방침을 확인하십시오.
• 앱 사용으로 발생하는 모든 법적 책임은 사용자 본인에게 있으며, 개발자는 이에 대해 책임지지 않습니다.
• 음성 인식 결과에는 오류가 있을 수 있습니다. 중요한 내용은 원래 강의에서 확인하십시오.
• 처음 실행할 때 이 내용에 동의해야 사용할 수 있으며, 설정에서 다시 볼 수 있습니다.

오픈소스(MIT)입니다: https://github.com/WeldingArc/lecture-transcriber

## What's New (2.3)
• 기록마다 이름 변경·삭제 버튼이 바로 보입니다 (⋯ 또는 우클릭으로 공유)
• 일시정지 / 계속 — 쉬는 시간의 소리는 녹음하지 않습니다 (⌘P)
• 글 편집 — 잘못 들린 단어를 기록에서 바로 고칩니다
• ⌘F로 기록 안에서 찾기
• ‘녹음’ 메뉴와 단축키: ⌘R 시작·정지, ⌘O 파일 불러오기
• 녹음 중에 종료하거나 창을 닫으면 먼저 확인하고, 종료하더라도 지금까지의 내용을 저장합니다
• 슬라이드 PDF: 강의자 카메라를 스스로 찾아 표시하고 슬라이드 인식에서 제외합니다 (카메라 때문에 같은 슬라이드가 여러 장 담기던 문제를 줄였습니다)

## What's New (2.2)
• 앱 전체의 문구를 격식 있는 표현으로 다듬었습니다
• 처음 실행할 때 이용 안내 및 면책 고지를 표시합니다(설정 › 정보에서 다시 볼 수 있습니다)

## What's New (2.1)
• 강의 언어를 선택할 수 있습니다 — 한국어 / English (시작 버튼 아래)
• 새 음성 인식 엔진(선택, 내려받기): Qwen3-ASR — 한국어와 영어가 섞인 강의, 억양이 강한 영어에 가장 정확합니다 · Parakeet — 영어 강의 전용, 빠르고 가볍습니다
• 영어로 말하는 강의를 한국어 강의로 받아 적을 때 단어가 두 번씩 적히던 문제를 수정했습니다
• 한국어 문장 사이의 영어 인용을 더 많이, 제자리에 받아 적습니다
• 슬라이드 PDF 설명 애니메이션이 더 빨라졌습니다
• 첫 화면이 앱이 하는 일을 그림으로 보여 줍니다

## What's New (2.0)
• Apple 온디바이스 음성 인식으로 새로 만들었습니다 — AI 모델을 따로 내려받을 필요가 없습니다
• 새로운 ‘기록’ — 강의마다 녹음과 받아 적은 글을 한곳에서 보고 들을 수 있습니다
• 슬라이드 PDF — 슬라이드를 자동으로 모아 한 말과 함께 PDF로
• 말하는 대로 글자가 바로 나타납니다
• 영어 구간은 영어 그대로 받아 적습니다

## Notes for App Review (English)
Lecture Transcriber transcribes the audio that is playing on the Mac (e.g. an online lecture in a browser) in real time, entirely on-device, using Apple's SpeechAnalyzer/SpeechTranscriber (ko-KR, plus en-US to keep English quotes in English). Optionally (Settings › 음성 인식) the user can download an open speech model — Whisper large-v3-turbo (about 575 MB), Qwen3-ASR 1.7B (about 1.5 GB) or Parakeet 0.6B (English only, about 540 MB), from huggingface.co — and transcribe with it instead, also entirely on-device. The main screen's 강의 언어 switch (한국어 / English) sets the lecture's main language. No account, no server, no network use for content.

How to test:
1. Launch the app. On first launch it shows a usage notice and disclaimer (이용 안내 및 면책 고지: personal study use only; recorded lectures, slides and transcripts stay the copyright of their owners and must not be shared or distributed; check the course's recording policy first; the user bears any legal responsibility; transcripts can contain errors) — click "동의하고 시작" (Agree and start); it can be reopened from Settings › 정보 or Help › 이용 안내 및 면책 고지. Then wait for "준비됨" (Ready).
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
