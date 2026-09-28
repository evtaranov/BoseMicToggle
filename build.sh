#!/bin/bash
# Builds BoseMicToggle.app into ~/Applications.
#
# We build a .app rather than a bare binary: the agent needs an Info.plist
# (LSUIElement) and the bundle identity its Accessibility grant is tied to.
#
# IMPORTANT after every rebuild: the signature here is ad-hoc, so the code hash
# changes and macOS treats the build as a new application -- the Accessibility
# grant is lost. Restoring it requires removing the entry from
# System Settings -> Privacy & Security -> Accessibility with "-" and adding it
# again with "+"; toggling the checkbox on the stale entry does not help.
# A stable signing identity (a self-signed certificate) instead of ad-hoc would
# put an end to this.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/BoseMicToggle.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"

# The icon is drawn in code; a prebuilt .icns is committed, but if it is missing
# we regenerate it so a clone without binaries still builds.
if [ ! -f "$SRC_DIR/AppIcon.icns" ]; then
	swift "$SRC_DIR/make-icon.swift" "$SRC_DIR"
	iconutil -c icns "$SRC_DIR/AppIcon.iconset" -o "$SRC_DIR/AppIcon.icns"
fi
cp "$SRC_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

swiftc \
	-O \
	-target "arm64-apple-macos13.0" \
	-framework AVFoundation \
	-framework AppKit \
	-framework ApplicationServices \
	-framework Foundation \
	-o "$APP/Contents/MacOS/BoseMicToggle" \
	"$SRC_DIR/main.swift"

# Signing is mandatory: without it macOS will not grant Accessibility.
codesign --force --sign - "$APP"

echo "built: $APP"
