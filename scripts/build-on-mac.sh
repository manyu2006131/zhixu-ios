#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null; then
  echo '需要安装完整 Xcode 的 Mac。' >&2
  exit 1
fi
# This validates compilation for the simulator; it does not create a signed IPA.
xcodebuild -project Zhixu.xcodeproj -scheme Zhixu -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
