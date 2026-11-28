"""Local time for everything split by day or time of day (dose ratios by time of day, daily doses,
stats for today, weekly summaries, times in messages).

By default that's the server's own time zone. A server in another zone than its user (a cloud VM
in UTC, say) sets "timezone" in config.json to an IANA name such as "Asia/Seoul".
"""
from datetime import datetime

TZ = None  # None: the server's local time zone


def configure(name):
    """Use the IANA time zone `name` (None or "" keeps the server's own). ValueError if unknown."""
    global TZ
    if not name:
        TZ = None
        return
    if not isinstance(name, str):
        raise ValueError('"timezone" must be a time zone name such as "Asia/Seoul"')
    try:
        from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
    except ImportError as e:  # pragma: no cover - Python < 3.9
        raise ValueError('"timezone" needs Python 3.9 or later') from e
    try:
        TZ = ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError) as e:
        raise ValueError(f'unknown "timezone" "{name}" (use an IANA name such as "Asia/Seoul"; '
                         'on Windows, pip install tzdata)') from e


def describe():
    return str(TZ) if TZ else "server local time"


def at(ts):
    """The local datetime of Unix time ts."""
    return datetime.fromtimestamp(ts, TZ)


def now():
    return datetime.now(TZ)
