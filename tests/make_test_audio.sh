#!/bin/bash
# Generates the test audio used by tests/*.py with macOS's built-in voices (nothing downloaded).
# Needs the Korean voice "Yuna" (System Settings → Accessibility → Spoken Content → System voice).
set -euo pipefail
cd "$(dirname "$0")"
ROOT=..
PY="$ROOT/.venv/bin/python"
say -v '?' | grep -q '^Yuna ' || { echo "Korean voice 'Yuna' is not installed"; exit 1; }
EN=$(say -v '?' | grep -Eo '^(Samantha|Alex|Daniel|Karen|Fred) ' | head -1 | tr -d ' ')

say -v Yuna -r 175 -o lecture.aiff -f lecture.txt          # ~75 s, hidden words: 코끼리 · 푸른 하늘 은하수
say -v Yuna -o short.aiff -f short.txt                      # ~20 s, hidden word: 파인애플
afconvert -f WAVE -d LEI16@16000 -c 1 short.aiff short.wav

# Korean → English quote → short Korean phrase → Korean: nothing may come back translated.
say -v Yuna -o mx1.aiff "오늘은 애덤 스미스의 국부론에서 유명한 문장을 함께 읽어 보겠습니다."
say -v "$EN" -o mx2.aiff "It is not from the benevolence of the butcher, the brewer, or the baker that we expect our dinner."
say -v Yuna -o mx3.aiff "단어는 사과."
say -v Yuna -o mx4.aiff "이 문장을 꼭 기억하세요. 출석 확인 문구는 무지개입니다."
"$PY" - <<'PY'
import subprocess, wave, numpy as np
def pcm(f):
    raw = subprocess.run(["../bin/lecture-tap", "--file", f], capture_output=True, check=True).stdout
    return np.frombuffer(raw, "<f4")
gap = np.zeros(int(16000 * 1.4), np.float32)
parts = []
for f in ["mx1.aiff", "mx2.aiff", "mx3.aiff", "mx4.aiff"]:
    parts += [pcm(f), gap]
def save(name, x):
    with wave.open(name, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
save("mixed_lang.wav", np.concatenate(parts))
save("silence_4s.wav", np.zeros(16000 * 4, np.float32))
PY
rm -f mx1.aiff mx2.aiff mx3.aiff mx4.aiff

# Sped-up playback (needs ffmpeg; skipped otherwise)
if command -v ffmpeg >/dev/null; then
  for sp in 1.5 2.0; do
    ffmpeg -loglevel error -y -i lecture.aiff -filter:a "atempo=$sp" -ar 16000 -ac 1 "lecture_x$sp.wav"
  done
fi
ls -1 *.aiff *.wav
