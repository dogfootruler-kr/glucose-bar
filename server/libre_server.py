#!/usr/bin/env python3
"""Local bridge: polls the LibreLinkUp cloud (same data LibreView / Health2Sync see)
and serves the latest glucose reading at http://127.0.0.1:8765/glucose.

Config: ~/.config/freestyle-bar/config.json  {"email": "...", "password": "..."}
If "password" is omitted it is read from the macOS Keychain
(service "freestyle-bar", account = email).
Standard library only.
"""
import hashlib
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_PATH = os.path.expanduser("~/.config/freestyle-bar/config.json")
PORT = int(os.environ.get("FREESTYLE_BAR_PORT", "8765"))
POLL_SECONDS = 60
DEFAULT_BASE = "https://api.libreview.io"
TREND_ARROWS = {1: "↓", 2: "↘", 3: "→", 4: "↗", 5: "↑"}

state = {"reading": None, "history": [], "error": None, "updated": None}
lock = threading.Lock()


def log(msg):
    print(f"{datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


def load_config():
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    if not cfg.get("password"):
        cfg["password"] = subprocess.run(
            ["security", "find-generic-password", "-s", "freestyle-bar", "-a", cfg["email"], "-w"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    return cfg


class LibreLinkUp:
    def __init__(self, email, password, base=None, version="4.16.0"):
        self.email, self.password = email, password
        self.base = base or DEFAULT_BASE
        self.version = version
        self.token = None
        self.account_id = None

    def _headers(self):
        h = {
            "accept-encoding": "identity",
            "cache-control": "no-cache",
            "content-type": "application/json",
            "product": "llu.android",
            "version": self.version,
        }
        if self.token:
            h["authorization"] = f"Bearer {self.token}"
            h["account-id"] = self.account_id
        return h

    def _request(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=self._headers())
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.load(resp)

    def login(self):
        self.token = None
        res = self._request("POST", "/llu/auth/login", {"email": self.email, "password": self.password})
        data = res.get("data") or {}
        if data.get("redirect"):
            self.base = f"https://api-{data['region']}.libreview.io"
            log(f"region redirect -> {self.base}")
            res = self._request("POST", "/llu/auth/login", {"email": self.email, "password": self.password})
            data = res.get("data") or {}
        if res.get("status") == 920 or "minimumVersion" in json.dumps(res):
            raise RuntimeError(f"API wants a newer client version: {res}")
        step = data.get("step")
        if step:
            raise RuntimeError(f"Open the LibreLinkUp app and accept: {step.get('type')} ({step.get('componentName')})")
        if "authTicket" not in data:
            raise RuntimeError(f"Login failed: {res}")
        self.token = data["authTicket"]["token"]
        self.account_id = hashlib.sha256(data["user"]["id"].encode()).hexdigest()
        log("logged in")

    def graph(self):
        if not self.token:
            self.login()
        try:
            conns = self._request("GET", "/llu/connections")["data"]
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                self.login()
                conns = self._request("GET", "/llu/connections")["data"]
            else:
                raise
        if not conns:
            raise RuntimeError("No connections: invite this account from the FreeStyle Libre app (Share → LibreLinkUp)")
        pid = conns[0]["patientId"]
        return self._request("GET", f"/llu/connections/{pid}/graph")["data"]


def parse_ts(m):
    # FactoryTimestamp is UTC, e.g. "10/16/2026 11:15:00 AM"
    dt = datetime.strptime(m["FactoryTimestamp"], "%m/%d/%Y %I:%M:%S %p").replace(tzinfo=timezone.utc)
    return dt.isoformat()


def poll_loop(client):
    while True:
        try:
            g = client.graph()
            cur = g["connection"]["glucoseMeasurement"]
            reading = {
                "mgdl": cur["ValueInMgPerDl"],
                "mmol": round(cur["ValueInMgPerDl"] / 18.0182, 1),
                "trend": cur.get("TrendArrow"),
                "arrow": TREND_ARROWS.get(cur.get("TrendArrow"), "?"),
                "isHigh": cur.get("isHigh", False),
                "isLow": cur.get("isLow", False),
                "timestamp": parse_ts(cur),
                "targetLow": g["connection"].get("targetLow"),
                "targetHigh": g["connection"].get("targetHigh"),
            }
            history = [{"mgdl": m["ValueInMgPerDl"], "timestamp": parse_ts(m)} for m in g.get("graphData", [])]
            with lock:
                state.update(reading=reading, history=history, error=None,
                             updated=datetime.now(timezone.utc).isoformat())
            log(f"{reading['mgdl']} mg/dL {reading['arrow']} @ {reading['timestamp']}")
        except urllib.error.HTTPError as e:
            msg = f"HTTP {e.code}: {e.read()[:300]!r}"
            log(msg)
            with lock:
                state["error"] = msg
            if e.code == 429:
                time.sleep(300)
        except Exception as e:  # keep serving last known value
            log(f"error: {e}")
            with lock:
                state["error"] = str(e)
        time.sleep(POLL_SECONDS)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") not in ("/glucose", ""):
            self.send_error(404)
            return
        with lock:
            body = json.dumps(state).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    try:
        cfg = load_config()
    except Exception as e:
        sys.exit(f"Cannot load config {CONFIG_PATH}: {e}")
    client = LibreLinkUp(cfg["email"], cfg["password"], cfg.get("baseUrl"), cfg.get("version", "4.16.0"))
    threading.Thread(target=poll_loop, args=(client,), daemon=True).start()
    log(f"serving on http://127.0.0.1:{PORT}/glucose")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
