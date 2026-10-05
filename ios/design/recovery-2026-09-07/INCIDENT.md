# Инцидент с данными Lori во время device-проверки

7 сентября 2026, время Europe/Moscow (UTC+3). Статус: **личный архив не восстановлен; все изменения на iPhone остановлены**. Исходные три исправления не считаются завершёнными.

## Подтверждённые факты

- До инцидента обычный контейнер Lori содержал локальные модели и метаданные. В 22:24:46 read-only список `Library/Application Support/Lori` показывал `Models`, `Summary`, `summaries.json` (около 4 KB), `topics.json` (около 1 KB), `speed.json` (401 bytes), `Черновики`.
- В 22:41 настоящий GigaAM обработал синтетическую запись. MLX тоже загрузила реальную установленную модель. Это подтверждает доступность весов до поздних операций.
- После последних установки и копирования, в 22:49 свежий DEBUG probe получил ошибку отсутствия GigaAM.
- В 22:50 обычный `Documents/Lori/Workspace` вернул **0 files**. `Library/Application Support/Lori` содержал только вновь созданный `summaries.pending.json` (2 bytes).
- Полная read-only инвентаризация текущего контейнера сохранена в 22:54. Среди его Documents нет пользовательских аудио или расшифровок: только новый journal и синтетический RecoveryProbe. Среди Application Support нет прежних моделей и метаданных.
- Обычное приложение в проверенном коде использует `Documents/Lori/Workspace`. В `WorkspaceStore` нет выбора корня через внешний bookmark. DEBUG probe явно подставляет `Documents/Lori/RecoveryProbe`; это объясняет отдельный UI, но **не объясняет отсутствие реальных файлов и весов на диске**.
- Предыдущее объяснение только тестовым списком было преждевременным. Нельзя говорить, что архив цел, или что достаточно выйти из probe.

## Хронология

| Время | Действие / наблюдение |
|---|---|
| 22:24:46 | Каталоги моделей и метаданные присутствуют в обычном Application Support |
| 22:36:44 | Обычная сборка установлена отдельной командой devicectl install |
| 22:37–22:38 | Device unit-test настоящей MLX модели прошёл за 19.403 s; временное хранилище, синтетический текст |
| 22:41:03 | Один синтетический WAV скопирован в `Documents/Lori/RecoveryProbe/input.wav`, без remove-existing |
| 22:41:28 | Запущен DEBUG probe; настоящий GigaAM, обычные service/Runway |
| 22:41:38 | Статус: часть 16/30, checkpoint 1, runway running |
| 22:41:51 | Открыты системные Настройки: обычный уход Lori в фон |
| 22:42:13 | В фоне расшифровка сохранена, описание в очереди |
| 22:42:27 | Lori активирована без завершения процесса; описание осталось ожидающим |
| 22:43:55 | Старый полный journal скопирован наружу; содержит записи с 27 августа и события до 7 сентября |
| 22:48:05 | Установлена DEBUG сборка с исправлением отмены MLX |
| 22:48:27 | Выполнена приведённая ниже copy-to команда с remove-existing для новой синтетической папки |
| 22:48:40 | Первый запуск в новом коротком journal; прежних строк с августа в текущем файле уже нет |
| 22:49:16 | Завершился ранее начатый запуск `--terminate-existing ... --recovery-probe` |
| 22:49:18 | Probe: `FAIL: transcription error`, GigaAM models missing |
| 22:49:40–22:49:46 | После сообщения пользователя сохранены journal и probe; дальнейшие device mutations прекращены |
| 22:50:38–22:50:42 | Обычный Workspace пуст, прежний Application Support отсутствует |
| 22:54 | Полная инвентаризация и копия оставшихся Documents/Library наружу |

## Потенциально связанная команда

Команду выполнил агент. Намерение было заменить только уже сохранённую диагностическую папку, однако наблюдаемая потеря шире этого намерения. Точная причинность между установкой, копированием и сменой контейнера ещё не установлена. Повторять команду нельзя.

```text
xcrun devicectl device copy to \
  --device 247A1220-6E0F-542D-A34D-C164E95C310C \
  --source /private/tmp/lori-long-probe \
  --destination Documents/Lori/RecoveryProbe \
  --domain-type appDataContainer \
  --domain-identifier ru.ilyaqa.lori.local \
  --remove-existing-content true
```

Вывод этой операции (сохранён из tool result):

```text
22:48:27 Acquired tunnel connection to device.
22:48:27 Enabling developer disk image services.
22:48:27 Acquired usage assertion.
File on Device
Path: /private/var/mobile/Containers/Data/Application/8D9C0057-EA56-4AE4-9A4C-4BB0E45FE00F/Documents/Lori/RecoveryProbe
URL Resources: Writable, Readable, Directory
File Size: 96 bytes
Last modification date: 07.09.2026, 22:48
Permissions: UID: 501, GID: 501, Permissions: 493
Extended Attributes: [:]
```

Предыдущий подтверждённый data-container путь (копирование первого WAV в 22:41):

```text
/private/var/mobile/Containers/Data/Application/E4484742-930A-4804-A7FD-8DA05DD283E7/Documents/Lori/RecoveryProbe/input.wav
```

Новый подтверждённый data-container путь:

```text
/private/var/mobile/Containers/Data/Application/8D9C0057-EA56-4AE4-9A4C-4BB0E45FE00F/
```

Это UUID контейнеров **данных**, не UUID установочных bundle-каталогов. Само изменение UUID не доказывает удаления; отсутствие содержимого подтверждено отдельно. Между install 22:48:05 и copy 22:48:27 отдельной проверки Models/Workspace не было, поэтому точный момент потери не локализован до одной операции.

## Что сохранено наружу

Уникальная папка: `/private/tmp/LoriIncident-20260907-2255/`.

- `device-inventory.json`: полный текущий список (41 запись, включая каталоги).
- `current-Documents/`, `current-Library/`: оставшиеся данные текущего контейнера. Они не являются копией утраченного архива.
- `lori-probe-journal.txt`: journal до инцидента, 27 августа — 7 сентября.
- `lori-local-error-journal.txt`: короткий journal после инцидента.
- `lori-real-workspace-files.json`, `lori-real-support-files.json`: результаты пустого Workspace и отсутствующих каталогов.
- Диагностические статусы до/во время/после первого фонового прогона.
- `candidate-originals/` и `candidate-originals.json`: пять независимых m4a из Downloads. Копии проверены SHA256. Связь с утраченным архивом не подтверждена.

Кандидаты из Downloads:

| Файл | Размер | Подтверждённая длительность / дата файла |
|---|---:|---|
| Новая запись 48.m4a | 56 599 440 bytes | 692.053 s; 27 августа |
| Новая запись 49.m4a | 41 051 010 bytes | 514.731 s; 27 августа |
| Новая запись 42.m4a | 38 252 732 bytes | 6 марта |
| Новая запись 29.m4a | 12 659 274 bytes | 29 января |
| Новая запись 27.m4a | 45 362 898 bytes | 28 января |

Отдельно `/private/tmp/LoriRecoveryEvidence/`: 25 файлов из двух Simulator-контейнеров, всего 2 252 221 bytes, плюс найденные summaries. Многие — короткие UI samples и корзина тестовых запусков. Это возможные отдельные копии, **не резервная копия iPhone**.

## Проверенные ограничения восстановления

- `~/Library/Application Support/MobileSync/Backup` возвращает `Operation not permitted` и в обычном, и в elevated read-only запуске. Это ограничение macOS privacy/TCC; обход не предпринимался. Наличие/отсутствие backup внутри не установлено.
- Указанный по прежней заметке `~/Desktop/journal.txt` сейчас не найден. Доинцидентный journal уже сохранён в указанной выше папке.
- Документированный devicectl appDataContainer выбирает приложение по bundle ID. Подтверждённого supported способа открыть исторический data-container UUID через этот API не найдено. Попыток обходить файловую изоляцию относительными путями не было.
- Записи, созданные только микрофоном Lori, могут не иметь оригинала в Диктофоне/Downloads. Восстановимость без backup не доказана.

## Безопасные следующие шаги

1. Выяснить наличие существующего Mac/iCloud backup и дату до инцидента. Не создавать новую копию поверх старой и не запускать full-device restore автоматически.
2. Сопоставить пять сохранённых m4a и другие известные пользователю оригиналы с конкретными утраченными записями. Сначала показать список найденного; не загружать на телефон наугад.
3. Если доступен backup, извлекать Lori в отдельную локальную папку, проверить аудио, расшифровки и метаданные. Не заменять сразу весь телефон.
4. Любое восстановление на телефон — только после конкретного обзора состава и согласования, с сохранением текущей копии и без перезаписи оставшихся данных.
5. До разрешения инцидента не продолжать ASR/probe, не переустанавливать, не запускать Lori и не скачивать модели. Обычный запуск после probe **пока не возвращён**, поскольку действует запрет на любые device writes/launch.

## Исходные исправления

Последний Simulator unit-прогон после изменения MLX: 550 tests, 8 skipped, 0 failures. Два ASR integration suites исключены. Этот результат не отменяет инцидент и не является основанием считать задачу завершённой. Исправленная отмена MLX собрана для iPhone, но повторный физический прогон не состоялся из-за отсутствия моделей. Cloud/background/lock и восстановление пользовательских данных остаются незавершёнными.

Дополнительные read-only проверки: доступ к `~/Library/Group Containers/group.com.apple.VoiceMemos.shared` также закрыт macOS privacy (`Operation not permitted`), обход не предпринимался. Host CoreDevice log сохранён (`coredevice-host-events.txt`, 175 строк); в выборке сетевые disconnect/remove-handler события, нет подтверждения удаления конкретного data-container или возможности вернуть его.

## Дополнительный разбор кода и подписи (read-only)

- `DeviceSummaryIntegrationTests` удаляет только два файла с уникальным именем `summary-device-UUID.json` и `.pending.json` внутри `temporaryDirectory`. Очистки корня Documents/Application Support в этом тесте нет.
- `RecoveryProbe` сам не содержит removeItem/reset/removePersistentDomain. Его файлы и тестовые summary/queue адресуются только `Documents/Lori/RecoveryProbe`. Подмена корня только для DEBUG-аргумента; обычный root не меняется настройкой/bookmark.
- `LoriLocalApp` не сбрасывает пользовательский домен настроек. `--forget-attachments` не передавался нашим probe; соответствующая функция удаляет только staging и Documents/Inbox.
- `WorkspaceStore.ensureRoot` только создаёт папку; не очищает её. `safeURL` отвергает абсолютные пути и `..`.
- Очистка `BackgroundTranscriptionTransport` ограничена `Application Support/Lori/Jobs/<jobUUID>` и файлами с префиксом jobUUID в `Jobs/Transfers`. Новые job IDs создаются UUID; данных о некорректном ID в этом прогоне нет.
- `InterruptedRecords` удаляет только свой queue-файл, `TranscriptCheckpoint.prune` — файлы в `Lori/Черновики`. `SummaryRunner`/`SummaryStore` не удаляют корни Workspace/Models. Удаление варианта SummaryModel существует как отдельное явное действие; вызова из startup/probe не найдено.
- В проверенных новых/изменённых startup/test/cleanup путях не найдено операции, объясняющей одновременное исчезновение обычного Workspace, Models, Summary, метаданных и прежнего journal. Это статический результат; он не доказывает единственную внешнюю причину.
- Сохранённые логи `device-build`, `device-unlocked`, `probe-build`, `probe-fixed-build` используют одну и ту же development team и один и тот же сертификат codesign. Идентификаторы команды/сертификата в отчёт не включены.
- Application identifier в трёх логах, где он напечатан, совпадает. В последнем build соответствующая операция была закэширована; отдельно проверен её текущий signing input `LoriLocal.app.xcent`: application identifier и team совпадают с первой сборкой, App Groups отсутствуют. Результат сравнения без секретов: `signing-comparison.json` в evidence.
- Признаков перехода на другую team/application identifier по этим артефактам нет. Это сужает гипотезу изменения подписи, но само по себе не исключает поведение механизма установки. Промежуточной инвентаризации между install и copy не было.

Доступные read-only направления на этом Mac исчерпаны без информации/доступа пользователя к существующей резервной копии либо конкретным оригиналам. На телефон восстановление не выполнялось.
