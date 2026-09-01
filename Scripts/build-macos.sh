#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="$repo_root/.build/xcode"
cd "$repo_root"

if ! command -v swift >/dev/null 2>&1 || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Swift and Xcode are required on macOS." >&2
  exit 2
fi

swift test --package-path Packages/CodexTouchCore
xcodebuild \
  -project CodexTouchBar.xcodeproj \
  -target CodexTouchBar \
  -configuration Debug \
  -sdk macosx \
  SYMROOT="$derived_data/Build/Products" \
  OBJROOT="$derived_data/Build/Intermediates.noindex" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

echo "Built app: $derived_data/Build/Products/Debug/CodexTouchBar.app"
