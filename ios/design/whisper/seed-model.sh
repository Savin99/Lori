#!/bin/bash
# Кладёт скачанную Core ML-модель Whisper в контейнер приложения в симуляторе.
# Приложение её не качает намеренно (632 МБ), а владелец кладёт папку через
# «Файлы» — для интеграционного теста то же самое делается этим скриптом.
#
#   ./design/whisper/seed-model.sh <udid> [папка с моделью]
#
# Скачать модель на хост: python3 design/whisper/fetch_model.py --out <папка>
set -euo pipefail

UDID="${1:?укажи udid симулятора}"
SOURCE="${2:-$HOME/Library/Caches/lori-models/whisper-large-v3-turbo}"
# Имя как в репозитории WhisperKit: движок ищет папку со словом «whisper»,
# так что имя не жёсткое, но пусть совпадает с тем, что качает fetch_model.py.
NAME="openai_whisper-large-v3-v20240930_turbo_632MB"

for part in MelSpectrogram.mlmodelc AudioEncoder.mlmodelc TextDecoder.mlmodelc tokenizer.json tokenizer_config.json; do
  [ -e "$SOURCE/$part" ] || { echo "в $SOURCE нет $part — прогони fetch_model.py" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/../qa/safe-container.py" "$UDID" "$SOURCE" "Documents/Lori/Models/$NAME"
