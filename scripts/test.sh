#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
frameworks="$developer_dir/Library/Developer/Frameworks"
args=(--build-system native --disable-xctest)
# Some Command Line Tools releases ship Testing.framework but SwiftPM does not
# add a framework search path. Keep this local to the build, not global settings.
if [[ -d "$frameworks/Testing.framework" ]]; then
    args+=(-Xswiftc -F -Xswiftc "$frameworks"
           -Xlinker -F -Xlinker "$frameworks"
           -Xlinker -rpath -Xlinker "$frameworks")
fi
# Recent CLT versions keep Testing's interop runtime outside the framework path.
testing_runtime="$developer_dir/Library/Developer/usr/lib"
if [[ -f "$testing_runtime/lib_TestingInterop.dylib" ]]; then
    args+=(-Xlinker -rpath -Xlinker "$testing_runtime")
fi
swift test "${args[@]}" "$@"
