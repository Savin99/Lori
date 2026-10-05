#!/bin/bash
# Кладёт скачанные ONNX-модели GigaAM в контейнер приложения в симуляторе:
# приложение качает их само, но для интеграционного теста удобнее положить руками.
#
#   ./design/gigaam/seed-models.sh <udid> <папка с GigaAM-v3-rnnt и GigaAM-v3-ctc>
#
# Скачать модели на хост можно так (225 МБ на вариант):
#   BASE=https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/main
#   mkdir -p models/GigaAM-v3-ctc && curl -L -o models/GigaAM-v3-ctc/v3_e2e_ctc.int8.onnx "$BASE/v3_e2e_ctc.int8.onnx"
set -euo pipefail

UDID="${1:?укажи udid симулятора}"
SOURCE="${2:?укажи папку со скачанными моделями}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for variant in GigaAM-v3-rnnt GigaAM-v3-ctc; do
  if [ -d "$SOURCE/$variant" ]; then
    python3 "$SCRIPT_DIR/../qa/safe-container.py" "$UDID" "$SOURCE/$variant" "Library/Application Support/Lori/Models/$variant"
  fi
done
