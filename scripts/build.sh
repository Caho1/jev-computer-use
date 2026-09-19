#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Build requires macOS and Xcode Command Line Tools.' >&2
  exit 2
fi
jev_source_dir="$(cd "$(dirname "$0")" && pwd)"
jev_cache_dir="$HOME/Library/Caches/jev-mac-use"
mkdir -p "$jev_cache_dir"
xcrun swiftc -swift-version 5 -O -framework AppKit -framework ApplicationServices \
  "$jev_source_dir/AXBridge.swift" -o "$jev_cache_dir/axbridge"
codesign --force --sign - "$jev_cache_dir/axbridge"
"$jev_cache_dir/axbridge" --doctor
