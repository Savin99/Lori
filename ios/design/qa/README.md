# Lori QA: изоляция тестовых данных

Схема `LoriQA`, конфигурация `QA`: отдельное приложение **Lori QA**, bundle ID
`ru.ilyaqa.lori.local.qa`. Личная Lori сохраняет прежние bundle ID, Keychain service
и группу доступа. QA получает собственные контейнер, настройки, Keychain group,
идентификаторы фонового планировщика и URLSession. Обмена данными между приложениями нет.

Обычная Lori игнорирует `--recovery-probe` и `--forget-attachments`.
Новый тестовый контейнер сначала пуст: отсутствие личных моделей и записей ожидаемо.

## Запуск в симуляторе

Всегда указывать UUID конкретного симулятора; `booted` не допускается в скриптах.

```sh
xcodebuild -project LoriLocal.xcodeproj -scheme LoriQA \
  -destination 'platform=iOS Simulator,id=<simulator-uuid>' \
  -derivedDataPath /private/tmp/LoriQA CODE_SIGNING_ALLOWED=NO build-for-testing
python3 design/qa/install-qa.py /private/tmp/LoriQA/Build/Products/QA-iphonesimulator/LoriLocal.app <simulator-uuid> --simulator
./design/qa/seed-audio.sh <simulator-uuid>
```

Скрипты seed-audio, seed-dialog, gigaam/seed-models и whisper/seed-model проверяют
метаданные QA-контейнера. Файлы только добавляются: существующий файл, ссылка или
недопустимый путь останавливают операцию. Не удалять старые данные для обхода отказа.
Для чистого набора использовать новый отдельный QA-симулятор.

`install-qa.py` проверяет **готовый Info.plist**, а не имя каталога `.app`.
Без `--simulator` он устанавливает только QA-сборку на явно указанный телефон;
личная сборка отклоняется до вызова инструмента. Скрипт не содержит uninstall,
reset, удаления контейнера или copy-to.

## Главный экран: посев, проверочный движок, снимки

```sh
python3 design/qa/seed-home.py <simulator-uuid>              # записи за три дня
python3 design/qa/seed-home.py <simulator-uuid> --inbox-only # пять файлов «Поделиться» → Lori
python3 design/qa/seed-home.py <simulator-uuid> --untranscribed # ещё одна запись без расшифровки
```

`seed-home.py` кладёт в рабочую папку записи с расшифровками (таймкоды, говорящие, разные движки и
режимы) и одну без расшифровки (`--untranscribed` добавляет ещё такую же — тесты кнопки
«Расшифровать» на неё и опираются), с датами за три дня (дата ставится уже после копирования: по ней
строятся группы дней и время на карточке). `--inbox-only` оставляет пять файлов в `Documents/Inbox`
— так их кладёт система при «Поделиться» → Lori; при запуске приложение прикрепляет их к панели и
удаляет папку. `Documents/Inbox` — единственное новое место посева в `safe-container.py`; остальные
гарантии прежние: только Lori QA, только добавление, без перезаписи и ссылок.

Очередь, полосы и строку ошибки симулятор сам не покажет: распознавания в нём нет. Lori QA с
аргументом `--ui-stub-engine` (длительность — `--ui-stub-seconds N`) считает проверочным движком
`QAStubEngine`: доли, отмена, расшифровка с таймкодами, а файл с «fail» в имени падает с «Нет связи с
сервисом». Включается только в DEBUG-сборке Lori QA и только по аргументу; в Release его нет в коде.

Снимки главного экрана — `TranscriptionUITests`: `testZZ1AttachedPanelAndQueueScreenshots` (посев
`--inbox-only` прямо перед запуском этого теста: остальные тесты стартуют с `--forget-attachments`,
а он чистит и `Documents/Inbox`) и `testZZ2ListScreenshots`. Тема переключается внутри теста
(`XCUIDevice.shared.appearance`), снимки достаются `xcrun xcresulttool export attachments`.
Экран записи в очереди и в работе — `testZZ3RecordScreenQueueScreenshots`: нужны две записи без
расшифровки — если их меньше, добавь `--untranscribed` (каждый запуск — ещё одна); в конце тест
снимает очередь, и обе остаются без текста. `testFailureKeepsRecordScreenOpen` опирается на две
записи с «fail» в имени — по одной от каждого прогона `testZZ1…`.

Два свойства прогона, которые выглядят как поломка, но ею не являются:
- тест плашки записи пропускается: у симулятора без звукового входа `AVAudioRecorder.record()`
  отвечает «нет» (половинчатый файл уходит в корзину Lori, в списке его нет);
- прерванное задание с сохранёнными настройками поднимается само при следующем запуске — тесты с
  проверочным движком снимают такую очередь, чтобы запуск без заглушки не отдал её настоящему движку.

## Полный прогон на чистом симуляторе

Порядок важен: часть тестов опирается на записи, которые оставляет `testZZ1…` (две записи с
«fail» в имени нужны `testFailureKeepsRecordScreenOpen`, одна — `testRetryFromRecordScreenShowsNoStaleAlert`),
а `Documents/Inbox` чистит любой запуск с `--forget-attachments`. Команды — из корня репозитория,
с явным UUID; в `ios/` не заходить (`cd`): служебная папка среды агента `.claude/.cc-writes` в
текущем каталоге попадает в проект при `xcodegen`.

```sh
U=<simulator-uuid>; DD=<derived-data>
X="xcodebuild -project ios/LoriLocal.xcodeproj -scheme LoriQA -destination id=$U -derivedDataPath $DD CODE_SIGNING_ALLOWED=NO"
$X build-for-testing
python3 ios/design/qa/install-qa.py $DD/Build/Products/QA-iphonesimulator/LoriLocal.app $U --simulator
# Без разрешения тест плашки записи упрётся в системный вопрос, и тот перекроет остальные тесты.
xcrun simctl privacy $U grant microphone ru.ilyaqa.lori.local.qa
ios/design/qa/seed-audio.sh $U                          # «UI sample» — экран записи
python3 ios/design/qa/seed-home.py $U                   # записи за три дня, одна без расшифровки
python3 ios/design/qa/seed-home.py $U --untranscribed   # вторая без расшифровки
ios/design/redesign-2026-10-05/seed-record-states.sh $U # набор снимков экрана записи
# Две записи с «fail»: testZZ1 дважды, каждый раз сразу после посева Inbox.
for i in 1 2; do
  python3 ios/design/qa/seed-home.py $U --inbox-only
  $X -only-testing:LoriLocalUITests/TranscriptionUITests/testZZ1AttachedPanelAndQueueScreenshots test-without-building
done
$X -only-testing:LoriLocalTests test-without-building
$X -only-testing:LoriLocalUITests \
   -skip-testing:LoriLocalUITests/TranscriptionUITests/testZZ1AttachedPanelAndQueueScreenshots test-without-building
```

Записи без расшифровки тесты очереди не расходуют: каждый в конце снимает свою очередь. Если
прогон упал посреди теста с заглушкой, его задания остались в очереди и при следующем запуске без
`--ui-stub-engine` уйдут настоящему движку (облачный без ключа — ошибка на карточке, и запись
выпадает из набора «без расшифровки»). Поэтому после падения первым запускать тест с заглушкой —
он снимает остаток очереди (`stopQueueIfRunning`), — а записи, ставшие ошибкой, добирать
`--untranscribed`.

## Границы защиты

Эти инструменты не перехватывают произвольные команды терминала. Приложение не
может запретить Xcode/iOS удалить его собственный контейнер. Поэтому прямые
операции замены/очистки личного контейнера запрещены правилами проекта. Перед
обновлением личной Lori нужна проверенная внешняя копия аудио, текстов и метаданных.
Копия внутри того же контейнера не защищает от такого удаления.

Это предотвращение повторения опасного тестового сценария, не восстановление
утраченных файлов и не доказательство единственной причины инцидента.

## Проверки ограничений

```sh
python3 design/qa/test_safety.py
```

Тесты не обращаются к iPhone: вызовы инструментов подставные, файлы — во временной
папке. Проверяются отказ для личной сборки и личного контейнера, запрет перезаписи,
символических ссылок, корневых путей и неоднозначного выбора симулятора.
