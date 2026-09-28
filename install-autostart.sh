#!/bin/bash
# Installs the login LaunchAgent.
#
# The plist is generated here rather than committed: launchd does not
# understand "~" and requires an absolute path, which differs per user.
#
# Remove it again with: ./install-autostart.sh --uninstall
set -euo pipefail

LABEL="io.github.bosemictoggle"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/BoseMicToggle.app"

if [ "${1:-}" = "--uninstall" ]; then
	launchctl unload "$PLIST" 2>/dev/null || true
	rm -f "$PLIST"
	echo "autostart removed"
	exit 0
fi

if [ ! -d "$APP" ]; then
	echo "$APP is missing -- build it first: ./build.sh" >&2
	exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

# Launch through /usr/bin/open rather than the binary directly: that is how the
# app keeps the bundle identity its Accessibility grant is tied to.
cat > "$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-a</string>
		<string>$APP</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST_END

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "autostart installed: $PLIST"
