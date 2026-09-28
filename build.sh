#!/bin/bash
# Собирает BoseMicToggle.app в ~/Applications.
#
# Собираем .app, а не отдельный бинарник: агенту нужен Info.plist (LSUIElement)
# и bundle-идентичность, от которой зависит грант Accessibility.
#
# ВАЖНО после каждой пересборки: подпись здесь ad-hoc, поэтому хэш кода
# меняется и macOS считает сборку новым приложением -- грант Accessibility
# слетает. Восстанавливается только удалением записи из
# Настройки -> Конфиденциальность -> Универсальный доступ кнопкой "-"
# и добавлением заново через "+"; переключение галочки на старой записи
# не помогает. Чтобы это прекратилось, нужна стабильная подпись
# (самоподписанный сертификат) вместо ad-hoc.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/BoseMicToggle.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"

# Иконка рисуется кодом; в репозитории лежит готовый .icns, но если его нет --
# собираем заново, чтобы клон без бинарников тоже собирался.
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

# Подпись обязательна: без неё macOS не выдаёт приложению Accessibility.
codesign --force --sign - "$APP"

echo "собрано: $APP"
