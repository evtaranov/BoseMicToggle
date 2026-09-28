#!/bin/bash
# Ставит автозапуск при входе в систему.
#
# plist генерируется здесь, а не лежит в репозитории: launchd не понимает "~"
# и требует абсолютный путь, а он у каждого свой.
#
# Снять автозапуск: ./install-autostart.sh --uninstall
set -euo pipefail

LABEL="io.github.bosemictoggle"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/BoseMicToggle.app"

if [ "${1:-}" = "--uninstall" ]; then
	launchctl unload "$PLIST" 2>/dev/null || true
	rm -f "$PLIST"
	echo "автозапуск снят"
	exit 0
fi

if [ ! -d "$APP" ]; then
	echo "нет $APP -- сначала соберите: ./build.sh" >&2
	exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

# Запускаем через /usr/bin/open, а не бинарник напрямую: так приложение
# получает bundle-идентичность, от которой зависит грант Accessibility.
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

echo "автозапуск установлен: $PLIST"
