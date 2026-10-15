#!/usr/bin/env python3
"""Chrome native-messaging host for TerrierGPT Companion.

Chrome starts this process and speaks length-prefixed JSON on stdin/stdout.
The host writes the same handoff envelope the menu-bar app writes, asks the
extension for the front tab when the menu drops a request file, and serves
`browser-actions.json` when the extension asks for its catalog.

Nothing here opens a network connection. `open` is used only for
`terriergpt://companion` and `ctsrecipes://inbox`.
"""

import json
import os
import re
import struct
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

HOST_VERSION = 1
MAX_MESSAGE = 1024 * 1024
MAX_TEXT = 180_000
REQUEST_STALE_MS = 8000
ANSWER_CONTRACT = "terriergpt-answer"
SAFE_CONTRACT = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
FENCE = re.compile(r"```(?:json)?\s*([\s\S]*?)```", re.IGNORECASE)

write_lock = threading.Lock()
stop = threading.Event()


def support_dir():
    override = os.environ.get("TERRIERGPT_SUPPORT", "").strip()
    if override:
        return Path(override)
    return Path.home() / "Library" / "Application Support" / "TerrierGPTMenu"


def slug(name):
    return name.lower().replace(" ", "-")


def send(obj):
    raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    if len(raw) > MAX_MESSAGE:
        raw = json.dumps({"ok": False, "reason": "too-large"}).encode("utf-8")
    packet = struct.pack("<I", len(raw)) + raw
    with write_lock:
        sys.stdout.buffer.write(packet)
        sys.stdout.buffer.flush()


def read_message():
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        return None
    length = struct.unpack("<I", header)[0]
    if length > MAX_MESSAGE:
        sys.stderr.write("native host: message too large\n")
        return None
    body = sys.stdin.buffer.read(length)
    if len(body) < length:
        return None
    try:
        message = json.loads(body.decode("utf-8"))
    except json.JSONDecodeError:
        return {"op": "invalid"}
    return message if isinstance(message, dict) else {"op": "invalid"}


def stamp(now):
    return now.strftime("%Y-%m-%dT%H-%M-%SZ")


def iso(now):
    return now.strftime("%Y-%m-%dT%H:%M:%SZ")


def write_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")
    temporary = path.with_name("." + path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, raw)
    finally:
        os.close(fd)
    os.replace(temporary, path)
    return raw


def fenced_payload(text):
    found = None
    for match in FENCE.finditer(text or ""):
        try:
            obj = json.loads(match.group(1).strip())
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            contract = obj.get("contract")
            if isinstance(contract, str) and SAFE_CONTRACT.match(contract):
                found = obj
    return found


def fallback_payload(text, title):
    payload = {
        "answer": text,
        "contract": ANSWER_CONTRACT,
        "generated_by": "app-fallback",
        "version": 1,
    }
    if title:
        payload["title"] = title
    return payload


def envelope(text, title, url, now):
    payload = fenced_payload(text) or fallback_payload(text, title)
    contract = payload.get("contract") if isinstance(payload.get("contract"), str) else None
    if not contract or not SAFE_CONTRACT.match(contract):
        payload = fallback_payload(text, title)
        contract = ANSWER_CONTRACT
    source = {"agent": "terriergpt", "extracted_from": "chrome-companion"}
    if url:
        source["url"] = url[:2000]
    if title:
        source["title"] = title[:300]
    return {
        "contract": contract,
        "created_at": iso(now),
        "handoff": 1,
        "id": str(uuid.uuid4()).lower(),
        "payload": payload,
        "source": source,
        "text": text,
        "validation": {
            "issues": ["Written by the Chrome companion host."],
            "schema": None,
            "status": "unchecked",
        },
    }, contract


def launch(url):
    if not (url.startswith("terriergpt://companion?") or url == "ctsrecipes://inbox"):
        return False
    binary = os.environ.get("TERRIERGPT_OPEN_BIN", "/usr/bin/open")
    try:
        subprocess.run([binary, "-g", url], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except OSError:
        return False


def handle_handoff(message):
    reply_id = message.get("id")
    text = message.get("text") if isinstance(message.get("text"), str) else ""
    text = text.strip()
    if not text:
        send({"id": reply_id, "ok": False, "op": "handoff", "reason": "empty"})
        return
    truncated = len(text) > MAX_TEXT
    if truncated:
        text = text[:MAX_TEXT]
    title = message.get("title") if isinstance(message.get("title"), str) else ""
    title = " ".join(title.split())[:300]
    url = message.get("url") if isinstance(message.get("url"), str) else ""
    url = url.strip()[:2000]
    wake = message.get("wake") is True

    now = datetime.now(timezone.utc)
    body, contract = envelope(text, title, url, now)
    root = support_dir()
    handoffs = root / "handoffs"
    filename = "%s-%s.json" % (stamp(now), contract)
    path = handoffs / filename
    write_json(path, body)
    write_json(handoffs / "latest.json", body)

    inbox_path = None
    if wake:
        inbox = handoffs / "inbox"
        inbox.mkdir(parents=True, exist_ok=True)
        dropped = dict(body)
        dropped["hops"] = 0
        inbox_file = inbox / filename
        temporary = inbox / (".%s" % filename)
        write_json(temporary, dropped)
        os.replace(temporary, inbox_file)
        inbox_path = str(inbox_file)
        launch("ctsrecipes://inbox")

    kind = "1" if wake else "0"
    launch("terriergpt://companion?recipes=%s&title=%s" % (kind, quote(title[:120], safe="")))
    send({
        "contract": contract,
        "id": reply_id,
        "inbox": inbox_path,
        "ok": True,
        "op": "handoff",
        "path": str(path),
        "truncated": truncated,
    })


def handle_catalog(message):
    """Read the catalog CTS Recipes wrote. The prompt text is the reply, not a log."""
    reply_id = message.get("id")
    path = support_dir() / "browser-actions.json"
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        send({"id": reply_id, "ok": False, "op": "catalog", "reason": "no-catalog"})
        return
    if not isinstance(catalog, dict) or not isinstance(catalog.get("actions"), list):
        send({"id": reply_id, "ok": False, "op": "catalog", "reason": "no-catalog"})
        return
    send({"id": reply_id, "ok": True, "op": "catalog", "catalog": catalog})


def claim_request():
    directory = support_dir() / "browser-requests"
    source = directory / "request.json"
    if not source.is_file():
        return None
    try:
        message = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(message, dict):
        return None
    browser = os.environ.get("TERRIERGPT_BROWSER", "").strip()
    wanted = message.get("browser") if isinstance(message.get("browser"), str) else ""
    if browser and wanted and wanted != browser:
        return None
    age = message.get("at")
    now_ms = int(time.time() * 1000)
    if isinstance(age, (int, float)) and now_ms - int(age) > REQUEST_STALE_MS:
        source.unlink(missing_ok=True)
        return None
    claim = directory / ("request-%s.json" % os.getpid())
    try:
        os.replace(source, claim)
    except OSError:
        return None
    claim.unlink(missing_ok=True)
    return message


def write_response(message):
    reply_id = message.get("id")
    if not isinstance(reply_id, str) or not reply_id:
        return
    directory = support_dir() / "browser-requests"
    # The menu is waiting on this name. Keep the id to the characters we generate.
    if not re.match(r"^[A-Za-z0-9-]{8,80}$", reply_id):
        return
    write_json(directory / ("response-%s.json" % reply_id), message)


def beat():
    browser = os.environ.get("TERRIERGPT_BROWSER", "").strip() or "host"
    path = support_dir() / "native-host" / "alive" / slug(browser)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(os.getpid()), encoding="utf-8")


def forget_beat():
    browser = os.environ.get("TERRIERGPT_BROWSER", "").strip() or "host"
    path = support_dir() / "native-host" / "alive" / slug(browser)
    path.unlink(missing_ok=True)


def watch():
    while not stop.is_set():
        try:
            beat()
            message = claim_request()
            if message and message.get("op") == "read-page" and isinstance(message.get("id"), str):
                send({"id": message["id"], "op": "read-page"})
        except Exception as error:
            sys.stderr.write("native host watch: %s\n" % error)
        stop.wait(0.2)


def main():
    threading.Thread(target=watch, daemon=True).start()
    try:
        while True:
            message = read_message()
            if message is None:
                break
            op = message.get("op")
            if op == "handoff":
                handle_handoff(message)
            elif op == "read-page":
                write_response(message)
            elif op == "catalog":
                handle_catalog(message)
            elif op == "hello":
                send({"host": HOST_VERSION, "ok": True, "op": "hello"})
    finally:
        stop.set()
        forget_beat()


if __name__ == "__main__":
    main()
