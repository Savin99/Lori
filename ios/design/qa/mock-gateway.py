#!/usr/bin/env python3
"""Local gateway fixture. Never sends transcripts to a provider or logs them.

python3 design/qa/mock-gateway.py --port 18891
Fixture token: fixture-gateway (synthetic, not a personal credential).
СБОЙ → agent; КВОТА → quota; ЗАДЕРЖКА → 20 running polls.
transcribe: raw audio, X-Lori-Key/Speakers/Language/Vocabulary; no audio is logged.
--transcribe-error auth|quota|timeout|agent, --transcribe-fail-part N,
--transcribe-delay N (number of running polls) control audio failures.
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4
from urllib.parse import urlsplit, parse_qs, unquote

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
                    job["state"] = "running" if job["polls"] > 0 else ("failed" if job.get("error") else "done")
                return self.reply(job)
        self.reply({"error": {"code": "missing"}}, 404)

    def do_POST(self):
        if not self.allowed():
            return
        url = urlsplit(self.path.removeprefix("/gateway"))
        if url.path != "/v1/jobs":
            return self.reply({"error": {"code": "missing"}}, 404)
        transcribe = parse_qs(url.query).get("kind") == ["transcribe"]
        try:
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if transcribe:
                assert body and self.headers.get("Content-Type", "").startswith("audio/")
                assert self.headers.get("X-Lori-Speakers") in ["0", "1"]
                assert self.headers.get("X-Lori-Key")
                payload = {"key": self.headers["X-Lori-Key"]}
                kind = "transcribe"
                text = unquote(self.headers.get("X-Lori-Vocabulary", ""))
            else:
                payload = json.loads(body)
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
            if transcribe:
                self.server.transcribe_count += 1
                delayed_part = getattr(self.server, "transcribe_delay_part", 0)
                job["polls"] = self.server.transcribe_delay if delayed_part in [0, self.server.transcribe_count] else 2
                failure = self.server.transcribe_error if self.server.transcribe_fail_part in [0, self.server.transcribe_count] else None
                if failure == "auth":
                    return self.reply({"error": {"code": "auth"}}, 401)
                if failure:
                    job.update(state="queued" if getattr(self.server, "transcribe_fail_after_delay", False) else "failed",
                               error={"code": failure, "retryAfter": 120})
                else:
                    speakers = self.headers.get("X-Lori-Speakers") == "1"
                    job["result"] = {"segments": [
                        {"speaker": "S1" if speakers else None, "start": "09:59", "text": "Сегодня обсуждали выпуск Лори."},
                        {"speaker": "S2" if speakers else None, "start": None, "text": "Анна проверит качество записи завтра."}]}
            elif "СБОЙ" in text or "КВОТА" in text:
                job.update(state="failed", error={"code": "quota" if "КВОТА" in text else "agent", "retryAfter": 120})
            elif kind == "annotate":
                job["result"] = {"title": "Проверка подписки Gemini", "description": "Обсудили выпуск и проверку качества.",
                    "summary": {"brief": "Анна проверит качество записи завтра.", "highlights": ["Проверка записи"],
                                "decisions": [], "tasks": [{"text": "Проверить качество записи", "owner": "Анна", "due": "завтра"}], "openQuestions": ["Как дополнить словарь?"]}}
            else:
                job["result"] = {"markdown": "# Отчёт по записи\n\n## Суть\n\nОбсудили выпуск Лори.\n\n## Задачи\n\n- Анна проверит качество завтра.\n  1. Записать проверку.\n    * Сохранить образец.\n\n## Открытые вопросы\n\nКак дополнить словарь?"}
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
    parser.add_argument("--transcribe-error", choices=["auth", "quota", "timeout", "agent"])
    parser.add_argument("--transcribe-fail-part", type=int, default=0, help="0: every part, N: only part N")
    parser.add_argument("--transcribe-delay", type=int, default=2, help="running polls before done")
    parser.add_argument("--transcribe-delay-part", type=int, default=0, help="0: all parts, N: only part N is slow")
    parser.add_argument("--transcribe-fail-after-delay", action="store_true", help="show listening before the controlled failure")
    args = parser.parse_args()
    print(f"mock gateway on 127.0.0.1:{args.port}", flush=True)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.transcribe_error = args.transcribe_error
    server.transcribe_fail_part = args.transcribe_fail_part
    server.transcribe_delay = args.transcribe_delay
    server.transcribe_count = 0
    server.transcribe_delay_part = args.transcribe_delay_part
    server.transcribe_fail_after_delay = args.transcribe_fail_after_delay
    server.serve_forever()
