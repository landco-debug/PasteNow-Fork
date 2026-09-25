#!/bin/bash
set -euo pipefail

OUT="${1:-dist}"
ZIP="PasteNow-2.32-761.zip"
URL="https://pastenow.app/api/release_manager/downloads/app.pastenow.PasteNow/761.zip"
EXPECTED_SHA="f894ef1fce545beaeb1fbd9446cd391f5636c2d9a963eeb55a59c60f33cd10f0"

rm -rf "$OUT" build-pastenow-fork
mkdir -p "$OUT" build-pastenow-fork

echo "Downloading official PasteNow 2.32 build 761..."
curl --fail --location --retry 3 --retry-delay 2 "$URL" -o "build-pastenow-fork/$ZIP"
ACTUAL_SHA="$(shasum -a 256 "build-pastenow-fork/$ZIP" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "SHA-256 mismatch: $ACTUAL_SHA" >&2
  exit 2
fi

ditto -x -k "build-pastenow-fork/$ZIP" build-pastenow-fork/unpacked
APP="$(find build-pastenow-fork/unpacked -maxdepth 3 -type d -name 'PasteNow.app' -print -quit)"
[[ -n "$APP" ]] || { echo "PasteNow.app not found" >&2; exit 3; }

MACOS="$APP/Contents/MacOS"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

if [[ ! -f "$MACOS/PasteNow" ]]; then
  echo "Main executable missing" >&2
  exit 4
fi

mv "$MACOS/PasteNow" "$MACOS/PasteNow.real"

clang -O2 -fobjc-arc -dynamiclib \
  -framework AppKit -framework Foundation -framework CoreServices \
  -Wl,-install_name,@rpath/PasteNowMultiPasteFix.dylib \
  patch/PasteNowMultiPasteFix.m \
  -o "$FRAMEWORKS/PasteNowMultiPasteFix.dylib"

clang -O2 patch/launcher.c -o "$MACOS/PasteNow"
chmod 755 "$MACOS/PasteNow" "$MACOS/PasteNow.real"

# Re-sign the renamed vendor executable ad-hoc WITHOUT Hardened Runtime.
# This is required because Hardened Runtime strips DYLD_INSERT_LIBRARIES.
codesign --remove-signature "$MACOS/PasteNow.real" || true
codesign --force --sign - "$MACOS/PasteNow.real"

# Sign the injected library, launcher, and then the containing app bundle.
codesign --force --sign - "$FRAMEWORKS/PasteNowMultiPasteFix.dylib"
codesign --force --sign - "$MACOS/PasteNow"
codesign --force --deep --sign - "$APP"

PLIST="$APP/Contents/Info.plist"
VERSION="$(defaults read "$PLIST" CFBundleShortVersionString 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(defaults read "$PLIST" CFBundleVersion 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
echo "Base version: $VERSION ($BUILD)"
file "$MACOS/PasteNow" "$MACOS/PasteNow.real" "$FRAMEWORKS/PasteNowMultiPasteFix.dylib"
codesign --verify --deep --strict "$APP"

cat > "$OUT/TESTING.txt" <<'EOF'
PasteNow-Fork — multi-image Enter fix
Base: PasteNow 2.32 build 761

TEST
1. Quit any running PasteNow.
2. Move PasteNow-Fork.app to Applications (or run it from Downloads for the first test).
3. If macOS blocks the ad-hoc-signed fork, right-click the app -> Open once.
4. Select 2 or more IMAGE clips in PasteNow.
5. Press Enter once.
6. Expected: all selected images are pasted/transferred in one action.
7. Verify one selected image still behaves exactly as before.
8. Verify drag-and-drop still works.

The fork leaves PasteNow's normal Enter action intact. For a 2+ selection, it arms a narrow pasteboard hook; only if the first emitted writer is an image does it batch subsequent image writers into one multi-item pasteboard payload. Single-item Enter and non-image multi-selection stay on the stock path.
EOF

mv "$APP" "$OUT/PasteNow-Fork.app"
ditto -c -k --keepParent "$OUT/PasteNow-Fork.app" "$OUT/PasteNow-Fork-2.32-MultiPaste.zip"
shasum -a 256 "$OUT/PasteNow-Fork-2.32-MultiPaste.zip" > "$OUT/PasteNow-Fork-2.32-MultiPaste.zip.sha256"
echo "Built $OUT/PasteNow-Fork-2.32-MultiPaste.zip"
