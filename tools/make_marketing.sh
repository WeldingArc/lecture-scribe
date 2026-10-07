#!/bin/bash
# Marketing screenshots for the App Store and the README: each app screen (the browser demo, demo data only) under a
# feature label, a headline and a line of pitch — a Korean and an English set.
#
#   tools/make_marketing.sh        → docs/appstore/marketing/{ko,en}/NN-name.jpg (2880×1800, Mac App Store size)
#
# Needs the Pretendard font; tools/shot.swift is compiled on the fly. The app's own screens go to build/marketing-src.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SHOT=build/shot
SRC=build/marketing-src
OUT=docs/appstore/marketing
mkdir -p build "$SRC" "$OUT/ko" "$OUT/en"
if [ ! -x "$SHOT" ] || [ tools/shot.swift -nt "$SHOT" ]; then swiftc -O tools/shot.swift -o "$SHOT"; fi
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

# name | ?shot= mode | KO label | KO headline | KO pitch | EN label | EN headline | EN pitch
while IFS='|' read -r name mode ke kt ks ee et es; do
  [ -z "$name" ] && continue
  "$SHOT" "file://$ROOT/ui/index.html?shot${mode:+=$mode}" "$SRC/$name.png" 1440 900 > /dev/null
  for lang in ko en; do
    if [ "$lang" = ko ]; then e=$ke; t=$kt; s=$ks; else e=$ee; t=$et; s=$es; fi
    "$SHOT" "file://$ROOT/tools/marketing.html?lang=$lang&img=$(enc "$ROOT/$SRC/$name.png")&eyebrow=$(enc "$e")&title=$(enc "$t")&sub=$(enc "$s")" \
      "$SRC/$name-$lang.png" 1440 900 > /dev/null
    sips -s format jpeg -s formatOptions 92 "$SRC/$name-$lang.png" --out "$OUT/$lang/$name.jpg" > /dev/null   # ≈ 1/5 of the PNG
  done
  echo "· $name"
done <<'EOF'
01-live||실시간 받아쓰기|강의를 듣는 동안, 실시간으로 받아 적습니다|LearnUs · YouTube · Zoom — Mac에서 나오는 소리라면 무엇이든|LIVE TRANSCRIPTION|Lectures written down live, as you listen|LearnUs, YouTube, Zoom — anything your Mac plays
02-key-sentences|detail|중요 문장|시험·과제·출석, 중요한 문장은 자동으로 표시|놓치기 쉬운 공지를 기록 맨 위에 모아 보여 줍니다|KEY SENTENCES|Exams, assignments, attendance — highlighted for you|Easy-to-miss announcements, collected at the top
03-slides|slides|슬라이드 PDF|강의자 카메라까지 알아보는 슬라이드 PDF|슬라이드가 바뀔 때마다 그때 한 말과 함께 PDF로 모읍니다|SLIDE PDF|A slide PDF that spots the lecturer's camera|Each new slide is saved with what was said while it was up
04-library|library|기록|모든 강의를 한곳에|녹음과 글을 함께 보관하고, 이름 변경과 삭제도 바로|LIBRARY|Every lecture in one place|Recordings and transcripts together — rename or delete right from the list
05-find|find|찾기 · 다시 듣기 · 글 편집|찾고, 다시 듣고, 바로 고칩니다|⌘F로 찾고, 문장을 누르면 그 부분부터 재생하고, 잘못 들린 단어는 글 편집으로|FIND · REPLAY · EDIT|Find it. Hear it again. Fix it.|⌘F to search, click a sentence to replay, fix misheard words in place
06-privacy|settings|개인정보|모든 처리는 이 Mac 안에서|인터넷 전송 없음 · Apple 온디바이스 음성 인식 · 원하면 다른 엔진도|PRIVACY|Everything stays on your Mac|No uploads · Apple's on-device speech recognition · more engines if you want
EOF
echo "→ $OUT/ko, $OUT/en"
