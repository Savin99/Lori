#!/bin/bash
# Кладёт «диалог двух голосов» в рабочую папку приложения в симуляторе —
# для живой проверки разделения говорящих (diarization_mode у Gemini).
#
# В macOS установлен один русский голос (Milena), поэтому второй «говорящий»
# делается сдвигом высоты тона через ffmpeg: для проверки полей запроса и
# разбора ответа этого достаточно, но настоящее качество диаризации меряется
# только на записи двух живых людей.
#
#   ./design/qa/seed-dialog.sh <explicit-simulator-uuid>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UDID="${1:?укажи UUID тестового симулятора Lori QA}"
NAME="Dialog sample"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say -v Milena -o "$WORK/a1.aiff" "Здравствуйте, давайте начнём встречу. Сегодня обсуждаем расшифровку."
say -v Milena -o "$WORK/b1.aiff" "Согласен, начинаем. У меня два вопроса по словарю и таймкодам."
say -v Milena -o "$WORK/a2.aiff" "Хорошо, отвечаю по порядку. Сначала про словарь имён и терминов."
say -v Milena -o "$WORK/b2.aiff" "Спасибо, это всё, что я хотел узнать. Заканчиваем запись."

# Второй голос: ниже тоном (0.84) с возвратом темпа (1.19), паузы — тишина 0.7 с.
for part in b1 b2; do
  /opt/homebrew/bin/ffmpeg -v error -y -i "$WORK/$part.aiff" \
    -af "asetrate=22050*0.84,aresample=22050,atempo=1.19" "$WORK/$part-low.wav"
done
for part in a1 a2; do
  /opt/homebrew/bin/ffmpeg -v error -y -i "$WORK/$part.aiff" "$WORK/$part-low.wav"
done
/opt/homebrew/bin/ffmpeg -v error -y -f lavfi -i anullsrc=r=22050:cl=mono -t 0.7 "$WORK/gap.wav"

/opt/homebrew/bin/ffmpeg -v error -y \
  -i "$WORK/a1-low.wav" -i "$WORK/gap.wav" -i "$WORK/b1-low.wav" -i "$WORK/gap.wav" \
  -i "$WORK/a2-low.wav" -i "$WORK/gap.wav" -i "$WORK/b2-low.wav" \
  -filter_complex "[0][1][2][3][4][5][6]concat=n=7:v=0:a=1" "$WORK/dialog.wav"
afconvert -f m4af -d aac "$WORK/dialog.wav" "$WORK/$NAME.m4a"

DEST="$WORK/seed"
mkdir -p "$DEST"
cp "$WORK/$NAME.m4a" "$DEST/$NAME.m4a"


python3 "$SCRIPT_DIR/safe-container.py" "$UDID" "$DEST" Documents/Lori/Workspace
