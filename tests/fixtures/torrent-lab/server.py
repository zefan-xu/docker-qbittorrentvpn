#!/usr/bin/env python3
import json
import os
import re
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, unquote, urlparse

DATA_DIR = os.environ.get("DATA_DIR", "/data")
LOG_DIR = os.environ.get("LOG_DIR", "/logs")
PORT = int(os.environ.get("PORT", "8080"))
THROTTLE_BPS = int(os.environ.get("THROTTLE_BPS", "0"))
LOG_PATH = os.path.join(LOG_DIR, "torrent-lab.log")
PAUSE_PATH = os.path.join(LOG_DIR, "paused")
TRACKER_PEERS = {}
TRACKER_LOCK = threading.Lock()
TRACKER_TTL_SECONDS = 1800
os.makedirs(DATA_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)


def write_event(event):
    event["ts"] = time.time()
    line = json.dumps(event, sort_keys=True)
    with open(LOG_PATH, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    print(line, flush=True)


def safe_join(root, request_path):
    relative = unquote(request_path).lstrip("/")
    full = os.path.abspath(os.path.join(root, relative))
    root_abs = os.path.abspath(root)
    if full != root_abs and not full.startswith(root_abs + os.sep):
        raise ValueError("path escapes data dir")
    return full


def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode("ascii") + b"e"
    if isinstance(value, bytes):
        return str(len(value)).encode("ascii") + b":" + value
    if isinstance(value, str):
        return bencode(value.encode("utf-8"))
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        out = b"d"
        for key in sorted(value):
            out += bencode(key)
            out += bencode(value[key])
        return out + b"e"
    raise TypeError(type(value))


def tracker_params(query):
    params = {}
    for key, value in parse_qsl(query, keep_blank_values=True, encoding="latin-1"):
        params[key] = value
    return params


class LabHandler(BaseHTTPRequestHandler):
    server_version = "qbtvpn-torrent-lab/1"

    def log_message(self, _fmt, *_args):
        return

    def send_text(self, status, body, content_type="text/plain"):
        payload = body.encode("utf-8")
        self.send_bytes(status, payload, content_type)

    def send_bytes(self, status, payload, content_type="application/octet-stream"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/control/pause":
            open(PAUSE_PATH, "w", encoding="utf-8").close()
            write_event({"type": "control", "action": "pause", "client_ip": self.client_address[0]})
            self.send_text(200, "paused\n")
            return
        if path == "/control/resume":
            try:
                os.unlink(PAUSE_PATH)
            except FileNotFoundError:
                pass
            write_event({"type": "control", "action": "resume", "client_ip": self.client_address[0]})
            self.send_text(200, "resumed\n")
            return
        if path == "/reset":
            open(LOG_PATH, "w", encoding="utf-8").close()
            self.send_text(200, "reset\n")
            return
        self.send_text(404, "not found\n")

    def do_HEAD(self):
        self.serve_path(send_body=False)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.send_text(200, "ok\n")
            return
        if parsed.path == "/announce":
            self.serve_announce(parsed)
            return
        if parsed.path == "/requests":
            try:
                with open(LOG_PATH, "r", encoding="utf-8") as fh:
                    body = fh.read()
            except FileNotFoundError:
                body = ""
            self.send_text(200, body, "application/x-ndjson")
            return
        self.serve_path(send_body=True)

    def serve_announce(self, parsed):
        params = tracker_params(parsed.query)
        info_hash = params.get("info_hash", "").encode("latin-1")
        peer_id = params.get("peer_id", "").encode("latin-1")
        event = params.get("event", "")
        try:
            port = int(params.get("port", "0"))
            left = int(params.get("left", "0") or "0")
        except ValueError:
            self.send_text(400, "invalid announce\n")
            return
        if len(info_hash) != 20 or not peer_id or port <= 0:
            self.send_text(400, "invalid announce\n")
            return

        now = time.time()
        client_ip = self.client_address[0]
        peer_key = (peer_id, client_ip, port)
        with TRACKER_LOCK:
            peers = TRACKER_PEERS.setdefault(info_hash, {})
            for key, peer in list(peers.items()):
                if now - peer["updated"] > TRACKER_TTL_SECONDS:
                    peers.pop(key, None)
            if event == "stopped":
                peers.pop(peer_key, None)
            else:
                peers[peer_key] = {
                    "ip": client_ip,
                    "port": port,
                    "left": left,
                    "updated": now,
                }
            compact_peers = b""
            peers_returned = 0
            complete = 0
            incomplete = 0
            for key, peer in peers.items():
                if peer["left"] == 0:
                    complete += 1
                else:
                    incomplete += 1
                if key == peer_key:
                    continue
                try:
                    compact_peers += socket.inet_aton(peer["ip"]) + struct.pack("!H", peer["port"])
                    peers_returned += 1
                except OSError:
                    continue

        write_event({
            "type": "announce",
            "info_hash": info_hash.hex(),
            "event": event,
            "client_ip": client_ip,
            "port": port,
            "left": left,
            "complete": complete,
            "incomplete": incomplete,
            "peers_returned": peers_returned,
        })
        body = bencode({
            "interval": 5,
            "min interval": 2,
            "complete": complete,
            "incomplete": incomplete,
            "peers": compact_peers,
        })
        self.send_bytes(200, body, "text/plain")

    def serve_path(self, send_body=True):
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/files/"):
            self.send_text(404, "not found\n")
            return
        if os.path.exists(PAUSE_PATH):
            write_event({
                "type": "file",
                "status": 503,
                "path": parsed.path,
                "range": self.headers.get("Range", ""),
                "client_ip": self.client_address[0],
            })
            self.send_text(503, "paused\n")
            return
        try:
            full = safe_join(DATA_DIR, parsed.path[len("/files/"):])
        except ValueError:
            self.send_text(400, "bad path\n")
            return
        if not os.path.isfile(full):
            self.send_text(404, "not found\n")
            return

        size = os.path.getsize(full)
        start = 0
        end = size - 1
        status = 200
        range_header = self.headers.get("Range", "")
        if range_header:
            match = re.match(r"bytes=(\d*)-(\d*)$", range_header)
            if match:
                if match.group(1):
                    start = int(match.group(1))
                if match.group(2):
                    end = int(match.group(2))
                end = min(end, size - 1)
                status = 206
        if start > end or start >= size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return

        length = end - start + 1
        write_event({
            "type": "file",
            "status": status,
            "path": parsed.path,
            "range": range_header,
            "client_ip": self.client_address[0],
            "bytes": length,
        })
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if not send_body:
            return
        with open(full, "rb") as fh:
            fh.seek(start)
            remaining = length
            while remaining > 0:
                chunk = fh.read(min(65536, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)
                if THROTTLE_BPS > 0:
                    time.sleep(len(chunk) / THROTTLE_BPS)


def main():
    open(LOG_PATH, "a", encoding="utf-8").close()
    write_event({"type": "startup", "data_dir": DATA_DIR, "port": PORT})
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), LabHandler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
