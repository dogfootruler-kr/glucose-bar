#!/usr/bin/env python3
"""Local bridge: polls the LibreLinkUp cloud (same data LibreView / Health2Sync see),
keeps every reading in a local SQLite database and serves it over HTTP.

  GET /                       live web page
  GET /glucose?hours=12       latest reading, delta, sensor info and history
  GET /stats?low=70&high=180  time in range, average and A1c estimate (today / 7 days)
  GET /export.csv             every stored reading

Config: ~/.config/freestyle-bar/config.json
  {"email": "...", "lan": false}
If "password" is omitted it is read from the macOS Keychain
(service "freestyle-bar", account = email). "lan": true listens on all interfaces
so other devices at home can open the web page.
Standard library only.
"""
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CONFIG_PATH = os.path.expanduser("~/.config/freestyle-bar/config.json")
DB_PATH = os.path.expanduser("~/Library/Application Support/freestyle-bar/glucose.db")
WEB_PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web.html")
PORT = int(os.environ.get("FREESTYLE_BAR_PORT", "8765"))
POLL_SECONDS = 60
DEFAULT_BASE = "https://api.libreview.io"
TREND_ARROWS = {1: "↓", 2: "↘", 3: "→", 4: "↗", 5: "↑"}

state = {"reading": None, "sensor": None, "error": None, "updated": None}
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


# --- storage -----------------------------------------------------------------

def db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("CREATE TABLE IF NOT EXISTS readings (ts INTEGER PRIMARY KEY, mgdl INTEGER NOT NULL, trend INTEGER)")
    return conn


def store(rows):
    with db() as conn:
        conn.executemany("INSERT OR IGNORE INTO readings (ts, mgdl, trend) VALUES (?, ?, ?)", rows)


def history(since_ts):
    with db() as conn:
        return conn.execute("SELECT ts, mgdl FROM readings WHERE ts >= ? ORDER BY ts", (since_ts,)).fetchall()


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat()


def delta_for(ts, mgdl):
    """Change vs the reading closest to 5 minutes earlier (3-10 min window)."""
    with db() as conn:
        row = conn.execute(
            "SELECT mgdl FROM readings WHERE ts BETWEEN ? AND ? ORDER BY ABS(ts - ?) LIMIT 1",
            (ts - 600, ts - 180, ts - 300),
        ).fetchone()
    return mgdl - row[0] if row else None


def stats(since_ts, low, high):
    vals = [m for _, m in history(since_ts)]
    if not vals:
        return None
    avg = sum(vals) / len(vals)
    return {
        "count": len(vals),
        "average": round(avg),
        "inRange": round(100 * sum(low <= v <= high for v in vals) / len(vals)),
        "below": round(100 * sum(v < low for v in vals) / len(vals)),
        "above": round(100 * sum(v > high for v in vals) / len(vals)),
        "gmi": round(3.31 + 0.02392 * avg, 1),  # glucose management indicator (A1c estimate)
    }


# --- LibreLinkUp client ------------------------------------------------------

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
    return int(dt.timestamp())


def poll_loop(client):
    while True:
        try:
            g = client.graph()
            conn = g["connection"]
            cur = conn["glucoseMeasurement"]
            ts = parse_ts(cur)
            store([(parse_ts(m), m["ValueInMgPerDl"], None) for m in g.get("graphData", [])]
                  + [(ts, cur["ValueInMgPerDl"], cur.get("TrendArrow"))])
            reading = {
                "mgdl": cur["ValueInMgPerDl"],
                "mmol": round(cur["ValueInMgPerDl"] / 18.0182, 1),
                "trend": cur.get("TrendArrow"),
                "arrow": TREND_ARROWS.get(cur.get("TrendArrow"), "?"),
                "delta": delta_for(ts, cur["ValueInMgPerDl"]),
                "isHigh": cur.get("isHigh", False),
                "isLow": cur.get("isLow", False),
                "timestamp": iso(ts),
                "targetLow": conn.get("targetLow"),
                "targetHigh": conn.get("targetHigh"),
            }
            sensors = g.get("activeSensors") or []
            s = (sensors[0]["sensor"] if sensors else conn.get("sensor")) or {}
            sensor = {"serial": s.get("sn"), "activated": iso(s["a"]), "productType": s.get("pt")} if s.get("a") else None
            with lock:
                state.update(reading=reading, sensor=sensor, error=None,
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


# --- HTTP --------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def _send(self, body, ctype, extra=None):
        self.send_response(200)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        path = url.path.rstrip("/")
        if path == "":
            with open(WEB_PAGE, "rb") as f:
                self._send(f.read(), "text/html; charset=utf-8")
        elif path == "/glucose":
            hours = min(float(q.get("hours", 12)), 24 * 90)
            since = int(time.time() - hours * 3600)
            with lock:
                payload = dict(state)
            payload["history"] = [{"mgdl": m, "timestamp": iso(ts)} for ts, m in history(since)]
            self._send(json.dumps(payload).encode(), "application/json")
        elif path == "/stats":
            low, high = int(q.get("low", 70)), int(q.get("high", 180))
            midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
            week = datetime.now().astimezone() - timedelta(days=7)
            payload = {"today": stats(int(midnight.timestamp()), low, high),
                       "week": stats(int(week.timestamp()), low, high)}
            self._send(json.dumps(payload).encode(), "application/json")
        elif path == "/export.csv":
            lines = ["timestamp_utc,local_time,mg_dl,mmol_l"]
            for ts, m in history(0):
                local = datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")
                lines.append(f"{iso(ts)},{local},{m},{m / 18.0182:.1f}")
            self._send(("\n".join(lines) + "\n").encode(), "text/csv",
                       {"content-disposition": 'attachment; filename="glucose.csv"'})
        else:
            self.send_error(404)

    def log_message(self, *args):
        pass


def main():
    try:
        cfg = load_config()
    except Exception as e:
        sys.exit(f"Cannot load config {CONFIG_PATH}: {e}")
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    db().close()
    client = LibreLinkUp(cfg["email"], cfg["password"], cfg.get("baseUrl"), cfg.get("version", "4.16.0"))
    threading.Thread(target=poll_loop, args=(client,), daemon=True).start()
    host = "0.0.0.0" if cfg.get("lan") else "127.0.0.1"
    log(f"serving on http://{host}:{PORT}/")
    ThreadingHTTPServer((host, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
