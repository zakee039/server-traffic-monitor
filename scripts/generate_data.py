#!/usr/bin/env python3
import argparse
import calendar
import datetime as dt
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

DEFAULT_CONFIG = {"reset_day": 1, "quota_gb": 100.0, "adjustments": {}}

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--interface", required=True)
    p.add_argument("--output", default="/var/lib/server-traffic-monitor/data.json")
    p.add_argument("--state", default="/var/lib/server-traffic-monitor/public_state.json")
    p.add_argument("--config", default="/var/lib/server-traffic-monitor/config.json")
    return p.parse_args()

def run_json(cmd):
    cp = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return json.loads(cp.stdout)

def atomic_json(path, obj, mode=0o644):
    out_dir = os.path.dirname(path) or "."
    os.makedirs(out_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=out_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
            f.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            v = json.load(f)
            return v if isinstance(v, dict) else dict(default)
    except Exception:
        return dict(default)

def load_config(path):
    cfg = load_json(path, DEFAULT_CONFIG)
    try:
        cfg["reset_day"] = min(28, max(1, int(cfg.get("reset_day", 1))))
    except Exception:
        cfg["reset_day"] = 1
    try:
        cfg["quota_gb"] = max(1.0, float(cfg.get("quota_gb", 100.0)))
    except Exception:
        cfg["quota_gb"] = 100.0
    if not isinstance(cfg.get("adjustments"), dict):
        cfg["adjustments"] = {}
    return cfg

def vnstat(interface):
    raw = run_json(["/usr/bin/vnstat", "-i", interface, "--json"])
    if not raw.get("interfaces"):
        raise RuntimeError("vnStat returned no interfaces")
    return next((x for x in raw["interfaces"] if x.get("name") == interface), raw["interfaces"][0])

def date_of(item):
    d = item.get("date") or {}
    return dt.date(int(d["year"]), int(d["month"]), int(d.get("day", 1)))

def nft_counter(name):
    try:
        raw = run_json(["/usr/sbin/nft", "-j", "list", "counter", "inet", "server_traffic_monitor", name])
    except Exception:
        return None
    for item in raw.get("nftables", []):
        c = item.get("counter")
        if c and c.get("name") == name:
            return int(c.get("bytes", 0) or 0)
    return None

def update_public_state(path, raw_counter, now):
    state = load_json(path, {})
    started = state.get("started_at")
    if not started:
        started = now.isoformat()
        state = {"started_at": started, "last_counter": raw_counter, "days": {}}
        delta = 0
    else:
        last = int(state.get("last_counter", raw_counter) or 0)
        delta = raw_counter - last if raw_counter >= last else raw_counter
        delta = max(0, delta)

    day_key = now.date().isoformat()
    days = state.setdefault("days", {})
    days[day_key] = int(days.get(day_key, 0) or 0) + delta
    state["last_counter"] = raw_counter
    state["updated_at"] = now.isoformat()

    cutoff = (now.date() - dt.timedelta(days=45)).isoformat()
    state["days"] = {k: int(v or 0) for k, v in days.items() if k >= cutoff}
    atomic_json(path, state, 0o600)
    return state

def add_months(year, month, delta):
    idx = year * 12 + (month - 1) + delta
    return idx // 12, idx % 12 + 1

def period_bounds(day, reset_day):
    if day.day >= reset_day:
        sy, sm = day.year, day.month
    else:
        sy, sm = add_months(day.year, day.month, -1)
    start = dt.date(sy, sm, reset_day)
    ny, nm = add_months(sy, sm, 1)
    next_start = dt.date(ny, nm, reset_day)
    return start, next_start - dt.timedelta(days=1)

def sum_days(days, start, end):
    total = 0
    cur = start
    while cur <= end:
        total += int(days.get(cur.isoformat(), 0) or 0)
        cur += dt.timedelta(days=1)
    return total

def cpu_snapshot():
    with open("/proc/stat", "r", encoding="utf-8") as f:
        parts = f.readline().split()
    vals = list(map(int, parts[1:]))
    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
    return sum(vals), idle

def cpu_percent():
    try:
        t1, i1 = cpu_snapshot()
        time.sleep(0.15)
        t2, i2 = cpu_snapshot()
        dtot = t2 - t1
        didle = i2 - i1
        return round(max(0.0, min(100.0, (dtot - didle) * 100.0 / dtot)), 1) if dtot else 0.0
    except Exception:
        return 0.0

def cpu_frequency_mhz():
    values = []
    for p in Path("/sys/devices/system/cpu").glob("cpu[0-9]*/cpufreq/scaling_cur_freq"):
        try:
            values.append(float(p.read_text().strip()) / 1000.0)
        except Exception:
            pass
    if not values:
        try:
            with open("/proc/cpuinfo", "r", encoding="utf-8") as f:
                for line in f:
                    if line.lower().startswith("cpu mhz"):
                        values.append(float(line.split(":", 1)[1].strip()))
        except Exception:
            pass
    return round(sum(values) / len(values), 0) if values else 0.0

def memory_stats():
    info = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as f:
        for line in f:
            k, v = line.split(":", 1)
            info[k] = int(v.strip().split()[0]) * 1024
    total = int(info.get("MemTotal", 0))
    available = int(info.get("MemAvailable", info.get("MemFree", 0)))
    used = max(0, total - available)
    pct = round(used * 100.0 / total, 1) if total else 0.0
    return used, total, pct

def disk_stats():
    d = shutil.disk_usage("/")
    used = int(d.used)
    total = int(d.total)
    pct = round(used * 100.0 / total, 1) if total else 0.0
    return used, total, pct

def status_for(used_pct):
    if used_pct > 100: return "超额"
    if used_pct >= 95: return "危险"
    if used_pct >= 85: return "警告"
    if used_pct >= 70: return "提醒"
    return "正常"

def main():
    args = parse_args()
    now = dt.datetime.now(dt.timezone.utc)
    today = now.date()
    yesterday = today - dt.timedelta(days=1)

    cfg = load_config(args.config)
    if not os.path.exists(args.config):
        atomic_json(args.config, cfg, 0o600)

    iface = vnstat(args.interface)
    traffic = iface.get("traffic", {})
    vdays = traffic.get("day", []) or []
    day_map = {}
    for item in vdays:
        try:
            day_map[date_of(item)] = item
        except Exception:
            pass
    def vn_day_tx(d):
        return int((day_map.get(d) or {}).get("tx", 0) or 0)

    raw4 = nft_counter("public_tx_v4")
    raw6 = nft_counter("public_tx_v6")
    public_available = raw4 is not None or raw6 is not None
    raw_public = int(raw4 or 0) + int(raw6 or 0)
    state = update_public_state(args.state, raw_public, now) if public_available else load_json(args.state, {})
    days = state.get("days", {}) if isinstance(state, dict) else {}

    reset_day = cfg["reset_day"]
    period_start, period_end = period_bounds(today, reset_day)
    raw_period = sum_days(days, period_start, today)
    period_key = period_start.isoformat()
    adjustment = int(cfg.get("adjustments", {}).get(period_key, 0) or 0)
    period_tx = max(0, raw_period + adjustment)

    last7 = []
    for offset in range(6, -1, -1):
        d = today - dt.timedelta(days=offset)
        last7.append({
            "date": d.isoformat(),
            "label": f"{d.month}/{d.day}",
            "tx_bytes": int(days.get(d.isoformat(), 0) or 0)
        })

    started_at = state.get("started_at")
    observed_start = period_start
    if started_at:
        try:
            observed_start = max(period_start, dt.datetime.fromisoformat(started_at).date())
        except Exception:
            pass
    elapsed_days = max(1, (today - observed_start).days + 1)
    total_days = (period_end - period_start).days + 1
    projection = int(period_tx / elapsed_days * total_days)

    cpu_pct = cpu_percent()
    cpu_mhz = cpu_frequency_mhz()
    mem_used, mem_total, mem_pct = memory_stats()
    disk_used, disk_total, disk_pct = disk_stats()

    quota_gb = float(cfg["quota_gb"])
    quota_bytes = quota_gb * 1_000_000_000
    quota_used_pct = period_tx * 100.0 / quota_bytes if quota_bytes else 0.0

    out = {
        "generated_at": now.isoformat(),
        "source": "vnStat + nftables + procfs",
        "interface": args.interface,
        "status": status_for(quota_used_pct),
        "config": {
            "reset_day": reset_day,
            "quota_gb": quota_gb,
            "period_start": period_start.isoformat(),
            "period_end": period_end.isoformat()
        },
        "public": {
            "available": public_available,
            "started_at": started_at,
            "raw_period_tx_bytes": raw_period,
            "adjustment_bytes": adjustment,
            "period_tx_bytes": period_tx,
            "today_tx_bytes": int(days.get(today.isoformat(), 0) or 0),
            "yesterday_tx_bytes": int(days.get(yesterday.isoformat(), 0) or 0),
            "last7_days": last7,
            "last7_tx_bytes": sum(int(x["tx_bytes"]) for x in last7),
            "projection_bytes": projection,
            "counter_raw_bytes": raw_public
        },
        "system": {
            "cpu_percent": cpu_pct,
            "cpu_frequency_mhz": cpu_mhz,
            "memory_used_bytes": mem_used,
            "memory_total_bytes": mem_total,
            "memory_percent": mem_pct,
            "disk_used_bytes": disk_used,
            "disk_total_bytes": disk_total,
            "disk_percent": disk_pct
        },
        "vnstat": {
            "today_tx_bytes": vn_day_tx(today),
            "yesterday_tx_bytes": vn_day_tx(yesterday)
        }
    }
    atomic_json(args.output, out, 0o644)

if __name__ == "__main__":
    main()
