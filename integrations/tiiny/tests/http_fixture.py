"""Loopback-only Tiiny HTTP fixtures. No credentials or bodies are logged."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import struct
import threading
import time
import zlib


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\0\xff\0\0\xff")) + chunk(b"IEND", b"")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, data, status=200):
        data = data if isinstance(data, bytes) else json.dumps(data).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self.server.request_count += 1
        records = [
            {"model_id": "fixture-code", "name": "Fixture Code", "type": "Text Generation", "supported": ["Tool Use"], "context_window": 32768, "npu_usage": 47, "status": "running", "tags": [{"size": 100}]},
            {"model_id": "fixture-image", "name": "Fixture Image", "type": "Text-to-Image", "npu_usage": 23, "status": "running", "tags": [{"size": 100}]},
        ]
        self.reply({
            "/api/v1/models/online_models": records,
            "/api/v1/models/npu/status": {"npu_total": 100, "npu_used": 70, "models": [{"model_id": r["model_id"], "npu_usage": r["npu_usage"]} for r in records]},
            "/api/v1/sys/storage": {"total_bytes": 200000000000, "remaining_bytes": 100000000000},
        }.get(self.path, {}))

    def do_POST(self):
        self.server.request_count += 1
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        prompt = str(data.get("prompt", "")) + json.dumps(data.get("messages", []))
        if "http_timeout" in prompt:
            time.sleep(1)
        if "http_failure" in prompt:
            self.reply({"error": {"message": "fixture-secret-key"}}, 503)
        elif "malformed_response" in prompt:
            self.reply(b"not JSON")
        elif self.path == "/v1/images/generations":
            self.reply({"data": [{"b64_json": base64.b64encode(b"invalid" if "invalid_png" in prompt else png()).decode()}]})
        elif "Classify the user's Godot request" in prompt:
            self.reply({"choices": [{"message": {"role": "assistant", "content": "general"}}]})
        else:
            content = json.dumps({"points": [[0, 0], [32, 0], [32, 48], [0, 48]]}) if "ConvexPolygonShape2D" in prompt else "HTTP fixture OK"
            self.reply({"choices": [{"message": {"role": "assistant", "content": content}}]})


def start():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.request_count = 0
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server
