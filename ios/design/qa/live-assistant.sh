#!/bin/bash
# Живой прогон ассистента по настоящему сервису.
#
# Ключ агенту не передаётся и в репозитории не лежит: скрипт читает его из
# файла владельца и отдаёт тестовому процессу переменной окружения. Вывод
# xcodebuild фильтруется на случай, если ключ куда-то просочится.
#
#   mkdir -p ~/.config/lori && pbpaste > ~/.config/lori/assistant-key
#   chmod 600 ~/.config/lori/assistant-key
#   ./design/qa/live-assistant.sh [имя-теста]
set -u -o pipefail

KEY_FILE="${LORI_ASSISTANT_KEY_FILE:-$HOME/.config/lori/assistant-key}"
MODEL="${LORI_ASSISTANT_MODEL:-deepseek-v4-flash}"
DEVICE="${LORI_SIMULATOR:-iPhone 17 Pro}"
IOS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ ! -f "$KEY_FILE" ]; then
  echo "Нет файла с ключом: $KEY_FILE"
  echo "Положите туда ключ ассистента — тесты без него просто пропускаются."
  exit 1
fi

KEY="$(tr -d ' \t\r\n' < "$KEY_FILE")"
if [ -z "$KEY" ]; then
  echo "Файл $KEY_FILE пуст."
  exit 1
fi

# Проверка формы, а не значения: сам ключ не печатается никогда. Без неё в файл
# однажды уехало содержимое буфера обмена, и это выяснилось только по ответу
# сервиса — после четырёх запросов и пары минут ожидания.
case "$KEY" in
  sk-*) ;;
  *)
    echo "В $KEY_FILE лежит не ключ: ${#KEY} знаков, начинается не на «sk-»."
    echo "Похоже, в буфере обмена было что-то другое. Откройте файл и вставьте ключ руками:"
    echo "  open -e $KEY_FILE"
    exit 1
    ;;
esac
if [ "${#KEY}" -lt 20 ] || [ "${#KEY}" -gt 200 ]; then
  echo "В $KEY_FILE подозрительная длина: ${#KEY} знаков."
  exit 1
fi

ONLY="LoriLocalTests/AssistantLiveTests"
if [ $# -gt 0 ]; then ONLY="$ONLY/$1"; fi

echo "Живой прогон: $ONLY, модель $MODEL"

# Ключ уходит в тестовый процесс через SIMCTL_CHILD_ (симулятор) и
# TEST_RUNNER_ (раннер) — какой из них сработает, зависит от типа цели.
export SIMCTL_CHILD_LORI_ASSISTANT_KEY="$KEY"
export SIMCTL_CHILD_LORI_ASSISTANT_MODEL="$MODEL"
export TEST_RUNNER_LORI_ASSISTANT_KEY="$KEY"
export TEST_RUNNER_LORI_ASSISTANT_MODEL="$MODEL"

xcodebuild \
  -project "$IOS_ROOT/LoriLocal.xcodeproj" \
  -scheme LoriQA \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -only-testing:"$ONLY" \
  test 2>&1 | sed "s|$KEY|<ключ>|g"

exit "${PIPESTATUS[0]}"
