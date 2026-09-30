#!/bin/bash
# Fast local development build & run (No installation to /Applications required)

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

echo "⚡️ Building Debug build..."
xcodegen

# Prefer Xcode-managed Apple Development signing when a local team is supplied.
# With neither override, fresh clones keep the project's ad-hoc default.
if [ -z "${OPENCLIP_DEV_TEAM:-}" ] && [ -z "${OPENCLIP_DEV_SIGN_IDENTITY:-}" ] && [ -f "$PROJECT_DIR/keys/dev-signing-identity" ]; then
  IFS= read -r OPENCLIP_DEV_SIGN_IDENTITY < "$PROJECT_DIR/keys/dev-signing-identity" || true
fi
SIGNING_ARGS=()
if [ -n "${OPENCLIP_DEV_TEAM:-}" ]; then
  SIGNING_ARGS+=("DEVELOPMENT_TEAM=$OPENCLIP_DEV_TEAM" "CODE_SIGN_IDENTITY=Apple Development" "CODE_SIGN_STYLE=Automatic" "-allowProvisioningUpdates")
elif [ -n "${OPENCLIP_DEV_SIGN_IDENTITY:-}" ]; then
  SIGNING_ARGS+=("CODE_SIGN_IDENTITY=$OPENCLIP_DEV_SIGN_IDENTITY" "CODE_SIGN_STYLE=Manual")
fi

xcodebuild -scheme OpenClip -configuration Debug -destination 'platform=macOS,arch=arm64' "${SIGNING_ARGS[@]}" build > /dev/null

# Ask Xcode where it just built, rather than globbing DerivedData: several OpenClip-*
# folders can exist (the hash changes with the project path) and picking the wrong one
# silently launches a stale binary.
BUILT_PRODUCTS_DIR="$(xcodebuild -scheme OpenClip -configuration Debug -destination 'platform=macOS,arch=arm64' "${SIGNING_ARGS[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '/[[:space:]]BUILT_PRODUCTS_DIR = /{print $2; exit}')"
APP_PATH="$BUILT_PRODUCTS_DIR/OpenClip.app"

if [ ! -d "$APP_PATH" ]; then
  # Fall back to the most recently built bundle.
  APP_PATH="$(ls -dt "$HOME/Library/Developer/Xcode/DerivedData/OpenClip-"*/Build/Products/Debug/OpenClip.app 2>/dev/null | head -n 1)"
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "Error: Could not find built OpenClip.app in DerivedData"
  exit 1
fi

echo "Terminating old instances & launching from DerivedData..."
pkill -f OpenClip || true
sleep 0.3
# Launch the bundle through LaunchServices so macOS tracks OpenClip as an application
# for TCC permission requests, rather than inheriting the shell's launch context.
/usr/bin/open -n --stdout /tmp/openclip.log --stderr /tmp/openclip.log "$APP_PATH"

echo "Running directly from: $APP_PATH (logs at /tmp/openclip.log)"
