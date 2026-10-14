#!/bin/bash
# Makes the public download: dist/Notch-Plus-<version>.dmg, ad-hoc signed (NOT notarized: that needs a paid
# Apple Developer account). Prints the sha256 for the Homebrew cask.
# Usage: ./Scripts/make_dmg.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
OUT="$DIR/dist"
DMG="$OUT/Notch-Plus-$VERSION.dmg"
mkdir -p "$OUT"

echo "==> Building with a plain ad-hoc signature"
NOTCH_SIGN=adhoc ./build.sh

# Work in a scratch folder (not Desktop or iCloud, so Finder adds no tags or extended attributes).
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Notch+"
ditto --norsrc --noextattr "$DIR/Notch+.app" "$STAGE/Notch+/Notch+.app"
xattr -cr "$STAGE/Notch+/Notch+.app"
codesign --force --deep --sign - "$STAGE/Notch+/Notch+.app"
codesign --verify --deep --strict "$STAGE/Notch+/Notch+.app"
ln -s /Applications "$STAGE/Notch+/Applications"
cp "$DIR/Scripts/Read me first.txt" "$STAGE/Notch+/Read me first.txt"

echo "==> Making the disk image"
rm -f "$DMG"
hdiutil create -volname "Notch+" -srcfolder "$STAGE/Notch+" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
codesign --force --sign - "$DMG"
hdiutil verify "$DMG" >/dev/null
SUM="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "$SUM  $(basename "$DMG")" > "$DMG.sha256"
echo "==> $DMG"
echo "    size   $(du -h "$DMG" | awk '{print $1}')"
echo "    sha256 $SUM"
