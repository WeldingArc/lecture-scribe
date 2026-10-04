#!/bin/bash
# 강의 받아쓰기 installer — downloads the latest release and puts it in your Applications folder.
#
#   curl -fsSL https://raw.githubusercontent.com/JoshiChoi/lecture-scribe/main/scripts/install.sh | bash
#
# Why a script: the app is free and not notarized by Apple, so a zip downloaded in a browser is
# blocked by Gatekeeper. Downloaded with curl it isn't quarantined, so it opens normally.
set -euo pipefail
REPO="JoshiChoi/lecture-scribe"
URL="${LECTURE_ZIP_URL:-https://github.com/$REPO/releases/latest/download/LectureScribe-mac.zip}"   # override: tests
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
say_ko "처음 실행하면 AI 모델(약 570MB)을 한 번 내려받아요."
[ -n "${LECTURE_NO_OPEN:-}" ] || open "$dest/$APP_NAME"
