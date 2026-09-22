#!/usr/bin/env bash
set -euo pipefail

TABLE="server_traffic_monitor"
RULES="/etc/server-traffic-monitor/public-counter.nft"

if /usr/sbin/nft list table inet "$TABLE" >/dev/null 2>&1; then
  /usr/sbin/nft delete table inet "$TABLE"
fi

exec /usr/sbin/nft -f "$RULES"
