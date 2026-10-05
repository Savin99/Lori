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
