#!/usr/bin/env python3
"""Exercise the real CLI and protect its quality reports and holdout boundaries."""

import csv
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import sys
from threading import Thread
import time


root = Path(__file__).resolve().parents[2]
command = sys.argv[1:] or [str(root / "tools/benchmark-prediction")]


def run(*args):
    output = subprocess.check_output(command + list(args), cwd=root, text=True)
    rows = csv.DictReader(output.splitlines(), delimiter="\t")
    return {(row["mode"], row["group"]): row for row in rows}


baseline = run("--dictionary")["dictionary", "all"]
assert (baseline["cases"], baseline["shown"], baseline["wrong_shows"]) == ("38", "25", "13"), baseline
results = run("--pipeline")
original = results["pipeline", "all"]
assert (original["cases"], original["shown"], original["wrong_shows"], original["misses"]) == ("38", "25", "13", "12"), original
assert original["dictionary_shows"] == "25" and original["model_shows"] == "0", original
assert results["pipeline", "trigger:completion"]["cases"] == "18"
assert results["pipeline", "trigger:next-word"]["cases"] == "20"
right = results["pipeline-edges", "right-text"]
assert right["negative_cases"] == "2" and right["negative_shows"] == "0", right
assert results["pipeline-edges", "cancelled"]["interrupted"] == "1"
assert results["pipeline-edges", "alternatives"]["hit_%"] == "100.0"

history = results["pipeline-history", "personal-learn"]
empty = results["pipeline-empty", "personal-learn"]
assert history["history_shows"] == "1" and history["hit_%"] == "100.0", history
assert empty["history_shows"] == "0" and empty["hit_%"] == "0.0", empty
for group in ("personal-future", "personal-copy", "personal-document", "personal-duplicate"):
    row = results["pipeline-history", group]
    assert row["cases"] == "1" and row["history_shows"] == "0", row


class ModelServer(BaseHTTPRequestHandler):
    prompts = []
    infill_prompts = []

    def reply(self, content_type, payload):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        assert self.path == "/health", self.path
        self.reply("application/json", b'{"status":"ok"}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/infill":
            pair = (body["input_prefix"], body["input_suffix"])
            self.infill_prompts.append(pair)
            assert body["stream"] and body["grammar"] and body["n_predict"] == 12
            text = " детали" if pair == ("Давайте обсудим ", " завтра утром.") else ""
            event = {"stop": True, "stop_type": "eos", "content": text,
                     "completion_probabilities": [{"logprob": -0.1}]}
            self.reply("text/event-stream", ("data: " + json.dumps(event) + "\n\n").encode())
            return
        assert self.path == "/completion", self.path
        prompt = body["prompt"]
        self.prompts.append(prompt)
        assert body["stream"] and body["grammar"], body
        text = " Zoom" if prompt == "Сегодня встреча в" else ""
        score = -0.1
        if prompt == "Echo style":
            text, score = " qqrabit", -2.12
        if prompt == "Echo on xyzabc":
            text, score = " yes", -2.12
        if prompt == "Проверю в письме":
            time.sleep(0.25)
        event = {"stop": True, "stop_type": "eos", "content": text,
                 "completion_probabilities": [{"logprob": score}]}
        self.reply("text/event-stream", ("data: " + json.dumps(event) + "\n\n").encode())

    def log_message(self, *args):
        pass


with ThreadingHTTPServer(("127.0.0.1", 0), ModelServer) as server:
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        live = run("--pipeline", "--port", str(server.server_port))
        assert not ModelServer.infill_prompts
        infill = run("--pipeline", "--port", str(server.server_port),
                     "--infill", "Tests/PredictionEval/infill_traces.json")
        with TemporaryDirectory() as scratch:
            holdout = Path(scratch) / "holdout.json"
            holdout.write_text(json.dumps([
                {"id": "c", "group": "en-completion", "text": "Echo style qqr|abit."},
                {"id": "n", "group": "en-next", "text": "Echo on xyzabc |yes."},
            ]))
            thresholds = run("--tune-confidence", str(holdout), "--port", str(server.server_port))
    finally:
        server.shutdown()
        thread.join()

original = live["pipeline", "all"]
assert original["dictionary_shows"] == "25" and original["model_shows"] == "1", original
assert original["hit_%"] == "34.2", original
cancelled = live["pipeline-edges", "cancelled"]
assert (cancelled["interrupted"], cancelled["shown"], cancelled["errors"]) == ("2", "0", "0"), cancelled
assert "Проверю в письме" in ModelServer.prompts, ModelServer.prompts
assert "Сегодня встреча в" in ModelServer.prompts and "До сих" not in ModelServer.prompts, ModelServer.prompts
assert "Следом проверю" not in ModelServer.prompts, ModelServer.prompts
assert thresholds["confidence-holdout-baseline", "trigger:completion"]["hit_%"] == "100.0"
assert thresholds["confidence-holdout-high", "trigger:completion"]["shown"] == "0"
assert thresholds["confidence-holdout-low", "trigger:next-word"]["hit_%"] == "100.0"
assert thresholds["confidence-holdout-baseline", "trigger:next-word"]["shown"] == "0"
infill_result = infill["pipeline-infill", "all"]
assert (infill_result["cases"], infill_result["shown"], infill_result["hit_%"]) == ("20", "1", "5.0"), infill_result
assert ("Давайте обсудим ", " завтра утром.") in ModelServer.infill_prompts
assert all("опе" not in left and not right.startswith("/etc/") for left, right in ModelServer.infill_prompts)
assert infill_result["negative_shows"] == "0"
print("Prediction pipeline CLI, infill fencing, model fallback, cancellation and personal holdout checks passed")
