#!/usr/bin/env python3
"""Local bridge: polls the LibreLinkUp cloud (same data LibreView / Health2Sync see),
keeps every reading in a local SQLite database and serves it over HTTP.

  GET /                       live web page
  GET /glucose?hours=12       latest reading, delta, sensor info and history
  GET /stats?low=70&high=180  time in range, average and A1c estimate (today / 7 days)
  GET /readings?start=&end=   readings between two Unix times
  GET /export.csv             every stored reading
  GET/POST /events            meals, insulin and exercise
                              (POST {kind, timestamp?, carbs?, units?, insulinType?, activity?, minutes?, intensity?, note?, photo?})
  PATCH /events/<id>          change fields (same as POST; "removePhoto": true drops the photo)
  DELETE /events/<id>
  GET /photos/<id>            meal photo
  POST /meals/estimate        {photo?, mediaType?, text?} -> Claude carb estimate
  GET /meals?days=30&high=180 meals with their glucose impact and how the insulin dose worked out
  GET /exercise?days=30&low=70 exercise with how glucose responded, during and in the 12 h after
  GET /dose?carbs=50&target=120&low=70   rapid-insulin suggestion learned from the history
  GET /summary, POST /summary/generate   weekly recap written by Claude

Config: ~/.config/freestyle-bar/config.json
  {"email": "...", "lan": false}
If "password" is omitted it is read from the macOS Keychain
(service "freestyle-bar", account = email). "lan": true listens on all interfaces
so other devices at home can open the web page.
Glucose features use the standard library only; meal estimates and weekly summaries
use the Claude Agent SDK with your Claude subscription login (installed in .venv by install.sh).
"""
import base64
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

import dosing
import exercise
import insights

try:
    import ai
except ImportError:  # claude-agent-sdk not installed: AI features off
    ai = None

CONFIG_PATH = os.path.expanduser("~/.config/freestyle-bar/config.json")
DATA_DIR = os.path.expanduser("~/Library/Application Support/freestyle-bar")
DB_PATH = os.path.join(DATA_DIR, "glucose.db")
PHOTO_DIR = os.path.join(DATA_DIR, "photos")
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
    conn.row_factory = sqlite3.Row
    conn.execute("CREATE TABLE IF NOT EXISTS readings (ts INTEGER PRIMARY KEY, mgdl INTEGER NOT NULL, trend INTEGER)")
    conn.execute("""CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, kind TEXT NOT NULL,
        carbs REAL, units REAL, insulin_type TEXT, note TEXT, photo TEXT, estimate TEXT,
        activity TEXT, minutes REAL, intensity TEXT)""")
    columns = {r[1] for r in conn.execute("PRAGMA table_info(events)")}
    for col, kind in (("activity", "TEXT"), ("minutes", "REAL"), ("intensity", "TEXT")):
        if col not in columns:  # databases from before exercise was logged
            conn.execute(f"ALTER TABLE events ADD COLUMN {col} {kind}")
    conn.execute("""CREATE TABLE IF NOT EXISTS summaries (
        id INTEGER PRIMARY KEY AUTOINCREMENT, created INTEGER NOT NULL,
        period_start INTEGER NOT NULL, period_end INTEGER NOT NULL, text TEXT NOT NULL)""")
    return conn


def store(rows):
    with db() as conn:
        conn.executemany("INSERT OR IGNORE INTO readings (ts, mgdl, trend) VALUES (?, ?, ?)", rows)


def history(since_ts, until_ts=None):
    with db() as conn:
        rows = conn.execute("SELECT ts, mgdl FROM readings WHERE ts >= ? AND ts <= ? ORDER BY ts",
                            (since_ts, until_ts or 2 ** 40)).fetchall()
    return [(r[0], r[1]) for r in rows]


def event_json(r):
    return {
        "id": r["id"], "ts": r["ts"], "timestamp": iso(r["ts"]), "kind": r["kind"],
        "carbs": r["carbs"], "units": r["units"], "insulinType": r["insulin_type"], "note": r["note"],
        "activity": r["activity"], "minutes": r["minutes"], "intensity": r["intensity"],
        "photo": f"/photos/{r['id']}" if r["photo"] else None,
        "estimate": json.loads(r["estimate"]) if r["estimate"] else None,
    }


def events(since_ts, kind=None):
    with db() as conn:
        rows = conn.execute("SELECT * FROM events WHERE ts >= ? AND (? IS NULL OR kind = ?) ORDER BY ts",
                            (since_ts, kind, kind)).fetchall()
    return [event_json(r) for r in rows]


def parse_time(value):
    return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())


def save_photo(conn, eid, body):
    os.makedirs(PHOTO_DIR, exist_ok=True)
    ext = {"image/png": "png", "image/webp": "webp", "image/gif": "gif"}.get(body.get("mediaType"), "jpg")
    name = f"{eid}.{ext}"
    with open(os.path.join(PHOTO_DIR, name), "wb") as f:
        f.write(base64.b64decode(body["photo"]))
    conn.execute("UPDATE events SET photo = ? WHERE id = ?", (name, eid))
    return name


def remove_photo(name):
    try:
        os.remove(os.path.join(PHOTO_DIR, name))
    except FileNotFoundError:
        pass


events_version = 0  # bumped on every change to the log, so cached fits know to redo


def add_event(body):
    global events_version
    kind = body.get("kind")
    if kind not in ("meal", "insulin", "exercise"):
        raise ValueError("kind must be meal, insulin or exercise")
    ts = parse_time(body["timestamp"]) if body.get("timestamp") else int(time.time())
    if kind == "exercise":
        exercise.validate({**body, "ts": ts}, time.time())
    with db() as conn:
        cur = conn.execute(
            """INSERT INTO events (ts, kind, carbs, units, insulin_type, note, estimate, activity, minutes, intensity)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (ts, kind, body.get("carbs"), body.get("units"), body.get("insulinType"), (body.get("note") or "").strip() or None,
             json.dumps(body["estimate"]) if body.get("estimate") else None,
             body.get("activity"), body.get("minutes"), body.get("intensity")))
        eid = cur.lastrowid
        if body.get("photo"):
            save_photo(conn, eid, body)
        row = conn.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
    events_version += 1
    return event_json(row)


EDITABLE = {"carbs": "carbs", "units": "units", "insulinType": "insulin_type", "note": "note",
            "activity": "activity", "minutes": "minutes", "intensity": "intensity"}


def update_event(eid, body):
    """Changes the fields present in body; the others stay as they are."""
    global events_version
    with db() as conn:
        row = conn.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not row:
            raise LookupError("No such entry")
        sets = {col: body[key] for key, col in EDITABLE.items() if key in body}
        if "note" in sets:
            sets["note"] = (sets["note"] or "").strip() or None
        if body.get("timestamp"):
            sets["ts"] = parse_time(body["timestamp"])
        if "estimate" in body:
            sets["estimate"] = json.dumps(body["estimate"]) if body["estimate"] else None
        if row["kind"] == "exercise":
            exercise.validate({k: sets.get(col, row[col]) for k, col in
                               (("activity", "activity"), ("minutes", "minutes"), ("intensity", "intensity"), ("ts", "ts"))},
                              time.time())
        if sets:
            conn.execute(f"UPDATE events SET {', '.join(f'{c} = ?' for c in sets)} WHERE id = ?", (*sets.values(), eid))
        if (body.get("photo") or body.get("removePhoto")) and row["photo"]:
            remove_photo(row["photo"])
            conn.execute("UPDATE events SET photo = NULL WHERE id = ?", (eid,))
        if body.get("photo"):
            save_photo(conn, eid, body)
        row = conn.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
    events_version += 1
    return event_json(row)


def delete_event(eid):
    global events_version
    with db() as conn:
        row = conn.execute("SELECT photo FROM events WHERE id = ?", (eid,)).fetchone()
        conn.execute("DELETE FROM events WHERE id = ?", (eid,))
    events_version += 1
    if row and row["photo"]:
        remove_photo(row["photo"])


fit_cache, fit_lock = {}, threading.Lock()   # low -> (key, fit)


def fitted(low=70):
    """(carb ratio and sensitivity or None without insulin logs, exercise effects), learned from the
    last 30 days. Kept until a new reading arrives or the log changes."""
    with fit_lock:
        since = int(time.time()) - 30 * 86400
        readings = history(since)
        key = (readings[-1][0] if readings else None, events_version)
        if fit_cache.get(low, (None,))[0] != key:
            fit_cache[low] = (key, exercise.fit(readings, events(since), low))
        return fit_cache[low][1]


def dosing_params(low=70):
    return fitted(low)[0]


def meals_with_impact(since_ts, high, low=70):
    now = time.time()
    context = events(since_ts - 4 * 3600)
    meals = [e for e in context if e["kind"] == "meal"]
    insulin = [e for e in context if e["kind"] == "insulin"]
    params, fx = fitted(low)
    out = []
    for m in meals:
        if m["ts"] < since_ts:
            continue
        readings = history(m["ts"] - 15 * 60, m["ts"] + insights.MEAL_WINDOW)
        m["impact"] = insights.meal_impact(m["ts"], readings, high, now, fx)
        m["dose"] = dosing.meal_dose(m["ts"], meals, insulin, readings, low, high, now, params, fx)
        exercised = fx.lowered(m["ts"], m["ts"] + insights.MEAL_WINDOW)
        m["exercise"] = None
        if abs(exercised) >= 10:
            m["exercise"] = {"items": fx.describe(m["ts"] - 3600, m["ts"] + insights.MEAL_WINDOW), "effect": round(exercised)}
        out.append(m)
    return out


def exercise_with_impact(since_ts, low=70):
    now = time.time()
    context = events(since_ts - 6 * 3600)
    params, fx = fitted(low)
    out = []
    for e in exercise.sessions(context):
        if e["ts"] < since_ts:
            continue
        e["impact"] = exercise.impact(e, history(e["ts"] - 15 * 60, exercise.ends_at(e) + 12 * 3600), params, fx, context, low, now)
        for k in ("lowest", "lowAfter"):
            if e["impact"] and e["impact"][k]:
                e["impact"][k]["timestamp"] = iso(e["impact"][k]["ts"])
        out.append(e)
    return out


def dose_suggestion(carbs, target, low):
    params, fx = fitted(low)
    if not params:
        raise RuntimeError("Log your rapid and long-acting insulin for a day or two first.")
    now = int(time.time())
    recent = history(now - 30 * 60)
    glucose = recent[-1][1] if recent and recent[-1][0] >= now - 15 * 60 else None
    fc = insights.forecast(recent) if glucose is not None else None
    return dosing.suggest(params, carbs, glucose, fc["slope"] if fc else None, events(now - 8 * 3600), now, target, low,
                          exercise.dose_effect(fx, now))


def post_exercise():
    post = exercise.post_exercise(exercise.sessions(events(int(time.time()) - 24 * 3600)), time.time())
    if post:
        post["until"] = iso(post.pop("untilTs"))
    return post


# --- weekly summary ------------------------------------------------------------

def latest_summary():
    with db() as conn:
        r = conn.execute("SELECT * FROM summaries ORDER BY created DESC LIMIT 1").fetchone()
    if not r:
        return None
    return {"id": r["id"], "created": iso(r["created"]), "periodStart": iso(r["period_start"]),
            "periodEnd": iso(r["period_end"]), "text": r["text"]}


summary_lock = threading.Lock()


def generate_summary(low=70, high=180):
    if not ai:
        raise RuntimeError("Install claude-agent-sdk to enable summaries.")
    with summary_lock:
        start, end, prev_start = insights.week_bounds(datetime.now())
        s, e, p = int(start.timestamp()), int(end.timestamp()), int(prev_start.timestamp())
        sessions = [x for x in exercise_with_impact(s, low) if x["ts"] <= e]
        digest = insights.weekly_digest(history(s, e), history(p, s), events(s), meals_with_impact(s, high, low), low, high, s, e,
                                        sessions)
        if not digest["week"]:
            raise RuntimeError("No glucose data for the past week yet.")
        text = ai.weekly_summary(digest)
        with db() as conn:
            conn.execute("INSERT INTO summaries (created, period_start, period_end, text) VALUES (?, ?, ?, ?)",
                         (int(time.time()), s, e, text))
        log("weekly summary generated")
        return latest_summary()


def summary_scheduler():
    """Writes the weekly recap on Sunday from 19:00 local time, once per week."""
    while True:
        try:
            now = datetime.now()
            last = latest_summary()
            last_created = datetime.fromisoformat(last["created"]).astimezone() if last else None
            if now.weekday() == 6 and now.hour >= 19 and ai and ai.available() and (
                    not last_created or last_created.date() != now.date()):
                generate_summary()
        except Exception as e:
            log(f"summary error: {e}")
        time.sleep(1800)


def iso(ts):
    return datetime.fromtimestamp(int(ts), timezone.utc).isoformat()  # whole seconds: the app's decoder rejects fractions


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
    def _json(self, payload, status=200):
        self._send(json.dumps(payload).encode(), "application/json", status=status)

    def _body(self):
        length = int(self.headers.get("content-length") or 0)
        if length > 20 * 1024 * 1024:
            raise ValueError("Request too large")
        return json.loads(self.rfile.read(length) or b"{}")

    def _send(self, body, ctype, extra=None, status=200):
        self.send_response(status)
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
            rows = history(since)
            payload["history"] = [{"mgdl": m, "timestamp": iso(ts)} for ts, m in rows]
            fc = insights.forecast(history(int(time.time()) - 30 * 60))
            if fc and fc["fromTs"] < time.time() - 10 * 60:
                fc = None  # data too old to project
            if fc:
                fc["points"] = [{"mgdl": p["mgdl"], "timestamp": iso(p["ts"])} for p in fc["points"]]
                fc["fromTimestamp"] = iso(fc.pop("fromTs"))
            payload["forecast"] = fc
            payload["events"] = events(since)
            payload["postExercise"] = post_exercise()
            payload["aiAvailable"] = bool(ai and ai.available())
            self._json(payload)
        elif path == "/stats":
            low, high = int(q.get("low", 70)), int(q.get("high", 180))
            midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
            week = datetime.now().astimezone() - timedelta(days=7)
            payload = {"today": stats(int(midnight.timestamp()), low, high),
                       "week": stats(int(week.timestamp()), low, high)}
            self._send(json.dumps(payload).encode(), "application/json")
        elif path == "/readings":
            start = int(float(q.get("start", time.time() - 3 * 3600)))
            end = int(float(q.get("end", time.time())))
            self._json([{"mgdl": m, "timestamp": iso(ts)} for ts, m in history(start, end)])
        elif path == "/export.csv":
            lines = ["timestamp_utc,local_time,mg_dl,mmol_l"]
            for ts, m in history(0):
                local = datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")
                lines.append(f"{iso(ts)},{local},{m},{m / 18.0182:.1f}")
            self._send(("\n".join(lines) + "\n").encode(), "text/csv",
                       {"content-disposition": 'attachment; filename="glucose.csv"'})
        elif path == "/events":
            hours = min(float(q.get("hours", 24)), 24 * 365)
            self._json(events(int(time.time() - hours * 3600)))
        elif path.startswith("/photos/"):
            with db() as conn:
                row = conn.execute("SELECT photo FROM events WHERE id = ?", (path.split("/")[-1],)).fetchone()
            if not row or not row["photo"]:
                return self.send_error(404)
            ext = row["photo"].rsplit(".", 1)[-1]
            with open(os.path.join(PHOTO_DIR, row["photo"]), "rb") as f:
                self._send(f.read(), {"jpg": "image/jpeg"}.get(ext, f"image/{ext}"))
        elif path == "/meals":
            since = int(time.time() - float(q.get("days", 30)) * 86400)
            self._json(meals_with_impact(since, int(q.get("high", 180)), int(q.get("low", 70))))
        elif path == "/exercise":
            since = int(time.time() - float(q.get("days", 30)) * 86400)
            self._json(exercise_with_impact(since, int(q.get("low", 70))))
        elif path == "/dose":
            try:
                self._json(dose_suggestion(float(q.get("carbs", 0)), int(q.get("target", 120)), int(q.get("low", 70))))
            except Exception as e:
                self._json({"error": str(e)}, 400)
        elif path == "/summary":
            self._json({"summary": latest_summary(), "aiAvailable": bool(ai and ai.available())})
        else:
            self.send_error(404)

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/")
        q = {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}
        try:
            if path == "/events":
                self._json(add_event(self._body()), 201)
            elif path == "/meals/estimate":
                if not ai:
                    raise RuntimeError("Install claude-agent-sdk to enable estimates.")
                b = self._body()
                self._json(ai.estimate_meal(b.get("photo"), b.get("mediaType") or "image/jpeg", b.get("text")))
            elif path == "/summary/generate":
                self._json(generate_summary(int(q.get("low", 70)), int(q.get("high", 180))))
            else:
                self.send_error(404)
        except Exception as e:
            log(f"{path} error: {e}")
            self._json({"error": str(e)}, 400)

    def do_PATCH(self):
        path = urlparse(self.path).path.rstrip("/")
        if not (path.startswith("/events/") and path.split("/")[-1].isdigit()):
            return self.send_error(404)
        try:
            self._json(update_event(int(path.split("/")[-1]), self._body()))
        except LookupError as e:
            self._json({"error": str(e)}, 404)
        except Exception as e:
            log(f"{path} error: {e}")
            self._json({"error": str(e)}, 400)

    def do_DELETE(self):
        path = urlparse(self.path).path.rstrip("/")
        if path.startswith("/events/") and path.split("/")[-1].isdigit():
            delete_event(int(path.split("/")[-1]))
            self._json({"ok": True})
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
    threading.Thread(target=summary_scheduler, daemon=True).start()
    host = "0.0.0.0" if cfg.get("lan") else "127.0.0.1"
    log(f"serving on http://{host}:{PORT}/")
    ThreadingHTTPServer((host, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
