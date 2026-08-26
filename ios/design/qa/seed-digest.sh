#!/bin/bash
# Кладёт в рабочую папку приложения полный набор для проверки карточки записи:
# запись, её дословную расшифровку и обработанную заметку в тематической папке.
#
# Зачем: в симуляторе нет ни моделей распознавания, ни ключа модели, поэтому
# ни расшифровку, ни обработку там получить нельзя — а переключатель
# «Важное ↔ Расшифровка» проверить надо.
#
#   ./design/qa/seed-digest.sh [udid]
#
# После этого:
#   xcodebuild -project LoriLocal.xcodeproj -scheme LoriLocal \
#     -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
#     -only-testing:LoriLocalUITests/DigestCardUITests \
#     CODE_SIGNING_ALLOWED=NO test
set -euo pipefail

BUNDLE_ID="ru.ilyaqa.lori.local"
UDID="${1:-booted}"
NAME="UI sample"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say -v Milena -o "$WORK/sample.aiff" "Проверка карточки записи. Раз, два, три, четыре, пять."
afconvert -f m4af -d aac "$WORK/sample.aiff" "$WORK/$NAME.m4a"

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
DEST="$CONTAINER/Documents/Lori/Workspace"
mkdir -p "$DEST/Transcripts" "$DEST/Работа"

# Набор должен быть повторяемым: заметки, созданные прошлым прогоном из этих же
# записей, убираем. Ищем по front matter, а не по имени файла — имя придумывает модель.
find "$DEST" -name "*.md" -type f -print0 2>/dev/null | while IFS= read -r -d "" note; do
  if grep -q "^audio: UI live.m4a$" "$note" 2>/dev/null; then
    rm -f "$note"
  fi
done
cp "$WORK/$NAME.m4a" "$DEST/$NAME.m4a"

cat > "$DEST/Transcripts/$NAME.md" <<'EOF'
# UI sample

**[00:00–00:06]** Значит смотри, по найму у нас два кандидата, первый сильнее в бэкенде.

**[00:06–00:13]** Оффер надо выкатить до пятницы, иначе его перехватят.
EOF

cat > "$DEST/Работа/Планёрка по найму.md" <<EOF
---
lori: digest
audio: $NAME.m4a
transcript: Transcripts/$NAME.md
theme: Работа
tags: найм, планёрка
created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---

# Планёрка по найму

Разобрали двух кандидатов и договорились о сроке оффера.

## Важное
- Первый кандидат сильнее в бэкенде
- Оффер нужен до пятницы, иначе кандидата перехватят

## Решения
- Берём первого кандидата

## Задачи
- [ ] Выкатить оффер до пятницы
EOF

# Вторая пара — запись с расшифровкой, но БЕЗ обработанной заметки.
# На ней проверяется сама обработка: приложение должно сходить в модель и создать
# заметку само. Первая пара для этого не годится — там заметка уже лежит.
LIVE="UI live"
cp "$WORK/$NAME.m4a" "$DEST/$LIVE.m4a"
cat > "$DEST/Transcripts/$LIVE.md" <<'EOF'
# UI live

**[00:00–00:07]** Так, по найму: первый кандидат сильнее в бэкенде, оффер нужен до пятницы.

**[00:07–00:12]** Иначе его перехватят, там ещё две компании в процессе.
EOF

# Пары для проверки сбоев: в тексте расшифровки стоят метки, по которым
# подставная модель отвечает прозой вместо JSON и отдаёт HTTP 500.
for pair in "UI fail:СБОЙ" "UI err:ПЯТЬСОТ"; do
  name="${pair%%:*}"
  mark="${pair##*:}"
  cp "$WORK/$NAME.m4a" "$DEST/$name.m4a"
  printf '# %s\n\n**[00:00–00:05]** Тестовая расшифровка, метка %s.\n' "$name" "$mark" \
    > "$DEST/Transcripts/$name.md"
done

# История чата с вложением: диалог с карточкой принесённой записи. Документный
# выбор файла из UI-теста не подсунуть, поэтому вложение сеется прямо в историю —
# так проверяется отрисовка карточки и её действия.
SUPPORT="$CONTAINER/Library/Application Support/Lori"
mkdir -p "$SUPPORT"
python3 - "$SUPPORT/chat-history.json" "$LIVE" <<'PYTHON'
import json, sys, uuid, datetime

path, name = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
conversation = {
    "id": str(uuid.uuid4()),
    "updatedAt": now,
    "bubbles": [
        {"id": str(uuid.uuid4()), "role": "user", "text": "вот запись, разберись"},
        {"id": str(uuid.uuid4()), "role": "attachment", "text": name, "path": f"{name}.m4a"},
    ],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump([conversation], handle, ensure_ascii=False)
PYTHON

echo "готово:"
echo "  $DEST/$NAME.m4a"
echo "  $DEST/Transcripts/$NAME.md"
echo "  $DEST/Работа/Планёрка по найму.md"
echo "  $DEST/$LIVE.m4a (без обработанной заметки — для проверки обработки)"
echo "  $DEST/Transcripts/$LIVE.md"
echo "  $DEST/UI fail.m4a, $DEST/UI err.m4a (управляемые сбои модели)"
echo "  история чата с вложением «$LIVE»"
