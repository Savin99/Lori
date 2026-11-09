#!/usr/bin/env python3
"""HTTP smoke tests for the local audio fixture; no personal credentials or audio."""
import importlib.util
import json
from pathlib import Path
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

spec = importlib.util.spec_from_file_location("mock_gateway", Path(__file__).with_name("mock-gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


class AudioGatewayFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = mock.ThreadingHTTPServer(("127.0.0.1", 0), mock.Handler)
        cls.server.transcribe_count = 0
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}/gateway"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        mock.jobs.clear()
        mock.keys.clear()
        self.server.transcribe_count = 0
        self.server.transcribe_error = None
        self.server.transcribe_fail_part = 0
        self.server.transcribe_delay = 2
        self.server.transcribe_delay_part = 0
        self.server.transcribe_fail_after_delay = False

    def request(self, path, method="GET", body=None, **headers):
        headers["Authorization"] = "Bearer fixture-gateway"
        request = Request(self.base + path, data=body, headers=headers, method=method)
        try:
            with urlopen(request, timeout=5) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            return error.code, json.load(error)

    def post(self, key="part1", speakers="1"):
        return self.request("/v1/jobs?kind=transcribe", method="POST", body=b"synthetic-audio", **{
            "Content-Type": "audio/wav", "X-Lori-Key": key, "X-Lori-Speakers": speakers,
            "X-Lori-Language": "ru", "X-Lori-Vocabulary": "%D0%9B%D0%BE%D1%80%D0%B8%2CC%2B%2B"})

    def test_modes_polling_and_idempotence(self):
        for speakers in ["0", "1"]:
            status, accepted = self.post(key=speakers, speakers=speakers)
            self.assertEqual(status, 202)
            self.assertEqual(self.post(key=speakers, speakers=speakers)[1]["id"], accepted["id"])
            path = "/v1/jobs/" + accepted["id"]
            self.assertEqual(self.request(path)[1]["state"], "running")
            done = self.request(path)[1]
            self.assertEqual(done["state"], "done")
            self.assertEqual(done["result"]["segments"][0]["speaker"], "S1" if speakers == "1" else None)
            self.assertEqual(done["result"]["segments"][0]["start"], "09:59")

    def test_controlled_errors_and_only_second_part(self):
        for code in ["quota", "timeout", "agent", "auth"]:
            self.setUp()
            self.server.transcribe_error = code
            self.server.transcribe_fail_part = 2
            first = self.post()[1]
            self.assertEqual(first["state"], "queued")
            status, second = self.post(key="part2")
            if code == "auth":
                self.assertEqual(status, 401)
                self.assertEqual(second["error"]["code"], code)
            else:
                failed = self.request("/v1/jobs/" + second["id"])[1]
                self.assertEqual(failed["state"], "failed")
                self.assertEqual(failed["error"]["code"], code)
                self.assertEqual(failed["error"]["retryAfter"], 120)

    def test_delay_and_cancel(self):
        self.server.transcribe_delay = 50
        accepted = self.post()[1]
        path = "/v1/jobs/" + accepted["id"]
        for _ in range(3):
            self.assertEqual(self.request(path)[1]["state"], "running")
        self.assertEqual(self.request(path, method="DELETE")[1]["state"], "cancelled")
        self.assertEqual(self.request(path)[1]["state"], "cancelled")

    def test_new_task_shape_and_delayed_second_part_failure_retry(self):
        _, accepted = self.request("/v1/jobs", method="POST", body=json.dumps({
            "kind": "annotate", "key": "note", "transcript": "План"}).encode(), **{"Content-Type": "application/json"})
        path = "/v1/jobs/" + accepted["id"]
        self.request(path)
        tasks = self.request(path)[1]["result"]["summary"]["tasks"]
        self.assertEqual(tasks, [{"text": "Проверить качество записи", "owner": "Анна", "due": "завтра"}])
        self.server.transcribe_delay = 3
        self.server.transcribe_delay_part = 2
        self.server.transcribe_error = "quota"
        self.server.transcribe_fail_part = 2
        self.server.transcribe_fail_after_delay = True
        first = self.post("first")[1]
        second = self.post("second")[1]
        path = "/v1/jobs/" + second["id"]
        self.assertEqual(self.request(path)[1]["state"], "running")
        self.assertEqual(self.request(path)[1]["state"], "running")
        self.assertEqual(self.request(path)[1]["state"], "failed")
        self.assertEqual(self.request(path)[1]["error"]["retryAfter"], 120)
        retried = self.post("second")[1]
        self.assertNotEqual(retried["id"], second["id"])
        self.assertEqual(self.request("/v1/jobs/" + retried["id"])[1]["state"], "running")
        self.assertEqual(self.request("/v1/jobs/" + retried["id"])[1]["state"], "done")
        self.assertEqual(self.post("first")[1]["id"], first["id"])

    def test_missing_key_and_invalid_speaker_are_rejected(self):
        status, _ = self.request("/v1/jobs?kind=transcribe", method="POST", body=b"synthetic", **{
            "Content-Type": "audio/wav", "X-Lori-Speakers": "2"})
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main()
