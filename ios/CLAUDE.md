# Lori iOS handoff — 2026-08-24 (functional-core pass)

Read `AGENTS.md` first. It is the binding project contract.

## What is already implemented

- Native SwiftUI iOS app `LoriLocal`, bundle ID `ru.ilyaqa.lori.local`.
- Local workspace under `Documents/Lori/Workspace`, with safe list/read/write/rename/trash APIs.
- Folder drawer and local browser; user can create folders and import a single document via the iOS picker.
- Separate `+` control opens an add menu instead of chat.
- DeepSeek Chat Completions integration with a Keychain-only API key and a settings-side `Проверить подключение` action.
- Local microphone capture to `.m4a`; Apple on-device speech recognition creates Markdown transcripts.
- Unit tests for workspace sandboxing and UI tests that tap the folder and `+` controls in iOS Simulator.
- Editable notes: `NoteEditorSheet` saves on **Готово** and on swipe-to-dismiss, names a new note from its first line, and offers rename / move-to-trash.
- Rename and move-to-trash from the UI in all three places: home card context menu, browser swipe and context menu, editor `…` menu.
- Multi-round agent loop (`AssistantStore.maxToolRounds` = 6) with tool activity shown as a muted line in the transcript.
- Chat history persisted through `ConversationArchive` (Application Support), restored on launch, capped at 50 conversations.
- Injectable `ChatCompleting` and `keyProvider`, so the agent loop is unit-tested without network or Keychain.

## Important recent bugs and their fixes

| Reported behavior | Current implementation |
| --- | --- |
| Folder button appeared to do nothing | It now opens a folder drawer with create/search/select behavior. |
| `+` opened the DeepSeek chat | It now offers **Новая заметка** and **Выбрать файл**. |
| The model said a file was missing | The system prompt now requires `list_files` first and uses the exact relative path returned by it. An empty workspace is reported as empty, not as a made-up missing file. |
| Saved API key looked lost | The text field clears by design; settings now show a persistent saved status and a safe connection-check button. |

## Fixed in this pass

| Reported behavior | Cause | Current implementation |
| --- | --- | --- |
| Notes could not be written | `FileDetailSheet` was a read-only `Text` | `NoteEditorSheet` with `TextEditor`, saves on Готово and on dismiss |
| Model answered «Готово.» without doing the work | `send()` ran exactly one tool round and silently dropped the second `tool_calls` | loop up to 6 rounds, then an explicit limit message |
| History was empty after every restart | `archivedConversations` lived only in memory | `ConversationArchive` JSON in Application Support |
| Chat did not scroll after sending | `.id` existed only on assistant bubbles, so `scrollTo(last.id)` was a no-op | dedicated bottom anchor, scroll on bubble count and on `isSending` |
| Only the model could delete or rename | `moveToTrash`/`rename` had no UI entry point | context menu, swipe actions and editor menu |
| A card under the composer looked tappable but was not | composer background was `canvas.opacity(0.95)` | opaque composer background |

## Current handoff state

- 31 unit tests and 3 UI tests pass on iPhone 17 Pro Max, iOS 26.5. The UI test drives the whole note lifecycle: create in the editor, reopen, append, move to trash.
- The note editor was verified visually on a simulator screenshot taken from inside a UI test.
- The multi-round agent loop and history persistence are covered by unit tests with a scripted `ChatCompleting`. They have **not** been exercised against the real DeepSeek API, because the key is intentionally unavailable to agents.
- Chat autoscroll was not verified at runtime for the same reason — an empty chat cannot be scrolled. Only the fix and its reasoning are in place.
- The build was not installed on the owner’s physical iPhone in this pass.
- Do not claim the owner’s API key is valid until the owner runs **Проверить подключение** on the device.

## Next safe action

Ask the owner to run **Проверить подключение** in settings, then send `Перечисли файлы в рабочей папке`
with a couple of real notes present. That is the only way to confirm the multi-round tool loop and
the chat autoscroll against a live model.

## Visual pass — same session, after the functional core

- Interface language is Russian throughout, headings included. **This deviates from the Granola reference, whose chrome is English.** One string per label to revert.
- Note rows: name without extension plus modification time. File sizes and per-row padlocks removed; the «only on this iPhone» fact is stated once, in the header.
- Home is grouped: `Папки` (app-generated folders last), then notes under real date headers — «Сегодня», «Вчера», «12 августа».
- Fake calendar card removed. An empty workspace shows a real hint with a «Создать первую заметку» button.
- `ChatHistorySheet` rebuilt to the app's scale (44 pt close button, 17 pt padding), grouped by date, with a right-aligned relative time per row.
- `LoriFont` everywhere: semantic styles and `relativeTo:`, rows sized by padding — Dynamic Type works. `.preferredColorScheme(.light)` plus cream `Form`/`List` backgrounds keep the palette consistent.
- Screen transitions and an animated folder drawer.
- Recording pill with pause, live level meter, elapsed time and «Отмена» — the partial file goes to `.LoriTrash`.
- One shared `AudioCaptureStore` in `ContentView`: recording survives switching between home and chat, which it previously did not.
- Real model picker (`DeepSeekModel`: V4 Flash / V4 Pro) in the composer and in settings, replacing two menu items with one value and a free-text field.
- `Спросить про заметку` / `Спросить про папку` prefill the chat with a ready question.
- Thumbs up/down and the fake «развернуть» explanation removed; copy remains.
- App icon added — the project had no asset catalog at all, so the app shipped with the default placeholder. It is a Georgia `L` on the cream canvas, rendered natively by `design/icon/RenderIcon.swift`; three Higgsfield concepts (serif L, folded page, olive sprout) and four native variants (cream/ink, ink/cream, cream/olive, olive/cream) are kept in `design/icon/`.

## Transcription pipeline — same session

- Recording no longer depends on transcription. `AudioCaptureStore.start` asks only for the microphone; `stop()` returns the saved path. Previously `start` threw when no recognition model was available, so audio could not be captured at all.
- `TranscriptionService` transcribes **any** audio file in the workspace — recorded or imported — and writes `Transcripts/<name>.md` without overwriting an existing one.
- Audio rows in both the home list and the browser: waveform icon, «Запись · дата», tap to open or create a transcript, context menu with «Расшифровать» / «Открыть расшифровку», spinner while running.
- Engine boundary is `LocalTranscribing`: `AppleSpeechTranscriber` (iOS 26 `SpeechAnalyzer`, legacy `SFSpeechRecognizer` fallback) and `GigaAMCoreMLTranscriber` (stub). Settings shows which engine is in use.
- After a recording on the home screen the transcript opens in the editor instead of being sent to DeepSeek. Dictation inside the chat still goes to the model.
- Fixed a bug introduced earlier the same session: two `.alert` modifiers on one view cancelled each other, so transcription errors were invisible.

### What is verified and what is not

- Verified in the simulator: the whole pipeline runs and reports its state — tapping an audio file starts transcription and shows an explicit message. 31 unit tests and 3 UI tests pass.
- **Not verified: actual recognition.** The iOS Simulator ships no speech models (`SpeechTranscriber.supportedLocales` is empty for every language), so no audio can be transcribed there. A real iPhone with Russian dictation installed is the only way to confirm it.
- A 4-second Russian test file made with `say -v Milena` plus `afconvert` is the fastest way to check on a device.

## Транскрипция работает на устройстве — 25 августа 2026

Проверено на реальном файле владельца (`Inbox/audio 5 2.mp3`, 346 секунд) на iPhone 16 Pro Max / iOS 26.5:
**10 кусков, 8 секунд обработки, 1233 символа русского текста.**

Что для этого пришлось исправить:

- **Движок выбирается по языку, а не по версии iOS.** `SpeechTranscriber` из iOS 26 знает 30 локалей, русского среди них нет, а `supportedLocale(equivalentTo: ru_RU)` всё равно отвечает «ru-RU» — приложение уходило качать несуществующий `transcription.ru` и получало `asset unavailable ... Not Installing`. Русский умеет только классический `SFSpeechRecognizer`, зато на устройстве.
- **Длинное аудио режется на куски по тишине** (`AudioChunker`): целевая длина 40 секунд, разрез сдвигается к самому тихому окну в пределах ±4 секунд, чтобы не рвать слово. `SFSpeechURLRecognitionRequest` рассчитан на короткую диктовку.
- **Собираются все результаты распознавания, а не первый.** Распознаватель отдаёт несколько финальных результатов на файл, по репликам. Код завершался на первом: на шести минутах выходило 132 символа вместо 1233. Теперь этим занимается `RecognitionCollector` через `SFSpeechRecognitionTaskDelegate`.
- В строке файла виден прогресс: «Расшифровываю… 3 из 10».

Ограничение классического движка: **текст без знаков препинания и заглавных букв.** Это и закрывает GigaAM — его словарь содержит пунктуацию и заглавные, то есть модель выдаёт оформленный текст сама.

## GigaAM работает на устройстве — 25 августа 2026

Три модели Core ML экспортированы из `v3_e2e_rnnt` и проверены на iPhone 16 Pro Max / iOS 26.5
на реальной записи владельца (346 секунд): **38 секунд обработки, 1165 символов,
18 точек, 29 запятых, 20 заглавных.** Пунктуацию и заглавные модель ставит сама.

Приёмка экспорта — `design/gigaam/verify_coreml.py`: он сверяет **итоговый текст** с тем,
что выдаёт сама библиотека на `example.wav`. Совпадение почти полное; расходятся
заглавные в четырёх словах после запятых — там логиты почти равны, и fp16 перекидывает
argmax. Численно сравнивать активации энкодера бессмысленно: fp16 через 16 слоёв Conformer
даёт до 12% на случайном входе, и это ни о чём не говорит.

Грабли, на которые ушло больше всего времени:

- **Длина последовательности запекается в граф** (`view(t, b, h, d_k)` в rotary-внимании),
  поэтому окно энкодера фиксированное — 4499 кадров признаков, около 45 секунд.
  Обещать динамическую ось было бы обманом: модель молча считала бы неверно.
  Приложение режет аудио под это окно и дополняет хвост **тишиной** `log(1e-9)`, а не нулями:
  нуль в логарифмической шкале означает мощность 1, то есть громкий шум.
- **Длину нельзя передавать входом**: из неё в графе строится маска через `torch.arange`,
  и coremltools 9 падает на касте массива из одного элемента — это несовместимость с numpy 2
  (`only 0-dimensional arrays can be converted to Python scalars`). В скрипте экспорта стоит
  точечная заплатка `patch_scalar_cast`, а длина зашита константой.
- **Core ML выравнивает внутреннюю размерность**: выход joint на 1025 классов приходит
  буфером из 1040 значений. Читать подряд нельзя — только по `strides` (`MLArrayIO`).
- **Выходы надо объявлять fp32**: при `compute_precision=FLOAT16` они по умолчанию Float16,
  и Swift падает с `specified scalar type Float does not match Float16`.
- `torch.jit.trace` не проходит `check_trace` из-за кеша позиционных эмбеддингов;
  проверка отключена, вместо неё сквозная сверка текста.

Модели лежат в `Documents/Lori/Models` контейнера приложения (видны через «Файлы»,
в списке заметок не показываются) и продублированы в `/Users/ilyaqa/Projects/GigaAM/coreml-build`.
Энкодер 422 МБ, предиктор 2.2 МБ, joint 1.3 МБ, словарь 9 КБ.
Если моделей нет, `TranscriptionService` уходит на движок Apple — текст без пунктуации.

## Второй мозг: обработка, память, вики — 25 августа 2026

Расшифровка перестала быть конечным продуктом. Теперь запись даёт **два** текста, и оба остаются:
дословный в `Transcripts/` и обработанный — в тематической папке. В карточке записи стоит
переключатель «Важное ↔ Расшифровка», по умолчанию открыто «Важное».

- `DigestService` просит модель собрать заголовок, суть, «важное», решения, задачи и теги строгим
  JSON и сама раскладывает заметку по темам: тема выбирается **из уже существующих папок первого
  уровня** (сравнение без учёта регистра), иначе на каждую запись появлялась бы новая папка
  с почти тем же названием. Служебные `Recordings` / `Transcripts` / `Inbox` / `Models` темой быть
  не могут.
- Связь «аудио ↔ расшифровка ↔ заметка» живёт во **front matter самой заметки**, а не во внешнем
  индексе: front matter переживает переименование, переезд и правку руками. `DigestService` только
  кэширует обход и пересобирает его, когда файл по кэшированному пути исчез.
- Обработка требует ключа модели. Без ключа карточка не показывает пустоту: «Важное» отдаёт ту же
  расшифровку, разбитую на абзацы локально (`TranscriptReadability`). Слова при этом не меняются,
  а разрез идёт только по концу предложения — текст без пунктуации (движок Apple) остаётся одним
  абзацем, потому что рвать его наугад хуже, чем не рвать.
- Память — **видимая заметка** `Память Lori.md`, а не скрытая база: владелец должен читать и править
  то, что о нём запомнили. Содержимое подставляется в системную инструкцию перед каждой отправкой,
  поэтому «помнит» работает и без вызова инструмента. Переключатель «Использовать память»
  выключает всё сразу: и инструменты `remember` / `forget`, и подстановку фактов.
- Агенту добавлены `search_notes` (поиск сразу по всем заметкам и расшифровкам), `list_topics`
  и `topic_notes`. Это честный поиск по словам: основа — первые пять букв, чтобы падежи сходились,
  плюс список стоп-слов. Не вектора и не эмбеддинги — называть это векторным RAG нельзя.
- Вики (`WikiIndex`, `WikiSheet`, вход в шторке папок) считается из файлов и нигде не хранится:
  темы — папки, теги — из front matter и `#решёток`, связи — из `[[двойных скобок]]`, обратные
  ссылки — из прямых. Ссылка без заметки показывается как будущая тема, а не как ошибка.
- `LLMSettings`: можно указать свой адрес API и имя модели — подойдёт любой сервис с API как
  у OpenAI, включая модель, поднятую на своём компьютере. Мусор в поле адреса откатывает всё
  на DeepSeek, а не ломает чат молча. В `Info.plist` для этого добавлены `NSAllowsLocalNetworking`
  и `NSLocalNetworkUsageDescription`.

### Что проверено и что нет

- **124 модульных теста и 15 UI-тестов проходят** на iPhone 17 Pro / iOS 26.5 (один UI-тест плашки
  записи пропускается: симулятор не начинает запись даже с выданным доступом к микрофону).
- Переключатель в карточке проверен вживую в симуляторе (`DigestCardUITests`): «Важное» показывает
  обработанную заметку с заголовком, разделами и темой, «Расшифровка» — дословный текст,
  «Открыть заметку» открывает именно заметку. Скриншоты снимаются изнутри теста.
- Вики проверена вживую (`WikiUITests`): вход из шторки папок, темы, теги, страница заметки.
- **Не проверено на живой модели:** сам DeepSeek. Весь путь до него и обратно проверен на локальном
  сервере, но качество «Важного» и то, как модель выбирает тему, может оценить только владелец
  на устройстве — ключ агенту недоступен намеренно.
- **Не проверено: автоматическая обработка сразу после расшифровки.** В симуляторе нет моделей
  распознавания, поэтому расшифровку там не получить. Проверено правило (`shouldProcess`)
  и ручной запуск обработки.
- Грабля UI-тестов: под открытым листом остаются кнопки шторки папок с теми же названиями,
  и `firstMatch` цепляет невидимую — тап падает с «Failed to not hittable». Искать надо среди
  `allElementsBoundByIndex.first { $0.isHittable }`.

### Прогон против настоящего HTTP — тот же день

Подставной `ChatCompleting` не проверяет ни сеть, ни разбор ответа, ни настройки провайдера,
поэтому весь путь модели прогнан через локальный сервер с API как у OpenAI
(`design/qa/mock-llm.py`, ключ владельца не нужен). **124 модульных теста и 15 UI-тестов
проходят**, из них пять новых — сквозные: обработка расшифровки в заметку тематической папки,
поиск по заметкам в чате, запоминание факта, ответ модели не в том формате, ошибка провайдера
и предел раундов вызова инструментов.

Что при этом нашлось и исправлено:

- **Композер врал про модель.** При своём провайдере в чате горело «V4 Flash», хотя запрос уходил
  к другой модели. Теперь при своём провайдере вместо меню DeepSeek стоит имя настоящей модели,
  а в настройках сказано, что выбор модели DeepSeek ни на что не влияет.
- **Проверка подключения тоже врала**: «DeepSeek принял ключ» независимо от адреса.
  Теперь «Подключение работает: <куда именно>».
- **Служебная папка могла стать темой.** Модель вполне может ответить `theme: "Transcripts"` —
  заметка легла бы в сырьё, которое вики не показывает. Такой ответ теперь откатывается
  на «Заметки».
- **`CODE_SIGNING_ALLOWED=NO` делает Keychain недоступным.** В неподписанной сборке нет
  entitlements вообще, `SecItemAdd` возвращает «A required entitlement isn't present», ключ
  не сохраняется — то есть документированная команда тестов физически не может проверить ни один
  путь с моделью. Прогонять такие тесты нужно с обычной подписью «Sign to Run Locally».
- **Правило автообработки вынесено из интерфейса** в `DigestService.shouldProcess` и покрыто
  тестом: сам автоматический проход в симуляторе не воспроизвести (нет расшифровки), а правило —
  можно. Ручное «Обработать» работает и при выключенной автообработке.

Предел раундов проверен по-настоящему: подставная модель зовёт инструмент бесконечно,
приложение делает ровно шесть запросов и говорит «Остановился после 6 обращений к файлам».
Бесконечного цикла и лишних трат нет.

Две грабли тестов, которые читаются как дефекты приложения: под открытым листом остаются
одноимённые кнопки экрана под ним (`firstMatch` берёт невидимую — фильтровать по `isHittable`),
а из вложенной папки лист закрывается в два шага, потому что «Готово» есть только в корне.

### Прогон против настоящего DeepSeek — тот же день

Владелец сам вбил ключ в симуляторе (агент ключ не запрашивал и не касался). Первый ответ провайдера
был «Authentication Fails» — ключ оказался недействителен, приложение показало это дословно;
после замены ключа всё пошло. Что дал настоящий `deepseek-v4-flash`:

- **Обработка расшифровки.** Тему выбрал существующую («Работа»), заголовок «Оффер бэкенд-кандидату
  до пятницы», четыре пункта в «Важном», задачу с дедлайном, четыре тега, а «Решения» оставил
  пустыми — решений в записи и не было. Ровно то поведение, которого требует промпт.
- **Чат.** На «что я говорил про оффер» сходил в `search_notes`, ответил по найденному и назвал
  точные пути заметок. На «запомни, что…» вызвал `remember`, факт лёг в «Память Lori.md».
- **Память работает и на следующем ходу:** факт, который уже есть в памяти, модель узнаёт из
  системной инструкции и отвечает без вызова инструмента. В тесте это выглядело как поломка,
  поэтому запоминаемый факт теперь уникален на каждый прогон.

Что настоящая модель вскрыла в интерфейсе (заглушка не могла — она отвечала простым текстом):

- **Ответы приходят Markdown’ом, а чат рисовал их как есть**: «**Где это записано:**», обратные
  кавычки вокруг путей, дефисы вместо списков. Появился `MarkdownText`: блоки (заголовки, списки,
  нумерация, цитаты, ограждения кода) разбираются сами, строчная разметка отдаётся
  `AttributedString`. Копирование по-прежнему кладёт в буфер исходный текст. Отдельно поправлен
  чекбокс `[ ]` посреди строки — Markdown рисовал его серым квадратом пустой ссылки.
- **Шапка чата уезжала вместе с лентой**: на длинном ответе текст лез под статусную строку, а кнопки
  закрытия и истории уходили за экран. Шапка приколочена через `safeAreaInset(edge: .top)`.

Итог прогонов: **131 модульный тест и 15 UI-тестов**, из UI пропускаются четыре — три сбойных
сценария (их умеет только заглушка, а она остановлена) и плашка записи (симулятор не начинает
запись). Режим провайдера печатается в лог прогона: через переменную окружения `TEST_RUNNER_…`
он до раннера не доезжает, и один «зелёный» прогон незаметно шёл против заглушки — теперь режим
определяется по факту, поднята заглушка или нет, а прогон против заглушки с сохранённым ключом
запрещён (иначе ключ владельца уходит на локальный сервер).

### Микрофон убран из композера — 25 августа 2026

По решению владельца кнопки микрофона больше нет ни на главной, ни в чате. Запись начинается
единственным явным входом: «+» → «Записать». Причина — одна кнопка означала две разные вещи:
на главной «записать материал», в чате «продиктовать вопрос», и различить это по кнопке было нельзя.
Диктовка-вопрос вместе с ней ушла: запись теперь всегда материал. Главная кнопка чата только
отправляет и погашена, пока в поле пусто. Пилюля записи в композерах осталась — это живое состояние
и единственный способ поставить на паузу, остановить и отменить.

Что удалять **не** стали: `AudioCaptureStore`, плашку записи, доступ к микрофону в `Info.plist` —
требование цели «записывать или принимать аудио» осталось в силе, изменился только вход.
Проверяется `RecordingEntryUITests`.

### Аудио прямо в чат — 25 августа 2026

Скрепка в чате раньше молча копировала файл в `Inbox`: ни расшифровки, ни сообщения, ни следа —
файл исчезал. Теперь принесённый файл проходит весь путь:

1. Копия в рабочей папке, в ленте появляется карточка вложения (`ChatAttachmentCard`).
2. Аудио расшифровывается на устройстве, в карточке видно «Расшифровываю… 3 из 10».
3. Текст уходит модели **служебным** сообщением (`AssistantStore.addContext`, лимит
   `maxContextCharacters`, обрезка проговаривается в самом сообщении) — по вложению можно
   спрашивать сразу, но стены расшифровки в ленте нет.
4. Если включено «Сразу делать „Важное“» и есть ключ — заметка в тематической папке, и карточка
   показывает «Важное готово · тема».
5. Не аудио и не текст (картинка, архив) — честная строка в чате, что Lori это прочитать не может.
   Притворяться, что «принял», нельзя.

Развилка приёма вынесена в `ChatIngest.decide` и покрыта тестом. Восстановление диалога из истории
текст вложения в контекст **не** возвращает: файл надо принести заново, иначе модель получит
выдуманную историю. Лист в чате стал один (`ChatSheet`: история / файл) — правило «один `.sheet`
на экран» соблюдено.

Проверено: 137 модульных тестов и 17 UI-тестов. Карточка вложения проверена живьём — историю чата
с вложением сеет `design/qa/seed-digest.sh`, потому что системный выбор файла из теста не подсунуть.
Непроверенным остался только сам выбор файла: шесть строк склейки между документным выбором
и `ChatIngest.bring`.

### Движение в чате — выбрано по макетам, 25 августа 2026

Владелец выбирал по живым макетам (`design/motion/index.html`, опубликованы артефактом):
**1Б** — кольцо с процентами у вложения, **4В** — спокойная карточка с намёком на текст,
**3А** — панель вопроса снизу (отложена: нужен инструмент, которым модель задаёт вопрос
с вариантами). Раздел 2 владелец не выбрал, поэтому принцип такой: где прогресс настоящий —
кольцо с процентами; где его нет (обработка это один запрос) — строка с бегущим блеском.
Врать процентами там, где их нечем считать, нельзя.

- `MotionBits.swift`: `ProgressRing` (доля или бесконечное вращение), `ShimmerLabel` (блик по маске
  из самого текста), `RevealedLines` (первые строки проявляются по очереди), `MotionText` (разрезка
  по словам с многоточием на обрыве).
- `TranscriptionService.progressFraction` — доля числом. Разбирать «3 из 10» обратно из строки
  во вьюхе было бы ломко: строка ещё и локализованная.
- Строки предпросмотра — **настоящий текст**, а не серые полоски: рисовать заглушки поверх готового
  текста значит прятать содержимое ради красоты.
- Сторонних анимационных библиотек не добавлял: `trim`, `TimelineView` и `transition` делают ровно
  это. Lottie имеет смысл, только если появится нарисованная дизайнером анимация.

Ещё две грабли UI-тестов (обе читаются как дефекты приложения): в `LazyVStack` строк за пределами
экрана в дереве элементов нет вовсе — перед поиском верхней строки надо промотать список к началу;
и **имя файла заметки не равно её заголовку** — символы, недопустимые в пути, вырезаются
(«Тема: смысл» → «Тема смысл»), поэтому строка списка и заголовок в карточке отличаются.

### Что владельцу стоит проверить на устройстве

1. Записать что-нибудь на несколько минут и дождаться «Важного»: заголовок, суть, пункты, тема.
2. Проверить, в какую папку легла заметка, и переложить руками, если тема не та — front matter
   при переносе не портится, карточка заметку не потеряет.
3. Сказать в чате «запомни, что…», затем в новом диалоге спросить об этом же.
4. Спросить «что я говорил про <тему>» — ответ должен опираться на `search_notes`, а не на догадки.
5. Открыть шторку папок → «Вики: темы и связи».

## Known remaining quality debt

- No persistent recording bar over sheets: recording continues while the editor or browser is open, with no indicator there. Granola shows one.
- No calendar integration. Adding one means EventKit and a permission prompt, not a placeholder card.
- Folders have no description or access fields, and there is no folder hero header — both exist in the reference.
- `AVAudioSession` uses mode `.measurement`, which disables input processing. `.default` is likely better for dictation but cannot be judged without a device test.
- GigaAM is still a stub, but the route is prepared and measured in `design/gigaam/` (export script with a resource preflight, plus the exact model and preprocessing spec). The owner's GigaAM v3 (428 MB, `v3_e2e_rnnt`, no ONNX export) sits at `/Users/ilyaqa/Projects/GigaAM`, but the Mac had 0.7 GB free RAM and 11 GB free disk on 24 August 2026 — too little to start a Core ML conversion, which also needs an RNN-T greedy decoder and a matching log-mel front end in Swift.
- The project is not under git, so there is no rollback for a bad edit.

## Known product boundary

The current transcription engine is Apple on-device speech recognition. GigaAM is not embedded on iOS yet; `GigaAMCoreMLTranscriber` remains an explicit stub. Do not start a heavyweight model conversion/download on the Mac without a new, explicit request and a memory/RAM check.
