#!/bin/bash
# Кладёт короткую русскую запись в рабочую папку приложения в симуляторе.
# Симулятор не пишет с микрофона, поэтому экран записи иначе нечем проверить.
# Приложение должно быть уже установлено: контейнер появляется только после установки.
#
#   ./design/qa/seed-audio.sh [udid]
#
# После этого:
#   xcodebuild -project LoriLocal.xcodeproj -scheme LoriLocal \
#     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
#     -only-testing:LoriLocalUITests/RecordingPlayerUITests \
#     CODE_SIGNING_ALLOWED=NO test
set -euo pipefail

BUNDLE_ID="ru.ilyaqa.lori.local"
UDID="${1:-booted}"
NAME="UI sample"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say -v Milena -o "$WORK/sample.aiff" "Проверка плеера записи. Раз, два, три, четыре, пять."
afconvert -f m4af -d aac "$WORK/sample.aiff" "$WORK/$NAME.m4a"

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
DEST="$CONTAINER/Documents/Lori/Workspace"
mkdir -p "$DEST"
cp "$WORK/$NAME.m4a" "$DEST/$NAME.m4a"

echo "готово: $DEST/$NAME.m4a"
