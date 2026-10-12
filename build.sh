#!/bin/bash
# Builds "Local Hosting.app" into ./build. Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Local Hosting.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LocalHosting "$APP/Contents/MacOS/LocalHosting"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] || swift Resources/make-icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"
if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/Local Hosting.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Local Hosting.app"
fi
