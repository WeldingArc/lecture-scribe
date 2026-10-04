#!/bin/bash
# Builds a self-contained "강의 받아쓰기.app" and dist/LectureScribe-mac.zip from a fresh checkout.
#
# Needs (developer machine only — users just download the zip): Apple Silicon Mac, Xcode
# Command Line Tools (swiftc), cmake, git, and uv (https://docs.astral.sh/uv/).
#
#   scripts/build_release.sh            # → build/release/강의 받아쓰기.app + dist/LectureScribe-mac.zip
#
# Environment overrides: BUNDLE_ID, VERSION.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="${BUNDLE_ID:-io.github.joshichoi.lecture-scribe}"
VERSION="${VERSION:-1.0.0}"
WHISPER_TAG="v1.9.4"
VAD_SHA256="870f483e18b0865f3f00d7571a87ee98e48cdd43a2441f418386e304d56b65f8"   # models/silero_vad_16k.npz
PY_VERSION="3.11"
PY_PACKAGES=("numpy==2.4.6")
MIN_MACOS="14.2"                       # Core Audio process taps need 14.2
TARGET="arm64-apple-macos$MIN_MACOS"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"

BUILD="$ROOT/build"
APP="$BUILD/release/강의 받아쓰기.app"
RES="$APP/Contents/Resources"
mkdir -p "$BUILD" "$ROOT/bin" "$ROOT/models" "$ROOT/dist"

step() { printf '\n· %s\n' "$*"; }

for tool in swiftc cmake git uv; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool"; exit 1; }
done
[ "$(uname -m)" = "arm64" ] || { echo "build on an Apple Silicon Mac"; exit 1; }

step "whisper.cpp $WHISPER_TAG (Metal, static)"
minos() { vtool -show-build "$1" 2>/dev/null | awk '/minos/ {print $2; exit}'; }
newer_than_min() { [ "$(printf '%s\n%s\n' "$MIN_MACOS" "$1" | sort -V | tail -1)" != "$MIN_MACOS" ]; }
if [ -x "$ROOT/bin/whisper-server" ] && newer_than_min "$(minos "$ROOT/bin/whisper-server")"; then
  rm -rf "$ROOT/bin/whisper-server" "$ROOT/whisper.cpp/build"     # built for a newer macOS: rebuild
fi
if [ ! -x "$ROOT/bin/whisper-server" ]; then
  [ -d "$ROOT/whisper.cpp" ] || git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$ROOT/whisper.cpp"
  # -ffile-prefix-map: keep the build machine's paths out of the binary's assert messages
  PFX="-ffile-prefix-map=$ROOT/=./"
  cmake -S "$ROOT/whisper.cpp" -B "$ROOT/whisper.cpp/build" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_C_FLAGS="$PFX" -DCMAKE_CXX_FLAGS="$PFX" -DCMAKE_OBJC_FLAGS="$PFX" \
        -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_SDL2=OFF >/dev/null
  cmake --build "$ROOT/whisper.cpp/build" -j 8 --config Release --target whisper-server >/dev/null
  cp "$ROOT/whisper.cpp/build/bin/whisper-server" "$ROOT/bin/whisper-server"
fi

step "Silero VAD weights (NumPy)"
echo "$VAD_SHA256  $ROOT/models/silero_vad_16k.npz" | shasum -a 256 -c - >/dev/null

step "native binaries"
SWIFT=(swiftc -O -swift-version 5 -target "$TARGET" -file-prefix-map "$ROOT/=./")
"${SWIFT[@]}" -o "$ROOT/bin/lecture-tap" "$ROOT/native/lecture-tap.swift" 2>/dev/null
"${SWIFT[@]}" -o "$BUILD/LectureScribe" "$ROOT/native/App.swift" 2>/dev/null

step "icon"
if [ ! -f "$BUILD/AppIcon.icns" ]; then
  swift "$ROOT/native/make_icon.swift" "$BUILD/icon_1024.png" >/dev/null
  ICONSET="$BUILD/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"
fi

step "bundle skeleton"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES/engine/bin" "$RES/engine/models" "$RES/ui" "$RES/licenses"
cp "$BUILD/LectureScribe" "$APP/Contents/MacOS/LectureScribe"
sed -e "s|<string>io.github.joshichoi.lecture-scribe</string>|<string>$BUNDLE_ID</string>|" \
    -e "s|<string>1.0</string>|<string>$VERSION</string>|" "$ROOT/native/Info.plist" > "$APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$RES/AppIcon.icns"
cp "$ROOT/backend.py" "$RES/engine/"
cp "$ROOT/bin/whisper-server" "$ROOT/bin/lecture-tap" "$RES/engine/bin/"
cp "$ROOT/models/silero_vad_16k.npz" "$RES/engine/models/"
cp "$ROOT/ui/index.html" "$RES/ui/"
cp -R "$ROOT/ui/fonts" "$RES/ui/fonts"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/licenses/"* "$RES/licenses/"

step "Python $PY_VERSION runtime + ${PY_PACKAGES[*]}"
uv python install "$PY_VERSION" >/dev/null 2>&1 || true
# the standalone (relocatable) interpreter — never the project's .venv
PYBIN="$(realpath "$(uv python find --no-project --managed-python "$PY_VERSION")")"
PYSRC="$(cd "$(dirname "$PYBIN")/.." && pwd -P)"
[ -f "$PYSRC/lib/python$PY_VERSION/os.py" ] || { echo "not a standalone Python install: $PYSRC"; exit 1; }
ditto "$PYSRC" "$RES/python"
# keep only the interpreter (the other scripts carry shebangs pointing at the build machine)
find "$RES/python/bin" -mindepth 1 ! -name "python$PY_VERSION" -delete
ln -s "python$PY_VERSION" "$RES/python/bin/python3"
PY="$RES/python/bin/python3"
SITE="$RES/python/lib/python$PY_VERSION/site-packages"
# trim what a headless engine never uses
rm -rf "$RES/python/include" "$RES/python/share" "$RES/python/lib/"tcl* "$RES/python/lib/"tk* \
       "$RES/python/lib/"itcl* "$RES/python/lib/"thread* "$RES/python/lib/libtcl"* "$RES/python/lib/libtk"* \
       "$RES/python/lib/pkgconfig" "$RES/python/lib/"libpython*.dylib   # interpreter is static
for d in idlelib tkinter turtledemo ensurepip lib2to3 test unittest/test pydoc_data \
         "config-$PY_VERSION-darwin"; do
  rm -rf "$RES/python/lib/python$PY_VERSION/$d"
done
rm -f "$RES/python/lib/python$PY_VERSION/lib-dynload/_tkinter"*.so
rm -rf "$RES/python/lib/python$PY_VERSION/site-packages/"*
uv pip install --quiet --python "$PY" --target "$SITE" "${PY_PACKAGES[@]}"
find "$SITE" -type d \( -name tests -o -name testing -o -name __pycache__ \) -prune -exec rm -rf {} +
rm -rf "$SITE/bin"
find "$RES/python" -name __pycache__ -type d -prune -exec rm -rf {} +
# uv writes the build machine's install path into sysconfig; restore the neutral default
sed -i '' "s|$PYSRC|/install|g" "$RES/python/lib/python$PY_VERSION/"_sysconfigdata_*.py
# precompile once; the app runs Python with -B so nothing is ever written inside the bundle
"$PY" -I -B -m compileall -f -q -j 0 --invalidation-mode unchecked-hash -s "$RES/" -p "/" \
     "$RES/python/lib" >/dev/null
"$PY" -I -B -c "import numpy; print('  numpy', numpy.__version__)"

step "self-containment check"
bad="$(find "$APP" -type l | while read -r l; do t="$(readlink "$l")"; if [[ "$t" == /* ]]; then echo "$l -> $t"; fi; done)"
[ -z "$bad" ] || { echo "absolute symlinks in bundle:"; echo "$bad"; exit 1; }
leaks="$(grep -rl "$HOME" "$APP" 2>/dev/null || true)"
[ -z "$leaks" ] || { echo "build-machine paths leaked into:"; echo "$leaks" | head; exit 1; }

step "macOS $MIN_MACOS compatibility"
too_new="$(find "$APP" -type f \( -perm -111 -o -name '*.so' -o -name '*.dylib' \) -print0 |
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q "Mach-O" || continue
    v="$(minos "$f")"; if [ -n "$v" ] && newer_than_min "$v"; then echo "$v  ${f#$APP/}"; fi
  done || true)"
[ -z "$too_new" ] || { echo "binaries that need a newer macOS than $MIN_MACOS:"; echo "$too_new"; exit 1; }
# Metal APIs newer than the minimum must be weak-linked (whisper.cpp checks @available at runtime)
strong="$(nm -m "$RES/engine/bin/whisper-server" | grep -E "MTLResidencySet" | grep -v weak || true)"
[ -z "$strong" ] || { echo "whisper-server hard-links macOS 15+ Metal symbols:"; echo "$strong"; exit 1; }
echo "  every binary runs on macOS $MIN_MACOS or later"

step "signing (ad-hoc)"
xattr -cr "$APP"                       # no quarantine/provenance flags from copied files
find "$APP" -type f \( -perm -111 -o -name '*.so' -o -name '*.dylib' \) -print0 |
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then codesign --force --sign - "$f" 2>/dev/null; fi
  done
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

step "zip"
ZIP="$ROOT/dist/LectureScribe-mac.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
echo "  app: $(du -sh "$APP" | cut -f1)   zip: $(du -h "$ZIP" | cut -f1)"
echo "  sha256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "  → $ZIP"
