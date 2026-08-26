#!/usr/bin/env bash
# Поднимает локальную библиотеку расшифровок Lori.
set -euo pipefail

cd "$(dirname "$0")"
TOKEN_FILE="${LORI_TOKEN_FILE:-$HOME/.config/lori/token}"
[ -f "$TOKEN_FILE" ] || { echo "нет файла доступа Lori" >&2; exit 1; }

pkill -f "ui/server.mjs" 2>/dev/null || true

node ui/server.mjs > /tmp/lori-bridge.log 2>&1 &
BRIDGE=$!

for _ in $(seq 1 30); do
  if curl -s -m 1 -o /dev/null "http://127.0.0.1:4173/"; then
    break
  fi
  kill -0 "$BRIDGE" 2>/dev/null || {
    echo "Lori не запустилась, смотри /tmp/lori-bridge.log" >&2
    tail -5 /tmp/lori-bridge.log >&2
    exit 1
  }
  sleep 1
done

curl -s -m 1 -o /dev/null "http://127.0.0.1:4173/" || {
  echo "Lori не слушает порт 4173" >&2
  exit 1
}

echo "Lori запущена. Открой сохранённый адрес на телефоне."
wait
