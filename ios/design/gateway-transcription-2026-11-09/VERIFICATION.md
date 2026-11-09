# Gemini по подписке: расшифровка и выпуск — 9 ноября 2026

Ветка `Savin99/feat-delegate-transcription-summaries`, только `ios/`, без push.

- `15d9aa6` — `fix(ios): отрисовать списки отчёта и сохранить заголовок из итога`.
- `1fc2753` — `feat(ios): добавить расшифровку Gemini через подписку`.
- `e5e421e` — `test(ios): дождаться готового итога и проверить заголовок в интерфейсе`.
- Повышение сборки и этот отчёт — отдельный `chore(ios)`-коммит (SHA в истории).

## Полный прогон

Схема `LoriQA`, собственный `/tmp/lori-subscription-20261109/dd`, подпись включена,
параллельные тесты выключены. Перед прогоном `pgrep -fl xcodebuild` — других сборок нет.
Заданный iPhone 17 `86E91244-4214-433C-ABA6-07D0508D2D6D` работает на **iOS 27.0**;
доступны только 27.0/27.1, iOS 26 здесь не проверена.

```sh
xcodebuild -project /Users/ilya/orca/workspaces/Lori/coney/ios/LoriLocal.xcodeproj \
  -scheme LoriQA -destination 'id=86E91244-4214-433C-ABA6-07D0508D2D6D' \
  -derivedDataPath /tmp/lori-subscription-20261109/dd \
  -resultBundlePath /tmp/lori-subscription-20261109/full.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:LoriLocalTests -only-testing:LoriLocalUITests/GatewayUITests test
```

Из `/tmp/lori-subscription-20261109/full.log`:

```text
Executed 901 tests, with 8 tests skipped and 0 failures (0 unexpected) in 42.281 (42.475) seconds
Test Case '-[LoriLocalUITests.GatewayUITests testConnection]' passed (13.391 seconds).
Test Case '-[LoriLocalUITests.GatewayUITests testSubscriptionEngineRequiresConfiguredGatewayInQuickPicker]' passed (29.084 seconds).
Test Case '-[LoriLocalUITests.GatewayUITests testSubscriptionTranscriptionUsesChunkTimeAndEngineName]' passed (29.362 seconds).
Test Case '-[LoriLocalUITests.GatewayUITests testSummaryAndReport]' passed (29.737 seconds).
Executed 4 tests, with 0 failures (0 unexpected) in 101.574 (101.579) seconds
** TEST SUCCEEDED **
```

901 учтено, 893 прошли, 8 пропущены. Пропуски: Qwen требует iPhone; три проверки
GigaAM (две ONNX и общий кеш) и три Whisper требуют весов; локальный сервер загрузки
на 8321 не запущен. Большие модели не скачивались. После успешного набора Xcode сообщил
`Failure collecting diagnostics from simulator … unable to find utility "simctl"` — это
сбор диагностического пакета после тестов; результат XCTest и код выхода успешные.

Новые/затронутые модульные проверки:

- `ReportMarkdownTests`: маркеры `-`, `+`, `*`, номера `3.`/`2)`, вложенность пробелами/табом,
  строчная Markdown-разметка остаётся в тексте.
- `GatewaySummaryRunnerTests`: уже оплаченные заголовок и описание берутся при отсутствии
  заголовка модели; ручное имя и `allowGeneratedTitle` сохраняются, прежний ответ модели не затирается.
- `GatewayTranscriberTests` (11): сырое PCM без JSON/multipart, Bearer и X-Lori-*, процентная
  запись словаря с кириллицей/+/%, режимы, отсутствие нативных слов/таймингов, игнорирование
  модельного 09:59, реальные границы частей на паузе и перекрытие, склейка, локальные S1/S2,
  ошибка второй части с её границами, коды quota/auth/timeout/agent и retryAfter, DELETE при
  отмене/пределе, стабильный ключ и расписка при переэкспорте, фоновое answersOnly без новой
  отправки, готовность без подмены, снимок адреса/режима/длины.
- `EngineCatalogTests` / `EngineShortlistTests`: облачный каталог содержит седьмой движок.

`GatewayUITests` работает с `design/qa/mock-gateway.py --port 18891`, синтетической
`Gateway QA.m4a` из предыдущего append-only посева и фиктивным токеном. Новый UI-тест
действительно перерасшифровывает эту запись через стандартную очередь и фоновый HTTP-транспорт,
проверяет приблизительное время и первую строку меню о движке. Второй проверяет отсутствие
неготового движка в быстром выборе (при ином выбранном), наличие с причиной в полном списке
и появление после настройки шлюза. Отчёт принудительно обновляется у заглушки, затем проверяются
типографская точка, вложенный номер и ещё более глубокий маркер — проверка не ослаблена.

После визуальной проверки UI-тест дополнен ожиданием окончания annotate и проверкой
заголовка/описания: прежний итог мог уже быть виден, пока обновление ещё считалось.
Повторен весь `GatewayUITests` на сборке **11**, без изменения кода приложения:
тот же вызов xcodebuild, только `-only-testing:LoriLocalUITests/GatewayUITests` и
`-resultBundlePath /tmp/lori-subscription-20261109/ui-verified.xcresult`.
`/tmp/lori-subscription-20261109/ui-verified.log`:

```text
Test Case '-[LoriLocalUITests.GatewayUITests testConnection]' passed (15.777 seconds).
Test Case '-[LoriLocalUITests.GatewayUITests testSubscriptionEngineRequiresConfiguredGatewayInQuickPicker]' passed (30.759 seconds).
Test Case '-[LoriLocalUITests.GatewayUITests testSubscriptionTranscriptionUsesChunkTimeAndEngineName]' passed (30.144 seconds).
Test Case '-[LoriLocalUITests.GatewayUITests testSummaryAndReport]' passed (32.697 seconds).
Executed 4 tests, with 0 failures (0 unexpected) in 109.377 (109.381) seconds
** TEST SUCCEEDED **
```

## Снимки и Python

Экспортированы из `ui-verified.xcresult`, просмотрены глазами; светлая тема, синтетические данные:

- [Маркированный, нумерованный и вложенный списки отчёта](gateway-report-lists.png).
- [Подписка и выбранный режим](gateway-engine-selected.png).
- [Первая строка меню с движком и предупреждения о времени/говорящих](gateway-transcript-engine.png).
- [Итог с заголовком из того же annotate](gateway-recording-summary.png).

```text
python3 ios/design/qa/test-mock-gateway.py
Ran 4 tests in 0.518s
OK

python3 ios/tools/test_embed_api_keys.py
Ran 7 tests in 0.006s
OK
```

Заглушка проверена настоящим локальным HTTP: оба режима, идемпотентность, очередь/опрос,
управляемые auth/quota/timeout/agent только второй части, задержка, DELETE, плохие заголовки.
Личного JSON и внешних API Python-тесты не используют.

## Выпуск и ресурсы

После зелёного полного набора номер повышен 10 → 11 в `project.yml`, затем:

```sh
ios/tools/release-ipa.sh --derived-data /Volumes/Movis/Mac-data/LoriWork/dd-release
```

Журнал `/Volumes/Movis/Mac-data/LoriWork/dd-release/ipa-release.log`:

```text
** BUILD SUCCEEDED **
Готово: LoriLocal 1.0 (11), /Users/ilya/orca/workspaces/Lori/coney/ios/build/dist/LoriLocal-unsigned.ipa
Опубликовано: /Users/ilya/Library/Mobile Documents/com~apple~CloudDocs/IPA Shelf/ru.ilyaqa.lori.local--1.0--11.ipa
```

Файл в IPA Shelf существует: **17 267 475 байт**, SHA-256
`271554d31d6ea058ae9a9e7b54cc7c0ad636834c87790afc025fdc9f00d02f4f`.
Info.plist внутри IPA: version **1.0**, build **11**; у `RecordingActivity.appex` тоже **11**.
Предыдущая сборка 10 была `dataless`: перед публикацией восстановлена штатным `brctl download`.
Новая IPA опубликована атомарно; это неподписанный архив, не проверка установки на iPhone.

Владелец `.app`: `/Volumes/Movis/Mac-data/LoriWork/dd-release/Build/Products/Release-iphoneos/LoriLocal.app` —
`PrivateAPIKeys.plist` **есть**; имя того же ресурса присутствует в ZIP опубликованной IPA.
Проверялись только наличие ресурса и обычные Info.plist приложения/расширения, значения
`PrivateAPIKeys.plist` не читались.

QA `.app` из полного прогона:
`/tmp/lori-subscription-20261109/dd/Build/Products/QA-iphonesimulator/LoriLocal.app` —
`PrivateAPIKeys.plist` **отсутствует**. Дополнительно собрана QA именно для устройства
(чтобы проверить запрет конфигурации, а не только платформы симулятора):

```sh
xcodebuild -project /Users/ilya/orca/workspaces/Lori/coney/ios/LoriLocal.xcodeproj \
  -scheme LoriQA -configuration QA -destination 'generic/platform=iOS' \
  -derivedDataPath /Volumes/Movis/Mac-data/LoriWork/dd-release \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 'CODE_SIGN_IDENTITY=' build
```

`/tmp/lori-subscription-20261109/qa-device.log`: `** BUILD SUCCEEDED **`.
`/Volumes/Movis/Mac-data/LoriWork/dd-release/Build/Products/QA-iphoneos/LoriLocal.app`:
bundle `ru.ilyaqa.lori.local.qa`, build **11**, `PrivateAPIKeys.plist` **отсутствует**.
Подпись отключена только у device-артефакта без запуска, модульные/ UI-тесты подписаны.

Файл `Secrets/APIKeys.local.json` агент не открывал, не менял и не коммитил; сборщик
использует его штатно, значения нигде не выводятся.

## Непроверенное

- Настоящий шлюз Mac mini, вход Antigravity, расход/восстановление квоты и качество общей
  модели на живом аудио; здесь только синтетические ответы заглушки.
- Установка, подпись и работа на физическом iPhone; фон, suspension/relaunch и системное
  пробуждение проверены модульными подстановками/распиской, на телефоне не проверены.
- iOS 26, реальные модели Qwen/GigaAM/Whisper (описанные восемь пропусков).
- Остальные UI-классы, тёмная тема и все размеры шрифта в этом заходе не прогонялись.
- Подписка не даёт точных таймингов, а говорящие между частями не сопоставляются — это
  ограничения выбранного движка, отражённые в интерфейсе и файле.
