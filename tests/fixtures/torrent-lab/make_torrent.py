#!/usr/bin/env python3
import argparse
import hashlib
import os
import time


def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, str):
        return bencode(value.encode())
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        out = b"d"
        for key in sorted(value):
            out += bencode(key)
            out += bencode(value[key])
        return out + b"e"
    raise TypeError(type(value))


def iter_file_chunks(path, chunk_size=1024 * 1024):
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(chunk_size)
            if not chunk:
                break
            yield chunk


def collect_files(source):
    if os.path.isfile(source):
        return [(os.path.basename(source), source)]
    files = []
    for root, _dirs, names in os.walk(source):
        for name in sorted(names):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, source)
            files.append((rel, full))
    return sorted(files)


def pieces_for(files, piece_length):
    pieces = []
    buf = b""
    for _rel, full in files:
        for chunk in iter_file_chunks(full):
            buf += chunk
            while len(buf) >= piece_length:
                pieces.append(hashlib.sha1(buf[:piece_length]).digest())
                buf = buf[piece_length:]
    if buf:
        pieces.append(hashlib.sha1(buf).digest())
    return b"".join(pieces)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--announce", default="http://127.0.0.1:9/announce")
    parser.add_argument("--webseed")
    parser.add_argument("--out", required=True)
    parser.add_argument("--hash-out", required=True)
    parser.add_argument("--piece-length", type=int, default=16384)
    args = parser.parse_args()

    files = collect_files(args.source)
    if not files:
        raise SystemExit("source has no files")

    info = {
        "name": args.name,
        "piece length": args.piece_length,
        "pieces": pieces_for(files, args.piece_length),
    }
    if len(files) == 1 and os.path.isfile(args.source):
        info["length"] = os.path.getsize(files[0][1])
    else:
        info["files"] = [
            {"length": os.path.getsize(full), "path": rel.split(os.sep)}
            for rel, full in files
        ]

    meta = {
        "announce": args.announce,
        "creation date": int(time.time()),
        "created by": "qbtvpn test fixture",
        "info": info,
    }
    if args.webseed:
        meta["url-list"] = args.webseed
    encoded_info = bencode(info)
    info_hash = hashlib.sha1(encoded_info).hexdigest()
    with open(args.out, "wb") as fh:
        fh.write(bencode(meta))
    with open(args.hash_out, "w", encoding="utf-8") as fh:
        fh.write(info_hash + "\n")
    print(info_hash)


if __name__ == "__main__":
    main()
