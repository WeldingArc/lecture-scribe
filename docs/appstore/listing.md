# App Store Connect — 강의 받아쓰기 (copy & paste)

| Field | Value |
|---|---|
| Name | 강의 받아쓰기 |
| Subtitle | 온라인 강의 실시간 받아쓰기 |
| Bundle ID | io.github.joshichoi.lecture-scribe |
| SKU | lecture-scribe-mac |
| Primary language | Korean |
| Category | Productivity (secondary: Education) |
| Price | Free |
| Age rating | 4+ (answer "No/None" to every question) |
| Copyright | 2026 JoshiChoi |
| Support URL | https://github.com/WeldingArc/lecture-scribe/issues |
| Marketing URL | https://github.com/WeldingArc/lecture-scribe |
| Privacy Policy URL | https://github.com/WeldingArc/lecture-scribe/blob/main/PRIVACY.md |
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
• 음성 인식 엔진 선택 — 기본은 Apple, 원하면 OpenAI의 공개 모델 Whisper(약 575MB)를 한 번 내려받아 Mac 안에서 써요
• 중요 문장 표시 — ‘출석’, ‘시험’, ‘과제’ 같은 단어가 나온 문장에 밑줄을 긋고 파일 끝에 따로 모아 줘요. 단어는 직접 바꿀 수 있어요
• 녹음·영상 파일을 끌어다 놓아도 받아 적어요 (재생 시간보다 훨씬 빨리)
• 슬라이드 PDF — 강의 자료가 없을 때, 슬라이드가 바뀔 때마다 한 장씩 모아 그동안 한 말과 함께 PDF로 만들어요 (보여 줄 강의 창은 직접 골라요)

■ 개인정보
음성 인식은 Apple의 온디바이스 음성 인식으로 Mac 안에서만 처리돼요. 소리와 글은 어디에도 전송되지 않고, 계정도 필요 없어요.

■ 알아 두세요
• macOS 26 이상, Apple Silicon(M1 이상) Mac
• 처음 [시작]을 누를 때 ‘시스템 오디오 녹음’ 권한을 허용해 주세요
• 개인 공부용으로 만들었어요. 강의 녹음이나 녹취록을 다른 사람과 공유하면 저작권 문제가 될 수 있어요

오픈소스(MIT)예요: https://github.com/WeldingArc/lecture-scribe

## What's New (2.0)
• Apple 온디바이스 음성 인식으로 새로 만들었어요 — AI 모델을 따로 내려받을 필요가 없어요
• 새로운 ‘기록’ — 강의마다 녹음과 받아 적은 글을 한곳에서 보고 들을 수 있어요
• 슬라이드 PDF — 슬라이드를 자동으로 모아 한 말과 함께 PDF로
• 말하는 대로 글자가 바로 나타나요
• 영어 구간은 영어 그대로 받아 적어요

## Notes for App Review (English)
Lecture Scribe transcribes the audio that is playing on the Mac (e.g. an online lecture in a browser) in real time, entirely on-device, using Apple's SpeechAnalyzer/SpeechTranscriber (ko-KR, plus en-US to keep English quotes in English). Optionally (Settings › 음성 인식) the user can download the open Whisper large-v3-turbo model (~575 MB, from huggingface.co) and transcribe with it instead — also entirely on-device. No account, no server, no network use for content.

How to test:
1. Launch the app and wait for "준비됨" (Ready).
2. Play any video with speech (Korean works best; English is also transcribed) in Safari or another app.
3. Click the round button (시작 / Start). macOS asks for "System Audio Recording" permission (NSAudioCaptureUsageDescription) — allow it.
4. Text appears live. Click it again (정지 / Stop): a .txt transcript and .m4a recording are saved to ~/Downloads/강의기록. "전체 복사" copies the whole transcript.
5. "기록" (Library) lists every session; open one to see its transcript with the recording — click any sentence to play from there.
6. You can also drag an audio/video file onto the window (or use 파일 불러오기) to transcribe it.
7. Optional: Settings (⌘,) › 음성 인식 › Whisper › "내려받기 · 575MB" downloads the model (checked against its SHA-256); it is then selected, and the next recording uses it. "삭제" removes it again.
8. Optional "슬라이드 PDF" checkbox: when recording starts, macOS's own content-sharing picker (SCContentSharingPicker) asks which window to watch; the app captures only that window, about twice a second, to detect slide changes and builds a PDF of the slides with the transcript. Nothing leaves the Mac, and no Screen Recording permission is requested.

Entitlements:
- com.apple.security.device.audio-input: required to read the Core Audio process tap (AudioHardwareCreateProcessTap) that captures the system's audio output. The app never opens the microphone.
- com.apple.security.files.downloads.read-write: saves transcripts and recordings to ~/Downloads/강의기록.
- com.apple.security.files.user-selected.read-only: reads a file the user picks or drops to transcribe it.
- com.apple.security.network.client: needed by the WKWebView that renders the app's local interface, and for the optional, user-initiated download of the Whisper model files from huggingface.co (plain HTTPS GET requests). No user data is ever sent.
