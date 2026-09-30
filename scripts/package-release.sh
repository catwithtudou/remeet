#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="${REMEET_APP_OUTPUT:-$PWD/build/Remeet.app}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
architecture="$(lipo -archs "$app_dir/Contents/MacOS/Remeet" | tr ' ' '-')"
output_dir="$PWD/build/releases"
archive="$output_dir/Remeet-$version-$architecture-local-test.zip"
if [[ -e "$archive" || -e "$archive.sha256" ]]; then
  echo "Already exists; preserve the prior artifact: $archive" >&2
  exit 1
fi
codesign --verify --strict "$app_dir"
# Scan raw bytes: Mach-O-aware strings tools can skip linker debug-map paths.
if LC_ALL=C /usr/bin/grep -aEq '/(Users|home)/[^/[:space:]]+/' "$app_dir/Contents/MacOS/Remeet"; then
  echo 'Refusing package: binary contains a personal build path. Rebuild Release with build-app.sh.' >&2
  exit 1
elif [[ $? -gt 1 ]]; then
  echo 'Refusing package: binary path scan failed.' >&2
  exit 1
fi
mkdir -p "$output_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive"
(cd "$output_dir" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
echo "$archive"
echo 'Local test package only; Developer ID signing/notarization is not performed.'
