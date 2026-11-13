# Внешнее аудио и видео — 13 ноября 2026, сборка 15

## Что изменено

Единая таблица `ImportFormats` разделяет допуск файла, попытку местного перевода и форматы
хранения. Входы: «Поделиться» (обычные типы документов, Alternate), системный пикер,
буфер без чтения при подсчёте, Быстрые команды. FLAC остаётся как есть; Ogg Opus и видео
становятся M4A. Порядок: проверенный исходник → Reader/Writer по всем звуковым дорожкам →
AudioFile/Converter → настроенный Mac mini → понятный отказ. Моно AAC-LC, ступенчатые
частота и битрейт по заданию. Для видео с немым хвостом проверяется длительность звука,
не видеоряда; несколько дорожек смешиваются в общей временной области.

Перевод вне главного актора, скрытый `.partial`, проверка AAC/моно/длительности перед
публикацией, уникальность по базе, дата импорта, бронь от параллельного импорта.
Оригинал не меняется; сбой оставляет его прикреплённым. Строка панели «Перевожу в M4A…»,
возможный перевод на Mac mini назван до нажатия. Временный заголовок без исходного расширения.
Журнал в файле называет источник, реальный кодек/частоту (либо «источник не определён»),
длительность звука и затраченное время. Шлюз имён файлов не журналирует.

Потребители прежнего `audioExtensions`:

| Место | Множество и причина |
| --- | --- |
| Список (`WorkspaceEntry.isAudio`, snapshot) | Хранимые + старые MP4/MOV; переведённые видны как M4A, FLAC не теряется |
| Занятые базы и свежая проверка на диске | Все входные расширения: вручную принесённое тоже резервирует расшифровку |
| Корзина и связанный отчёт | Хранимые + старые MP4/MOV, как список |
| `RecordTitle` | Все входные расширения: служебный `audio_5_2.ogg` не становится осмысленным именем |
| `ClipboardAudio` | Таблица входов с учётом настройки шлюза; видео включено, содержимое при подсчёте не читается |

Синхронный `importFile` остался только для проверенных исходных форматов; в продукте его
вызовов нет. Все четыре входа используют асинхронный импорт через панель.

## Измерения и доказательства

Устройство: **iPhone 17**, `86E91244-4214-433C-ABA6-07D0508D2D6D`, **iOS 27.0**.
Схема LoriQA, отдельный bundle ID, подпись включена. `pgrep -fl xcodebuild` проверялся перед
каждым прогоном; другие видимые запуски относились к DumatelFinance / iPhone 18 Pro,
не к этому симулятору. DerivedData: `/Volumes/Movis/Mac-data/LoriWork/dd-formats-20261113`.
Проект и Info.plist пересобраны `/opt/homebrew/bin/xcodegen generate --spec <repo>/ios/project.yml`.

Образцы: `LoriLocalTests/Fixtures/Formats`, генератор `design/qa/make-format-fixtures.sh`.
Синус 440 Гц, 1,6 с; маленький видеоряд 32×32, у отдельного MOV видео 4 с и звук 1,6 с.
Vorbis получен встроенным `vorbis -strict -2 -ac 2`, без libvorbis. Личных записей нет.

| Образец | Проверенная ветка iOS 27.0 |
| --- | --- |
| Opus `.ogg`, `.oga`, `.opus` | Reader/Writer → M4A |
| FLAC | Как есть, виден в списке |
| AC3, 3GP | Reader/Writer → M4A |
| MP4 и MOV с видео | Reader/Writer → M4A, играет |
| MOV с немым хвостом | В M4A попало 1,6 с звука из 4 с видео |
| WAV μ-law | Как есть |
| Ogg Vorbis | Шлюз; без шлюза понятный отказ |
| MP2 | Шлюз; без шлюза понятный отказ |
| WebM, MKV, WMA | Шлюз; без шлюза причина «нужен шлюз на Mac mini» |
| Битый Ogg | Отказ, исходник цел, в рабочей папке пусто |

**Поправка к предварительной пробе MP2:** AVAudioFile открывает файл, но это не чтение PCM.
Первое настоящее чтение даёт `fmt?` / 1718449215; не сработали Float32 и Int16.
Reader тоже отказывает. Поэтому не утверждаем, что MP2 переводится на этом iPhone:
попытка AudioFile сохранена, фактический путь образца — шлюз. Отдельный тест AudioFile →
Converter на настоящем WAV доказывает работоспособность запасной реализации.
Исправлена обработка EOF: чтение не заходит за `file.length`; настоящая ошибка декодера
не маскируется концом файла.

Для каждого образца проверены ветка, итоговый путь, AVAudioFile/AVAudioPlayer, длительность,
байты/дата исходника, отсутствие `.partial`, дата импорта и строка файлового журнала.
Для переведённых файлов — `CloudAudio.prepare` и настоящая нарезка `AudioSplitter`.
Подставной URLProtocol проверяет POST, путь `/v1/convert`, токен теста, имя и точное тело
файла, ошибки HTTP, битый ответ и уборку. Проверены текст таблицы, все импортированные
типы/MIME в Info.plist и отсутствие динамических UTType для каждого расширения таблицы.

Модульный прогон окончательного iOS-кода:

```text
xcodebuild -project <repo>/ios/LoriLocal.xcodeproj -scheme LoriQA \
  -destination id=86E91244-4214-433C-ABA6-07D0508D2D6D \
  -derivedDataPath /Volumes/Movis/Mac-data/LoriWork/dd-formats-20261113 \
  test -only-testing:LoriLocalTests ONLY_ACTIVE_ARCH=YES \
  -resultBundlePath /Volumes/Movis/Mac-data/LoriWork/formats-accepted-unit-20261113.xcresult

Executed 941 tests, with 8 tests skipped and 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

Полный шлюзовой набор:

```text
node --test test/agy-gateway.test.mjs
# tests 37
# pass 37
# fail 0
```

Тестовый ffmpeg проверяет общую авторизацию и блок неверных токенов, предел 95 МБ
(заявленный и chunked), поток M4A, безопасные аргументы, 0700 и уборку, 415/413/429/503/504,
убийство группы с потомком, один перевод и двоих ожидающих, независимость от agy и health.

В первых прогонах обнаружены и исправлены: нехватка четырёх объявлений UTType
(`mpa`, `mts`, `m2ts`, `vob`), EOF у AudioFile/Converter и ложное предположение о декодере MP2.
При сборке первый раз ещё не был добавлен в Xcode проект новый тестовый helper; xcodegen
это исправил. Не выдаём неудачные прогоны за зелёные.

Xcode после тестов печатает ошибку **сбора дополнительной диагностики** `simctl` (exit 72),
но сам закрытый xcresult содержит перечисленные тесты и итог TEST SUCCEEDED.
Orca emulator helper также отказался подключаться с `emulator_simctl_unavailable`;
сам `simctl` из оболочки и XCUITest доступны. Глобальные настройки Xcode не менялись.

## Живой системный пикер и плеер

Через `safe-container.py` в **QA**, с явным UUID, добавлены два новых синтетических
источника в `Documents/Lori/Models/Formats`: Telegram QA 13.11.2026.ogg и
Video QA 13.11.2026.mp4. Существующие данные не заменялись. В тесте работает настоящий
системный picker «Аудио из Файлов»; через него выбраны оба файла, затем явное нажатие
«Расшифровать». Оба появились в списке, плеер перешёл в состояние «Пауза» после
«Слушать», на вкладке показана сохранённая расшифровка проверочного движка QA.
Отдельная проверка на диске: исходные байты совпали с первоначальным посевом, в Imported
лежат M4A AAC/48 кГц/моно (ffprobe: 1,664 с с кодерным дополнением), в Markdown указан
«Проверочный движок QA», `.partial` нет. Повторный импорт Ogg получил номер по базе.

```text
xcodebuild -project <repo>/ios/LoriLocal.xcodeproj -scheme LoriQA \
  -destination id=86E91244-4214-433C-ABA6-07D0508D2D6D \
  -derivedDataPath /Volumes/Movis/Mac-data/LoriWork/dd-formats-20261113 \
  test-without-building -only-testing:LoriLocalUITests/FormatImportUITests \
  -resultBundlePath /Volumes/Movis/Mac-data/LoriWork/formats-accepted-ui-20261113.xcresult

FormatImportUITests.testFilesPickerImportsOggAndVideoAndPlaysTranscripts passed
Executed 1 test, with 0 failures (0 unexpected)
** TEST EXECUTE SUCCEEDED **
```

Снимки из этого закрытого xcresult:
[Ogg в панели](attachment-ogg.png), [Ogg с текстом и плеером](transcript-ogg.png),
[MP4 в панели](attachment-mp4.png), [MP4 с текстом и плеером](transcript-mp4.png).
Снимок MP4 просмотрен: имя без расширения, три вкладки, текст и плеер читаются.
Короткие проверочные файлы — синус, а не речь; текст QA синтетический, его таймкоды не
являются замером этого звука и не выдаются за настоящее распознавание.

Первые UI-прогоны останавливались на селекторах системного пикера и возврате из записи.
Исправлены: открытие значка папки, ограничение поиска коллекцией File View (карточка
позади sheet иначе подменяла файл), настоящая кнопка «Записи» вместо первой кнопки
навигационной панели. Финальный сценарий прошёл целиком, без пропусков.

Дополнительно настоящее приложение «Файлы» (`com.apple.DocumentsApp`): долгий тап
по Ogg и MP4 → «Поделиться» → Lori QA (через список приложений). Оба файла пришли в панель;
кнопка «Расшифровать» осталась доступной, автоматического запуска не было. Затем вложение
снято крестиком, оригиналы в Files сохранены. Это отдельный зелёный прогон, не общий прогон
всех прежних UI-тестов приложения:

```text
xcodebuild -project <repo>/ios/LoriLocal.xcodeproj -scheme LoriQA \
  -destination id=86E91244-4214-433C-ABA6-07D0508D2D6D \
  -derivedDataPath /Volumes/Movis/Mac-data/LoriWork/dd-formats-20261113 \
  test -only-testing:LoriLocalUITests/FormatImportUITests/testShareFromFilesBringsOggAndVideoWithoutStartingAutomatically \
  ONLY_ACTIVE_ARCH=YES \
  -resultBundlePath /Volumes/Movis/Mac-data/LoriWork/formats-share-20261113.xcresult

FormatImportUITests.testShareFromFilesBringsOggAndVideoWithoutStartingAutomatically passed
Executed 1 test, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

Снимки: [Ogg после «Поделиться»](share-ogg.png), [MP4 после «Поделиться»](share-mp4.png).
Сценарий занял 297 секунд из-за ожиданий XCTest об окончании анимации контекстного меню Files
(несколько раз по 60 с); это **не время перевода**. Итого два новых UI-сценария, оба зелёные,
первый проверяет импорт/плеер/текст, второй — регистрацию получателя и явный запуск.

Для повторения: `design/qa/make-format-fixtures.sh`, собрать LoriQA; создать отдельную
папку с копиями opus.ogg и video.mp4 под именами выше и передать её
`python3 design/qa/safe-container.py <UUID> <папка> Documents/Lori/Models/Formats`.
Helper откажет, если посев с этими именами уже существует; это не повод стирать данные.

## Живой шлюз

Перед заменой SHA-256 установленного файла совпал с родителем коммита шлюза.
На Mac mini сохранена копия `agy-gateway.before-formats-20261113.mjs`, новый файл проверен
`node --check`, установлен атомарным переименованием в
`~/Services/lori-gateway/ui/agy-gateway.mjs`, служба перезапущена:

```sh
launchctl kickstart -k gui/$(id -u)/com.lori.agy-gateway
```

Локально на Mac mini и с рабочего Мака через VPS:

```text
health 200 {"ok":true,"convert":true,"agy":{"path":"/Users/ilyaqa/.local/bin/agy","version":"1.5.8"}}
convert 200 audio/mp4
ffprobe: codec_name=aac, sample_rate=48000, channels=1, duration=1.600000
```

Дополнительные живые POST через VPS, ffprobe всех ответов:

```text
layer2.mp2  200  AAC / 48000 / 1 канал / 1.608000 с
vorbis.ogg  200  AAC / 48000 / 1 канал / 1.600000 с
matroska.mkv 200 AAC / 48000 / 1 канал / 1.600000 с
windows.wma 200  AAC / 48000 / 1 канал / 1.599833 с
```

Токен читался непосредственно внутри скрипта из `~/.config/lori/gateway-token` на Mac mini
или `ios/Secrets/APIKeys.local.json` на рабочем Маке. Значения не печатались; JSON не менялся.
`ffmpeg` на Mac mini — `/opt/homebrew/bin/ffmpeg` 8.1.2, PATH службы его содержит.

## Сознательно изменённые старые тесты

Ogg/Opus/FLAC больше не служат примерами неизвестного формата. Общие тесты отказа теперь
используют PDF/PNG/TXT; специальные тесты Ogg/FLAC проверяют приём. Helper-источники
`WorkspaceImportTests.source` и `ImportBatchTests.staged` вместо произвольных байтов создают
настоящее аудио своего расширения, иначе новый обязательный контроль звука правильно отказывает.
Изменённые тесты перечислены ниже; дополнительный комментарий о формате изменён рядом
с `ImportBatchTests.testTheWholeBatchIsQueuedInOneGoBeforeAnythingStarts`, тело теста прежнее.
- `ImportFormatTests.testDrainStillReturnsOnlyWhatWasTaken`.
- `ImportFormatTests.testEveryAcceptedExtensionPassesInAnyCase`.
- `ImportFormatTests.testIntentFileOfAnUnsupportedTypeIsRejected` → `testIntentFileWithOggTypeIsAccepted`.
- `ImportFormatTests.testOtherFormatsAreNotSupported`.
- `ImportFormatTests.testRejectedFileFromTheVisibleInboxIsRemoved`.
- `ImportFormatTests.testRejectionNamesTheFileTheFormatAndWhatIsSupported`.
- `ImportFormatTests.testStageAllKeepsTheGoodOnesInOrderAndReportsTheBadOnes`.
- `ImportFormatTests.testSystemInboxReportsRejectedFilesAndStillClearsTheFolder`.
- `ImportFormatTests.testTheListedFormatsAreExactlyTheAcceptedExtensions`.
- `ImportFormatTests.testUnsupportedFileIsRejectedBeforeAnythingIsCopied`.
- `ClipboardBatchTests.testFileReferenceToAnUnsupportedAudioFormatIsRefusedWithAReason` → `testFileReferenceToOggIsTaken`.
- `ClipboardBatchTests.testOnlyUnsupportedItemsFailWithTheFormatMessage` → `testOggAndFlacAreBothAccepted`.
- `ClipboardBatchTests.testUnsupportedItemIsSkippedWithAReasonAndTheRestAreTaken` → `testOggItemIsTakenAlongsideOtherAudio`.
- `WorkspaceImportTests.testNameIsKeptAsGiven`.
- `WorkspaceImportTests.testSynchronousImportFollowsTheSameRules`.
- `WorkspaceImportTests.testUnsupportedFormatIsRejectedAndNothingIsCopied`.
- `ImportBatchTests.testBatchReportsAPartialFailureAndTheRestGoOn`.
- `ImportBatchTests.testTheWholeBatchIsQueuedInOneGoBeforeAnythingStarts`.
- `ImportBatchTests.testUnsupportedFormatIsRefusedAndTheStagedCopyIsCleanedUp`.

## Непроверенное и границы

- AMR/AMR-WB: в этой сборке ffmpeg нет кодера, образцов нет; допуск в таблице не объявляется
  доказательством декодирования. При отказе системного декодера нужен шлюз.
- iOS 18–26 и физический iPhone, настоящий Telegram/WhatsApp, Share UI этих приложений,
  реальные фоновые пробуждения и ручное прослушивание звука не проверялись.
- Быстрые команды и буфер проверены модульно; исполнение Shortcut из системного приложения
  и вставка из настоящего мессенджера отдельно не запускались.
- Форматы таблицы вне перечисленных образцов не проверены настоящими файлами в этом заходе;
  они проходят допуск и ту же проверку кодека, затем либо переводятся, либо дают честный отказ.
- Старые MOV, уже лежащие в Workspace, не переписываются автоматически. Они остаются видны;
  чтобы получить совместимый M4A, их следует принести через обычный импорт.
- Проверочный движок QA подтверждает интеграцию импорта с очередью и сохранением текста,
  не качество настоящего распознавания речи. Большие модели не скачивались.
- IPA неподписанная, установка/переподпись на телефоне не проверяется этим выпуском.


## Выпуск и коммиты

`tools/release-ipa.sh --derived-data /Volumes/Movis/Mac-data/LoriWork/dd-release`:
**BUILD SUCCEEDED**, опубликована **`ru.ilyaqa.lori.local--1.0--15.ipa`** в iCloud Drive → IPA Shelf.
Размер 17663138 байт, SHA-256 `366f9bb7d5ecced97cca9b596889771213e94410fa55e290fee50d93351ca7a9`.
ZIP проверен целиком; локальная IPA и iCloud-копия идентичны. У приложения и расширения
версия **1.0 (15)**. Ресурс `PrivateAPIKeys.plist` присутствует в owner Release IPA и
отсутствует в QA `.app`; проверялось только наличие, значения не открывались.

Первый release остановился на старом кэше SwiftPM: два `path` в
`dd-release/SourcePackages/workspace-state.json` ссылались на уже удалённую папку
`/tmp/lori-gateway-20261109/dd`. Сами оба XCFramework были на месте. Перед исправлением
кэша сохранена копия `workspace-state.before-formats-20261113.json`; пути направлены на
существующие артефакты текущего DerivedData, повторный штатный release успешен.
Это исправление кэша сборки, не изменение личных данных или исходников зависимостей.

Коммиты без push:

- `e8cfabd` — `feat(gateway): переводить внешние аудио и видео в M4A`.
- `bd441b7` — `feat(ios): принимать голосовые и видео с проверенным переводом в M4A`.
- `3b82d1d` — `test(ios): проверить получение Ogg и видео через Поделиться`.

Все с `Co-authored-by: Claude <claude@anthropic.com>`; документация и доказательства —
отдельным завершающим коммитом. Установленный на Mac mini файл совпал с репозиторием:
SHA-256 `7ee3bf012db0e1f9b1d54253081caf4cad1a1fab53caf264e203afc29b72270b`.
