#!/usr/bin/env python3
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile

BASE = "/var/lib/server-traffic-monitor"
CONFIG = os.path.join(BASE, "config.json")
STATE = os.path.join(BASE, "public_state.json")
DEFAULT = {"reset_day": 1, "quota_gb": 100.0, "adjustments": {}}

def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            v = json.load(f)
            return v if isinstance(v, dict) else dict(default)
    except Exception:
        return dict(default)

def atomic_json(path, obj, mode=0o600):
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
            f.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def add_months(year, month, delta):
    idx = year * 12 + month - 1 + delta
    return idx // 12, idx % 12 + 1

def period_bounds(day, reset_day):
    if day.day >= reset_day:
        sy, sm = day.year, day.month
    else:
        sy, sm = add_months(day.year, day.month, -1)
    start = dt.date(sy, sm, reset_day)
    ny, nm = add_months(sy, sm, 1)
    return start, dt.date(ny, nm, reset_day) - dt.timedelta(days=1)

def sum_days(days, start, end):
    total = 0
    d = start
    while d <= end:
        total += int(days.get(d.isoformat(), 0) or 0)
        d += dt.timedelta(days=1)
    return total

def refresh():
    subprocess.run(["/usr/bin/systemctl", "start", "server-traffic-monitor-data.service"], check=True)

def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: admin_action.py ACTION REQUEST_FILE")
    action, request_file = sys.argv[1], sys.argv[2]
    if not os.path.exists(request_file):
        return
    try:
        payload = load_json(request_file, {})
        cfg = load_json(CONFIG, DEFAULT)
        cfg.setdefault("adjustments", {})

        if action == "refresh":
            pass
        elif action == "package":
            reset_day = int(payload.get("reset_day", 0))
            quota_gb = float(payload.get("quota_gb", 0))
            if not 1 <= reset_day <= 28:
                raise ValueError("reset_day must be 1..28")
            if not 1 <= quota_gb <= 100000:
                raise ValueError("quota_gb out of range")
            cfg["reset_day"] = reset_day
            cfg["quota_gb"] = quota_gb
            cfg["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
            atomic_json(CONFIG, cfg)
        elif action == "adjust":
            target = float(payload.get("target", -1))
            unit = str(payload.get("unit", "GB")).upper()
            if target < 0 or unit not in ("GB", "MB"):
                raise ValueError("invalid target")
            target_bytes = int(target * (1_000_000_000 if unit == "GB" else 1_000_000))
            reset_day = min(28, max(1, int(cfg.get("reset_day", 1))))
            today = dt.datetime.now(dt.timezone.utc).date()
            start, _ = period_bounds(today, reset_day)
            state = load_json(STATE, {})
            days = state.get("days", {}) if isinstance(state, dict) else {}
            raw = sum_days(days, start, today)
            cfg["adjustments"][start.isoformat()] = target_bytes - raw
            cfg["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
            atomic_json(CONFIG, cfg)
        else:
            raise ValueError("unsupported action")

        refresh()
    finally:
        try:
            os.unlink(request_file)
        except FileNotFoundError:
            pass

if __name__ == "__main__":
    main()
