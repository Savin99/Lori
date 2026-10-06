# Lori iOS — working rules

## IPA release destination

Owner configuration (2026-09-22): release IPA files go to iCloud Drive → **IPA Shelf** via `tools/release-ipa.sh`; see [IPA_RELEASE.md](IPA_RELEASE.md). For an existing IPA use `python3 tools/ipa-release.py --publish-only <path>`. Publish atomically and replace only previous managed files with the same Bundle ID. Never delete other apps from the shared folder. These are unsigned artifacts for later signing, not proof of installability.

## Scope

Work only in this native iOS project unless the user explicitly asks otherwise:

```text
<repo>/ios
```

Do not modify the Mac side of the repository (`lori/ingest.py`, `ui/server.mjs`, `launchd/`) for an
iOS task. It is a separate program with its own life.

## Product intent

Lori for iPhone is a **transcription app**, with no layer on top of it. Its whole loop:

1. The user records audio from the iPhone microphone, or brings in an audio file (four routes, below).
2. Lori transcribes it with the engine chosen in settings and saves `Transcripts/<name>.md`.
3. The user listens, reads, fixes the text by hand, copies it, or shares it as a file — PDF или
   Markdown, формат выбирается при нажатии («Экспорт расшифровки» ниже).

There is no question-and-answer layer. The owner, 5 October 2026: «я чатам там с ИИ не пользуюсь» —
the transcript leaves Lori as a file, and questions are asked to an AI outside the app. The in-app chat
«Спроси свой архив» was removed that day; see «The assistant layer» below. Titles and descriptions made
by the **local** model (`Summarizer`, MLX) are not a chat and stay.

Everything removed on 27 August 2026 stays removed as well: no wiki, no digests, no autonomous agent,
no note editor, no folder browser. Do not bring any of it back without an explicit request.

The writable sandbox stays:

```text
Documents/Lori/Workspace
```

with `Recordings/` (microphone), `Imported/` (brought from outside), `Transcripts/` (results) and
`.LoriTrash/`. The folder is visible in «Файлы» because file sharing is enabled in `Info.plist`.

Внешнее аудио входит четырьмя дорогами, и все они сходятся в одном месте — прикреплённым файлом
в нижней панели (`ImportInbox`, промежуточная папка `tmp/Принесённое`):

- «Аудио из Файлов» — системный пикер, сразу несколько файлов (`ImportInbox.stageAll`): негодный
  файл не отменяет остальные, о нём — одно сообщение;
- **«Поделиться» → Lori** из Диктофона, Telegram, почты — через `CFBundleDocumentTypes`, а не через
  Share Extension: расширению нужен общий контейнер App Group, а **App Groups бесплатная команда
  разработчика не подписывает**. Система кладёт копию в `Documents/Inbox` и будит приложение, а
  панель разбирает папку при каждом появлении (`ImportInbox.collectSystemInbox`);
- «Вставить аудио» из буфера обмена — всё аудио разом, по порядку буфера
  (`ClipboardAudio.takeBatch`). Подсказка над панелью и пункт меню `+` считают его по типам:
  «В буфере 5 аудио», «Вставить 5 аудио»;
- действие «Расшифровать в Lori» для Быстрых команд (`TranscribeInLoriIntent`).

Жёсткие правила этого слоя:

- **Принесённый файл никогда не уходит в расшифровку сам.** Он показывается в панели с движком и
  оценкой времени («в облако · примерно 3 минуты» против «на телефоне · примерно 12 минут»), и в
  работу его отправляет нажатие. Тумблер «Расшифровывать запись сразу» относится только к диктофону.
- **Имя принесённого файла — временный заголовок** (`SummaryStore.setImported`), а не ручное имя:
  осмысленное («Совещание 27.08») стоит, пока модель не придумала своё, — подменять его на
  «Запись 22:22» значит терять единственную примету. Служебное имя («Новая запись 12»,
  «audio_5_2», «IMG_1234») уступает первой фразе расшифровки (`RecordTitle.isGenericName`).
- `Documents/Inbox` **удаляется целиком** после разбора: `Documents` виден в «Файлах», и пустая
  служебная папка не должна там стоять рядом с рабочей. Кроме одного случая: файл, который не
  вышло принять не из-за формата (нет места, сбой диска), остаётся там вместе с папкой —
  следующий разбор попробует снова (`ImportInbox.collectSystemInbox`). Тихо стереть то, что
  человек отправил в Lori, хуже, чем оставить папку.
- Наличие аудио в буфере определяется **по типам, а не чтением**: `numberOfItems` и типы каждого
  элемента (`types(forItemSet:)`, `ClipboardAudio.inventory`). Чтение показывает системную плашку о
  вставке, и делать это без просьбы человека нельзя; `UIPasteboard.types` для этого не годится —
  он отдаёт типы только первого элемента, и пять скопированных файлов выглядели одним.
- **Пачка уходит одним нажатием и строго по очереди.** «Расшифровать 5» —
  `TranscriptionService.importAndEnqueue`: одна проверка движка до всего, потом копирование всех
  файлов, потом все разом в очередь в порядке панели. Движок не готов — не сделано ничего, файлы
  в панели, причина одним сообщением. Из панели снимаются только вошедшие: `composer.clear()` после
  частичного успеха стёр бы промежуточные копии тех, что не вошли, и повторять было бы нечего.
  Причины отказов — одним сообщением на всё нажатие, а не алертом на файл.

## The assistant layer («Спроси свой архив») — удалён

Чат по расшифровкам удалён **5 октября 2026** по просьбе владельца: «я чатам там с ИИ не
пользуюсь». Расшифровка уходит из Lori файлом, а вопросы к ней задаются ИИ снаружи. Ушло всё:
сервисы `Assistant*`, экран треда, экран ключа, звёздочка в шапке, пункт «Спросить по этой записи»
в «…», поле вопроса в нижней панели, аккаунт Keychain `.assistant`, чат-каталог моделей.
**Не возвращать без явной просьбы владельца.** Как он был устроен (префиксный кэш, роутер по
оглавлению, ссылки на секунды) — в истории Git и в `CLAUDE.md` за 28–29 августа 2026.

Что от него осталось сознательно:

- **Следы на телефоне не стираются**: `Application Support/Lori/thread.json` (тред вместе с
  отправленными кусками расшифровок), запись Keychain `assistant-api-key`, ключи `UserDefaults`
  `assistantBaseURL` и `assistantModel`. Код их больше не читает. Стирать их — значит без просьбы
  удалять данные владельца ради нескольких килобайт. Поэтому же имя `assistant-api-key` не
  переиспользуется: новый аккаунт с этим именем молча получил бы старый ключ.
- **Поле `assistant` в `Secrets/APIKeys.local.json` принимается и пропускается**
  (`tools/embed-api-keys.py`): в личном файле владельца оно есть, а незнакомое поле
  останавливает сборку. В IPA оно не попадает.
- **`AudioPlaybackStore` по-прежнему умеет менять файл.** Правило появилось ради ленты ответа,
  где пилюли вели в разные записи, но хранилище, молча играющее прежнюю запись, — ловушка для
  любого экрана.

## Six engines, chosen by hand

| Engine | Where it runs | Needs |
| --- | --- | --- |
| `GigaAM v3` (`GigaAMTranscriber`) | on the iPhone, ONNX Runtime | model downloaded in one tap into `Lori/Models` |
| `Whisper large-v3 turbo` (`WhisperKitTranscriber`) | on the iPhone, Core ML через WhisperKit | папку модели кладут руками в `Lori/Models`, приложение её не качает |
| Apple (`AppleSpeechTranscriber`) | on the iPhone | system speech models for the locale |
| OpenAI (`OpenAITranscriber`) | in the cloud | key in Keychain; any OpenAI-shaped `/audio/transcriptions` |
| Gemini (`GeminiTranscriber`) | in the cloud | key in Keychain |
| ElevenLabs Scribe (`ElevenLabsTranscriber`) | in the cloud | key in Keychain |

Hard rules:

- **The engine is never substituted silently.** If the chosen one is unavailable, `TranscriptionService`
  reports why (`unavailability(of:)`) and stops. The old behaviour — falling back from GigaAM to Apple —
  is gone on purpose: a fallback that sends audio somewhere else is a privacy bug, not a convenience.
- Cloud engines send the whole recording to a third party. The settings screen says so in plain Russian,
  and the transcript card repeats it before the first run.
- Owner request (2026-09-24): personal device builds may include fallback API keys from
  `Secrets/APIKeys.local.json` (ignored by Git; see `Secrets/README.md`). Manual Keychain values
  take priority. Never print, log or commit key values. QA and simulator builds must exclude
  personal bundled keys; tests use fixtures and injected `keyProvider` values.
- Word timings exist only where the engine really gives them: GigaAM, whisper models и Gemini
  с включёнными таймкодами (нативные `word_info` через `timestamp_granularities`). Придумывать
  таймкоды нельзя: границы отправленного куска — это не время речи, такие реплики помечаются
  `isApproximate`.
- **Whisper large-v3 turbo идёт через WhisperKit** (`argmaxinc/argmax-oss-swift`) — первая и пока
  единственная сторонняя зависимость приложения, версия закреплена в `Package.resolved`. Свой экспорт
  в Core ML отвергнут: у Whisper авторегрессивный декодер с KV-кешем и словарь на 51866 токенов.
- **Модель Whisper приложение не качает — и это не недоделка.** `download: false` в
  `WhisperKitTranscriber` — единственная защита от того, чтобы 618 МБ уехали по мобильной сети;
  папку кладут руками в `Lori/Models` через «Файлы» (`design/whisper/fetch_model.py` собирает её на
  Mac, `seed-model.sh` — в симулятор). Поэтому пометка готовности у него **«Нет модели»**, а не
  «Скачать модель»: кнопки скачивания нет и обещать её нельзя.
- **Рядом с весами обязаны лежать `tokenizer.json` и `tokenizer_config.json`** из
  `openai/whisper-large-v3`: по первому WhisperKit решает, что токенизатор локальный, из второго
  читает класс токенизатора. Без них пакет уходит за токенизатором в сеть — а расшифровка обязана
  работать офлайн. Нехватка файла — это ошибка `modelIncomplete` с именем файла, а не докачка.
- **Куски у Whisper — 28 секунд** при окне модели в 30: кусок обязан проходить одним окном.
  Нарезка и перекрытие — общий `AudioChunker`, дубли из перекрытия отбрасываются по времени
  в `TranscriptAssembler.merge`, как у GigaAM.
- **Whisper даёт таймкоды слов и не различает говорящих** — так и записано в `EngineToggles`.
  Пословные времена считает отдельный проход по вниманию, и он может не дать результата: тогда
  словом становится целая реплика, потому что текст важнее точности времени.
- **Whisper выдумывает текст на тишине** — это свойство модели, а не приложения, и его проверяет
  `WhisperKitIntegrationTests.testSilenceDoesNotBecomeInventedText`: тишина обязана давать честную
  `emptyResult`, а не выдуманную реплику в расшифровке.
- **ElevenLabs Scribe отправляет запись целиком, одним запросом, и нарезки у него нет вовсе.**
  Это не упрощение: сервис берёт до 5 ГБ и 10 часов на запрос (`openapi.json`), тайминги слов
  приходят нативно на всю запись, а **говорящих сервис нумерует внутри запроса** — разрезать
  запись значит выдать «S1» из первой части и «S1» из второй за одного человека. Расплата —
  минуты тишины на экране, поэтому движок докладывает словами через `note`, а полоса честно
  показывает только 0 из 1 и 1 из 1. Своя сессия (`CloudSession.patient`) нужна потому, что
  `timeoutIntervalForResource` — потолок на всю задачу и из `URLRequest` не поднимается.
- **`tag_audio_events` отправляется всегда, даже выключенным**: у сервиса это поле по умолчанию
  **включено**, и промолчать значит получить «(laughter)» в расшифровке, не спросив человека.
  Режим движка отвечает ровно за то, что словами не является: «Дословно», «Со звуками»
  (`tag_audio_events`), «Причёсанный текст» (`no_verbatim`, только у `scribe_v2`).
- **Это единственный движок, где оба переключателя «Расшифровки» настоящие и независимые**:
  таймкоды — `timestamps_granularity` (`word` или `none`, оба значения документированы),
  говорящие — `diarize`. Режим их не отменяет и не подменяет; на это есть тест.
- **Метки говорящих у ElevenLabs считаются с нуля** (`speaker_0`), а в приложении с единицы:
  `ElevenLabsTranscriber.label` прибавляет один. Не переиспользуй `GeminiAnnotations.label` —
  она трактует `speaker_N` как счёт с единицы и дала бы «S0».
- **Списка моделей распознавания у ElevenLabs нет.** `GET /v1/models` отвечает моделями синтеза
  речи, признака «умеет распознавать» в ответе не существует. Поэтому у этого движка в
  `ProviderScreen` нет кнопки «Обновить список моделей», а выбор идёт из
  `ModelCatalog.elevenLabsSuggestions`. Ключ проверяется самым дешёвым `GET /v1/user`.
- У Gemini есть **специализированная модель распознавания речи** `gemini-3.5-transcribe`
  (с 26 августа 2026), она и стоит по умолчанию. Фильтр списка моделей не имеет права её
  выбрасывать: всё, что похоже на распознаватель (`transcribe` в имени, «speech» в описании),
  остаётся в выборе независимо от заявленных методов.

## Какой движок отработал — видно на экране записи

Полное имя движка уже писалось в файл (`_Расшифровано: …_`) и разбиралось
(`TranscriptDocument.engine`), но нигде не показывалось. Теперь оно стоит своей строкой под
датой: короткое имя (всё до первой запятой) плюс иконка «телефон / облако».

- **На карточке в списке движка по-прежнему нет, и это не забывчивость.** Там он был убран
  намеренно: в списке это выглядит как настройка, а не свойство записи. На экране записи наоборот —
  расшифровку можно перезапустить другим движком, и какой отработал, относится именно к этому тексту.
- **Не в ряду с датой.** Первая версия стояла в одном ряду с датой и темой, и он переполнился:
  дата переехала на две строки, имя движка ушло в многоточие. С 5 октября 2026 у даты своя строка,
  а движок делит строку только с чипом темы (справа) — и не режется: не влезли вместе, тема уходит
  под движок (`SplitRow` в `TranscriptScreen`). Та же ловушка, что и с чипами панели.
- **Иконка кодирует не бренд, а локальность** — уходила ли запись с телефона. Она же стоит у каждого
  движка в подменю «Расшифровать заново»: выбор там делается в один тап, и цена ошибки — отправленный
  наружу звук, поэтому после выбора экран переспрашивает и говорит, уйдёт ли запись наружу.
  Локальность разбирается по хвосту имени, и это надёжно: строку писали мы сами
  (`Transcribing.name`). Незнакомое имя иконки не получает вовсе — соврать про то, уходила ли запись
  наружу, хуже, чем промолчать.

## Экран записи (5 октября 2026)

Сверху вниз — в порядке вопросов человека: заголовок, описание, дата и длительность, движок с темой,
плеер, **«Поделиться»** и «Скопировать», блок состояния (только когда есть что сказать), текст.

- **«Поделиться» — главная кнопка экрана**, оливковая капсула под плеером с меню PDF / Markdown;
  «Скопировать» рядом, обведённой. Расшифровка уходит из Lori файлом — решение владельца в день,
  когда удалили чат. В панели навигации только «‹ Записи» (словом: у `Label` панель iOS 26
  оставляет одну стрелку) и «…»; иконки копирования и шаринга в углу дублировали кнопки.
  **Пока текста нет, этих кнопок нет вовсе** — ни в очереди, ни в работе, ни после ошибки:
  выключенные серые капсулы спорили с единственной живой кнопкой блока состояния. Пока файл
  расшифровки дочитывается, они видны выключенными — иначе экран подпрыгивал бы при открытии.
- **Georgia — только заголовок.** Под ним — только описание локальной модели
  (`RecordTitle.generatedDetail`): начало текста стоит ниже, повторять его незачем. Дата абсолютная.
- **Имя записи одно на всё** — `RecordTitle.resolve`: шапка, правка текста, тема, файл экспорта,
  заметка Obsidian. У записи без имени файл и заметка называются с полной датой («Запись 5 октября
  2026, 09:10»), а не «Запись 09:10»: файл переживёт день.
- **Таймкод — кнопка, текст — нет.** Тап по времени перематывает и включает звук; реплику можно
  выделить. Время одной формой у готовых и частичных реплик (с часа — `1:05:20`). На крупном
  шрифте время и говорящий встают над репликой — в строку тексту оставалось по слову.
- **Колонка говорящих одна на всю запись** — по самому широкому кружку (`speakerPills`), не шире
  96 pt (`@ScaledMetric`, растёт со шрифтом); длинное имя обрезается многоточием. Раньше ширина
  была своя у каждой реплики, и столбец текста шёл лесенкой. Меряется по шрифту, а не раскладкой:
  ленивый список строит только видимые строки, и колонка из них прыгала бы при прокрутке.
- **Блок состояния — одно значение `TranscriptionService.state(for:)`.** Очередь с местом и «Убрать
  из очереди», работа с полосой и «Остановить», обрыв с «Продолжить», ошибка строкой с «Повторить»,
  нет текста — «Расшифровать» с движком и оценкой. Ошибка — строкой здесь, а не вторым алертом.
- **«Продолжить» идёт тем же движком** (`interruptedEngine`): без него запись без снимка настроек
  ушла бы движком из нынешних настроек. Текст про обрыв говорит «Lori продолжит сама» — так работает
  `resumeInterrupted` и для облачных заданий со снимком.
- **Переименование и удаление делает список** — экран получает замыкания `onRename` / `onDelete` и
  без них этих пунктов не показывает. Переименовать нельзя запись в работе, в очереди и прерванную
  (`TranscriptionRecordState.allowsRename`): у первых задание держит старый путь, у прерванной
  `forget` снял бы сохранённое задание. Список проверяет это ещё раз в момент «Сохранить» — пока
  окно открыто, запись могла уйти в работу («Сначала дождись окончания расшифровки или останови
  её.»). Набранное сравнивается с заголовком, видимым при открытии окна, а не с нынешним. Держат
  `RecordActionPolicyTests` и `testInterruptedRecordCannotBeRenamed`.
- **Плеер лежит в `@State`, а не в `@StateObject`.** Позиция публикуется каждые 60 мс; экран,
  подписанный на неё целиком, пересобирал бы шапку и сотни реплик на каждом тике. Подписана только
  карточка плеера.
- Вопросы из «…» привязаны к самой кнопке «…»: в iOS 26 `confirmationDialog` встаёт поповером у
  своего вида и без кнопки «Отмена» — отказ это тап мимо (UI-тест так и закрывает его).

## Nothing to type in

The owner's rule, stated plainly: «почему я должен это всё вписывать? в нормальных продуктах
такого нет». So:

- The GigaAM model is downloaded by one button. The address is in the code
  (`GigaAMCatalog.swift`), not in a text field.
- Cloud model names come from the service itself (`ModelCatalog`): `GET /v1/models` for OpenAI,
  `GET /v1beta/models` for Gemini, filtered to what can handle audio. The picker is the interface;
  a hand-typed name is a fallback, not the norm.
- What still has to be typed is only the API key and the vocabulary — a key cannot be guessed, and
  the vocabulary is the owner's own words.

When adding anything new, ask first whether the app can find it out by itself.

## Vocabulary

`TranscriptionSettings.vocabulary` is the owner's list of names and terms, edited as plain text in
settings. OpenAI receives it in the official `prompt` field; Gemini gets it appended to the prompt;
ElevenLabs receives it in the official `keyterms` field — **and that field costs +20% of the
transcription price**, so it is sent only when the vocabulary is actually filled in, the help text on
the provider screen says so, and a service complaint about `keyterms` retries the request without them
rather than failing the transcription. The terms are cleaned to the service's own rules first (≤50
characters, ≤5 words, none of `< > { } [ ] \`): one bad term rejects the whole request.
The list is cut at `vocabularyLimit` characters — with whisper the hint shares the same 224 tokens as
the transcript, and a long dictionary starts crowding out the result. Local engines ignore it, and the
settings text says that.

## Model installation

Models are not bundled (~225 MB per variant) and not exported by hand. Two variants of the open ONNX
export live in `GigaAMCatalog.swift` with their sizes and SHA-256:
`istupakov/gigaam-v3-onnx`, files `v3_e2e_rnnt_*` and `v3_e2e_ctc.*`. `ModelDownloadWorker` downloads
them into a staging directory, verifies size and checksum, and only then swaps the variant's directory
in `Application Support/Lori/Models`. Rules that matter:

- No zip: iOS has no public unzip API. These are plain files, so there is nothing to unpack.
- All or nothing. A failure removes the staging directory and leaves the installed model untouched —
  half a model is worse than none, the engine would not start anyway.
- Progress is reported inside a file, not per file: 225 MB arrive as one file, and «файл 1 из 4» would
  leave the bar at zero and then jump to a hundred (`DownloadProgress` delegate).
- Why not Core ML: nobody publishes a Core ML export of GigaAM, and converting the 845 MB fp32 model
  needs a Mac with `coremltools` and more RAM than the owner's — measured 27 August 2026, 8 GB.
  Details and the verified graph interface are in `design/gigaam/README.md`.

## Audio and transcription truth

- `AudioCaptureStore` records `.m4a` into `Workspace/Recordings` and does **nothing else**. It asks for
  the microphone only. Recording used to be gated behind speech preparation, so a device without
  recognition models could not even save audio — never reintroduce that coupling.
- Transcription is a separate step in `TranscriptionService`, works on any audio already in the
  workspace, and writes `Transcripts/<name>.md`. A failed transcription must leave the audio in place.
- One transcript per recording: re-running another engine **replaces** the file (and stamps
  `_Расшифровано: <движок>_` into it). Earlier it created «Встреча 2.md», and three attempts left a mess.
- **Записи идут по одной, остальные ждут в очереди** — `TranscriptionSettings.concurrency`,
  умолчание 1, предел общий (облачная запись занимает то же место, что и локальная).
  Настройка 1–3 осталась: планировщик её держит, и поднять её — одна строка на экране
  «Расшифровка». История такая: владелец попросил «два разных аудио одновременно», это было
  сделано и работает, а посмотрев — сказал «пофиг на асинхрон, пусть в очередь встают».
  Умолчание вернули, машинерию оставили. **Не выкидывать её**: на ней держится фоновая
  задача (`waitForDrain`) и отмена по конкретной записи, а параллель включается настройкой.
  Разрезать **одну** запись между локальными движками нельзя и незачем — они делят один
  процессор, и сумма времени от этого не уменьшается.
- **Веса локальной модели общие на всю очередь** (`EngineSessionCache`). Раньше каждый вызов
  `transcribe()` собирал модель заново: 618 МБ Core ML у Whisper, три сессии ONNX у GigaAM — то есть
  пять записей подряд означали пять загрузок. Это главный выигрыш по времени, и он остаётся в силе
  при очереди по одной. Он же делает две записи сразу безопасными, когда настройку поднимают:
  вторая копия весов не влезла бы в потолок памяти (право `increased-memory-limit` бесплатная
  команда не подписывает).
  **Сам счёт через модель сериализован, и это не лень:** у `OnnxSession` есть изменяемое поле, а
  буфер выхода ORT переиспользуется следующим вызовом; одновременный `transcribe` на одном
  `WhisperKit` нигде не обещан. Куски двух записей чередуются — обе двигаются, память как на одну.
- **Перед второй локальной записью проверяется свободная память** (только когда настройку
  подняли выше единицы; `MemoryReport.availableBytes`,
  запас в `deviceHeadroomBytes`). Не хватило — запись ждёт со строкой «Жду память», а не роняет
  процесс. Ноль означает «система не сказала» (симулятор) и запретом не считается.
- **Очередь идёт в порядке постановки — и до перезапуска, и после.** `resumeInterrupted` поднимает
  записи по дате снимка задания (`TranscriptionJob.created`; повторная постановка тем же движком
  снимок не перезаписывает, поэтому порядок переживает несколько перезапусков подряд), ничья
  решается путём. Раньше шло по алфавиту пути: пять файлов, поставленных в одном порядке, после
  перезапуска считались в другом. Записи без снимка (прежний формат файла) идут первыми и между
  собой по пути. Держат `QueueOrderTests` и проверка порядка в `testRecordsQueueOneAtATimeByDefault`.
- **Состояние записи — одно значение, `TranscriptionService.state(for:)`**: `.idle`,
  `.queued(position:waitsForMemory:)`, `.starting`, `.running`, `.interrupted`, `.failed`. Раньше
  карточка собирала его из пяти коллекций, и между «вышла из очереди» и «вошла в работу» запись
  числилась нигде: на секунды она мигала «Без расшифровки». Окно названо — `starting` (с `start` до
  входа в `running`). `.interrupted` стоит выше `.running`: оборванная ещё сворачивает работу и не
  вправе числиться «Расшифровывается». Место в очереди — `queuePosition(for:)`, с единицы;
  `isActive` — «ждёт, запускается или считается»: на такой записи нельзя показывать «Без
  расшифровки» и предлагать «Расшифровать».
- **Пачка — от первой поставленной записи до момента, когда очередь опустела.** Счёт «2 из 5»
  (`batchTotal`, `batchDone`) ведёт сервис, а не экран и не фоновая задача: добавленные по ходу
  записи входят в ту же пачку, снятые человеком и оборванные системой из счёта выходят, а
  обработанной считается и расшифрованная, и закончившаяся ошибкой. Очередь опустела — счётчики
  обнуляются, итог остаётся в `lastBatch` (`TranscriptionBatchOutcome`; `isClean` — без ошибок и
  обрывов, отмена человеком не сбой). `waitForDrain()` отдаёт итог именно этой пачки, и фоновая
  задача отчитывается системе по нему (`TranscriptionRunway.completionSuccess`). Раньше она смотрела
  на общие `failed` и `interrupted`, которые никто не обнулял: одна старая ошибка делала неудачной
  каждую следующую пачку.
- **Готовность движка проверяется один раз перед пачкой** — `preflightProblem(for:)`, та же
  `unavailability(of:)`, что остановит и саму запись. Раньше движок проверялся на старте каждой
  записи, и пять файлов при пропавшем ключе давали пять одинаковых строк «Ошибка». Пакетный
  `importAndEnqueue` спрашивает один раз до импорта; не готов — не делается ничего
  (`TranscriptionImportReport.blockedBy`), файлы остаются в промежуточной папке. Одиночный `enqueue`
  вопроса не задаёт: его проверка идёт на старте записи.
- **Импорт и постановка — одно действие, `importAndEnqueue`** (файл и пачка). Пачка остаётся одной:
  сначала копируются **все** файлы, потом они встают в очередь подряд, одним циклом без `await`, в
  порядке выбора и тем движком, что назван в начале. Постановка вперемешку с копированием давала
  сбой на быстром движке (в тесте — «4 вместо 5»): короткая первая запись успевала расшифроваться,
  пока копировалась вторая, очередь пустела посреди ввода, счёт «1 из 5» рассыпался на «1 из 1» и
  «1 из 4», а фоновая задача закрывалась и просилась заново. Негодный файл падает один
  (`TranscriptionImportReport.failed`). Очередь не сохранилась — импорт этого файла откатывается
  (копия в рабочей папке убирается, промежуточная остаётся). Сама запись в работу не уходит: этот
  вызов и есть нажатие человека.
- **Правила копирования в рабочую папку** (`WorkspaceStore.importFileAsync`, те же у `importFile`):
  - формат проверяется **до** копирования: всё вне `WorkspaceEntry.audioExtensions` (m4a, mp3, wav,
    aac, caf, aiff, aif, mp4, mov) отклоняется текстом с перечнем поддерживаемых
    (`ImportInbox.supportedFormatsTitle`, тест сверяет его с множеством). Раньше `.ogg`, `.opus`,
    `.flac` копировались, но в список не попадали. Файл из «Быстрых команд» без расширения получает
    его по типу;
  - имя уникально **по базе**: расшифровка лежит в `Transcripts/<база>.md`, и `Совещание.m4a` рядом
    с `Совещание.mp3` (или та же база в `Recordings/` и `Imported/`) делили бы один текст — вторая
    расшифровка затирала бы первую. Занятыми считаются база любого аудио в любой папке и любой
    расшифровки (текст мог пережить аудио); регистр и форма юникода не различаются; занято — номер
    («Совещание 2.mp3»);
  - копия — целиком или никак: под скрытым именем `.lori-import-<uuid>.partial`, затем
    переименование; остаток после падения убирает `WorkspaceStore.start()`;
  - дата изменения копии — момент импорта: список «новые сверху» сортируется по ней, а копия хранит
    дату оригинала. В пачке даты идут с шагом 10 мс на убыль — первый файл самый новый, и список
    читается в порядке расшифровки. Своей «даты записи» у приложения нет, везде читается
    `modifiedAt`: у принесённой записи это день, когда её принесли.
- **Ошибка последней попытки переживает перезапуск.** Раньше `failed` жил в памяти, и после
  перезапуска запись, на которой расшифровка не вышла, выглядела нетронутой («Без расшифровки»).
  Тексты ошибок лежат в `interrupted.json` под необязательным ключом `failures`: файлы прежних
  версий читаются, без ошибок ключ не пишется вовсе, старая сборка лишний ключ пропустит. Ошибка
  уходит, только когда запись поставили заново, удалили (`forget(_:)` — его обязан позвать экран,
  удаляющий запись, как зовёт `topics.forget` и `summaries.forget`) или когда её файла нет на диске
  (убрали через «Файлы»; чистится в `resumeInterrupted`). Восстановленная ошибка — не обрыв: запись
  не «Прервано», сама в очередь не встаёт и следующую пачку неудачной не делает.
- **«Отменить всё» (`cancelAll()`) снимает всё, что держит очередь**: идущие, запускающиеся, ждущие и
  «Прервано» — вместе с сохранённой очередью. Прерванные входят намеренно: локальные из них
  поднялись бы сами при ближайшем возвращении, и «отменить всё» отменилось бы за спиной у человека.
  Ошибки прошлых попыток остаются. Записи снимаются без планировщика, а он и сохранение зовутся один
  раз в конце: иначе итог пачки закрывался бы на первой снятой записи и недосчитал остальные.
- **Отмена и обрыв системой не теряют и не воскрешают записи.** Пока отменённая работа сворачивается,
  место за ней держится (`cancelling`): «Отменить» и тут же «Расшифровать» не теряется, а
  запоминается и исполняется, когда прежняя работа закончилась (`restartAfterCancel`); обрыв
  системой (`interruptEverything`) в это окно снятую запись не трогает — иначе она вернулась бы в
  сохранённую очередь и при ближайшем запуске поднялась сама.
- **Работа продолжается в фоне** — `BGContinuedProcessingTask` (iOS 26), `TranscriptionRunway`.
  Задача **одна на всю очередь** и сама ничего не считает: считает `TranscriptionService` в своём
  процессе, а задача держит процесс живым и ведёт системную полосу в Dynamic Island и на локскрине.
  Своего Live Activity нет и не должно быть: ему нужен отдельный таргет расширения (ещё один App ID
  против лимита бесплатной команды), фонового времени он не даёт, а полоса вышла бы второй рядом с
  системной. Ресурс `.gpu` не просим — он требует entitlement, который бесплатная команда не
  подписывает, как и App Groups. Нет фона (симулятор, отказ, iOS ниже 26) — приложение говорит об
  этом строкой состояния, а не обещает молча.
- **Идентификатор фоновой задачи один и тот же в трёх местах, и форма у него базовая, без `.*`:**
  `BGTaskSchedulerPermittedIdentifiers`, `register` и заявка — везде `ru.ilyaqa.lori.local.transcribe`.
  Заголовок `BGTaskRequest.h` описывает другое (шаблон в регистрации, `<база>.<uuid>` в заявке), и
  первая версия следовала ему — на телефоне это дало отказ без единого внятного слова. Замер
  подставными идентификаторами на iOS 26.5:

  | В `Info.plist` | `register` | `submit` | Ответ рантайма |
  | --- | --- | --- | --- |
  | `…probewild.*` | любая | — | «Registration rejected; … is not advertised» |
  | `…probea` | `…probea` | `…probea` | **принята** |
  | `…probea` | `…probea` | `…probea.<uuid>` | код 3, «Unrecognized Identifier» |

  То есть форма с шаблоном в plist ломает регистрацию целиком, а составная заявка к базовой
  регистрации **не привязывается**. Подавать надо ровно то, что зарегистрировано. Нам этого хватает:
  задача одна на всю очередь, а повторная заявка с тем же идентификатором заменяет предыдущую.
- **`submit` незарегистрированного идентификатора не возвращает ошибку, а роняет процесс:**
  `*** Assertion failure in -[BGTaskScheduler _handleSubmissionWithoutRegistrationForTaskRequest:error:]`.
  Поэтому результат `register` обязательно запоминается (`TranscriptionRunway.isRegistered`), и без
  принятой регистрации заявка не подаётся вовсе. Обе вещи стерегут тесты
  `testTaskIdentifierIsTheBaseFormAndMatchesTheBundle` и `testHandlerRegistrationIsAccepted`.
- **Обработчики планировщика обязаны быть `nonisolated` и `@Sendable`.** `TranscriptionRunway` —
  `@MainActor`-класс, и замыкание, созданное внутри него, наследует изоляцию главного актора.
  Планировщик зовёт обработчик со своей очереди `com.apple.BGTaskScheduler` — рантайм Swift 6 бьёт
  `dispatch_assert_queue` и роняет процесс **ровно в тот момент, когда фон наконец заработал**:
  `EXC_BREAKPOINT` в `closure #1 in static TranscriptionRunway.register()`. Отсюда
  `nonisolated static func register()`, `nonisolated static let` у того, к чему она обращается,
  и `@Sendable` на самом замыкании и на `expirationHandler`. Задача переезжает на главный актор
  в явной коробке (`TaskBox`): `BGTask` — класс Objective-C и `Sendable` не является.
- **Отказ планировщика разбирается по `userInfo`, а не по коду.** Код 3 (`notPermitted`) означает
  четыре разные вещи, и три круга переспросов ушло на то, чтобы это понять. Теперь при отказе в
  журнал пишется полный `NSError` (домен, код, `userInfo`) и состояние приложения, а
  `TranscriptionRunway.remedy()` спрашивает систему сам (`backgroundRefreshStatus`,
  `isLowPowerModeEnabled`). Именно `userInfo` и назвал причину: «Unrecognized Identifier».
- **Заявка не подаётся, пока приложение не активно.** Она создаётся «от имени приложения на
  переднем плане», а `resumeInterrupted` дёргает очередь прямо на запуске. Такая заявка
  откладывается до `didBecomeActive` (`applicationDidBecomeActive`), а не тратится впустую.
- **У движка есть колбэк `note`** — сказать словами, чем он занят, пока процентов ещё нет. Whisper
  готовит 618 МБ весов под Neural Engine **минуты**, и всё это время «готовлю аудио» на экране
  читается как зависание. Реализуют только те, кому есть что сказать, — как и `partial`.
- **Полоса прогресса считает сделанное, а не начатое** (`TranscriptionService.fraction`). Движок
  сообщает номер куска, за который только берётся; раньше он засчитывался как готовый (`done + 1`),
  и на записи из двух кусков «100%» стояло ровно с середины работы. На Whisper, где кусок идёт
  минутами, владелец увидел это и решил, что приложение зависло. Ноль в начале честнее сотни
  в середине; сотню ставит последний вызов `progress(total, total)`.
- **Обрыв системой — не ошибка движка.** Очередь пишется в `Application Support/Lori/interrupted.json`
  при постановке записи; запись о работе уходит из файла, когда работа кончилась (сам файл
  остаётся). Смахнули приложение из переключателя задач — обработчик истечения не позовут вовсе, и
  файл остаётся единственным следом. Что осталось в файле, помечается «Прервано» и поднимается
  заново при возвращении в приложение и при появлении сети. В файле три части: `jobs` — снимок
  задания на каждую запись (`TranscriptionJob`: движок, настройки **на момент нажатия**, без
  ключей, дата постановки), `legacy` — записи прежнего формата, где лежал только движок, и
  необязательный `failures` — тексты ошибок (см. выше).
- **Считается заново, но не обязательно с нуля: готовое переживает обрыв.** Правило «оборвалось —
  с нуля, половину текста не сохраняем» было верным 1 сентября, когда облачная запись укладывалась
  в один-два запроса; для облака его отменили по просьбе владельца 2 сентября (`CLAUDE.md`): девять
  оплаченных частей — другая цена. Что сохраняется: `LocalTranscriptCheckpoint` у GigaAM и Whisper —
  готовые куски и слова с временами (`Application Support/Lori/Jobs/<id>/local.json`; незаконченный
  кусок считается заново, снимок привязан к заданию и нарезке); `TranscriptCheckpoint` у Gemini —
  готовые части черновиком в `Application Support/Lori/Черновики` (отпечаток файла, движка, модели,
  режима, длины части и словаря; старше недели не поднимается); у всех облачных движков полученные
  по заданию ответы лежат расписками (`BackgroundTranscriptionTransport`, `Jobs/Transfers`):
  запрос, на который ответ уже пришёл, заново не отправляется. У ElevenLabs запись уходит одним
  запросом, и чекпоинтов по частям нет вовсе.
- **В файле лежит путь ВМЕСТЕ С ДВИЖКОМ, и перезапуск идёт тем же движком.** Первая
  версия хранила только пути и ставила запись «текущим движком из настроек». На живом прогоне это
  дало ровно то, что запрещено в этом файле двумя разными правилами: запись, прерванная на GigaAM,
  при следующем запуске ушла в **Gemini**, потому что в настройках к тому моменту стоял он — молча
  подменённый движок плюс 22 МБ звука третьей стороне без единого нажатия. Теперь движок хранится
  в снимке вместе с настройками: поднятая запись считается теми же, а не теми, что стоят сейчас.
- **Облачная запись поднимается сама только тогда, когда у неё есть снимок задания**
  (`resumeInterrupted`: `!kind.leavesDevice || configurations[path] != nil`). Снимок делается по
  нажатию «Расшифровать» (или по остановке диктофона при включённом «Расшифровывать запись
  сразу»): в нём тот самый облачный движок и те самые настройки, которые человек выбрал и видел.
  Поднятая запись — продолжение того же задания, а не новая отправка: движок и настройки из
  снимка, а то, на что ответ уже получен (расписки, черновик Gemini), заново не уходит. Облачная
  запись без снимка (`legacy`, файл прежнего формата) сама не поднимается никогда: она остаётся
  «Прервано», и решает человек — для неё нет ни согласия, ни настроек. Локальные поднимаются сами
  всегда: с телефона ничего не уходит и денег не стоит. Раньше здесь стояло «облачные не
  перезапускаются вовсе» — так было, пока снимков заданий не было. Запрет для записи без снимка
  держит `testResumeKeepsTheEngineAndNeverSendsToCloudOnItsOwn`.
- **Прогресс фоновой задачи обязан двигаться, даже когда доли нет.** Планировщик снимает задачу,
  которая стоит на месте, и на первом живом прогоне снял: облачный запрос идёт одним куском, доли
  у него нет, ноль простоял две с половиной минуты. Записи без доли отдают оценку по времени
  (`TranscriptionService.elapsedShare`), заведомо приблизительную и с потолком ниже единицы —
  «готово» ставит только настоящее завершение.
- **Экран не гаснет, пока очередь идёт и приложение на виду** (`TranscriptionRunway.syncScreen`,
  `UIApplication.isIdleTimerDisabled`). Довод — расчёт из комментария в коде, на телефоне не
  подтверждённый: автоблокировка (через ~30 секунд без касаний) уводит приложение в фон, а где
  настоящей фоновой задачи нет (симулятор, iOS ниже 26, отказ системы), остаётся запасное окно UIKit
  в те же ~30 секунд, и после него всё оборванное считается заново с нуля — длинная запись,
  оставленная на столе, пропадала бы. Флаг отпускается, когда очередь опустела или приложение
  перестало быть на виду (`willResignActive`): он глобален для приложения и не должен пережить его
  уход из-под пальца человека. Уход с переднего плана ловит сам `TranscriptionRunway` по
  уведомлениям — `LoriLocalApp` пересылает ему только `didBecomeActive` и `didEnterBackground`.
- **Строка под полосой — «2 из 5 · название»** (`currentSubtitle`). Счёт берётся у сервиса, запись —
  `currentPath` (самая давно начатая из идущих, а не первая по алфавиту), название — у
  `displayTitle`: замыкания, которое должно подставить приложение (заголовок записи из
  `RecordTitle.resolve`); без него — имя файла. Название не идёт через разбор пути: «Отчёт 27.08»
  потеряло бы «.08».
- `AppleSpeechTranscriber` uses iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` (built for long files) and
  falls back to `SFSpeechURLRecognitionRequest` below iOS 26. Two hard-won details:
  - the locale must be reserved with `AssetInventory.reserve(locale:)` **before**
    `assetInstallationRequest(supporting:)`, otherwise the system answers
    `Cannot check the download status, … is not subscribed to transcription.<lang>`;
  - do **not** call `SFSpeechRecognizer.requestAuthorization` on the `SpeechAnalyzer` path. It shows a
    system dialog that nothing answers in tests and the call then hangs forever.
- `SpeechTranscriber.supportedLocale(equivalentTo:)` returns a locale even where no models exist, so
  availability is decided by `SpeechTranscriber.supportedLocales` being non-empty. Russian is not in
  that list — for Russian the classic `SFSpeechRecognizer` is the only on-device path.
- **The iOS Simulator has no speech models at all**, so Apple-engine transcription can only be verified
  on a physical iPhone (`TranscriptionError.assetsUnavailable` says this plainly).
- Тайминги слов считаются как в `gigaam/timestamps_utils.py`: слово открывает кусок с `▁`,
  начало — кадр первого токена, конец — кадр последнего плюс один, шаг кадра берётся по факту
  (длительность куска / число кадров энкодера), без поправки на задержку RNN-T.
- Куски аудио **перекрываются** (`AudioChunker.overlapSeconds`), иначе слово на стыке теряется целиком.
  Дубли из перекрытия отбрасываются по времени в `TranscriptAssembler.merge`, а не сравнением строк.
- **Core ML EP у ONNX Runtime не подключается.** На квантованном графе он всё равно отдаёт
  почти всё CPU, зато на компиляции модели удваивает расход памяти — и в симуляторе этого не
  видно, потому что провайдера там нет. Приложение падало только на телефоне.
- **Прогресс загрузки — только через делегата уровня сессии.** У асинхронного
  `session.download(from:delegate:)` колбэки не приходят вовсе (проверено и на подставном
  транспорте, и на настоящем HTTP): полоса стояла на нуле, пока 226 МБ качались.
- **Буфер выхода принадлежит рантайму и переиспользуется.** И Core ML, и ORT отдают память, которую
  затирает следующий вызов: состояние LSTM копируется сразу (`OnnxSession.Tensor` держит свою `Data`).
  Симптом был обманчивым: декодер уходил в blank и терял начало записи.
- **Длины у графов GigaAM объявлены int64, но встречаются сборки с int32.** `OnnxSession` пробует
  второй тип и запоминает удачный, а не гадает на каждом кадре.
- **Порядок осей `log_probs` у CTC проверяется по числу классов**, а не берётся на веру: `[1,T,C]`
  и `[1,C,T]` отличаются только этим, а перепутать — получить кашу вместо текста.
- **Куски по 20 секунд** — это память, а не требование графа: входы динамические, но внимание в
  Conformer глобальное и растёт квадратично.
- **Настоящую длину куска обязательно передавать в энкодер**: из неё строится маска паддинга,
  а внимание в Conformer глобальное.
- Гео-отказ (`User location is not supported`, `Country, region, or territory not supported`) —
  это про регион запроса, а не про ключ, и лечится своим адресом API: на Mac лежит
  `ui/api-proxy.mjs`, телефон ходит через него. Ключ в прокси не хранится, его присылает клиент.
- Тексты для человека пишутся одной строкой: склейка многострочных литералов уже протащила
  в интерфейс дорожку пробелов.
- Gemini пробует `interactions`, а при «нет такого метода» повторяет через классический
  `models/<модель>:generateContent`: новый интерфейс включён не у каждого ключа. Ошибку про
  неверный ключ повторять другим адресом нельзя — она должна дойти как есть.
- **Движок, модель и режим — три разных уровня** (`EngineCatalog`). Движок отвечает на вопрос
  «кто считает» и несёт локальность (`iphone` или облако); модель — техническая строка вроде
  `gemini-3.5-transcribe`, она живёт в настройках; режим — осознанный выбор человека, и он
  раскрывается в модель плюс поля запроса. Экраны читают только `EngineDescriptor`, поэтому
  новый движок не требует правок в интерфейсе. Режим хранится в тех же ключах, что и раньше
  (вариант GigaAM, режим Gemini, модель OpenAI), поэтому возврат к движку восстанавливает его
  режим сам собой. У движка с пустым списком режимов чип режима в панели исчезает.
- **Палитра адаптивная** (`LoriPalette.pair`). Цвета заданы парой «светлый — тёмный», а не
  жёстко кремовыми, и `preferredColorScheme(.light)` больше нет. Белый в разметке запрещён:
  для текста на тёмной заливке есть `onInk`, иначе в тёмной теме надписи исчезают.
- Заголовки и описания записей (`Summarizer` на MLX, `SummaryStore`, `SummaryRunner`,
  `RecordTitle`) — в разделе «Заголовки и описания записей» ниже.
- **Перед отправкой в облако запись переводится в FLAC 16 кГц моно** (`CloudAudio`).
  Диктофон пишет ALAC (Apple Lossless) 48 кГц — такого формата нет среди тех, что принимают
  сервисы расшифровки (у Google это WAV, MP3, AIFF, AAC, OGG, FLAC). Файл уходил без возражений,
  а ответ приходил пустой: сервис не мог его раскодировать. Именно так пропала расшифровка записи
  11:32. Побочная польза — запрос весит примерно в десять раз меньше (54 МБ → 5 МБ).
- **Приложение ведёт свой журнал** (`Journal`, файл `Documents/Lori/journal.txt`). Системный журнал
  устройства с Mac без пароля не забрать: `log collect` требует root, `sysdiagnose` — согласия на
  самом телефоне. Поэтому всё важное пишется в файл: поля запроса, размер ответа, сколько разобрано
  слов, попытки, срывы. Файл виден в «Хранилище → Журнал работы» и забирается через
  `devicectl device copy from --domain-type appDataContainer`.
- **Нарезка у Gemini есть, и она не про предел сервиса, а про время в расшифровке.**
  Документация Google говорит прямо: `timestamp_granularities` документированы только как
  `["word"]`, они несовместимы с `custom_vocabulary` и «degrade transcription accuracy».
  Значит в режиме «Точность» время из сервиса не достать вовсе, и единственное честное время —
  границы того куска, который отправили мы сами. Отсюда `TranscriptionSettings.geminiPartSeconds`
  (по умолчанию 10 минут, потолок — предел режима: час, а с таймкодами 30 минут): длина части
  это и есть частота отметок времени. Границы **садятся на паузы**
  (`AudioSplitter.split(alignToSilence:)` → `AudioChunker.quietestOffset`) — разрез по таймеру
  попадает в середину слова, и человек видит это прямо в тексте.
  Урок прошлой пятиминутной нарезки учтён, а не забыт: части перекрываются, дубли снимает
  `SegmentMerge`, а мельчить нельзя — каждый стык это шанс потерять слово.
- **Сорвавшийся участок переспрашивается половинами, а не списывается.** Где начался повтор,
  в «Точности» узнать неоткуда — времени внутри ответа нет, а считать позицию по доле знаков
  значило бы назвать выдуманную секунду. Зато срыв — свойство длинного запроса, и та же речь
  куском вдвое короче обычно проходит. Заход ровно один (`GeminiTranscriber.recover`): два
  подряд означают, что дело не в длине. Половины принимаются, как только дали текст — сравнивать
  с усечённым началом по длине неверно, в нём заведомо нет всего, что шло после срыва.
- **Имена говорящих живут отдельно от расшифровки** (`SpeakerNames`,
  `Application Support/Lori/speakers.json`). Метка в файле остаётся «S1:» — это то, что сказал
  движок, и подменять её в `.md` нельзя: перерасшифровка вернула бы «S1», а правка имени задним
  числом переписывала бы файл целиком. Долгое нажатие на кружок называет говорящего сразу по всей
  записи (метка одна на запись), а в «Скопировать», шаринг и Obsidian уходит уже имя: снаружи
  приложения кружков нет и «S1» ничего не значит. Имена переезжают и удаляются вместе с записью.
- **Расшифровка режется на абзацы** (`TranscriptDocument.paragraphs`, по границам предложений) —
  и та, что без таймкодов, и та, что с ними. Движок без таймкодов отдаёт текст одним куском, а у
  Gemini в «Точности» одна реплика — это целая отправленная часть, десять минут речи: и то и
  другое на экране простыня в несколько экранов высотой. Сверху при этом стоит строка с причиной,
  когда таймкодов нет вовсе — режим «Причёсанный текст», выключенный тумблер или движок, который
  их не даёт. Молчать нельзя: пропажу перемотки человек примет за поломку. Режим берётся из самого
  файла (`_Режим: …_`), а не из нынешних настроек: расшифровку могли сделать другим движком.
- **Абзацам время не раздаётся.** Секунда абзаца считалась бы по доле знаков, а речь идёт
  неравномерно: подпись «≈12:30» под абзацем читается как факт и указывает не туда. Время стоит
  у первого абзаца реплики — там, где оно настоящее, — а продолжения держат пустую колонку той
  же ширины, иначе абзацы одной реплики разъезжаются и читаются как разные реплики.
- **Тайминги — нативные.** `timestamp_granularities: ["word"]` даёт время каждого слова
  (`start_offset`/`end_offset`) и говорящего; `GeminiAnnotations` ищет их в ответе по смыслу
  полей, а не по угаданному пути. Границы отправленного фрагмента таймкодом речи не считаются:
  такие реплики помечены `isApproximate` и пишутся в файл как «**[кусок 0:00–5:00]**».
- **Форма запроса Gemini — из документации, а не из догадок.** Настройки лежат внутри
  `generation_config.transcription_config`: `language_codes` (список BCP-47), `custom_vocabulary`
  (до 1000 терминов, лучше до 100), `mode` — строка `"smart"` либо объект
  `{"type": "verbatim", "timestamp_granularities": ["word"], "diarization_mode": "speaker"}`.
  Верхним уровнем эти поля отправлять нельзя: сервис отвечает «Unknown parameter» на каждое по
  очереди. Полный текст ответа — в `output_text`, слова с таймингами — в аннотациях `word_info`
  (`text`, `speaker`, `start_offset`, `end_offset`). Пределы: час аудио, 30 минут с таймкодами
  или диаризацией, до восьми говорящих.
- **Язык уходит в оба сервиса.** Документация OpenAI прямо говорит, что язык улучшает точность и
  скорость; у `gpt-transcribe` поле называется `languages[]` (список), у whisper и `gpt-4o-…` —
  одиночное `language`. «Определяй сам» означает, что поле не отправляется вовсе.
- **Набор полей запроса подстраивается под сервис.** На «Unknown name "x"» приложение убирает
  именно это поле и повторяет запрос (`GeminiTranscriber.unknownField`), а словарь при отказе
  штатного поля уходит в текст подсказки. Гадать форму настроек по названиям кнопок в AI Studio
  нельзя — это уже приводило к ошибкам.
- **Режим решает всё, тумблеры только показывают.** Режимы Gemini — «Точность» (дословно, час
  одним запросом), «Спикеры и таймкоды» (`timestamp_granularities` + `diarization_mode`, предел
  падает до 30 минут) и «Причёсанный текст» (`smart`). Пара «режим плюс независимые тумблеры»
  позволяла собрать состояние, которого у сервиса не бывает: режим «Точность» с подписью «без
  таймкодов» — и рядом включённый тумблер «Таймкоды реплик». Теперь `geminiWantsWordTimestamps`
  и `geminiWantsDiarization` смотрят **только** на режим, а «Таймкоды реплик» и «Разделять
  говорящих» в «Расшифровке» — индикаторы: они показывают, что даёт режим, и гаснут с
  объяснением (`EngineToggles`). Порядок режимов один и тот же везде (`GeminiMode.ordered`).
  Миграция приводит обе прошлые формы (старое `timecodes`; «точность» с двумя включёнными
  тумблерами) к нынешнему `speakers`.
- **Строкой в `mode` отправляется только `smart`.** Проверка «всё, кроме accuracy → smart»
  однажды уже сломалась: появился третий режим и молча уехал в smart, то есть ровно в тот
  режим, который несовместим с тем, что он должен включать.
- **Один компонент выбора движка** (`EngineSections`) на шит из панели и экран настроек. До
  этого их было два, и они разошлись: имя «GigaAM v3» было записано в четырёх местах по-разному,
  готовность в одном показывалась бейджем, в другом строкой «Состояние». Режим живёт в настройках
  своего движка — там же, где движок выбран, — а не в общей «Расшифровке».
- **Шит из панели — только готовые движки** (владелец, 6 октября 2026: «в селекторе не нужно
  показывать модели, которых нет»; `EngineShortlist`, `EngineSections(onlyReady:)`). Готовность —
  та же, что у бейджа чипа (`EngineDirectory.readyKinds`), своей проверки нет. Исключение одно:
  **выбранный движок виден всегда**, даже неготовый, со своим бейджем и галочкой — пропади он из
  шита, выглядело бы, будто движок подменился сам. Пустой раздел («В облаке» без единого ключа)
  не показывается вовсе. В конце шита — тихая строка «Другие движки — в настройках» (готовы все —
  «Настройки движков»): она открывает `EngineScreen`, тот же экран, что «Настройки → Движок», и
  **там список полный** — модель качают и ключ вводят именно там. Шит перечитывает готовность при
  каждом показе и при возврате с экрана движка; чип — ещё и после закрытия настроек. Подменю
  «Расшифровать заново» — тоже только готовые, но без исключения для выбранного: это действие, а
  не выбор. С проверочным движком QA готовы все (`EngineDirectory.forInterface`).
- **Проверено на живом API 28 августа 2026** (все пять комбинаций, `/v1beta/interactions`):
  - `custom_vocabulary` **несовместим** с таймкодами и с диаризацией — сервис отвечает 400
    «custom_vocabulary is incompatible with timestamps/diarization» (без кавычек, виновник
    первым словом — эту форму разбирает `unknownField`). Приложение снимает словарь и
    повторяет запрос; словарь при этом доходит текстом подсказки. Со `smart` словарь совместим.
  - Говорящие приходят **только** в `word_info` вместе с таймингами: `diarization_mode` без
    `timestamp_granularities` сервис принимает, но говорящих не присылает вовсе. Поэтому
    включённые говорящие тянут за собой тайминги слов в запросе; писать ли время в файл —
    отдельное решение тумблера таймкодов (`Transcript.markdown(stamps:)`).
  - Метки говорящих сервис отдаёт в форме `spk:0`, `spk:1` — счёт с нуля;
    `GeminiAnnotations.label` переводит их в «S1», «S2» (владелец выбрал латиницу).
    В файле метка — текст «S1: …», на экране записи — цветной кружок (`SpeakerDot`),
    сам текст реплики без метки (`TranscriptDocument.speakerMark`). Старые файлы
    с «Г1:» читаются и показываются так же.
- **Зацикливание ловится детектором** (`RepetitionCheck`): повторы слов и n-грамм, доля
  уникальных слов, невозможная скорость речи. Сорвавшийся ответ не принимается: один настойчивый
  повтор запроса, затем речь до срыва сохраняется, остаток помечается предупреждением с таймкодом.
  Проверяется каждая реплика отдельно — иначе сегмент с циклом внутри тянулся в расшифровку целиком.
- **Полнота расшифровки проверяется, а не предполагается.** Gemini молча пропускает участки
  записи (на реальной записи владельца первые 1:40 просто отсутствовали, при том что GigaAM их
  распознал). Поэтому `TranscriptCoverage` считает покрытие по нативным таймингам слов — там,
  где они запрошены и пришли. Без таймингов покрытие не считается вовсе: пустой список —
  это «время не пришло», а не «текста нет».
- **О пропуске судит переспрос, а не громкость.** «Слов на этот участок не пришло» — это ещё не
  потеря: в разговоре молчат минутами, и на одной записи владельца так получились четыре ложные
  плашки разом. Порядок такой (`settleGaps`):
  - `AudioLoudness` слушает пропуск окнами по десять секунд — это **дешёвый предварительный
    фильтр**, чтобы не платить за тишину. Тихо — ни плашки, ни запроса;
  - есть звук — участок **переспрашивается отдельным куском**. Спрашиваем шире найденного звука
    (перекрытие ради контекста), а **берём только то, что попало внутрь пропуска**: расшифровка
    краёв у нас уже есть, и вторая версия тех же слов — дубль в тексте, а не находка. Формулировки
    у двух ответов разные, и `SegmentMerge` такой дубль не ловит — на экране получились две реплики
    на одной секунде с разными говорящими;
  - переспросили, внутри пусто — **плашки нет**: два независимых вопроса об одном участке ответили
    одно и то же, и настаивать на потерянной речи нечем;
  - переспросить не успели (предел `maxGapReasks`, каждый переспрос оплачен) — плашка говорит
    ровно факт: `> Пропуск 32:20–33:37: слов для этого участка сервис не дал`.
  Заход ровно один. **Порог считается от уровня речи этой же записи** (медиана пиков по
  расшифрованному времени, −12 dB) и требует полминуты звука подряд: абсолютный порог ловил бы шум
  комнаты, а одиночный скрип стула — не пропущенный разговор. Числа выставлены по живому прогону:
  уровень речи 0,307, шум в «пропусках» проходил порог −20 dB и не проходит −12 dB.
  Абсолютный −60 dBFS остался страховкой на случай, когда уровень речи не измерить.
- **Метки говорящих у Gemini живут внутри одного запроса.** `spk:0` во второй части — не обязательно
  тот же человек, что в первой: диаризация считается на присланном куске. Приложение это пока не
  сводит, и на длинной записи номера могут разъезжаться между частями.
- **`finishReason` читается и на удачном ответе.** `MAX_TOKENS` при непустом тексте — это
  расшифровка, оборванная посреди участка: текст выглядит нормальным, а всё, что шло после
  обрыва, не пришло. Повтор того же запроса это не лечит, поэтому участок сразу уходит в
  `recover` (половины), а причина остановки пишется в файл журнала строкой `остановка=…`.
  На живом прогоне записи 41:09 во всех пяти частях стоит `остановка=—`, то есть это страховка
  на будущее, а не объяснение уже виденных пропусков.
- Пустой ответ на часть — не повод её потерять молча: один повтор с настойчивой просьбой,
  а если и он пуст — предупреждение с таймкодом участка в файле расшифровки. Ответ без
  разбивки на реплики привязывается ко всему участку целиком.
- Дубли из перекрытия отбрасываются **по доле уже покрытого времени**, а не по «максимальному
  дошедшему времени»: переспрос по пропуску приходит после более поздних частей, и наивная
  проверка выбрасывала именно его.
- Cloud engines cut long audio themselves (`AudioSplitter`, `AVAssetExportSession`): OpenAI by request
  size (25 МБ limit), Gemini by duration — настройка длины части, но не больше предела режима:
  час одним запросом, 30 минут с таймкодами или говорящими. Part offsets are added back to word timings; the
  temporary parts directory is always removed, and the original file is never touched.
- Gemini inline audio is capped at 20 МБ per request, so anything above ~12 МБ goes through the Files
  API (resumable upload, wait for `ACTIVE`, delete after use).

## Заголовки и описания записей

Заголовок и описание записи — **одни на все экраны**. Хранит их `SummaryStore`
(`Application Support/Lori/summaries.json`), придумывает локальная модель (`Summarizer`, MLX; когда
её запускать, решает `SummaryRunner`), а что показать, решает `RecordTitle.resolve`.

- **MLX работает только на устройстве.** В симуляторе нет Metal-устройства, и библиотека не
  бросает ошибку, а гасит процесс в `mlx::core::metal::Device::Device()`. Поэтому в симуляторе
  генерация заголовков не вызывается вовсе (`#if targetEnvironment(simulator)`), а человек видит
  объяснение. Скачивание весов в симуляторе при этом работает и проверяется.
- **Заголовки делает локальная модель** (Qwen3 4B или 1.7B в четырёх битах). Веса скачиваются по
  желанию в «Настройки → Заголовки»; без них заголовком служит первая фраза. Крупная модель берётся,
  только когда `os_proc_available_memory()` показывает запас (`SummaryVariant.requiredFreeBytes`:
  3,1 ГБ у крупной, 1,5 ГБ у лёгкой; скачаны обе — при нехватке берётся лёгкая): права
  `com.apple.developer.kernel.increased-memory-limit` бесплатная команда разработчика не подписывает
  (проверено сборкой), поэтому потолок у приложения около трёх гигабайт.
- **Что показать как заголовок, решает один резолвер — `RecordTitle.resolve`**, и им обязаны
  пользоваться все места, где запись названа: карточка, экран записи, экспорт, Obsidian, правка
  текста, строка в Dynamic Island. Раньше каждое собирало своё: карточка брала имя от человека или
  модели, а экспорт и Obsidian — первую фразу, даже когда человек назвал запись иначе. Резолвер
  чистый и дешёвый (два словарных поиска, файлы не читаются), его зовут прямо из `body`; вид обязан
  наблюдать `SummaryStore` и `TranscriptPreviews`, чтобы перерисоваться, когда придёт заголовок
  модели или дочитается расшифровка. Старшинство (`RecordTitle.Source`), сверху вниз:
  1. `manual` — имя дал человек (переименование). Его не переписывает ничто, кроме успешного
     ответа на явное «Придумать заголовок»;
  2. `model` — заголовок локальной модели; он вправе заменить имя принесённого файла — такое имя
     временное;
  3. `importedName` — осмысленное имя принесённого файла («Совещание 27.08»): человек уже назвал
     запись, и подменить это первой фразой — значит потерять единственную примету;
  4. `transcript` — первая фраза расшифровки;
  5. `genericName` — служебное имя файла в читаемом виде («audio 5 2»), только пока расшифровка не
     дала заголовка;
  6. `date` — «Запись 21:46».

  Строка под заголовком — описание модели, а без него текст записи: продолжение первой фразы,
  **только когда и заголовок взят из текста**, иначе начало текста (отрезать «ушедшее в заголовок»
  не от чего — сниппет начинался бы с середины фразы). Описание модели без подстановки текста
  (`generatedDetail`) идёт в экспорт: текст записи там и так следует целиком.
- **Служебное имя — то, что дали диктофон, мессенджер, камера или сама Lori, а не человек**
  (`RecordTitle.isGenericName`): «Новая запись 12», «audio 5 2», «Вставленное …»,
  «Recording-<ISO>», `IMG_`/`VID_`, Telegram `audio_<дата>`, WhatsApp `PTT-…` и «WhatsApp Audio …»,
  `voice_message`, «Голосовое сообщение…», одни цифры, даты и время, «Untitled», «Без названия».
  Правило — по словам, а не по шаблонам: имя служебное, только если в нём нет ни одного слова вне
  списка (`genericWords`), кроме чисел и коротких кодов; «Совещание 27.08» и «Звонок Маше» — имена
  от человека. Служебное имя уступает первой фразе: раньше «Новая запись 12» побеждала навсегда,
  потому что имя принесённого файла стояло выше текста. Список слов пополняется вместе с тестом
  (`RecordGenericNameTests`), а не набором шаблонов.
- **Хранилище помнит происхождение имени** (`SummaryStore.Origin`): `manual` — `setManual`, имя дал
  человек; `imported` — `setImported`, имя принесённого файла, **временное**, а не ручное
  переименование (иначе «Новая запись 5» навсегда побеждала бы заголовок, который модель уже
  создала); `generated` — ответ модели (`store`). Файл старой сборки, где было только «ручное»,
  читается (`Entry.legacy`): ручное имя, которое на деле служебное, считается старым импортом — до
  `setImported` имена принесённых файлов помечались ручными. Старые сборки читают наш файл по-прежнему:
  `manual` пишется рядом с `origin`.
- **Имя от человека защищено, и защиту снимает только успешный ответ модели.** «Придумать
  заголовок» лишь ставит просьбу (`allowGeneratedTitle` → `replaceManual`); имя остаётся на месте и
  под защитой, пока модель не ответила, а заменяет его только `store(…, force: true)`. Ошибка,
  отмена, нехватка памяти — имя как было. Раньше защиту снимали заранее, и неудачная попытка
  оставляла имя человека беззащитным перед следующим автоматическим заголовком. Новое переименование
  отменяет прежнюю просьбу. Это же исправляет старые импорты, ошибочно помеченные как ручные.
- **Текст записи изменился — заголовок считается заново, а прежний виден, пока не придёт новый.**
  Вместе с ответом модели хранится отпечаток текста (`SummaryStore.fingerprint(of:)`, пробелы и
  переносы не в счёт). Тот же текст (перезапуск тем же движком) модель второй раз не гоняет; другой
  (перерасшифровка, правка) — `markStale`: ответ остаётся на экране и заменяется, когда придёт новый.
  У записей из старых сборок отпечатка нет, и такой ответ считается годным: перегенерировать всё
  подряд без причины хуже. Признак «модель ответила» — отдельное поле `summarized`: пустое описание
  тоже ответ, а раньше признаком служило само описание, и запись с пустым запускала модель на
  каждом возвращении в Lori.
- **Хранилище не теряет файл.** Не читается (защита данных до первой разблокировки) — писать поверх
  нельзя, запись ждёт, пока файл прочитается. Не разбирается — сначала копия рядом
  (`summaries.corrupt-<дата>.json`) и строка в журнал, и лишь потом начало с пустого; не вышла
  копия — поверх не пишем вовсе. Ошибки сохранения тоже идут в журнал.
- **`SummaryRunner`: ворота на передний план неприкосновенны** (крэш 2 сентября, `CLAUDE.md`).
  Модель считает на графическом процессоре, которого в фоне iOS не даёт, и MLX гасит процесс из
  своей очереди. Поэтому модель стартует только при `applicationState == .active`,
  `willResignActive` (не `didEnterBackground`) отменяет счёт, а прямо перед стартом передний план
  проверяется ещё раз: пока читался файл расшифровки, приложение могло уйти в фон. Отмена заявку не
  теряет — она откладывается.
- **Очередь заголовков хранит пути, а не тексты.** В `summaries.pending.json` лежат путь и признак
  явной просьбы; раньше туда ложился весь текст расшифровки, и без скачанных весов файл копил
  тексты всех записей бессрочно. Текст читается из файла расшифровки, когда до записи дошла очередь
  (в памяти живёт только тот, что пришёл с заявкой в этом запуске), — и это заодно самый свежий
  текст. Без весов автоматические заявки не копятся (явную просьбу человека держим). Причина
  простоя (фон, расшифровка, нет модели, мало памяти) пишется в журнал один раз подряд: `drain`
  зовут на каждое возвращение, каждую заявку и каждые 5 секунд, пока мало памяти, а числа в строке
  повтором не считаются.
- **После скачивания весов записи без заголовка встают в очередь сами — новые первыми, и не больше
  `backlogLimit` (10) автоматических заявок разом.** Модель занимает графический процессор на
  каждую запись (по оценке в коде — десятки секунд, не замер), и архив в сотню записей после
  скачивания — долгая работа и горячий телефон. Остальные — при следующих возвращениях в Lori или
  кнопкой «Придумать для N записей» (`summarizeBacklog`, без предела: человек попросил сам). Поиск
  таких записей (`recoverMissingSummaries`) **файлы не читает** — только снимок рабочей папки и
  хранилище: раньше на каждом возвращении в приложение каждая расшифровка разбиралась целиком на
  главном потоке.
- **«Придумать заголовок» — `SummaryRunner.requestTitle(for:)`, и его ответ — значение, а не
  ошибка**: `.queued`, `.needsModel`, `.waitingForMemory`, `.tooShort`, `.failed`. Без модели
  просьба ждёт веса и выполняется сама после скачивания, а экран предлагает скачать на месте.
- **Экран «Заголовки» отвечает на три вопроса и даёт одно главное действие**: что это (короткое
  объяснение), в каком состоянии модель, что нажать. Главная кнопка «Скачать» — для модели, которая
  подходит телефону (`SummaryModelStore.recommendedVariant` по `physicalMemory`: крупная 4B от
  7 ГБ, иначе лёгкая 1.7B). Порог — расчёт, а не замер: измерено только на телефоне с 8 ГБ (журнал
  2 сентября: после загрузки 2,3 ГБ весов свободно около гигабайта), а что на 6 ГБ крупной модели не
  хватит, выведено из этого. Вторая модель — запасной строкой; удаление с подтверждением; «Придумать
  для N записей». Строка в корне настроек — `statusLine`: «первая фраза» без модели («выключены» там
  было неправдой — заголовки есть и без неё), «скачивается N%», название модели.
- **Заголовок из первой фразы (`TranscriptTitle`) берёт текст тем же разбором, что экран записи и
  экспорт** (`TranscriptDocument.parse`): строка `_Режим: …_`, подпись движка, замечания, таймкоды
  и метки говорящих в заголовок и сниппет не попадают (раньше свой построчный разбор отстал от
  формата файла, и карточка называлась «_Режим: Быстрый текст_ Обсудили…»). Граница фразы — знак,
  за которым пробел или конец текста: «27.08», «3.5», «12:30» фразу не рвут, не рвут и сокращения с
  инициалами («т.е.», «А. С. Петров»); слишком ранняя граница («Ок.») уступает следующей; висящий на
  срезе предлог или союз снимается (`tidy`) — то же правило, что у заголовков модели
  (`Summarizer.tidy` зовёт `TranscriptTitle.tidy`).
- **Превью обновляются после сохранения расшифровки и не мигают датой**:
  `TranscriptPreviews.transcriptSaved` оставляет прежнее значение, пока новое не прочитано (раньше
  превью сбрасывали заранее, и карточка показывала «Запись 21:46»). Запись, у которой расшифровки
  не было, перечитывается сама, как только рабочая папка увидела файл; переименование переносит
  превью (`move`), а не перечитывает.
- **Переименование записи — `RecordRename.commit` поверх `WorkspaceStore.renameRecording`:**
  - имя с точкой сохраняет расширение аудио: «Совещание 27.08» раньше теряло `.m4a` (сравнивалось
    `pathExtension`, у которого тут «08») и пропадало из списка;
  - заголовок остаётся таким, как набран (`SummaryStore.setManual`), а имя файла выводится из него
    (`RecordTitle.fileBaseName`): «/», «\», «:» → «-», управляющие знаки → пробел, точки в начале
    снимаются, длина режется по границе знака (предел 255 − 37 байт: корзина приклеивает к имени
    UUID);
  - занятое имя — `WorkspaceError.nameTaken` («Запись с таким именем уже есть») до того, как
    сдвинулся хоть один файл; занятым считается и чужая или осиротевшая расшифровка, и запись с тем
    же именем в соседней папке; смена одного регистра работает;
  - «Готово» без правки не делает ничего (`RecordTitle.isNoOpRename`): раньше перенос темы и имён
    говорящих «со старого пути на новый» при совпавших путях их стирал. Поле правки заполняют
    видимым заголовком (`RecordTitle.resolve`), а не именем файла: иначе нажатие без правки делало
    «Recording-…» ручным заголовком навсегда;
  - расшифровка едет вместе с аудио, не вышло — возвращается и аудио; тема, имена говорящих,
    заголовок, превью и заявка модели переезжают только при смене пути.
- **Имя заметки Obsidian — имя файла в хранилище** (`ObsidianExport.noteName(from:)`): «:», «/», «\»
  → «-», знаки, ломающие ссылки Obsidian или запрещённые на Windows (`* " < > | ? # ^ [ ]`), →
  пробел, `%%` → `%`, точки в начале снимаются, предел 120 знаков, пусто — «Запись».

## Сколько займёт расшифровка

`TranscriptionSpeed` помнит скорость по факту прошлых прогонов на этом телефоне (секунд работы на
секунду звука, скользящее среднее, `Application Support/Lori/speed.json`), отдельно для каждого
движка и режима. Умолчания в коде живут ровно до первого замера: телефоны различаются в разы, а
сеть — на порядок, и гадать по названию движка нельзя. Для облака к оценке добавляется отправка:
запись уходит уже сжатой в FLAC 16 кГц моно (`CloudAudio`), это около 32 КБ на секунду звука.
Формулировка всегда со словом «примерно» — это оценка, а не обещание.

## UX requirements (do not regress)

- Home is the list of recordings, newest first, grouped by day, in the cream visual language —
  библиотека, а не пульт. Шапка без названия экрана: слева меню тем, подписанное тем, что показано
  («Все записи ▾» или имя темы), справа поиск и настройки — больше ничего.
- **Блок очереди над днями — единственный живой элемент экрана** (`QueueBlock`): виден, пока в
  пачке есть записи или хоть одна занята. «Расшифровка · 2 из 5», заголовок текущей записи с
  процентами и остатком **этой** записи (рядом с процентами, а не в первой строке — там он читался
  бы как время всей пачки), полоса (без доли — бегущий отрезок, при «Уменьшении движения» стоит),
  «Дальше: …, ещё N», «Остановить» с подтверждением → `cancelAll`, заметки «жду память» и «идёт,
  пока Lori открыта · почему?». Тап открывает текущую запись. При параллельной расшифровке (2–3
  записи) блок говорит о самой давней из идущих, остальные — строкой «Ещё идёт: …» («Ещё идут: 2
  записи»), счёт — диапазоном «2–3 из 5»: «2 из 5» при двух идущих читалось бы так, будто вторая
  ждёт; «Дальше» — только ждущие (`QueueSummary`). `cancelAll` снимает и прерванные записи, поэтому
  вопрос перед «Остановить» о них говорит, когда они есть (`StopQueueCopy`).
- **Карточка отвечает на три вопроса**: что это (заголовок из `RecordTitle`, до двух строк, на всю
  ширину — плашки-иконки нет), что внутри (описание, до двух строк, с заглавной), что с ней —
  строка состояния **только у неготовой** записи: «В очереди · 3-я», полоса и «Расшифровываю · 63% ·
  ещё ~2 мин», «Прервано» + «Продолжить» (тем же движком, что до обрыва, — `RecordStatus.engine`;
  так же и пункт долгого нажатия), первая фраза ошибки + «Повторить», «Без расшифровки» +
  «Расшифровать». Дата — только в заголовке дня; на карточке время и длительность, а запись без
  заголовка — «Запись 14:58», без «вчера». Кнопка на карточке — `borderless` и лежит поверх строки
  состояния: иначе она забирает тап по строке `List` и сливается с текстом в один элемент VoiceOver.
  Ошибку записи алертом не показываем — она уже на карточке и строкой на экране записи, а алерт
  списка поверх открытого листа этот лист закрывал. Сервис кладёт её ещё и в общую строку
  `lastError`, и главный экран снимает её оттуда сразу (`onChange`), пока она лежит в `failed`:
  иначе «Повторить», удаление или переименование убирали запись из `failed`, и устаревший текст
  вставал алертом «Lori» и выбивал лист (`testRetryFromRecordScreenShowsNoStaleAlert`).
- **Акцент один — оливковый, и задаётся на уровне окна** (`.tint` в `LoriLocalApp` плюс
  `AccentColor` в ассетах). Системный синий рядом с оливковым читался вторым акцентом: зелёная
  галочка движка и синяя галочка режима на одном экране. `.tint`, поставленный внутри
  `ContentView`, до UIKit-презентаций (пикер файлов, шит «Поделиться») не доходит — только ассет.
- **Сниппет карточки продолжает заголовок, а не повторяет его** — но только когда заголовок
  и правда взят из расшифровки. У записи с именем от человека или от модели отрезать «то, что
  ушло в заголовок» не от чего, и сниппет начинался бы с середины фразы (`TranscriptPreviews`
  держит оба варианта).
- **Словарь зеркалится в `Documents/Lori/vocabulary.txt`.** Файл настроек пуст, пока приложение
  работает, и наполняется при уходе в фон: настройка, сделанная перед жёстким завершением
  процесса, пропадает целиком — так и исчезли 52 слова. Восстановление только в одну сторону:
  пусто в настройках и есть в файле. Обратное значило бы спорить с человеком, который слова удалил.
- Нижняя панель (`Composer.swift`) обслуживает два сценария: записать голос и расшифровать
  принесённые файлы. Поля ввода в ней нет. В покое это одна строка: `+` (файлы, буфер — настроек
  там нет, их открывает шестерёнка в шапке), чип движка, чип режима и справа круглая кнопка
  записи. Прикреплённые файлы добавляют над строкой список (имя, длительность, крестик; видно
  четыре, дальше «Ещё N»), «5 файлов · 1:41:12», оценку «в облако · примерно …» и вытягивают круглую
  кнопку в капсулу «Расшифровать 5» во всю ширину под чипами (`matchedGeometryEffect`): рядом с
  чипами ей не хватает места даже на большом телефоне, а урезать имя движка в момент выбора нельзя.
  Смена состояния должна читаться как превращение, а не как подмена одной кнопки другой.
  Состояний три (`ComposerState`: покой, файлы, запись), они взаимоисключающие. Во время записи
  панель схлопывается в строку: таймер, живая волна, пауза, красная кнопка стоп. «Отмена»
  отправляет запись в `.LoriTrash`, стоп сохраняет файл. Не помещаются полные
  подписи чипов (крупный шрифт) — чипы прокручиваются вбок, кнопка записи остаётся на месте.
- **На iOS 26 панель — жидкое стекло** (владелец, 6 октября 2026: «внизу, где селектор, его нужно
  сделать в стиле Apple жидкое стекло»). Список прокручивается под панелью и просвечивает сквозь
  неё; читаемость держит само стекло, поэтому сплошной подложки на iOS 26 больше нет. Как сделано
  и почему (документация Apple — «Applying Liquid Glass to custom views», «Adopting Liquid Glass»,
  HIG «Materials» и «Color → Liquid Glass color»; объявления — `SwiftUICore.swiftinterface` SDK):
  - панель — `glassEffect(.regular, in:)` в том же скруглённом прямоугольнике 26, без оттенка и
    без `interactive()`: `.regular` размывает и подстраивает яркость того, что под ним, и именно
    он для элементов с текстом; цвет Apple оставляет главному действию, реакцию на касание —
    отдельным кнопкам;
  - внутри стекла своего стекла нет («avoid layering Liquid Glass elements on top of each other»):
    чипы и пауза — нейтральная полупрозрачная заливка (`LoriPalette.panelChip`/`panelButton`),
    а микрофон, стоп и «Расшифровать N» — прежняя сплошная заливка `ink` (стоп — `danger`):
    главное действие выделяется заливкой фона, как и советует HIG, и остаётся главным над любым
    содержимым под стеклом, а `glassProminent` положил бы стекло на стекло и перекрасил кнопку
    в оливковый (оттенок стиля — акцент окна);
  - подсказка буфера и «Добавляю…» над панелью — своими стеклянными плашками рядом с панелью, а не
    на ней: голый текст без подложки читался бы прямо по карточкам. Все формы — в одном
    `GlassEffectContainer(spacing: 4)`: интервал меньше просвета 8, иначе плашка и панель
    сливались бы в одну и в покое;
  - вместо `safeAreaInset` — `safeAreaBar`: последняя карточка так же прокручивается выше панели,
    а край прокрутки под панелью размывает и гасит строки у нижнего края;
  - ниже iOS 26 — ровно как было: сплошная карточка с обводкой на сплошной подложке до самого низа
    (полупрозрачная пропускала текст карточек сквозь чипы: в тёмной теме заливка карточки —
    шесть процентов белого). Снимки — `design/redesign-2026-10-05/glass-*.png`.
- **Волна рисуется в `Canvas`, а не стопкой вью.** `HStack` из полусотни столбиков требует свою
  ширину целиком и не сжимается — панель распирало шире экрана, и весь список уезжал влево.
- Чипы рисуются на 32pt, а нажимаются на 44pt (тот же приём, что у круглых кнопок). Правило родилось
  рядом с полем вопроса — крупные пилюли перетягивали внимание с его текста; поле ушло вместе с
  ассистентом, а правило осталось.
- Tapping a recording opens the player first; transcription starts by button or automatically after
  recording, if «Расшифровывать сразу» is on.
- The recording banner (`.recordingBanner`) goes **outside** `NavigationStack`, not inside: inside, a
  large navigation title covers it and the tap lands on the title instead of the banner.
- «Удалить запись» moves both the audio and its transcript to `.LoriTrash`. «Delete» never means
  irreversible deletion. **Удаление всегда переспрашивает** («Удалить запись? Аудио и расшифровка
  переедут в корзину Lori.»), и первой снимается расшифровка записи (`transcription.forget`,
  `summaryRunner.forget`) — иначе движок дописал бы текст к записи, которая уже в корзине.
- Действия с записью: свайп вправо — «Поделиться» (полный свайп) и «Тема»; влево — «Удалить»,
  «Переименовать» (не у записи в работе, в очереди или прерванной), «Obsidian». Без расшифровки
  делиться и слать в Obsidian нечего — этих кнопок нет. Долгое нажатие — меню со всеми действиями
  сразу. Переименование начинается с видимого заголовка (`RecordRename`), «Готово» без правки ничего
  не делает, а занятость записи проверяется ещё раз в момент «Готово».
- Search covers card titles (`RecordTitle`) and transcript text; one hit per recording, and it opens
  the recording. Сниппет — слова реплики без `**[0:34–1:12]**`, «S1:» и служебных строк (тот же
  разбор `TranscriptDocument`), «ё» ищется как «е». Когда закрывается лист записи, открытой из
  поиска, находки без файла (запись удалили или переименовали на её экране) уходят сразу, а индекс
  пересобирается фоном (`TranscriptSearchStore.refresh`): иначе старая находка открывала
  несуществующий файл.
- Правку текста (`TranscriptEditorSheet`) не теряют ни смахивание, ни «Отменить», ни плашка
  записи: с несохранённой правкой всё идёт через «Выйти без сохранения?».

## Экспорт расшифровки

«Поделиться» отдаёт **файл**, а не строку, и формат выбирается на месте: `TranscriptExport`
(модель и Markdown), `TranscriptPDF` (страницы A4), `ShareSheet` (лист с файлом).

- **Голая строка в `UIActivityItem` — это и была та самая жалоба «отправляет кракозябры».**
  Получатель вставлял её текстом в тело сообщения вместе со всей разметкой: `# Запись 22:22`,
  `_Расшифровано: …_`, `**[0:00–0:12]** S1: …`. Ошибки кодировки в файлах не было и нет —
  чтение и запись честно UTF-8; лечит именно **файл с расширением**, у которого получателю
  нечего угадывать. `TranscriptPDFTests.testRussianTextIsReadableBack` держит это тестом:
  русский текст обязан читаться обратно из готового PDF.
- **Формат спрашивается каждый раз, а не живёт в настройках**: PDF нужен, когда расшифровку
  отправляют человеку, Markdown — когда её несут в свой редактор. На экране записи это `Menu`
  на главной кнопке экрана (`shareMenu`), в свайпе вправо по карточке — `confirmationDialog`
  (меню в свайп-кнопку не поставить), в меню долгого нажатия — подменю «Поделиться». Запись без
  заголовка уходит под абсолютной датой («Запись 5 октября 2026, 09:10»), а не «вчера», — и из
  списка, и с экрана записи.
  Формулировки те же, что в веб-интерфейсе: «PDF · Удобно читать и отправлять»,
  «Markdown (.md) · Текст для дальнейшей работы». Продукт один, и на телефоне формат не должен
  называться иначе, чем на Маке.
- **Оба входа отдают один и тот же документ.** Раньше список шарил сырой текст `.md`, а экран
  записи — разобранный текст без таймкодов: два «Поделиться» для одной записи давали разное.
  Теперь оба собирают `TranscriptExport` из `TranscriptDocument`.
- **В файл уходит всё, что есть**: заголовок, абсолютная дата и время, длительность, тема,
  описание записи, «Расшифровано: движок», замечания, реплики с диапазонами времени и именами
  говорящих. Дата абсолютная (`d MMMM yyyy, HH:mm`), а не «сегодня, 22:22»: файл переживёт день.
- **Имена говорящих подставляются на границе** (`SpeakerNames`), как в «Скопировать» и Obsidian —
  в самом `.md` рабочей папки метка остаётся «S1:».
- **`isApproximate` и замечания доезжают до файла.** «кусок 0:00–5:00» — это границы
  отправленного фрагмента, а не время речи; человек, получивший расшифровку, должен знать
  и об этом, и о пропусках. В PDF замечания стоят в шапке, а не в конце: узнать о дырах
  надо до чтения, а не после.
- **`TranscriptDocument.Line` хранит и конец диапазона.** Экрану он не нужен — перематывают по
  началу, — но в файле на диске диапазон есть, и экспорт не имеет права быть беднее источника.
- **Страница PDF белая, а не кремовая, и цвета в рендере свои.** Кремовый холст — язык экрана,
  на печати он съедает тонер. А `LoriPalette` динамическая: лист, собранный в тёмной теме,
  вышел бы белым по белому. Цвет в тексте проставляется **двумя** ключами: шапку рисует UIKit
  и читает `.foregroundColor`, тело — CoreText, и у него для цвета свой ключ с `CGColor`.
- **`cg.textMatrix = .identity` перед каждым `CTFrameDraw` — не украшение.** Текстовая матрица
  **не входит в графическое состояние**: `saveGState`/`restoreGState` её не возвращают, и та,
  которую оставил после себя предыдущий `CTFrameDraw`, достаётся следующей странице. Живой
  экспорт с телефона вышел с одной верной страницей и 63 зеркальными
  (`testEveryPageStartsAtTheTopMargin` меряет это растром: 62 точки от верха у правильной
  страницы против 67 у зеркальной).
- **Страницы нарезает CoreText, и куски считаются заранее** — иначе в подписи не написать
  «стр. 2 из 5», а номер без общего числа не говорит, кончился ли документ. Взятая длина
  никогда не ноль: страница, на которую ничего не влезло, дала бы вечный цикл.
- **Файл ложится в `temporaryDirectory/LoriExport`, и папка чистится перед записью, а не после
  закрытия листа.** «Сохранить в Файлы» читает файл уже после того, как лист закрылся, и
  уборка «на выходе» выдёргивала бы его из-под получателя. Рабочая папка для экспорта не
  годится вовсе: она видна в «Файлах», и служебные копии стояли бы там рядом с записями.
- **Имя файла — заголовок записи** с вычищенными `/` и `:`, а не `lori-20260904-slug.pdf`:
  имя видит получатель. Оно же уходит темой письма через `UIActivityItemSource` — без него
  Почта отправляла бы расшифровку без темы. С экрана записи заголовок берётся из `RecordTitle`
  (имя от человека или модели, а не первая фраза), а у записи без имени — с полной датой.
- **PDF считается вне главного актора** (`Task.detached`): часовая расшифровка — это десятки
  страниц вёрстки, и кнопка не должна на них подвисать.
- **`UIActivityItemSource` нельзя изолировать главным актором**: протокол изоляции не
  объявляет, и Swift 6 отвечает ошибкой о пересечении границы.
- Экран правки текста делится **своим буфером** файлом `.md` и без выбора формата: он про сам
  текстовый файл, а PDF собирают с экрана записи, где есть шапка и имена.

## Data safety after the 7 September incident

- Never use the personal `ru.ilyaqa.lori.local` app as a test host on a physical device. Use the `LoriQA` scheme / `QA` configuration: separate bundle `ru.ilyaqa.lori.local.qa`, display name `Lori QA`, sandbox, defaults and Keychain access group. Simulator tests also default to this scheme.
- Never issue `devicectl copy to --remove-existing-content`, uninstall, container replacement or simulator erase against a user-data installation. A diagnostic subdirectory is not sufficient isolation.
- Use `design/qa/install-qa.py` for test installation: it checks the actual built Info.plist and refuses the personal app. Fixture scripts use `safe-container.py`, require an explicit simulator UUID, verify QA container metadata and refuse overwrites and symlinks. An existing fixture is a refusal, not permission to delete it.
- No direct copy-to operations into the personal phone container for QA. Test audio enters the separate QA app by normal import. Do not reuse personal keys or personal recordings for automated tests.
- Before an explicitly requested update to the personal app, obtain and verify a complete external copy of its audio, transcripts and metadata. Preserve existing backups; a copy inside the same app container does not protect against container deletion. Installation failure is not permission to uninstall.
- The incident's sole cause remains unproven between installation and copying. These guards remove the hazardous test workflow; they do not claim that an app can prevent external deletion of its sandbox. See `design/recovery-2026-09-07/INCIDENT.md`.

## Verification

Unit tests and UI tests run in the simulator. Only three simulators may be booted at once and `booted`
is then ambiguous — address the device by id:

```bash
xcodebuild -project LoriLocal.xcodeproj -scheme LoriQA \
  -destination 'id=<simulator-udid>' -derivedDataPath <scratch>/dd \
  CODE_SIGNING_ALLOWED=NO test
```

If `project.yml` or the file list changes: `/opt/homebrew/bin/xcodegen generate`.

**Симулятор обязан быть на iOS 26**: `id=<udid>` молча уводит на любой установленный рантайм, и
на iOS 18 весь фоновый путь `BGContinuedProcessingTask` просто не выполняется — тесты про него
пропускаются, а прогон выглядит зелёным. Проверять так:

```bash
xcrun simctl list devices available | awk '/^-- /{rt=$0} /iPhone/{print rt, $0}'
```

**Фоновую задачу в симуляторе не проверить вообще**: `BGTaskScheduler` там отвечает
`unavailable`. В симуляторе проверяется только запасной путь (состояние `foregroundOnly` и
честная строка о нём), сама полоса в Dynamic Island — только на телефоне.

Настоящую модель Whisper проверяет `WhisperKitIntegrationTests` (короткая фраза, тишина и замер
двух движков на одном файле). Модель кладётся так:

```bash
python3 design/whisper/fetch_model.py   # кэш ~/Library/Caches/lori-models, качает только раз
./design/whisper/seed-model.sh <udid>
```

**Путь контейнера обязательно перечитывать `simctl get_app_container`**: после переустановки
приложения каталог контейнера получает новый UUID (данные при этом переносятся), и сохранённый
путь перестаёт существовать.

Настоящую модель GigaAM проверяет `GigaAMOnnxIntegrationTests` — заглушкой имена входов, типы длин и
порядок осей не проверить. Модель кладётся в контейнер приложения
(`design/gigaam/seed-models.sh <udid> <папка>`), без неё тест пропускается. Прогон 27 августа 2026
на симуляторе iPhone 17 Pro: оба варианта дали «Проверка плеера записи. Раз, два, три, четыре, пять.»

UI tests need seeding, because the simulator neither records nor recognizes:

```bash
python3 design/qa/install-qa.py <built .app> <udid> --simulator
xcrun simctl privacy <udid> grant microphone ru.ilyaqa.lori.local.qa
./design/qa/seed-audio.sh <udid>
```

Весь набор UI-тестов на чистом симуляторе — в порядке из `design/qa/README.md`, «Полный прогон
на чистом симуляторе»: посев, дважды `testZZ1…` (он оставляет записи с «fail»), потом остальное.
Shell-команды агента — с абсолютными путями, без `cd` в `ios/`: среда агента оставляет в текущем
каталоге пустую `.claude/.cc-writes`, и `xcodegen` добавляет её в проект.

**Тёмная тема в снимках проверяется по пикселю, а не по имени файла.** Симулятор бывает в
состоянии, когда `simctl ui <udid> appearance dark` и `XCUIDevice.shared.appearance = .dark`
записывают настройку (`simctl ui … appearance` отвечает `dark`), а рисуют светлым даже
«Настройки», — и снимки `*-dark` молча выходят светлыми. Так было 6 октября 2026 на симуляторе
финального прогона: тёмные снимки того прогона светлые (в `design/` они не попали). Лечит
перезапуск симулятора (`simctl shutdown` / `boot`, данные остаются).

`Form` rows below the fold do not exist in the accessibility tree — a UI test must scroll to a field
before asking `exists`, and it cannot scroll back up to a field it passed. A sheet dismissing with an
animation leaves buttons under it existing but not hittable: wait for `isHittable` before tapping.

Two agent sessions must not run `xcodebuild … test` on the same simulator: each run relaunches
`ru.ilyaqa.lori.local.qa`, the other run's app dies mid-test and XCTest reports `Test crashed with signal
kill`. Check `ps aux | grep xcodebuild` first and use separate `-derivedDataPath`.

For physical QA, build the `LoriQA` scheme with configuration `QA`, keeping the
owner's signing team only in local command arguments. Install with
`python3 design/qa/install-qa.py <QA-app-path> <device-uuid>`. The helper rejects
an artifact with the personal bundle ID. Never uninstall the personal app to
work around installation/signing errors. Keep physical tests within the separate
QA app; use normal import for synthetic audio. Simulator results do not verify
physical background execution or GPU lifecycle.

## Working style

- Inspect before editing and preserve unrelated user changes.
- Comments explain **why**, in Russian, next to the decision they justify.
- Keep the Mac lightweight: do not download or compile large ASR models during routine work.
- Report only proven runtime/device results. A successful build does not prove the installed app works.
