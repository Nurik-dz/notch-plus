#!/bin/bash
# Builds "Notch+.app" in this folder with Xcode's toolchain and the macOS SDK.
# Usage: ./build.sh [release|debug]    ./build.sh test   (builds and runs the test harness)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

MODE="${1:-release}"
BUILD="$DIR/build"
mkdir -p "$BUILD"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

if [ "$MODE" = "test" ]; then
    echo "==> Compiling test harness"
    SOURCES=()
    while IFS= read -r -d '' f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' ! -name 'main.swift' -print0)
    xcrun swiftc -Onone -sdk "$SDK" -target arm64-apple-macos26.0 -swift-version 5 \
        -module-name NotchPlusTests "${SOURCES[@]}" Tests/main.swift -o "$BUILD/NotchPlusTests"
    echo "==> Running"
    "$BUILD/NotchPlusTests"
    exit 0
fi

OPT="-O"; [ "$MODE" = "debug" ] && OPT="-Onone -g"
APP="$DIR/Notch+.app"

echo "==> Compiling ($MODE)"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' -print0)
xcrun swiftc $OPT -sdk "$SDK" -target arm64-apple-macos26.0 -swift-version 5 \
    -module-name NotchPlus "${SOURCES[@]}" -o "$BUILD/NotchPlus"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/NotchPlus" "$APP/Contents/MacOS/NotchPlus"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf "APPL????" > "$APP/Contents/PkgInfo"
# the now-playing helper (BSD licensed, see Vendor/THIRD_PARTY.txt)
mkdir -p "$APP/Contents/Frameworks"
cp -R Vendor/MediaRemoteAdapter.framework "$APP/Contents/Frameworks/"
cp Vendor/mediaremote-adapter.pl "$APP/Contents/Resources/"
cp Vendor/THIRD_PARTY.txt "$APP/Contents/Resources/"
# seeking: the adapter's own seek is refused on recent macOS, so a tiny helper (run by the same trusted perl) sends the system's "change playback position" command
xcrun clang -dynamiclib -fobjc-arc -arch arm64 -framework Foundation Vendor/npseek.m -o "$BUILD/libnpseek.dylib"
cp "$BUILD/libnpseek.dylib" "$APP/Contents/Resources/"
cp Vendor/npseek.pl "$APP/Contents/Resources/"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify "$APP"
echo "==> Built: $APP"
