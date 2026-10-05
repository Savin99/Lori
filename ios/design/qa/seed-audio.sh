#!/bin/bash
# Кладёт короткую русскую запись в рабочую папку приложения в симуляторе.
# Симулятор не пишет с микрофона и не имеет моделей распознавания,
# поэтому экран записи иначе нечем проверить.
# Приложение должно быть уже установлено: контейнер появляется только после установки.
#
#   ./design/qa/seed-audio.sh <explicit-simulator-uuid>
#
# После этого:
#   xcodebuild -project LoriLocal.xcodeproj -scheme LoriQA \
#     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
#     -only-testing:LoriLocalUITests/TranscriptionUITests \
#     CODE_SIGNING_ALLOWED=NO test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UDID="${1:?укажи UUID тестового симулятора Lori QA}"
NAME="UI sample"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say -v Milena -o "$WORK/sample.aiff" "Проверка плеера записи. Раз, два, три, четыре, пять."
afconvert -f m4af -d aac "$WORK/sample.aiff" "$WORK/$NAME.m4a"

DEST="$WORK/seed"
mkdir -p "$DEST/Transcripts"
cp "$WORK/$NAME.m4a" "$DEST/$NAME.m4a"

# Рядом ложится расшифровка: без неё «Скопировать», «Поделиться» и «Спросить»
# на экране записи выключены, и проверить их нечем — распознавания в симуляторе
# нет вовсе. Таймкоды и метка говорящего здесь нарочно: это тот случай, на
# котором видно и перемотку тапом, и кружок говорящего, и экспорт с именами.
cat > "$DEST/Transcripts/$NAME.md" <<'MD'
# UI sample

_Расшифровано: GigaAM v3 CTC (int8), на этом iPhone_

**[0:00–0:02]** S1: Проверка плеера записи.

**[0:02–0:04]** S1: Раз, два, три, четыре, пять.
MD


python3 "$SCRIPT_DIR/safe-container.py" "$UDID" "$DEST" Documents/Lori/Workspace
