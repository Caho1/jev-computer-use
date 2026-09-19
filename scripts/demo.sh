#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then echo 'Native demo requires macOS.' >&2; exit 2; fi
jev_source_dir="$(cd "$(dirname "$0")" && pwd)"
jev_demo_dir="$HOME/Library/Caches/jev-mac-use/JevMacLab.app"
mkdir -p "$jev_demo_dir/Contents/MacOS"
cat > "$jev_demo_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.jev.maclab</string>
<key>CFBundleExecutable</key><string>JevMacLab</string>
<key>CFBundleName</key><string>Jev Mac Lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -O -framework AppKit "$jev_source_dir/DemoApp.swift" -o "$jev_demo_dir/Contents/MacOS/JevMacLab"
codesign --force --sign - "$jev_demo_dir"
open "$jev_demo_dir"
echo 'Jev Mac Lab is open. Keep it frontmost during the test.'
