#!/bin/bash
# 강의 받아쓰기 installer — downloads the latest release and puts it in your Applications folder.
#
#   curl -fsSL https://raw.githubusercontent.com/WeldingArc/lecture-transcriber/main/scripts/install.sh | bash
#
# One line that picks the right version for this Mac (v2 on macOS 26+, v1 on 14.2–15) and puts it in
# Applications. v1 isn't notarized, so a v1 zip opened from a browser download is blocked by
# Gatekeeper; downloaded with curl it isn't quarantined and opens normally.
set -euo pipefail
REPO="WeldingArc/lecture-transcriber"
URL_V2="https://github.com/$REPO/releases/latest/download/LectureScribe-mac.zip"
URL_V1="https://github.com/$REPO/releases/download/v1.0.0/LectureScribe-mac.zip"       # Whisper version
APP_NAME="강의 받아쓰기.app"

say_ko() { printf '%s\n' "$*"; }

if [ "$(uname -m)" != "arm64" ]; then
  say_ko "죄송해요. Apple Silicon(M1 이상) Mac에서만 동작해요."; exit 1
fi
ver="$(sw_vers -productVersion)"
major="${ver%%.*}"; rest="${ver#*.}"; minor="${rest%%.*}"
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "${minor:-0}" -lt 2 ]; }; then
  say_ko "macOS 14.2 이상이 필요해요. (지금: $ver)"; exit 1
fi
# macOS 26+: v2 (Apple's on-device speech recognition). 14.2–15: v1 (Whisper).
if [ "$major" -ge 26 ]; then URL="$URL_V2"; else URL="$URL_V1"; say_ko "macOS $ver — Whisper 버전(v1)을 설치해요."; fi
URL="${LECTURE_ZIP_URL:-$URL}"     # override: tests

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
say_ko "강의 받아쓰기 내려받는 중…"
curl -fL --progress-bar "$URL" -o "$tmp/app.zip"
ditto -x -k "$tmp/app.zip" "$tmp/unzipped"
[ -d "$tmp/unzipped/$APP_NAME" ] || { say_ko "내려받은 파일이 올바르지 않아요. 잠시 후 다시 시도해 주세요."; exit 1; }

dest="${LECTURE_INSTALL_DIR:-/Applications}"
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
if [ -d "$dest/$APP_NAME" ]; then
  if pgrep -f "$dest/$APP_NAME/Contents/MacOS/" >/dev/null 2>&1; then
    say_ko "강의 받아쓰기가 실행 중이에요. 앱을 종료(⌘Q)한 뒤 이 명령을 다시 실행해 주세요."; exit 1
  fi
  rm -rf "$dest/$APP_NAME"          # update: replace the previous version of this app only
fi
ditto "$tmp/unzipped/$APP_NAME" "$dest/$APP_NAME"
xattr -dr com.apple.quarantine "$dest/$APP_NAME" 2>/dev/null || true

say_ko "설치 완료: $dest/$APP_NAME"
if [ "$major" -ge 26 ]; then
  [ -d "$HOME/Library/Application Support/LectureScribe/models" ] && \
    say_ko "참고: v1의 AI 모델(570MB)은 이제 필요 없어요. 지우려면: rm -rf ~/Library/Application\\ Support/LectureScribe/models"
else
  say_ko "처음 실행하면 AI 모델(약 570MB)을 한 번 내려받아요."
fi
[ -n "${LECTURE_NO_OPEN:-}" ] || open "$dest/$APP_NAME"
