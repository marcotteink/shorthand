#!/bin/zsh
# Builds Shorthand.app into dist/
set -e
cd "$(dirname "$0")"

swift build -c release

APP="dist/Shorthand.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Shorthand "$APP/Contents/MacOS/Shorthand"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Stable designated requirement: keeps the Accessibility grant valid across rebuilds
codesign --force -s - -r='designated => identifier "ink.marcotte.shorthand"' "$APP"

echo "Built $APP"

# Deploy to /Applications so Spotlight and Launchpad find it
if [ -d "/Applications/Shorthand.app" ] || [ -w "/Applications" ]; then
  rm -rf "/Applications/Shorthand.app"
  cp -R "$APP" "/Applications/Shorthand.app"
  echo "Installed to /Applications/Shorthand.app"
fi
