#!/usr/bin/env bash
set -euo pipefail

app_path="${1:?usage: CODEX_SIGN_IDENTITY='Developer ID Application: …' bash Scripts/sign-macos.sh <path-to-app>}"
: "${CODEX_SIGN_IDENTITY:?Set CODEX_SIGN_IDENTITY to the local Developer ID Application identity}"

codesign --deep --force --options runtime --timestamp --sign "$CODEX_SIGN_IDENTITY" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
