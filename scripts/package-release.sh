#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="${REMEET_APP_OUTPUT:-$PWD/build/Remeet.app}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
configuration="$(/usr/libexec/PlistBuddy -c 'Print :RemeetBuildConfiguration' "$app_dir/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$configuration" == debug || "$configuration" == Debug ]]; then
  echo 'Refusing package: use a Release build, not a Debug app.' >&2
  exit 1
fi
architecture="$(lipo -archs "$app_dir/Contents/MacOS/Remeet" | tr ' ' '-')"
output_dir="$PWD/build/releases"
archive="$output_dir/Remeet-$version-$architecture.zip"
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
# Stamp only the archive copy. A local Release-optimized build remains a development build.
staging="$(mktemp -d "$output_dir/.package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$app_dir" "$staging/Remeet.app"
plist="$staging/Remeet.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :RemeetBuildKind release' "$plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :RemeetBuildKind string release' "$plist"
/usr/libexec/PlistBuddy -c "Add :RemeetReleaseTag string v$version" "$plist"
# Current distribution is ad-hoc; metadata changes require signing the packaged copy again.
codesign --force --sign - "$staging/Remeet.app"
codesign --verify --strict "$staging/Remeet.app"
ditto -c -k --sequesterRsrc --keepParent "$staging/Remeet.app" "$archive"
(cd "$output_dir" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
echo "$archive"
echo 'Developer ID signing/notarization is not performed; disclose this in the release notes.'
