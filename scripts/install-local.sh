#!/bin/zsh
# Build a Release copy signed with a local self-signed identity and install it to /Applications.
# WHY: a stable signing identity keeps the Accessibility grant across rebuilds; ad-hoc signing loses it every time.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:-SwiftShift Local}"
APP="build/dd/Build/Products/Release/Swift Shift.app"

security find-identity -p codesigning | grep -q "\"$IDENTITY\"" \
  || { echo "No code-signing identity named \"$IDENTITY\" in the keychain."; exit 1; }

mkdir -p build
echo "Building (log: build/install.log)..."
# WHY hardened runtime off: library validation rejects the embedded Sparkle framework under a self-signed identity with no team ID.
xcodebuild -project "Swift Shift.xcodeproj" -scheme "Swift Shift" -configuration Release \
  -derivedDataPath build/dd \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  ENABLE_HARDENED_RUNTIME=NO \
  build > build/install.log 2>&1 \
  || { tail -30 build/install.log; exit 1; }

codesign --verify --deep --strict "$APP"

osascript -e 'quit app "Swift Shift"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/Swift Shift.app"
ditto "$APP" "/Applications/Swift Shift.app"

# WHY: Sparkle would otherwise offer the upstream release and replace this build.
defaults write com.pablopunk.Swift-Shift SUEnableAutomaticChecks -bool false

codesign -dv "/Applications/Swift Shift.app" 2>&1 | grep -E "Identifier|Authority"
open "/Applications/Swift Shift.app"
