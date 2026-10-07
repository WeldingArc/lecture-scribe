<div align="center">

<img src="docs/icon-v2.png" width="112" alt="">

# Lecture Transcriber (강의 받아쓰기)

<p><a href="README.md">한국어</a> · <b>English</b></p>

**A Mac app that transcribes online lectures in real time**<br>
Apple on-device speech recognition · free · open source · everything stays on your Mac

<img src="docs/appstore/screenshots/02-live.png" width="760" alt="Lecture Transcriber — live transcription">

<img src="docs/appstore/screenshots/03-library.png" width="760" alt="Library — each lecture's transcript and recording together">

<sub>The app's interface is in Korean.</sub>

</div>

## Features

- **Speech recognition:** transcribes on your Mac with **Apple's on-device speech recognition (SpeechAnalyzer)**, built into macOS. There is nothing to download, and the lecture never leaves your Mac.
- **Other speech engines (optional).** Download one once in Settings › 음성 인식 (Speech recognition) to use it instead of Apple's. All run entirely on your Mac, and you can delete them when you no longer need them. (They use more power than Apple's.)
  - **Qwen3-ASR** (Alibaba's open model, about 1.5 GB) — the most accurate for lectures that mix Korean and English and for strongly accented English. (It may spell foreign names in English letters inside Korean sentences, write a very strongly Korean-accented short English line in Hangul, or turn unclear short Korean speech into made-up English. Japanese spoken in an English lecture comes out as Korean.)
  - **Whisper large-v3 turbo** (OpenAI's open model, about 575 MB)
  - **Parakeet** (NVIDIA's open model, about 540 MB) — for English lectures only. Korean speech is dropped or comes out as made-up English. The fastest and lightest of the downloadable engines.
- **Transcribes whatever your Mac is playing.** LearnUs, YouTube, Zoom — just play it. It never uses the microphone, so you can wear earphones and background noise doesn't matter.
- **Words appear as they are spoken.** When you stop, a text file (`.txt`) and a recording (`.m4a`) are saved automatically to `Downloads/강의기록`.
- **Library (기록)** — each lecture's recording and transcript in one place inside the app. Click a sentence to play from there; important sentences are collected at the top. Rename, search and share sessions.
- **Playback speed.** It keeps up with lectures played at 1.5× or 2×.
- **[전체 복사] (Copy all)** copies the whole transcript in one click, ready to paste into an AI such as ChatGPT or Claude for a summary.
- **English lectures.** Choose the lecture language under the start button: **한국어 / English**. An English lecture is transcribed in English, and Korean said in between is written in Korean where possible. Apple's recognizer can miss Korean remarks in an English lecture (short ones most often); Qwen3-ASR catches more of them.
- **Strong accents.** A strong accent can make the recognizer hear the other language (for example, strongly accented English written in Hangul). For an English lecture, switch to **English** before you start. With a very strong accent Apple's recognizer can still get it wrong; use **Qwen3-ASR** then — it is the most accurate on accented English. (Qwen3-ASR can also get short phrases wrong in a very noisy recording.)
- **English stays English.** Nothing is translated on purpose. (A very short English reply such as "Good question." can occasionally come out in Korean.) Apple's recognizer can miss a short English quote between Korean sentences entirely; if English quotes matter (exam phrases, for example), use Qwen3-ASR.
- **Important sentences** — sentences containing words such as 출석 (attendance), 시험 (exam) or 과제 (assignment) are underlined and collected at the end of the saved file. You choose the words.
- **File transcription** — drop an audio or video file onto the window to transcribe it much faster than real time. (For a one-hour lecture: about 1–2 minutes with Apple or Parakeet, 15–30 minutes with Whisper or Qwen3-ASR; longer when English is mixed in or the speech pauses often.)
- **Slide PDF (슬라이드 PDF)** — for classes that don't share their slides, check 슬라이드 PDF. Each time the slide changes, it is captured and put into a PDF together with what was said while it was on screen. A slide that fills in line by line is kept once, fully filled in, and the lecturer's camera is ignored. (Mac: pick the lecture window · iPhone/Mac: also from video files)

<p align="center"><img src="docs/slides-demo.gif" width="600" alt="How the slide PDF works"></p>

## Requirements

- **macOS 26 (Tahoe) or later** on an Apple Silicon (M1 or later) Mac
- On macOS 14.2–15, use [v1 (the Whisper version)](https://github.com/WeldingArc/lecture-transcriber/releases/tag/v1.0.0). The install command below picks the right version for your macOS automatically.

## Install

### Option 1 · One line in Terminal

Open the **Terminal** app (search "Terminal" in Spotlight), paste this line and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/WeldingArc/lecture-transcriber/main/scripts/install.sh | bash
```

Run the same line again to update.

### Option 2 · Download

Download `LectureScribe-mac.zip` from the [latest release](https://github.com/WeldingArc/lecture-transcriber/releases/latest), unzip it, and move `강의 받아쓰기.app` to your Applications folder. The app is not notarized yet, so if you downloaded it with a browser, right-click the app and choose **Open** the first time.

## First launch

On first launch the app shows a **usage notice and disclaimer** (이용 안내 및 면책 고지). Read it and click **[동의하고 시작] (Agree and start)**. The first time you click **[시작] (Start)**, macOS asks for **"System Audio Recording"** permission → **Allow**. (If the Korean speech model isn't on your Mac yet, macOS downloads it once.)

## How to use

1. Play the lecture and click **[시작] (Start)**
2. When it ends, click **[정지] (Stop)** → the text and recording are saved
3. Open past lectures in **[기록] (Library)** to listen again, or paste them into an AI with **[전체 복사] (Copy all)**

- **Transcribe a file:** drop an audio or video file onto the window, or use [파일 불러오기] (Open file)
- **Change the important words:** [중요 단어] at the bottom
- **Shortcut:** ⌘⇧C copies everything

## Good to know

- **For personal study.** Sharing or distributing lecture recordings or transcripts can raise copyright and portrait-right issues and may break your school's rules. See the usage notice and disclaimer below.
- Transcription is not perfect. Proper nouns such as names, and numbers (e.g. 4장 "chapter 4" heard as 사장 "president"), can be wrong, so check anything important against the recording.

## Usage notice and disclaimer

Lecture Transcriber is a tool to support personal study. On first launch you must agree to the following before using the app; you can read it again under Settings › 정보 › 이용 안내 및 면책 고지, or from the Help menu.

- Lectures, slides and transcripts you record or transcribe with this app remain the copyright of their owners, such as the lecturer and the university.
- Use recordings, transcripts and slide PDFs only for your own study. Sharing or distributing them, or posting them online, may infringe copyright.
- Before recording, check your course's recording policy and the lecturer's wishes.
- You alone are responsible for any legal consequences of using the app; the developer accepts no liability.
- Transcripts can contain errors. Check anything important against the original lecture.

## FAQ

<details>
<summary>I clicked [시작] (Start) but no text appears</summary>

Make sure the lecture is actually playing. If text still doesn't appear, open **System Settings → Privacy & Security → Screen & System Audio Recording**, turn on 강의 받아쓰기 in the **"System Audio Recording Only"** list, and reopen the app.
</details>

<details>
<summary>I updated from v1</summary>

Transcripts made with v1 stay in the `강의기록` folder in your home folder. From v2 on, they are saved to `Downloads/강의기록` (because of Apple's sandbox).

The Whisper model v1 used (570 MB) is no longer needed. To free the space, run this in Terminal:

```bash
rm -rf ~/Library/Application\ Support/LectureScribe/models
```
</details>

<details>
<summary>I want to uninstall the app</summary>

Move the app to the Trash, then delete the `~/Library/Containers/io.github.joshichoi.lecture-scribe` folder, which holds the settings and any downloaded speech models. To delete only a model, click ‘삭제’ (Delete) in Settings › 음성 인식. Your transcripts stay in `Downloads/강의기록`.
</details>

<details>
<summary>Something went wrong</summary>

Attach `app.log` from **Help → 로그 폴더 열기 (문제 신고용)** (Open log folder, for reporting problems) to an [issue](https://github.com/WeldingArc/lecture-transcriber/issues). The log contains neither your transcripts nor your Mac user name.
</details>

## How it works

```
Mac system audio ─▶ Core Audio tap (macOS 14.2+) ─▶ Apple SpeechAnalyzer
                                                   ├─ Korean recognition (live preview + final sentences)
                                                   └─ English recognition → English quotes kept, placed by word timing and confidence
                                               ─▶ the window + Downloads/강의기록 (.txt, .m4a)
```

When you choose another engine, a small runtime inside the app — **whisper.cpp** for Whisper, **transcribe.cpp** for Qwen3-ASR and Parakeet — transcribes with the downloaded model instead of SpeechAnalyzer. A voice-activity detector (Silero VAD) splits the audio at pauses, English quotes stay in English (Qwen3-ASR reads a piece again in two halves when it looks translated or seems to have dropped words), and made-up phrases (such as "Thank you for watching") and repeats are filtered out.

It is a single native Swift app (AppKit + WKWebView) that runs in Apple's sandbox. The app is about 16 MB (speech models are downloaded only if you choose one). To build it yourself, see [DEVELOPMENT.md](DEVELOPMENT.md).

**v1** ran OpenAI Whisper large-v3-turbo with whisper.cpp. It remains available for macOS 14.2–15 as the [v1.0.0 release](https://github.com/WeldingArc/lecture-transcriber/releases/tag/v1.0.0).

## License

MIT. Third-party software and licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the privacy policy is in [PRIVACY.md](PRIVACY.md).
