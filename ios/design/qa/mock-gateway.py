#!/usr/bin/env python3
"""Local gateway fixture. Never sends transcripts to a provider or logs them.

python3 design/qa/mock-gateway.py --port 18891
Fixture token: fixture-gateway (synthetic, not a personal credential).
СБОЙ → agent; КВОТА → quota; ЗАДЕРЖКА → 20 running polls.
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4

jobs = {}
keys = {}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, value, status=200):
        body = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def allowed(self):
        if self.headers.get("Authorization") == "Bearer fixture-gateway":
            return True
        print(f"fixture auth rejected: header length {len(self.headers.get('Authorization', ''))}", flush=True)
        self.reply({"error": {"code": "auth", "message": "fixture"}}, 401)
        return False

    def do_GET(self):
        if not self.allowed():
            return
        path = self.path.removeprefix("/gateway")
        if path == "/v1/health":
            return self.reply({"ok": True})
        if path == "/v1/usage":
            return self.reply({"groups": [{"name": "Gemini Models", "buckets": [
                {"id": "week", "window": "week", "remainingFraction": 0.96, "resetTime": None},
                {"id": "five-hour", "window": "5h", "remainingFraction": 0.98, "resetTime": None}]}]})
        with lock:
            job = jobs.get(path.rsplit("/", 1)[-1])
            if job:
                if job["state"] not in ["failed", "cancelled", "done"]:
                    job["polls"] -= 1
                    job["state"] = "running" if job["polls"] > 0 else "done"
                return self.reply(job)
        self.reply({"error": {"code": "missing"}}, 404)

    def do_POST(self):
        if not self.allowed():
            return
        if self.path.removeprefix("/gateway") != "/v1/jobs":
            return self.reply({"error": {"code": "missing"}}, 404)
        try:
            payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            text = payload["transcript"]
            kind = payload["kind"]
            assert kind in ["annotate", "report"] and isinstance(text, str) and text.strip()
        except (ValueError, KeyError, AssertionError):
            return self.reply({"error": {"code": "invalid"}}, 400)
        key = (kind, payload.get("key"))
        with lock:
            previous = jobs.get(keys.get(key)) if key[1] else None
            if previous and previous["state"] not in ["failed", "cancelled"]:
                return self.reply({"id": previous["id"], "state": previous["state"]}, 202)
            job_id = str(uuid4())
            job = {"id": job_id, "state": "queued", "polls": 20 if "ЗАДЕРЖКА" in text else 2}
            if "СБОЙ" in text or "КВОТА" in text:
                job.update(state="failed", error={"code": "quota" if "КВОТА" in text else "agent", "retryAfter": 120})
            elif kind == "annotate":
                job["result"] = {"title": "Проверка подписки Gemini", "description": "Обсудили выпуск и проверку качества.",
                    "summary": {"brief": "Анна проверит качество записи завтра.", "highlights": ["Проверка записи"],
                                "decisions": [], "tasks": ["Анна — проверить качество завтра"], "openQuestions": ["Как дополнить словарь?"]}}
            else:
                job["result"] = {"markdown": "# Отчёт по записи\n\n## Суть\n\nОбсудили выпуск Лори.\n\n## Задачи\n\n- Анна проверит качество завтра.\n\n## Открытые вопросы\n\nКак дополнить словарь?"}
            jobs[job_id] = job
            keys[key] = job_id
        self.reply({"id": job_id, "state": job["state"]}, 202)

    def do_DELETE(self):
        if not self.allowed():
            return
        with lock:
            job = jobs.get(self.path.rsplit("/", 1)[-1])
            if job:
                job["state"] = "cancelled"
                return self.reply(job)
        self.reply({"error": {"code": "missing"}}, 404)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18891)
    args = parser.parse_args()
    print(f"mock gateway on 127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
