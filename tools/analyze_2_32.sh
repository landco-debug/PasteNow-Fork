#!/bin/bash
set -euo pipefail

OUT="${1:-analysis-out}"
mkdir -p "$OUT"

ZIP="PasteNow-2.32-761.zip"
URL="https://pastenow.app/api/release_manager/downloads/app.pastenow.PasteNow/761.zip"
EXPECTED_SHA="f894ef1fce545beaeb1fbd9446cd391f5636c2d9a963eeb55a59c60f33cd10f0"

echo "Downloading official PasteNow 2.32 build 761..."
curl --fail --location --retry 3 --retry-delay 2 "$URL" -o "$ZIP"

ACTUAL_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
printf 'expected=%s\nactual=%s\n' "$EXPECTED_SHA" "$ACTUAL_SHA" | tee "$OUT/sha256.txt"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "SHA-256 mismatch; refusing to analyze a different build." >&2
  exit 2
fi

rm -rf unpacked
mkdir unpacked
ditto -x -k "$ZIP" unpacked

APP="$(find unpacked -maxdepth 3 -type d -name 'PasteNow.app' -print -quit)"
if [[ -z "$APP" ]]; then
  echo "PasteNow.app not found" >&2
  exit 3
fi

BIN="$APP/Contents/MacOS/PasteNow"
if [[ ! -f "$BIN" ]]; then
  echo "Main executable not found: $BIN" >&2
  exit 4
fi

{
  echo "APP=$APP"
  echo "BIN=$BIN"
  /usr/bin/file "$BIN"
  /usr/bin/lipo -info "$BIN" || true
} > "$OUT/binary-info.txt" 2>&1

/usr/bin/plutil -convert xml1 -o "$OUT/Info.plist.xml" "$APP/Contents/Info.plist"
/usr/bin/codesign -dvvv "$APP" > "$OUT/codesign.txt" 2>&1 || true
/usr/bin/codesign -d --entitlements :- "$APP" > "$OUT/entitlements.plist" 2>&1 || true
/usr/bin/otool -L "$BIN" > "$OUT/otool-L.txt" 2>&1 || true
/usr/bin/otool -l "$BIN" > "$OUT/otool-load-commands.txt" 2>&1 || true
/usr/bin/otool -ov "$BIN" > "$OUT/otool-objc.txt" 2>&1 || true

/usr/bin/nm -nm "$BIN" > "$OUT/nm.txt" 2>&1 || true
if command -v swift-demangle >/dev/null 2>&1; then
  swift-demangle < "$OUT/nm.txt" > "$OUT/nm-demangled.txt" 2>&1 || true
else
  cp "$OUT/nm.txt" "$OUT/nm-demangled.txt"
fi

/usr/bin/strings -a "$BIN" > "$OUT/strings.txt" 2>&1 || true

# Apple-Silicon instruction-level view. This is the target architecture for the user's M1 Mac.
if /usr/bin/lipo "$BIN" -verify_arch arm64 >/dev/null 2>&1; then
  /usr/bin/otool -arch arm64 -tvV "$BIN" > "$OUT/disasm-arm64.txt" 2>&1 || true
  python3 - "$OUT/disasm-arm64.txt" "$OUT/disasm-arm64-focused.txt" <<'PY'
import re, sys
src, dst = sys.argv[1:3]
ranges = [
    (0x100057000, 0x10007b800, "PasteItemViewController"),
    (0x1000abe00, 0x1000ad800, "WindowViewModel"),
]
addr_re = re.compile(r'^([0-9a-fA-F]{16})\\s')
lines = open(src, errors='ignore').read().splitlines()
with open(dst, 'w') as f:
    for lo, hi, label in ranges:
        f.write(f"===== {label} 0x{lo:x}-0x{hi:x} =====\\n")
        active = False
        for line in lines:
            m = addr_re.match(line)
            if m:
                a = int(m.group(1), 16)
                active = lo <= a < hi
            if active:
                f.write(line + "\\n")
PY
fi

PATTERN='paste|pasting|clipboard|selected|selection|select|return|enter|keyDown|keyEquivalent|drag|drop|pasteboard|NSPasteboard|performKeyEquivalent|insert|copy'
grep -Eai "$PATTERN" "$OUT/strings.txt" > "$OUT/strings-targeted.txt" || true
grep -Eai "$PATTERN" "$OUT/nm-demangled.txt" > "$OUT/symbols-targeted.txt" || true
grep -Eai "$PATTERN" "$OUT/otool-objc.txt" > "$OUT/objc-targeted.txt" || true

# Extract Swift/ObjC-ish readable identifiers adjacent to the most useful terms.
python3 - "$OUT/strings.txt" "$OUT/identifier-neighborhoods.txt" <<'PY'
import re, sys
src, dst = sys.argv[1:3]
lines = open(src, errors='ignore').read().splitlines()
needles = re.compile(r'(paste|clipboard|selected|selection|return|enter|keyDown|drag|drop|pasteboard)', re.I)
with open(dst, 'w') as f:
    for i, line in enumerate(lines):
        if needles.search(line):
            lo=max(0,i-3); hi=min(len(lines),i+4)
            f.write(f"--- around line {i+1} ---\n")
            for j in range(lo,hi):
                f.write(f"{j+1}: {lines[j]}\n")
PY

# Keep only text diagnostics in the artifact.
find "$OUT" -type f -maxdepth 1 -print | sort > "$OUT/manifest.txt"
echo "Analysis complete: $OUT"
