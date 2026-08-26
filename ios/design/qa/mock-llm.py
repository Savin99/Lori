#!/usr/bin/env python3
"""Подставной сервер с API как у OpenAI — чтобы гонять Lori вживую без ключа и без оплаты.

Зачем: обработку расшифровки, память и поиск нельзя проверить на подставном
`ChatCompleting` из юнит-теста — там не участвуют ни сеть, ни разбор ответа,
ни настройки провайдера. Здесь участвует всё, кроме самой модели.

Запуск:

    python3 design/qa/mock-llm.py [порт]

В настройках приложения: адрес `http://127.0.0.1:8765/v1`, имя модели любое,
ключ любой непустой. Симулятор ходит в сеть хоста, поэтому 127.0.0.1 — это Mac.

Ответы выбираются по содержимому запроса, состояния сервер не держит:
это ровно то, что делает настоящий API.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765

# Обработка расшифровки: строгий JSON, как требует промпт DigestService.
DIGEST = {
    "title": "Оффер до пятницы",
    "theme": "Работа",
    "summary": "Разобрали двух кандидатов и договорились о сроке оффера.",
    "highlights": [
        "Первый кандидат сильнее в бэкенде",
        "Оффер нужен до пятницы, иначе кандидата перехватят",
    ],
    "decisions": ["Берём первого кандидата"],
    "tasks": ["Выкатить оффер до пятницы"],
    "tags": ["найм", "оффер"],
}


def text_message(text):
    return {"role": "assistant", "content": text}


def tool_message(name, arguments):
    return {
        "role": "assistant",
        "content": None,
        "tool_calls": [
            {
                "id": f"call_{name}",
                "type": "function",
                "function": {
                    "name": name,
                    "arguments": json.dumps(arguments, ensure_ascii=False),
                },
            }
        ],
    }


def reply_for(payload):
    messages = payload.get("messages", [])
    system = " ".join(
        m.get("content") or "" for m in messages if m.get("role") == "system"
    )

    # 1. Обработка расшифровки в «Важное».
    if "редактор личных заметок" in system:
        source = " ".join(m.get("content") or "" for m in messages if m.get("role") == "user")
        # Управляемые сбои: настоящая модель иногда отвечает прозой вместо JSON,
        # и приложение обязано это показать, а не сохранить мусор.
        if "СБОЙ" in source:
            return text_message("Извини, не могу структурировать этот текст.")
        # Модель охотно оборачивает JSON в ограждение — пусть подставная делает то же,
        # иначе разбор ответа проверяется в идеальных условиях.
        return text_message(
            "Готово:\n```json\n" + json.dumps(DIGEST, ensure_ascii=False) + "\n```"
        )

    # 2. Чат. Смотрим только текущий ход: результаты инструментов ПОСЛЕ последнего
    # сообщения человека. Иначе старый результат поиска из истории заставляет отвечать
    # текстом там, где нужен новый вызов инструмента — настоящая модель решает по ходу.
    last_user_index = max(
        (i for i, m in enumerate(messages) if m.get("role") == "user"), default=-1
    )
    turn = messages[last_user_index + 1 :]
    tool_results = [m for m in turn if m.get("role") == "tool"]
    last_user = messages[last_user_index].get("content") or "" if last_user_index >= 0 else ""

    # Цикл вызовов инструментов: проверяем, что приложение упирается в свой предел,
    # а не ходит по кругу бесконечно. Проверка стоит до разбора результатов —
    # иначе после первого же ответа инструмента ветка ниже отвечает текстом.
    if "ЦИКЛ" in last_user:
        return tool_message("search_notes", {"query": "оффер"})

    if tool_results:
        result = tool_results[-1].get("content") or ""
        if result.startswith("Запомнил:"):
            return text_message("Запомнил. Спрашивай — буду держать это в голове.")
        if "ничего не нашлось" in result:
            return text_message("В заметках про это ничего нет.")
        first_path = ""
        for line in result.split("\n"):
            if ".md" in line:
                first_path = line.strip().split(" ")[-1]
                break
        return text_message(
            f"Нашёл в заметках: {first_path}. Там про оффер до пятницы."
        )

    if "запомни" in last_user.lower():
        fact = last_user.split("запомни", 1)[-1].strip(" ,:—-") or "что-то важное"
        return tool_message("remember", {"fact": fact})

    if "память" in system.lower() and "интегра" in last_user.lower():
        return text_message("Да, это у меня в памяти.")

    return tool_message("search_notes", {"query": last_user})


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body):
        raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        # «Проверить подключение» дёргает /models.
        if self.path.endswith("/models"):
            self._send(
                200,
                {"object": "list", "data": [{"id": "mock-local", "object": "model"}]},
            )
        else:
            self._send(404, {"error": {"message": f"нет обработчика для {self.path}"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError as error:
            self._send(400, {"error": {"message": f"битый JSON: {error}"}})
            return

        if not self.headers.get("Authorization", "").startswith("Bearer "):
            self._send(401, {"error": {"message": "нет ключа"}})
            return
        if not self.path.endswith("/chat/completions"):
            self._send(404, {"error": {"message": f"нет обработчика для {self.path}"}})
            return

        # Управляемая ошибка провайдера: HTTP 500 должен доходить до человека текстом.
        body = json.dumps(payload, ensure_ascii=False)
        if "ПЯТЬСОТ" in body:
            self._send(500, {"error": {"message": "у провайдера всё сломалось"}})
            return

        sys.stderr.write(
            "запрос: model=%s, сообщений=%d, инструментов=%d\n"
            % (
                payload.get("model"),
                len(payload.get("messages", [])),
                len(payload.get("tools", [])),
            )
        )
        self._send(
            200,
            {
                "choices": [
                    {"index": 0, "message": reply_for(payload), "finish_reason": "stop"}
                ]
            },
        )


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write(f"подставная модель слушает http://127.0.0.1:{PORT}/v1\n")
    server.serve_forever()
