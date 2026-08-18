#!/usr/bin/env bash
# Build and launch RÚV Noise from the terminal — no Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-Release}"
DERIVED="build"

echo "Building RÚV Noise ($CONFIG)…"
xcodebuild \
  -project RuvNoise.xcodeproj \
  -scheme RuvNoise \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  -quiet

APP="$DERIVED/Build/Products/$CONFIG/RuvNoise.app"
echo "Launching $APP"
open "$APP"
