#!/usr/bin/env python3
import json
import os
import socket
import socketserver
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOG_DIR = os.environ.get("LOG_DIR", "/logs")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "8080"))
DNS_PORT = int(os.environ.get("DNS_PORT", "53"))
os.makedirs(LOG_DIR, exist_ok=True)
LOG_PATH = os.path.join(LOG_DIR, "probe.log")


def default_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 1))
            return s.getsockname()[0]
    except OSError:
        return socket.gethostbyname(socket.gethostname())


DNS_A_RECORD = os.environ.get("DNS_A_RECORD", default_ip())


def write_event(event):
    event["ts"] = time.time()
    line = json.dumps(event, sort_keys=True)
    with open(LOG_PATH, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    print(line, flush=True)


class ProbeHandler(BaseHTTPRequestHandler):
    server_version = "qbtvpn-probe/1"

    def log_message(self, _fmt, *_args):
        return

    def _send_text(self, status, body, content_type="text/plain"):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/reset":
            open(LOG_PATH, "w", encoding="utf-8").close()
            self._send_text(200, "reset\n")
            return
        self._send_text(404, "not found\n")

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        if parsed.path == "/health":
            self._send_text(200, "ok\n")
            return
        if parsed.path == "/requests":
            try:
                with open(LOG_PATH, "r", encoding="utf-8") as fh:
                    body = fh.read()
            except FileNotFoundError:
                body = ""
            self._send_text(200, body, "application/x-ndjson")
            return
        if parsed.path == "/echo":
            request_id = qs.get("request_id", ["none"])[0]
            event = {
                "type": "http",
                "path": parsed.path,
                "request_id": request_id,
                "client_ip": self.client_address[0],
                "user_agent": self.headers.get("User-Agent", ""),
            }
            write_event(event)
            self._send_text(200, f"request_id={request_id} client_ip={self.client_address[0]}\n")
            return
        self._send_text(404, "not found\n")


def parse_qname(packet, offset=12):
    labels = []
    while True:
        length = packet[offset]
        offset += 1
        if length == 0:
            break
        labels.append(packet[offset:offset + length].decode("ascii", "ignore"))
        offset += length
    return ".".join(labels), offset


def dns_response(packet, addr):
    query_id = packet[:2]
    qname, q_end = parse_qname(packet)
    qtype, qclass = struct.unpack("!HH", packet[q_end:q_end + 4])
    question = packet[12:q_end + 4]
    flags = b"\x81\x80"
    qdcount = b"\x00\x01"
    ancount = b"\x00\x01" if qtype == 1 else b"\x00\x00"
    header = query_id + flags + qdcount + ancount + b"\x00\x00\x00\x00"
    answer = b""
    if qtype == 1:
        answer = (
            b"\xc0\x0c"
            + struct.pack("!HHI", 1, qclass, 30)
            + struct.pack("!H", 4)
            + socket.inet_aton(DNS_A_RECORD)
        )
    write_event({
        "type": "dns",
        "query": qname,
        "qtype": qtype,
        "client_ip": addr[0],
        "answer": DNS_A_RECORD if qtype == 1 else "",
    })
    return header + question + answer


class DnsHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        try:
            sock.sendto(dns_response(data, self.client_address), self.client_address)
        except Exception as exc:
            write_event({"type": "dns_error", "client_ip": self.client_address[0], "error": str(exc)})


def run_dns():
    with socketserver.ThreadingUDPServer(("0.0.0.0", DNS_PORT), DnsHandler) as server:
        server.serve_forever()


def main():
    open(LOG_PATH, "a", encoding="utf-8").close()
    write_event({"type": "startup", "dns_a_record": DNS_A_RECORD, "http_port": HTTP_PORT, "dns_port": DNS_PORT})
    threading.Thread(target=run_dns, daemon=True).start()
    httpd = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), ProbeHandler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
