# Lori

Личный «второй мозг» для надиктовок: голос → локальная расшифровка → заметка в Obsidian → итог по запросу.

Расшифровка идёт на своей машине через [GigaAM](https://github.com/salute-developers/GigaAM). Наружу
(в OpenAI) уходит только текст расшифровки и только после явного нажатия «сделать итог».

## Состав

| Часть | Что делает |
| --- | --- |
| `lori/ingest.py` | launchd-агент: ждёт аудио в inbox хранилища, дозагружает из iCloud, зовёт транскрайбер GigaAM, кладёт заметку в vault и убирает исходник |
| `ui/server.mjs` + `ui/web/` | локальный HTTP-мост на `:4173`: загрузка файлов, очередь задач, библиотека расшифровок, папки, экспорт в PDF, шаринг, живые события по SSE; вход по паролю или токену |
| `ios/` | нативное SwiftUI-приложение `LoriLocal`: локальный воркспейс, диктовка, агент на DeepSeek с ключом в Keychain, вики и поиск по заметкам. Подробности — в [ios/README.md](ios/README.md) |
| `launchd/` | plist'ы агентов (мост, ingest, туннель). Пути в них машинно-специфичные — правь под себя |
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
node --test test/
```

## Переменные окружения

`LORI_VAULT`, `LORI_TRANSCRIPTS`, `LORI_LIBRARY`, `LORI_GIGAAM_ROOT`, `LORI_PORT`, `LORI_TOKEN_FILE`,
`LORI_PASSWORD_FILE`, `LORI_ENV_FILE`, `LORI_DEVICE`, `LORI_SOFFICE`, `LORI_MAX_UPLOAD_BYTES`,
`LORI_SUMMARY_MAX_CHARS`, `LORI_OPENAI_MODEL`, `LORI_OPENAI_API_BASE_URL`, `OPENAI_API_KEY`.

Значения по умолчанию рассчитаны на машину автора (`/Users/ilyaqa/...`) — на чужой машине задавай их явно.

## Приватность

- `.env.local`, токены, логи и рабочие артефакты в репозиторий не попадают — см. `.gitignore`.
- Аудио и расшифровки не покидают машину; в облако уходит только текст итога по явному запросу.
