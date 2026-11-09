# Три вкладки Liquid Glass — 9 ноября 2026

Рабочая копия `/Users/ilya/orca/workspaces/Lori/coney`, схема **LoriQA**, симулятор **iPhone 17**,
`86E91244-4214-433C-ABA6-07D0508D2D6D`, **iOS 27.0**. Сборка **1.0 (13)**, предыдущая **12**.
Реализация: `0f416fb` — `feat(ios): добавить стеклянные вкладки и плавающий плеер`.
Выпуск/снимки/эта проверка — отдельным chore-коммитом, без пуша.
Изменения только в `ios/`, без запуска помощников, без Mac mini, без открытия или правки
`Secrets/APIKeys.local.json`.

## Решение и реализация

- Три вкладки под заголовком и строкой даты/длительности/темы. По умолчанию итог, если сохранён,
  иначе расшифровка; выбор сохраняется, пока экран открыт. Отдельное описание только без итога.
- Настоящий `.glassEffect(.regular.interactive())` и `GlassEffectContainer`, общее выделение
  через `glassEffectID`. Без второй стеклянной подложки; эффект на самой подписи, чтобы не
  размывать буквы. Естественная ширина пунктов, от 44 pt; начиная с XXL — столбец.
  VoiceOver получает группу `.isTabBar`, порядок и выбранное состояние; Reduce Motion снимает
  анимацию. Основание: [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass),
  [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).
- Суть итога 20 pt против основного 17 pt, разделы Georgia, прежние рабочие флажки и атрибуция.
  Пустое состояние с кнопкой или направлением в «Настройки → Подписка Gemini».
- Markdown-отчёт внутри вкладки, без `ReportSheet`: заголовки, списки с вложенностью, абзацы,
  прежний экспорт PDF/Markdown и обновление. Честная бегущая полоса без процента и отмена;
  прежний файл сохраняется до успеха. Один `.sheet(item:)` на экран.
- Прежняя расшифровка с говорящими, таймкодами, правкой и замечаниями. Прогресс частей сверху
  этой вкладки, в итоге короткая строка с переходом.
- Общая плавающая капсула плеера внизу, `.glassEffect(.regular)` на iOS 26+ и `safeAreaInset`.
  Содержимое идёт под ней, конец прокручивается выше. На крупном шрифте ползунок отдельной строкой.
  `AudioPlaybackStore` и перемотка прежние, переключение вкладки не останавливает звук.

## Проверка

Перед каждым прогоном — `pgrep -fl xcodebuild`; конкурирующего теста на этом симуляторе нет.
Свой Derived Data; существующий кэш исходников Swift packages использован без загрузки ASR-весов.
Подпись QA-тестов не отключалась. Команда завершающего зелёного прогона модульных, новых вкладок и трёх проверок текста/панели:

```sh
xcodebuild -project /Users/ilya/orca/workspaces/Lori/coney/ios/LoriLocal.xcodeproj \
  -scheme LoriQA -destination 'id=86E91244-4214-433C-ABA6-07D0508D2D6D' \
  -derivedDataPath /tmp/lori-glass-tabs-20261109/dd \
  -clonedSourcePackagesDirPath /tmp/lori-note-progress-20261109/dd/SourcePackages \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -only-testing:LoriLocalTests \
  -only-testing:LoriLocalUITests/RecordingTabsUITests \
  -only-testing:LoriLocalUITests/TranscriptScreenUITests/testReplicaTextIsSelectable \
  -only-testing:LoriLocalUITests/TranscriptScreenUITests/testShareMenuOffersPDFAndMarkdown \
  -only-testing:LoriLocalUITests/TranscriptScreenUITests/testToolbarButtonsAreHitAcrossTheirGlass \
  -resultBundlePath /tmp/lori-glass-tabs-20261109/accepted.xcresult test
```


`/tmp/lori-glass-tabs-20261109/accepted.log`, на окончательном коде с `safeAreaInset`:

```text
Executed 909 tests, with 8 tests skipped and 0 failures (0 unexpected) in 45.361 (45.562) seconds
Executed 6 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds
** TEST SUCCEEDED **
```

Три новых `RecordingTabsUITests`: переключение/изолированное содержимое каждой вкладки,
отметка задачи, возврат к ней, правильная вкладка при открытии, таймкод → плеер 0:30,
все вкладки с плеером, пустые состояния с/без шлюза, размеры XXXL и Accessibility L.
Три `TranscriptScreenUITests`: выбор слова/копирование, форматы PDF/Markdown и открытие
системного экспорта, нажатия по краям стеклянных групп панели.

После добавления проверки конца текста повторён только `testLargeTextTabsAndPlayer`
с теми же аргументами, `-only-testing:LoriLocalUITests/RecordingTabsUITests/testLargeTextTabsAndPlayer`,
результат `large-end.xcresult`, журнал `large-end.log`:

```text
Executed 1 test, with 0 failures (0 unexpected) in 21.512 (21.514) seconds
** TEST SUCCEEDED **
```

На Accessibility L последняя реплика целиком прокручена выше капсулы; проверены её
`isHittable` и `frame.maxY < player.frame.minY`, получен отдельный снимок.

Шесть Gateway-сценариев также проверены: пять прошли в `complete.xcresult`, исправленный
сценарий медленной части повторён в `final-check.xcresult` (те же xcodebuild-аргументы,
`-only-testing:LoriLocalUITests/GatewayUITests/testSlowPartFailureAndRetryOnlyMissingPart`):

```text
Test Case '-[LoriLocalUITests.GatewayUITests testSlowPartFailureAndRetryOnlyMissingPart]' passed (53.987 seconds).
```

Проверены короткий переход из итога к прогрессу, ожидание части 2 без процента,
ошибка с диапазоном и повтор только недостающей части. Остальные Gateway-проверки:
соединение, готовность движка, транскрипция с приблизительным временем, обновление итога
и встроенного отчёта с Markdown-списками/экспортом, сохранение задачи после перезапуска.

Расширенный ранний `complete.xcresult` был красным: 4 UI-сбоя. У меню iOS 27 подпись формата
объединяется с пояснением («PDF, Удобно читать и отправлять»); тесты теперь ищут формат
по началу подписи. Разросшаяся панель прогресса перекрывала карточку при повторном открытии —
тест прокручивает её выше панели. **Реальная регрессия выделения текста устранена**:
`safeAreaBar` заменён на `safeAreaInset`, сам текст/таймкоды не переписывались.
Контроль: исходная раскладка из `fc7a5ce` — `selection-baseline.xcresult`, 1 passed;
новая с `safeAreaBar` — failed; новая с отступом — `selection-inset.xcresult`, 1 passed;
затем ещё раз зелёный `accepted.xcresult`. В контроль старого экрана добавлен только AX-ID,
неоткрываемая ветка удалённого листа отчёта заглушена для компиляции; исходник после проверки
восстановлен точно. iOS 27 выбирает диапазон текста, поэтому тест нажимает на слово и при
необходимости на выделение ([Apple, textSelection](https://developer.apple.com/documentation/swiftui/view/textselection(_:))).

По последним результатам уникальных UI-проверок этих трёх классов: **20 passed, 5 skipped,
0 failed**. Это сводка нескольких прогонов, а не утверждение о единственном полном зелёном
UI-прогоне. Все четыре первоначально упавшие проверки повторены успешно; весь модульный
набор зелёный в завершающем прогоне. Пять пропусков перечислены ниже.
Сообщение IDE о невозможности собрать дополнительную диагностику через `simctl` не является
ошибкой тестов: `TEST SUCCEEDED`, result bundles и снимки получены.

QA использует `design/qa/mock-gateway.py` на 18891 и медленный вариант на 18892
(`--transcribe-delay 12 --transcribe-delay-part 2 --transcribe-error agent
--transcribe-fail-part 2 --transcribe-fail-after-delay`). Дополнительные данные —
`seed-glass-tabs.py`: синтетическая минута с репликами 0:00/0:30 и 53 секунды без текста.
Ранее посеяны `seed-gateway.py` и `seed-note-progress.py`; для прежних проверок панели добавлен
`seed-audio.sh`. Посев append-only через `safe-container.py`, только в явно выбранный QA-контейнер. На уже
посеянном симуляторе повторять его не надо: перезапись намеренно запрещена.


## Снимки

В этой папке, просмотрены; окончательный `accepted.xcresult`, большие шрифты и прокрутка —
`large-end.xcresult`. Экспорт: `xcrun xcresulttool export attachments --path <result> --output-path <dir>`.

| Вкладка | Светлая | Тёмная | Плеер отдельно |
| --- | --- | --- | --- |
| Итог | [снимок](summary-light.png) | [снимок](summary-dark.png) | [светлый](player-summary-light.png), [тёмный](player-summary-dark.png) |
| Отчёт | [снимок](report-light.png) | [снимок](report-dark.png) | [светлый](player-report-light.png), [тёмный](player-report-dark.png) |
| Расшифровка | [снимок](transcript-light.png) | [снимок](transcript-dark.png) | [светлый](player-transcript-light.png), [тёмный](player-transcript-dark.png) |

- [XXXL](transcript-extra-large-text-light.png), [Accessibility L](transcript-large-text-light.png),
  [последняя реплика выше капсулы](transcript-large-text-scrolled-light.png).
- [Без шлюза](empty-no-gateway.png), [с настроенным шлюзом, но без текста](empty-configured.png).
- [Выделение слова и системное меню при плавающем плеере](transcript-text-selection-light.png).

Тема проверена не именем файла: `NSBitmapImageRep` → deviceRGB, пиксель x=40, y=1000
на всех трёх полных снимках каждой темы: светлая **(247, 246, 237)**, тёмная **(23, 23, 21)**.
Разрешение полных снимков **1206 × 2622**. Предварительные кадры с размытым словом выбранной
вкладки сюда не включены; эффект перенесён с отдельного фона на саму подпись.

## Выпуск

```sh
ios/tools/release-ipa.sh --no-cloud \
  --derived-data /Volumes/Movis/Mac-data/LoriWork/dd-glass-tabs-release
ios/tools/release-ipa.sh --publish-only \
  /Users/ilya/orca/workspaces/Lori/coney/ios/build/dist/LoriLocal-unsigned.ipa
```

Финальная сборка: `/tmp/lori-glass-tabs-20261109/release-accepted.log`, Xcode-журнал
`/Volumes/Movis/Mac-data/LoriWork/dd-glass-tabs-release/ipa-release.log`; публикация — `publish.log`:

```text
** BUILD SUCCEEDED **
Готово: LoriLocal 1.0 (13), /Users/ilya/orca/workspaces/Lori/coney/ios/build/dist/LoriLocal-unsigned.ipa
Опубликовано: /Users/ilya/Library/Mobile Documents/com~apple~CloudDocs/IPA Shelf/ru.ilyaqa.lori.local--1.0--13.ipa
```

IPA существует в IPA Shelf, совпадает с локальной по SHA-256, ZIP проверен:
**17,448,845 байт**, SHA-256 **`3928ec8f47fec1e275b24d8673c92938afdf54b26353250fa4d23d7571659ccb`**.
В обычных Info.plist приложения и `RecordingActivity.appex`: версия **1.0**, сборка **13**;
Bundle ID `ru.ilyaqa.lori.local` и `ru.ilyaqa.lori.local.RecordingActivity`.
Ресурс `PrivateAPIKeys.plist` есть в owner Release ZIP и отсутствует в QA `.app` симулятора;
проверялось только наличие, значения не открывались. Личный JSON не открывался, не менялся
и не коммитился; штатный сборщик встраивает его самостоятельно. Публикация штатная, атомарная;
установка и подпись на телефоне не выполнялись. Устройство Release собиралось параллельно
с единственным тестовым процессом симулятора в отдельном Derived Data; конкурирующих тестов
на симуляторе не было.

## Непроверенное и границы

- Физический iPhone, подпись/установка IPA, доставка iCloud на телефон, настоящие фоновые
  пробуждения и suspension/relaunch. IPA — неподписанный артефакт для последующей подписи.
- iOS 26 и старше: установлен только iOS 27.0/27.1. Ветка Liquid Glass проверена на 27.0,
  ветка обычной подложки для iOS 18 — только компиляцией.
- Живой шлюз Mac mini, Antigravity, квота, настоящая модель Gemini: здесь localhost и фиктивный
  токен. Шлюз не менялся и не разворачивался.
- Qwen на устройстве, три GigaAM без весов, три Whisper без весов и отдельный сервер скачивания
  на 8321 — восемь пропусков модульного набора. Большие модели не скачивались.
- Пять старых UI-проверок требуют отдельного RecoveryProbe-посева и пропущены:
  `testCaptureLargeText`, `testCaptureRecordStates`, `testCaptureToolbar`,
  `testInterruptedRecordCannotBeRenamed`, `testTitleRequestOffersModelDownload`.
  Новые снимки вкладок/крупного шрифта получены своим посевом и не пропущены.
- Фактическое произнесение VoiceOver и системное включение Reduce Motion руками не проверялись;
  выбранное состояние, размер/доступность кнопок и крупный шрифт проверены UI-тестами.
- Весь остальной UI-набор приложения не прогонялся: проверены перечисленные три класса;
  не все размеры Dynamic Type, контрастности и локали. Фото/аудио только синтетические.
