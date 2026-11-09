# Lori

Личный «второй мозг» для надиктовок: голос → локальная расшифровка → заметка в Obsidian → итог по запросу.

Расшифровка идёт на своей машине через [GigaAM](https://github.com/salute-developers/GigaAM). Наружу
(в OpenAI) уходит только текст расшифровки и только после явного нажатия «сделать итог».

## Состав

| Часть | Что делает |
| --- | --- |
| `lori/ingest.py` | launchd-агент: ждёт аудио в inbox хранилища, дозагружает из iCloud, зовёт транскрайбер GigaAM, кладёт заметку в vault и убирает исходник |
| `ui/server.mjs` + `ui/web/` | локальный HTTP-мост на `:4173`: загрузка файлов, очередь задач, библиотека расшифровок, папки, экспорт в PDF, шаринг, живые события по SSE; вход по паролю или токену |
| `ios/` | нативное SwiftUI-приложение `LoriLocal` — транскрибатор для iPhone: запись и импорт аудио, расшифровка локально (GigaAM v3 на ONNX Runtime — модель ставится одной кнопкой, движок Apple) или через API (OpenAI, Gemini), свой словарь имён и терминов, ключи в Keychain. Подробности — в [ios/README.md](ios/README.md) |
| `ui/agy-gateway.mjs` | шлюз подписки Gemini: очередь расшифровок, итогов и отчётов через официальный Antigravity CLI, с токеном и чисткой следов |
| `ui/api-proxy.mjs` | прокси к API моделей через этот компьютер: нужен, когда сервис отказывает по региону телефона, а с машины работает |
| `launchd/` | plist'ы агентов (мост, ingest, туннель, прокси). Пути в них машинно-специфичные — правь под себя |
| `test/` | тесты моста на `node:test` |
| `design/` | заметки по референсам интерфейса |

## Требования

- macOS, Node.js 22+, Python 3.12+
- [GigaAM](https://github.com/salute-developers/GigaAM) с готовым venv — путь задаётся `LORI_GIGAAM_ROOT`
- хранилище Obsidian — путь задаётся `LORI_VAULT`
- LibreOffice (`soffice`) — только для экспорта в PDF

## Запуск

```bash
# токен доступа к мосту
mkdir -p ~/.config/lori && printf '%s' "$(openssl rand -hex 16)" > ~/.config/lori/token

# ключ OpenAI для итогов (файл не коммитится)
echo 'OPENAI_API_KEY=sk-...' > .env.local

./start.sh
```

Мост поднимется на `http://127.0.0.1:4173/`. Тесты:

```bash
node --test test/*.test.mjs
```

## Прокси к API моделей

Google отвечает `User location is not supported for the API use` по региону запроса: с этого
компьютера ключ работает, с телефона — нет. Вместо возни с профилями VPN на iPhone запросы
приложения пускаются через машину:

```bash
node ui/api-proxy.mjs                                            # Gemini на :8788
LORI_PROXY_TARGET=api.openai.com LORI_PROXY_PORT=8789 node ui/api-proxy.mjs
```

При старте он печатает адрес для приложения — его и вписывают в настройках Lori
(«Google Gemini API» → «Адрес API»). Ключ через прокси не хранится и не подставляется:
его присылает сам телефон. Слушает только локальную сеть; наружу выставлять не нужно.
Постоянный запуск — `launchd/com.lori.api-proxy.plist.example`.

## Шлюз подписки Gemini

`ui/agy-gateway.mjs` выполняет расшифровку аудио (`transcribe`), заголовок, описание и итог
(`annotate`), развёрнутый отчёт (`report`) через официальный Antigravity CLI по подписке
владельца. Нужны Node.js 22+, установленный `agy` с выполненным входом и `/usr/bin/sqlite3`
для адресной чистки истории. Задачи идут по одной, FIFO, до 20 ожидающих. Этот этап не меняет iOS-клиент.

Условия Antigravity не поддерживают обёртку CLI в приложения; риск принят владельцем — [подробности и замеры](docs/gemini-subscription.md).

```bash
# Отдельный HOME означает отдельный вход и отдельную историю agy.
mkdir -p ~/Services/lori-gateway/agy-home
# Вход на Mac mini (на другой машине поправь абсолютные пути).
HOME=/Users/ilyaqa/Services/lori-gateway/agy-home /Users/ilyaqa/.local/bin/agy

# Токен хранится отдельно от состояния agy, минимум 32 знака.
umask 077
mkdir -p ~/.config/lori
openssl rand -hex 32 > ~/.config/lori/gateway-token

LORI_AGY_HOME=~/Services/lori-gateway/agy-home node ui/agy-gateway.mjs
```

При явно заданном отдельном `LORI_AGY_HOME` шлюз при старте сохраняет свою политику инструментов
в его `settings.json`: остальные настройки остаются, файл заменяется атомарно с правами 0600.
Так запреты действуют и в последующих сеансах этого профиля без шлюза. Повреждённый JSON
останавливает запуск, исходный файл сохраняется. При настоящем HOME владельца шлюз ничего
в настройки не пишет.

По умолчанию шлюз доступен на `http://127.0.0.1:18890`. Каждый путь требует
`Authorization: Bearer <токен>`. После 20 неверных токенов за минуту весь шлюз отвечает 429
в течение минуты: за SSH-туннелем невозможно различить клиентов по IP.
Пример для постоянного запуска — [launchd/com.lori.agy-gateway.plist.example](launchd/com.lori.agy-gateway.plist.example).
Развёртывание и SSH-туннель на VPS на этом этапе не настраиваются.

| Переменная | По умолчанию / назначение |
| --- | --- |
| `LORI_GATEWAY_HOST`, `LORI_GATEWAY_PORT` | `127.0.0.1`, `18890` |
| `LORI_GATEWAY_TOKEN_FILE` | `~/.config/lori/gateway-token`; без файла или с коротким токеном шлюз не стартует |
| `LORI_AGY_BIN` | первый существующий `~/.local/bin/agy`, `~/Documents/Developer/bin/agy`, иначе `agy` из PATH |
| `LORI_AGY_HOME` | настоящий HOME; рекомендуется отдельная папка с собственным входом |
| `LORI_GATEWAY_MODEL` | `gemini-3.8-flash-low` для расшифровки и итога |
| `LORI_GATEWAY_REPORT_MODEL` | та же модель для отчёта |
| `LORI_GATEWAY_TRANSCRIBE_TIMEOUT_SECONDS` | `600` |
| `LORI_GATEWAY_ANNOTATE_TIMEOUT_SECONDS` | `300` |
| `LORI_GATEWAY_REPORT_TIMEOUT_SECONDS` | `600` |
| `LORI_GATEWAY_USAGE_TIMEOUT_SECONDS` | `30` |
| `LORI_GATEWAY_UPLOAD_TIMEOUT_SECONDS` | `600`; время приёма HTTP-запроса, включая загрузку аудио |
| `LORI_GATEWAY_RESULT_TTL_SECONDS` | `7200`; срок хранения завершённых задач в памяти, в тестах можно сократить |
| `LORI_AGY_CLEANUP` | `1`; удалять следы только своего разговора после каждого запуска, `0` — оставить для диагностики |

`GET /v1/health` возвращает путь и кешированную версию CLI; `GET /v1/usage` — остаток квоты
по группам и окнам без расхода подписки. Во время модельной задачи последний известный ответ
квоты возвращается сразу с `cachedAt` (ISO) и `stale: true`; если кеша ещё нет, запрос ждёт
в общей очереди. `POST /v1/jobs` принимает JSON
`{ "kind": "annotate", "key": "unique-key", "transcript": "…", "language": "ru" }`
(либо `kind: "report"`, необязателен `title`). Ответ — 202 с `id`, `kind`, `state`.
`GET /v1/jobs/:id` возвращает состояние и результат, `DELETE /v1/jobs/:id` отменяет задачу,
включая всю группу процессов CLI. Повтор с тем же `key` и видом возвращает прежнюю задачу,
пока она не завершилась ошибкой или отменой и не истёк срок хранения.

Для аудио: `POST /v1/jobs?kind=transcribe`, тело — исходные байты, типы:
`audio/mp4`, `audio/m4a`, `audio/x-m4a`, `audio/aac`, `audio/mpeg`, `audio/wav`, `audio/x-wav`,
`audio/flac`, `audio/ogg`, `audio/opus`, `audio/webm`. Заголовки: `X-Lori-Key`,
`X-Lori-Speakers: 1|0` (по умолчанию `0`), `X-Lori-Language`, `X-Lori-Vocabulary`
(термины через запятую, закодированные `encodeURIComponent`). JSON ограничен 4 МиБ,
расшифровка — 1 000 000 знаками, аудио — 95 МиБ. Времена сегментов приблизительны;
общая модель может менять формулировки даже при просьбе расшифровать дословно.

По умолчанию временная папка и локальные следы разговора удаляются после задачи, результат —
через два часа. Очередь и результаты не переживают перезапуск. Журнал содержит только размеры,
вид, длительность, токены, состояние и код ошибки; содержимое записи в него не пишется.
Аудио и текст при этом отправляются в Google; чистка локальной истории не удаляет их у сервиса.

## Переменные окружения

`LORI_VAULT`, `LORI_TRANSCRIPTS`, `LORI_LIBRARY`, `LORI_GIGAAM_ROOT`, `LORI_PORT`, `LORI_TOKEN_FILE`,
`LORI_PASSWORD_FILE`, `LORI_ENV_FILE`, `LORI_DEVICE`, `LORI_SOFFICE`, `LORI_MAX_UPLOAD_BYTES`,
`LORI_SUMMARY_MAX_CHARS`, `LORI_OPENAI_MODEL`, `LORI_OPENAI_API_BASE_URL`, `OPENAI_API_KEY`.

Значения по умолчанию рассчитаны на машину автора (`/Users/ilyaqa/...`) — на чужой машине задавай их явно.

## Приватность

- `.env.local`, токены, логи и рабочие артефакты в репозиторий не попадают — см. `.gitignore`.
- В Mac-конвейере аудио и расшифровки не покидают машину; в облако уходит только текст итога
  по явному запросу.
- В iOS-приложении это верно для локальных движков (GigaAM, Apple). Облачные движки — OpenAI
  и Gemini — по явному выбору человека отправляют сервису запись целиком; приложение говорит
  об этом прямо в настройках и не переключается на облако само.
