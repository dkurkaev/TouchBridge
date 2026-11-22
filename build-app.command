#!/bin/bash
# Собирает TouchBridge.app, подписывает и ставит в ~/Applications, затем запускает.
set -e
cd "$(dirname "$0")"
echo "▶︎ swift build"
swift build -c release 2>&1 | tee build.log | tail -5
APP="build/TouchBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/touchbridge "$APP/Contents/MacOS/TouchBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Подпись: сертификат разработчика (разрешения macOS сохраняются между пересборками) или ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -E "Apple Development|Developer ID Application" | sed -E 's/.*"(.*)".*/\1/' || true)
if [ -n "$IDENTITY" ]; then
  echo "▶︎ Подписываю: $IDENTITY"
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "▶︎ Сертификата разработчика нет — ad-hoc подпись (разрешения придётся выдавать заново после пересборки)"
  codesign --force --sign - "$APP"
fi

echo "▶︎ Устанавливаю в ~/Applications"
pkill -x TouchBridge 2>/dev/null || true
sleep 0.5
mkdir -p ~/Applications
rm -rf ~/Applications/TouchBridge.app
cp -R "$APP" ~/Applications/
open ~/Applications/TouchBridge.app
echo "✅ Готово. Иконка руки появилась в строке меню. Лог: ~/Library/Logs/TouchBridge.log"
