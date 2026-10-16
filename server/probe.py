#!/usr/bin/env python3
"""Checks what your own LibreView account (the one in the Libre app) can reach.
Prints the region, status codes and JSON keys only. No glucose values or tokens are printed."""
import getpass, hashlib, json, urllib.error, urllib.request

H = {"content-type": "application/json", "product": "llu.android", "version": "4.16.0",
     "accept-encoding": "identity", "cache-control": "no-cache"}

def call(base, method, path, body=None, extra=None):
    req = urllib.request.Request(base + path, method=method, headers={**H, **(extra or {})},
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, (e.read()[:200].decode(errors="replace"))

def shape(x):
    if isinstance(x, dict):
        return {k: shape(v) if k == "data" else type(v).__name__ for k, v in x.items()}
    if isinstance(x, list):
        return f"list[{len(x)}]"
    return type(x).__name__

email = input("Email of the account you use in the Libre app: ")
pw = getpass.getpass("Password: ")
base = "https://api.libreview.io"
st, res = call(base, "POST", "/llu/auth/login", {"email": email, "password": pw})
d = res.get("data", {}) if isinstance(res, dict) else {}
if d.get("redirect"):
    print("Region:", d["region"])
    base = f"https://api-{d['region']}.libreview.io"
    st, res = call(base, "POST", "/llu/auth/login", {"email": email, "password": pw})
    d = res.get("data", {}) if isinstance(res, dict) else {}
print("Login:", st, "status", res.get("status") if isinstance(res, dict) else res)
if d.get("step"):
    print("Pending step:", d["step"].get("type"), d["step"].get("componentName"))
if "authTicket" not in d:
    raise SystemExit("No token: stopping. " + json.dumps(res)[:300])
u = d["user"]
print("Account country:", u.get("country"), "| uiLanguage:", u.get("uiLanguage"), "| accountType:", u.get("accountType"))
auth = {"authorization": "Bearer " + d["authTicket"]["token"],
        "account-id": hashlib.sha256(u["id"].encode()).hexdigest()}
for path in ["/llu/connections", "/user", "/account", "/glucoseHistory?numPeriods=1&period=1",
             "/llu/notifications/settings", "/llu/config/country?country=KR"]:
    st, r = call(base, "GET", path, extra=auth)
    print(f"{path:45s} {st}  {shape(r) if isinstance(r, (dict, list)) else r[:120]}")
