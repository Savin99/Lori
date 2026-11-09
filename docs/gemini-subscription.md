# Gemini для Lori: подписка или API

Проверено 9 ноября 2026: документация Google, условия Antigravity, замеры `agy` 1.5.2 на новом Маке.

## Итог

- Подписка Google AI (Plus / Pro / Ultra) **не даёт API-ключа**. Доступ к её квоте из терминала —
  только Antigravity CLI (`agy`). Gemini CLI для потребительских аккаунтов отключён 18 июня 2026.
- **Встраивать `agy` в приложение условия запрещают**, исключения для личного некоммерческого
  использования в тексте нет (цитаты ниже). Блокировки в 2026 году уже были, и снимала их автоматика.
- **Законный способ взять из подписки деньги на Lori** — кредиты Google Developer Program на
  Gemini API: $10 в месяц на AI Pro, $40 на Ultra 20 ТБ, $100 на Ultra 30 ТБ. Нужна предоплата
  от $5; кредиты тратятся раньше неё, но только пока баланс предоплаты больше нуля.
- Платный уровень API не использует запросы для обучения. Бесплатный — использует, и их читают люди.

## Условия Antigravity (дословно)

- FAQ, https://antigravity.google/docs/faq:
  «Antigravity CLI headless mode (`agy -p`) is intended for direct scripting and CI workflows.
  Wrapping `agy` inside third-party coding agents or applications, or automating account rotation,
  is not supported under consumer plans.»
- Там же: «Using third-party software, tools, or services to access Antigravity is a violation of
  our Terms of Service … Such actions can result in suspension or termination of your account.»
- Условия, https://antigravity.google/terms: «This includes, but is not limited to, using the
  Service in connection with products not provided by us. Using third party software, tools, or
  services to access the Service (e.g. using OpenClaw with Antigravity OAuth) is a breach of this
  Agreement. Such actions may be grounds for suspension or termination of your Antigravity and/or
  Gemini CLI accounts.»
- Данные: «Google employees and contractors may access, view, review and use Interactions.»
  Телеметрию можно выключить, но «Google still uses your data to provide the service, process any
  feedback and help keep Antigravity safe».
- Блокировки: февраль 2026 — аккаунты, гонявшие квоту через сторонние инструменты, потом разбанены
  с предупреждением (https://github.com/google-gemini/gemini-cli/discussions/20632); март 2026 —
  «more robust detection for policy-violating use cases»
  (https://github.com/google-gemini/gemini-cli/discussions/22970).

## Antigravity CLI: что измерено

Новый Мак, `agy` 1.5.2, вход в аккаунт Google выполнен.

- Неинтерактивный режим: `-p`, `--output-format json|stream-json`, `--json-schema` (корень —
  `"type": "object"`), `--model`, `--effort`, `--sandbox`, `--disable-slash-commands`,
  `--print-timeout`, `--input-format stream-json`.
- Ответ `json`: `status`, `response`, `structured_output`, `conversation_id`, `num_turns`,
  `duration_seconds`, `usage` (входные, выходные, кэш, размышления), `finished_reason` при обрыве,
  `denied_actions`. Коды выхода по changelog: 1 — неверная схема или агент, 2 — ошибка вызова,
  3 — сбой хода и строка `AGY_ERROR: {...}` в stderr.
- Модели по подписке (`agy models`): `gemini-4-argon-{low,medium,high}`,
  `gemini-3.8-flash-{low,medium,high}`; в другой группе квоты — Claude Opus/Sonnet 5.5, GPT-OSS 120B.
  Специальной модели расшифровки `gemini-3.5-transcribe` под подпиской нет.
- Квота без траты квоты: `agy -p "/usage" --output-format json` — группы «Gemini Models» и
  «Claude and GPT models», окна неделя и 5 часов, `remaining_fraction`, `reset_time` (UTC).
  Расход пропорционален цене токенов. `/credits` — платные AI-кредиты (у владельца 0,
  `useG1Credits: false`). Мерить расход короткой пробы по `/usage` нельзя: окно скользящее,
  и за минуту остаток вырос.
- Аудио: `@файл` в режиме `-p` вложение не прикрепляет. Агент сам вызывает `read_file`, и файл
  уходит модели как медиа (m4a помечается `video/mp4`, модель его всё равно слышит). По changelog
  принимаются wav, mp3, m4a, aac, flac, opus, ogg; файлы больше 100 МБ отвергаются.
- Проба: синтетическая запись 11 секунд (`say -v Milena`, AAC 22 кГц), `gemini-3.8-flash-low`,
  JSON-схема. 9 секунд, 3 обращения к модели, 24 827 входных токенов (около 8 тысяч на обращение —
  системный промпт агента), 351 выходной. Заголовок, описание и задачи верные; в расшифровке
  «Джемини» → «Джимини», «на три часа дня» → «на 3:00 дня», «Не забыть» → «Не забудь» —
  общая модель пересказывает.
- Следы: каждый запуск оставляет разговор — `~/.gemini/antigravity-cli/conversations/<id>.db` и
  `brain/<id>/` с полным журналом и копией вложений (`.system_generated/logs/media/`).

## Gemini API

Документация переехала на https://aistudio.google.com/docs (оглавление — `/llms.txt`).

- `gemini-3.5-transcribe` — модель расшифровки, GA с 26 августа 2026: до часа аудио за запрос,
  до 30 минут с говорящими или таймкодами слов, до восьми говорящих, `ru-RU` в списке.
  Около $0,005 за минуту по оценке Google ($2 за 1M аудиотокенов, $12 за 1M выходных).
- `gemini-3.8-flash` — 1M токенов на вход, 65 536 на выход; $0,75 / $3,75 за 1M до 31 декабря 2026,
  с 1 января 2027 — $1,50 / $7,50. `gemini-3.5-flash-lite` — $0,30 / $2,50. `gemini-4-argon` —
  только платный уровень.
- Аудио: 32 токена в секунду; среди форматов есть `audio/m4a` и `audio/aac`; встроенный запрос
  до 100 МБ; Files API — до 2 ГБ, хранение 48 часов.
- Строгий JSON: `responseMimeType: "application/json"` плюс `responseJsonSchema`.
- OpenAI-совместимый адрес: `https://generativelanguage.googleapis.com/v1beta/openai/`, помечен
  как бета; `input_audio` в примерах только `wav`.
- Час записи: расшифровка ≈ $0,31 плюс итог на 3.8 Flash ≈ $0,03 — около $0,34.
- Условия, https://aistudio.google.com/docs/terms: бесплатный уровень — «Google uses the content you
  submit … to provide, improve, and develop Google products», «human reviewers may read, annotate,
  and process your API input and output»; платный — «Google doesn't use your prompts … or responses
  to improve our products». Платный — только через проект с активным платёжным аккаунтом.
- Журналы проекта: для проектов, созданных после 26 октября 2026, `generateContent` пишется
  в журнал по умолчанию, до 55 дней (https://aistudio.google.com/docs/logs-policy).
- Кредиты Developer Program: https://developers.google.com/program/plans-and-pricing.
  Предоплата и порядок списания: https://aistudio.google.com/docs/billing.

## Регион

России нет в списках доступности Gemini API, Antigravity, Google AI Pro и Developer Program.
API смотрит, откуда пришёл запрос: с iPhone он отвечает «User location is not supported for the
API use», поэтому приложение ходит через `ui/api-proxy.mjs` на Маке. Оба Мака выходят в сеть
из Нидерландов.

## Шлюз: замеры

Проверено 9 ноября 2026 на этом Маке: Node.js 22+, **Antigravity CLI 1.5.3**,
`gemini-3.8-flash-low`, настоящий HOME с уже выполненным входом. Шлюз слушал только
`127.0.0.1` на свободном порту; токен был во временном файле с правами 0600 и после проверки
удалён. **Во всех живых запусках `LORI_AGY_CLEANUP=0`**: чистку истории владельца не запускали,
в его SQLite не писали. Развёртывание, туннель и iOS-клиент не менялись.

### Запросы и результат

| Проверка | Результат | Время | Вход / выход, токены | conversation_id |
| --- | --- | --- | --- | --- |
| `GET /v1/health` | 200, версия `1.5.3` закеширована при старте | — | 0 / 0 | разговора нет |
| `GET /v1/usage` после исправления разбора | 200, две группы, недельное и пятичасовое окна | 3,243 с | 0 / 0 | разговора нет |
| `annotate` короткого русского текста | `done`, заголовок «Выпуск Лори и проверка качества», заполнены описание и итог | 5,482 с | 8 966 / 170 | `19e94032-c927-4ebe-b044-9dc688414ba0` |
| `transcribe` синтетической записи | `done`, один сегмент S1, `start: "00:00"` | 8,182 с | 18 152 / 145 | `46fad77c-91e4-496a-b9fd-01fce450a55c` |

Время задач — от начала выполнения в очереди до разбора и удаления временной рабочей папки;
в `/usage` — полное время HTTP-запроса. Остаток квоты не использовали для оценки цены этих
проб: окна скользящие. На модель ушло два запуска всего: один `annotate` и один `transcribe`.
Всего было восемь запусков CLI, включая `--help`, два `--version` и три `/usage`;
первоначальный общий лимит пять координатор расширил до девяти для исправления разбора.

Для аудио использованы `say -v Milena -r 160` и `afconvert -f m4af -d aac`: AAC mono,
22 050 Гц, **11,641 с**, файл **52 637 байт**. Произнесено:

> Сегодня мы обсуждали выпуск Лори. Анна проверит качество записи завтра утром. Встреча с
> командой назначена на пятницу, на три часа дня. Вопрос о новом словаре пока открыт.

Результат:

> Сегодня мы обсуждали выпуск Лори. Анна проверит качество записи завтра утром. Встреча с
> командой назначена на пятницу, на 3:00 дня. Вопрос о новом словаре пока открыт.

Имена и слова сохранены; «три часа» нормализовано в «3:00». Даже с указанием «дословно» общая
модель не гарантирует буквальной расшифровки. `start` — оценка модели от начала присланной
части, а не принудительное выравнивание по аудио.

### Протокол и ограничения инструментов

- `annotate` передавала всё задание и текст через одно сообщение stdin:
  `--input-format stream-json --output-format stream-json`, `event: "user"`.
  Конечное событие `result` с `--json-schema` содержит объект `structured_output`: шлюз
  принимает только его, и успешный `done` это подтвердил. Запасной `-p` для текста не понадобился;
  длинная расшифровка не оказывается в аргументах процесса.
- `transcribe` использовала `-p`, `--output-format json`, JSON-схему и явную просьбу прочитать
  `part.m4a` инструментом `read_file`. Чтение и передача аудио модели работают с `--sandbox` и
  `permissions.deny` для `command(*)`, `write_file(*)`, `read_url(*)`, `execute_url(*)`, `mcp(*)`.
  Оба модельных запуска приняли `--settings` с этими правилами и `useG1Credits: false`.
- Дополнительно переопределяются `allowNonWorkspaceAccess: false`, `toolPermission: "request-review"`
  и пустые `permissions.allow/ask`, чтобы шлюз не наследовал более широкие личные разрешения.
  Состояние и `settings.json` владельца не редактируются: это настройки только дочернего процесса.
- `/usage` идёт в той же FIFO-очереди, но без `--disable-slash-commands` и без схемы: это
  встроенная команда CLI, а не задача модели. Применение этого флага отправило бы `/usage` модели.

### Конверт `/usage`

Реальная 1.5.3 возвращает тот же путь `command.data.groups[].buckets[]`, который был у 1.5.2.
Ключи конверта (без значений):

```text
conversation_id
status
response
duration_seconds
num_turns
usage
  input_tokens
  output_tokens
  thinking_tokens
  cache_read_tokens
  total_tokens
command
  name
  data
    description
    groups[]
      name
      description
      buckets[]
        id
        name
        description
        window
        remaining_fraction
        reset_time
```

`response` здесь содержит человекочитаемые TSV-строки, а не сериализованный объект квоты.
Первая проба шлюза ошибочно ожидала прямой `groups` и ответила 502 за 3,417 с; после чтения
сырого ответа только `/usage` парсер исправлен. Поддерживаются `command.data`, прямой payload
и `structured_output`; наружу выходят только `groups`, `name`, `buckets`, `id`, `window`,
`remainingFraction`, `resetTime`. Совместимость этих конвертов покрыта подставным CLI.

### Следы и проверка чистки

Обе headless-задачи **добавили по одной строке** с указанным `conversation_id` в
`conversation_summaries.db → conversation_summaries`; в `conversations_fts` для них было
ноль строк. Созданы также `conversations/<id>.db`, `brain/<id>/` и привязки рабочей папки в
`cache/last_conversations.json`; в `cache/conversation_metadata.json` этих UUID нет.
Всё это оставлено в истории владельца по условиям проверки.

Системный `sqlite3 -readonly` сразу после задач дважды сообщил `unable to open database file`.
Повторное чтение системным CLI и чтение Python SQLite подтвердили счётчики выше; результат
модели восстановлен только чтением журналов **этих двух синтетических разговоров**.
Новых запусков модели ради сборщика замеров не делали. В рабочем коде sqlite3 не загружает
личный `.sqliterc` и имеет ограниченные повторы при временной недоступности/блокировке БД;
это не проверка удаления против настоящей истории.

При `LORI_AGY_CLEANUP=1` шлюз удаляет только новый UUID из ответа/init или из привязки
**своей уникальной рабочей папки** в кеше, никогда просто все новые файлы в HOME. Идентификаторы
проверяются, существовавшие до запуска разговоры исключаются, символические ссылки в путях
чистки отвергаются. В SQLite удаляются только строки этого UUID из двух названных таблиц;
кеш переписывается с сохранением остальных записей. Ошибка чистки возвращается как `agent`,
а не скрывается за успешным результатом.

Подставной `agy` в изолированных временных HOME проверяет файлы, SQLite/FTS, кеш, чужой
разговор, появившийся одновременно чужой разговор, отмену без JSON-envelope и отключённую
чистку. Тесты также проверяют последовательность задач вместе с `/usage`, идемпотентность,
убийство всей группы процессов при отмене/таймауте, границы загрузок и срок хранения результата.
Чистка против реальной истории владельца намеренно не проверялась.
