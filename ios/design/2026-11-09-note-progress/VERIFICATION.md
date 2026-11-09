# Итог заметкой и прогресс по частям — 9 ноября 2026

Рабочая копия `/Users/ilya/orca/workspaces/Lori/coney`, схема `LoriQA`,
симулятор **iPhone 17**, `86E91244-4214-433C-ABA6-07D0508D2D6D`, **iOS 27.0**.
Других агентов/подзадач не запускал. Шлюз на Mac mini не разворачивал.
Сборка приложения и расширения: **1.0 (12)**, прежняя **11**.

## Изменения

- Шлюз возвращает задачи `{text, owner, due}`; неизвестные исполнитель/срок — `null`;
  срок остаётся словами записи. Новая схема, инструкция модели, нормализация и тест.
- iOS читает строки прежних итогов и новую форму; отметки задач сохраняются атомарно,
  переносятся по совпадению текста при обновлении, видны как зачёркнутые приглушённые строки.
  Markdown/PDF содержат исполнителя и срок; «Скопировать» остаётся расшифровкой.
- Итог после плеера — заметкой с Georgia у разделов, висячими маркерами и относительной
  подписью. Расшифровка раскрывается на месте; её таймкоды, перемотка и правка прежние.
  Предупреждения движка внутри раскрываемой расшифровки. Отчёт доступен карточкой, один `.sheet`.
- Подписка планирует части с настоящими границами. Отправка — `didSendBodyData`, ожидание
  модели — часы и бегущие полосы без процента, оценка `≈` из `TranscriptionSpeed`.
  «Слушает» начинается только после `running` шлюза; загруженное в очереди ещё ждёт.
  Полоса в строке главной, очереди, записи и нижней панели; Reduce Motion останавливает
  движение полос, сохраняя обновление часов.
- Сбой части не останавливает следующие; оплаченные ответы лежат в `TranscriptCheckpoint`.
  Повтор выбранной части использует прежние условия и новый HTTP job. Ошибка и условия
  повтора переживают перезапуск. Квота содержит время восстановления из `retryAfter`.

## Node

```sh
node --test test/*.test.mjs
```

Журнал `/tmp/lori-note-node.log`:

```text
# tests 41
# pass 41
# fail 0
```

## LoriQA: полный модульный набор

Перед запуском — `pgrep -fl xcodebuild`, отдельный Derived Data. Подпись тестов не отключалась;
`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` исключают лишнюю сборку x86_64 зависимостей.

```sh
xcodebuild -project /Users/ilya/orca/workspaces/Lori/coney/ios/LoriLocal.xcodeproj \
  -scheme LoriQA -destination 'id=86E91244-4214-433C-ABA6-07D0508D2D6D' \
  -derivedDataPath /tmp/lori-note-progress-20261109/dd \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -only-testing:LoriLocalTests -only-testing:LoriLocalUITests/GatewayUITests \
  -resultBundlePath /tmp/lori-note-progress-20261109/verification.xcresult test
```

`/tmp/lori-note-progress-20261109/verification.log` (последний общий прогон модульных и UI):

```text
Executed 909 tests, with 8 tests skipped and 0 failures (0 unexpected) in 47.657 (47.878) seconds
** TEST SUCCEEDED **
```

Новое: старая/новая форма задач и PDF с атрибуцией; отметка, перезапуск, перенос только
совпавшего текста; байты с ограничением 0…1 и неизвестным объёмом, переходы и поздние тики;
сбой и абсолютный retryAt; продолжение следующих частей после сбоя; повтор одной части после
подъёма чекпоинта; сервис после перезапуска берёт прежний режим даже при смене настройки;
шлюз в `queued` не выдаётся за слушающую модель.

8 пропусков: MLX/Qwen только на телефоне; 3 проверки GigaAM без установленных весов;
3 Whisper без весов; отдельный сервер загрузки на 8321. Весов не скачивал.

## Заглушка и UI

Синтетические данные, адреса 127.0.0.1, фиктивный токен; никаких внешних API.
Новая 12-минутная запись добавлена `seed-note-progress.py` append-only через
`safe-container.py`, в QA, существующие файлы не заменялись.

```sh
python3 ios/design/qa/mock-gateway.py --port 18891
python3 ios/design/qa/mock-gateway.py --port 18892 \
  --transcribe-delay 12 --transcribe-delay-part 2 \
  --transcribe-error agent --transcribe-fail-part 2 --transcribe-fail-after-delay
python3 ios/design/qa/test-mock-gateway.py
python3 ios/tools/test_embed_api_keys.py
```

Python: **5 тестов заглушки, OK; 7 тестов встраивания ключей, OK**.


В том же общем прогоне, на окончательном коде сборки 12:

```text
Test Case '-[LoriLocalUITests.GatewayUITests testConnection]' passed (14.189 seconds).
Test Case '-[LoriLocalUITests.GatewayUITests testNoteTaskPersistsAndTranscriptExpandsInPlace]' passed (35.589 seconds).
Test Case '-[LoriLocalUITests.GatewayUITests testSlowPartFailureAndRetryOnlyMissingPart]' passed (53.909 seconds).
Test Case '-[LoriLocalUITests.GatewayUITests testSubscriptionEngineRequiresConfiguredGatewayInQuickPicker]' passed (33.028 seconds).
Test Case '-[LoriLocalUITests.GatewayUITests testSubscriptionTranscriptionUsesChunkTimeAndEngineName]' passed (35.247 seconds).
Test Case '-[LoriLocalUITests.GatewayUITests testSummaryAndReport]' passed (33.627 seconds).
Executed 6 tests, with 0 failures (0 unexpected) in 205.589 (205.596) seconds
** TEST SUCCEEDED **
```

Проверены обновление итога, живой флажок и его сохранение после завершения/запуска приложения,
раскрытие/сворачивание прежнего текста на месте, медленная вторая часть из трёх, строка на
главной/очередь/нижняя панель, ошибка с диапазоном, рабочий повтор одной части, открытие отчёта
новой карточкой, повторное создание и меню форматов. Число отправок при повторе отдельно
проверено модульно: после двух исходных частей всего три POST, с прежним режимом.

До общего зелёного прогона исправлены три селектора UI: вложенный identifier заметки может
перекрываться контейнером; AAC на главной имеет 11:59 вместо округлённых плеером 12:00;
после добавления карточки «Отчёт» поиск по одному слову даёт две кнопки — тест нажимает
`noteReport`. Проверки содержимого, отметки и завершения не ослаблялись. В итоговом наборе
нет исключённых UI-тестов. Диагностический сбор Xcode иногда пишет `unable to find utility
simctl`; это сообщение сбора дополнительных логов, сами тесты/снимки и result bundle получены.

## Снимки

Экспорт из `verification.xcresult`, просмотрены. Все в этой папке, синтетические данные:

- [Заметка, светлая](note-light.png), [тёмная](note-dark.png).
- [Отметка задачи, светлая](note-task-completed-light.png), [тёмная](note-task-completed-dark.png).
- [Расшифровка раскрыта на месте](note-transcript-expanded-light.png).
- [Медленная часть, светлая](progress-slow-record-light.png), [тёмная](progress-slow-record-dark.png).
- [Сбой части, светлая](progress-failed-light.png), [тёмная](progress-failed-dark.png).
- [Главная, очередь и нижняя панель](progress-home-queue-light.png).
- [После повтора части](progress-retried-light.png).
- [Отчёт с вложенными списками](gateway-report-sheet.png).

Тёмная тема проверена по пикселю холста: `NSBitmapImageRep` → deviceRGB, x=40, y=1000:
все четыре `*-dark.png` — **(23, 23, 21)**, `note-light.png` — **(247, 246, 237)**.
Ранние dark-кадры до перезапуска симулятора оказались светлыми и сюда не включены.
В очереди кнопка остановки поднята к названию: оценка времени и полоса имеют всю ширину,
на окончательном снимке не пересекаются с кнопкой.

## Выпуск

```sh
ios/tools/release-ipa.sh --no-cloud \
  --derived-data /Volumes/Movis/Mac-data/LoriWork/dd-note-progress-release
ios/tools/release-ipa.sh --publish-only \
  /Users/ilya/orca/workspaces/Lori/coney/ios/build/dist/LoriLocal-unsigned.ipa
```

Журнал сборки: `/Volumes/Movis/Mac-data/LoriWork/dd-note-progress-release/ipa-release.log`,
итог выпуска: `/tmp/lori-note-progress-20261109/release.log` и `publish.log`:

```text
** BUILD SUCCEEDED **
Готово: LoriLocal 1.0 (12), /Users/ilya/orca/workspaces/Lori/coney/ios/build/dist/LoriLocal-unsigned.ipa
Опубликовано: /Users/ilya/Library/Mobile Documents/com~apple~CloudDocs/IPA Shelf/ru.ilyaqa.lori.local--1.0--12.ipa
```

В IPA Shelf файл существует: **17 416 927 байт**, SHA-256
`a165a7cd82cc8f3ae7ac8a5626186c24a04a9e5fceac5fffdb660fb41f64d170`.
Обычные Info.plist приложения и `RecordingActivity.appex` внутри опубликованной IPA:
version **1.0**, build **12**, Bundle ID `ru.ilyaqa.lori.local` и
`ru.ilyaqa.lori.local.RecordingActivity`. ZIP публиковался штатно, атомарно; установка не выполнялась.

`PrivateAPIKeys.plist` есть в Release ZIP и отсутствует в QA `.app` симулятора.
Проверялось только наличие ресурса. `ios/Secrets/APIKeys.local.json` агент не читал,
не менял и не коммитил; штатный сборщик встраивает значения самостоятельно.

## Непроверенное и границы

- Живой шлюз Mac mini, вход Antigravity, настоящие ответы/квота/время её восстановления,
  извлечение исполнителей/сроков моделью на живом материале: здесь fake agy и HTTP-заглушка.
  Развёртывание шлюза — координатору, здесь не выполнялось.
- Физический iPhone, подпись и установка IPA, доставка iCloud на телефон, реальные фоновые
  пробуждения и suspension/relaunch. Перезапуск проверен в симуляторе/модульных подстановках.
- iOS 26 (нет такого установленного рантайма), реальные Qwen/GigaAM/Whisper и отдельный
  сервер скачивания на 8321 — восемь перечисленных пропусков.
- Остальные UI-классы, все размеры Dynamic Type и системное включение Reduce Motion этим
  прогоном не проверялись. Светлая/тёмная темы — указанные снимки, не все экраны приложения.
- Другие движки остаются с прежним индикатором; модель частей поставляет подписка Gemini.
  Live Activity не перестраивалась: она принадлежит диктофону, у расшифровки системная полоса
  BGContinuedProcessingTask. Решение и причина внесены в AGENTS.md.
- Подписка даёт приблизительные диапазоны, метки говорящих относятся к одной части,
  людей между частями не сопоставляет; это предупреждение в раскрытой расшифровке.
  Неподписанная IPA — артефакт для последующей подписи, не доказательство установки.
