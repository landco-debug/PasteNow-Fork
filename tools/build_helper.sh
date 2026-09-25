#!/bin/bash
set -euo pipefail

OUT="${1:-dist}"
NAME="PasteNow MultiPaste Helper"
APP="$OUT/$NAME.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$OUT"
mkdir -p "$MACOS"

clang -O2 -fobjc-arc \
  -mmacosx-version-min=13.0 \
  -framework Cocoa \
  -framework ApplicationServices \
  helper/PasteNowMultiPasteHelper.m \
  -o "$MACOS/PasteNowMultiPasteHelper"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>PasteNowMultiPasteHelper</string>
  <key>CFBundleIdentifier</key><string>io.github.landcodebug.PasteNowMultiPasteHelper</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>PasteNow MultiPaste Helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

chmod 755 "$MACOS/PasteNowMultiPasteHelper"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

cat > "$OUT/INSTALL-AND-TEST.txt" <<'EOF'
PasteNow 2.32 MultiPaste Helper

IMPORTANT
This build does NOT replace or modify PasteNow.app.
Use the untouched original PasteNow 2.32 build 761.

INSTALL
1. Quit the crashing PasteNow fork.
2. Restore the original PasteNow.app to /Applications.
   Do not delete PasteNow preferences, history, containers, or databases.
3. Move "PasteNow MultiPaste Helper.app" to /Applications.
4. Open the helper once.
5. Grant Accessibility access when macOS asks.
6. The PN menu-bar item should show "Active for PasteNow" while PasteNow is running.

TEST
1. Put the insertion focus in an app that accepts images.
2. Open PasteNow and select 2 or more image clips.
3. Press Return/Enter once.
4. Expected: all selected images are transferred.
5. Verify one selected item + Enter still uses stock PasteNow behavior.
6. Verify drag-and-drop is unchanged.

The helper uses a keyboard event tap scoped only to the PasteNow process.
It never re-signs or injects code into PasteNow, so PasteNow keeps its original
Developer ID / CloudKit identity.
EOF

ditto -c -k --keepParent "$APP" "$OUT/PasteNow-MultiPaste-Helper-0.2.zip"
shasum -a 256 "$OUT/PasteNow-MultiPaste-Helper-0.2.zip" > "$OUT/PasteNow-MultiPaste-Helper-0.2.zip.sha256"
echo "Built $OUT/PasteNow-MultiPaste-Helper-0.2.zip"
