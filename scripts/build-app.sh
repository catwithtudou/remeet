#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Usage: build-app.sh [debug|release]' >&2; exit 2;; esac
app_dir="${REMEET_APP_OUTPUT:-$PWD/build/Remeet.app}"
if [[ -e "$app_dir" || -L "$app_dir" ]]; then
  echo 'Output already exists; choose a new REMEET_APP_OUTPUT path to preserve the existing app.' >&2
  exit 1
fi
# The native SwiftPM backend also works with Command Line Tools without Xcode.
swift build --build-system native -c "$configuration"
binary_dir="$(swift build --build-system native -c "$configuration" --show-bin-path)"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Remeet" "$app_dir/Contents/MacOS/Remeet"
# SwiftPM Release may retain linker debug-map entries with absolute build paths.
# Strip only debug symbols from the packaged copy, before signing it.
if [[ "$configuration" == release ]]; then
  xcrun strip -S "$app_dir/Contents/MacOS/Remeet"
fi
cp Resources/Remeet.icns "$app_dir/Contents/Resources/Remeet.icns"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp quotes.example.json "$app_dir/Contents/Resources/quotes.example.json"
codesign --force --sign - "$app_dir"
echo "$app_dir"
