#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="server-traffic-monitor"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN=""
CERT_PATH=""
KEY_PATH=""
PORT="8443"
QUOTA_GB="100"
RESET_DAY="1"
INTERFACE=""
ADMIN_PASSWORD=""
OPEN_UFW="0"

usage() {
  cat <<'EOF'
Server Traffic Monitor installer

Usage:
  sudo bash install.sh \
    --domain monitor.example.com \
    --cert /path/to/fullchain.pem \
    --key /path/to/privkey.key

Options:
  --domain NAME          Required. Nginx server_name.
  --cert PATH            Required. TLS certificate / Cloudflare Origin certificate.
  --key PATH             Required. Matching TLS private key.
  --port PORT            HTTPS listen port. Default: 8443.
  --quota GB             Monthly/cycle traffic quota in GB. Default: 100.
  --reset-day DAY        Billing cycle reset day, 1-28. Default: 1.
  --interface NAME       Egress interface. Auto-detected when omitted.
  --admin-password PASS  Admin password. Random 16-char password when omitted.
  --open-ufw             If UFW is active, allow the selected TCP port.
  -h, --help             Show this help.

Example:
  sudo bash install.sh \
    --domain monitor.example.com \
    --cert /root/origin.pem \
    --key /root/origin.key \
    --port 8443 \
    --quota 100 \
    --reset-day 1
EOF
}

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --cert) CERT_PATH="${2:-}"; shift 2 ;;
    --key) KEY_PATH="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --quota) QUOTA_GB="${2:-}"; shift 2 ;;
    --reset-day) RESET_DAY="${2:-}"; shift 2 ;;
    --interface) INTERFACE="${2:-}"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="${2:-}"; shift 2 ;;
    --open-ufw) OPEN_UFW="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this installer as root (sudo)."
[[ -n "$DOMAIN" ]] || die "--domain is required."
[[ -n "$CERT_PATH" ]] || die "--cert is required."
[[ -n "$KEY_PATH" ]] || die "--key is required."
[[ -f "$CERT_PATH" ]] || die "Certificate not found: $CERT_PATH"
[[ -f "$KEY_PATH" ]] || die "Private key not found: $KEY_PATH"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid domain."
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "Invalid port."
[[ "$RESET_DAY" =~ ^[0-9]+$ ]] && (( RESET_DAY >= 1 && RESET_DAY <= 28 )) || die "reset-day must be 1..28."
[[ "$QUOTA_GB" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "quota must be a positive number."
awk -v q="$QUOTA_GB" 'BEGIN { exit !(q > 0) }' || die "quota must be > 0."

command -v apt-get >/dev/null 2>&1 || die "This installer currently supports apt-based Debian/Ubuntu systems."

if [[ -z "$INTERFACE" ]]; then
  INTERFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [[ -n "$INTERFACE" ]] || INTERFACE="$(ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
fi
[[ -n "$INTERFACE" ]] || die "Unable to detect the default egress interface. Use --interface."
[[ "$INTERFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Invalid interface name: $INTERFACE"
ip link show "$INTERFACE" >/dev/null 2>&1 || die "Interface does not exist: $INTERFACE"

info "Domain: $DOMAIN"
info "HTTPS port: $PORT"
info "Egress interface: $INTERFACE"
info "Quota: $QUOTA_GB GB"
info "Reset day: $RESET_DAY"

info "Installing minimal dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nginx vnstat nftables apache2-utils python3 openssl ca-certificates

nginx -V 2>&1 | grep -q -- '--with-http_dav_module' || die "Nginx was built without http_dav_module."

# Only reject the port when another non-Nginx process owns it.
PORT_INFO="$(ss -Hltnp "sport = :$PORT" 2>/dev/null || true)"
if [[ -n "$PORT_INFO" ]] && ! grep -qi nginx <<<"$PORT_INFO"; then
  echo "$PORT_INFO" >&2
  die "TCP port $PORT is already occupied by a non-Nginx process. Choose another --port."
fi

# Verify certificate/key pair without exposing the private key.
CERT_PUB="$(openssl x509 -in "$CERT_PATH" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
KEY_PUB="$(openssl pkey -in "$KEY_PATH" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
[[ -n "$CERT_PUB" && "$CERT_PUB" == "$KEY_PUB" ]] || die "TLS certificate and private key do not match."

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/$PROJECT/$STAMP"
mkdir -p "$BACKUP_DIR"

SITE_PATH="/etc/nginx/sites-available/$PROJECT"
ENABLED_PATH="/etc/nginx/sites-enabled/$PROJECT"
SITE_EXISTED="0"
ENABLED_EXISTED="0"

if [[ -f "$SITE_PATH" ]]; then
  cp -a "$SITE_PATH" "$BACKUP_DIR/nginx-site.conf"
  SITE_EXISTED="1"
fi
if [[ -e "$ENABLED_PATH" || -L "$ENABLED_PATH" ]]; then
  cp -a "$ENABLED_PATH" "$BACKUP_DIR/nginx-enabled-entry" 2>/dev/null || true
  ENABLED_EXISTED="1"
fi
[[ -f /etc/nginx/server-traffic-monitor.htpasswd ]] && cp -a /etc/nginx/server-traffic-monitor.htpasswd "$BACKUP_DIR/htpasswd" || true
[[ -d /etc/server-traffic-monitor ]] && cp -a /etc/server-traffic-monitor "$BACKUP_DIR/etc-server-traffic-monitor" || true
[[ -d /var/www/server-traffic-monitor ]] && cp -a /var/www/server-traffic-monitor "$BACKUP_DIR/www-server-traffic-monitor" || true
[[ -f /etc/systemd/system/server-traffic-monitor-data.service ]] && cp -a /etc/systemd/system/server-traffic-monitor-data.service "$BACKUP_DIR/data.service" || true
[[ -f /etc/systemd/system/server-traffic-monitor-data.timer ]] && cp -a /etc/systemd/system/server-traffic-monitor-data.timer "$BACKUP_DIR/data.timer" || true

install -d -m 0755 /usr/local/lib/server-traffic-monitor
install -d -m 0755 /etc/server-traffic-monitor
install -d -m 0700 /etc/nginx/ssl/server-traffic-monitor
install -d -m 0755 /var/www/server-traffic-monitor
install -d -m 0750 /var/lib/server-traffic-monitor
install -d -o www-data -g www-data -m 0750 /var/lib/server-traffic-monitor/api/admin

install -m 0755 "$ROOT_DIR/scripts/generate_data.py" /usr/local/lib/server-traffic-monitor/generate_data.py
install -m 0755 "$ROOT_DIR/scripts/admin_action.py" /usr/local/lib/server-traffic-monitor/admin_action.py
install -m 0755 "$ROOT_DIR/deploy/load-public-counter.sh" /usr/local/lib/server-traffic-monitor/load-public-counter.sh
install -m 0644 "$ROOT_DIR/web/index.html" /var/www/server-traffic-monitor/index.html

install -m 0644 "$CERT_PATH" /etc/nginx/ssl/server-traffic-monitor/fullchain.pem
install -m 0600 "$KEY_PATH" /etc/nginx/ssl/server-traffic-monitor/privkey.key

sed "s|@INTERFACE@|$INTERFACE|g" "$ROOT_DIR/deploy/public-counter.nft.in" > /etc/server-traffic-monitor/public-counter.nft
CHECK_TABLE="server_traffic_monitor_check_$$"
sed "s/table inet server_traffic_monitor/table inet $CHECK_TABLE/" /etc/server-traffic-monitor/public-counter.nft | /usr/sbin/nft --check -f -

sed "s|@INTERFACE@|$INTERFACE|g" "$ROOT_DIR/deploy/systemd/server-traffic-monitor-data.service.in" > /etc/systemd/system/server-traffic-monitor-data.service
install -m 0644 "$ROOT_DIR/deploy/systemd/server-traffic-monitor-data.timer" /etc/systemd/system/server-traffic-monitor-data.timer
install -m 0644 "$ROOT_DIR/deploy/systemd/server-traffic-monitor-counter.service" /etc/systemd/system/server-traffic-monitor-counter.service
install -m 0644 "$ROOT_DIR/deploy/systemd/server-traffic-monitor-admin@.service" /etc/systemd/system/server-traffic-monitor-admin@.service
install -m 0644 "$ROOT_DIR/deploy/systemd/server-traffic-monitor-admin-refresh.path" /etc/systemd/system/server-traffic-monitor-admin-refresh.path
install -m 0644 "$ROOT_DIR/deploy/systemd/server-traffic-monitor-admin-adjust.path" /etc/systemd/system/server-traffic-monitor-admin-adjust.path
install -m 0644 "$ROOT_DIR/deploy/systemd/server-traffic-monitor-admin-package.path" /etc/systemd/system/server-traffic-monitor-admin-package.path

# Preserve calibration data on reinstall; update only package defaults requested by this run.
CONFIG_PATH="/var/lib/server-traffic-monitor/config.json"
python3 - "$CONFIG_PATH" "$RESET_DAY" "$QUOTA_GB" <<'PY'
import json, os, sys, tempfile
path, reset_day, quota = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
cfg = {"reset_day": reset_day, "quota_gb": quota, "adjustments": {}}
try:
    with open(path, "r", encoding="utf-8") as f:
        old = json.load(f)
        if isinstance(old, dict):
            cfg["adjustments"] = old.get("adjustments", {}) if isinstance(old.get("adjustments", {}), dict) else {}
except Exception:
    pass
cfg["reset_day"] = reset_day
cfg["quota_gb"] = quota
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, separators=(",", ":"))
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY

PASSWORD_STATUS="generated"
if [[ -z "$ADMIN_PASSWORD" && -f /etc/nginx/server-traffic-monitor.htpasswd ]]; then
  PASSWORD_STATUS="preserved"
elif [[ -z "$ADMIN_PASSWORD" ]]; then
  ADMIN_PASSWORD="$(python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(16)))
PY
)"
else
  PASSWORD_STATUS="provided"
fi

if [[ "$PASSWORD_STATUS" != "preserved" ]]; then
  [[ ${#ADMIN_PASSWORD} -ge 8 ]] || die "Admin password must be at least 8 characters."
  printf '%s\n' "$ADMIN_PASSWORD" | htpasswd -iBc /etc/nginx/server-traffic-monitor.htpasswd admin >/dev/null
fi
chown root:www-data /etc/nginx/server-traffic-monitor.htpasswd
chmod 0640 /etc/nginx/server-traffic-monitor.htpasswd

sed -e "s|@DOMAIN@|$DOMAIN|g" -e "s|@PORT@|$PORT|g" "$ROOT_DIR/deploy/nginx/server.conf.in" > "$SITE_PATH"
ln -sfn "$SITE_PATH" "$ENABLED_PATH"
ln -sfn /var/lib/server-traffic-monitor/data.json /var/www/server-traffic-monitor/data.json

if ! nginx -t; then
  echo "[ERROR] nginx -t failed. Rolling back this site's Nginx entry." >&2

  if [[ "$SITE_EXISTED" == "1" ]]; then
    cp -a "$BACKUP_DIR/nginx-site.conf" "$SITE_PATH"
  else
    mv "$SITE_PATH" "$BACKUP_DIR/nginx-site.failed"
  fi

  if [[ "$ENABLED_EXISTED" == "0" && ( -e "$ENABLED_PATH" || -L "$ENABLED_PATH" ) ]]; then
    mv "$ENABLED_PATH" "$BACKUP_DIR/nginx-enabled.failed"
  fi

  nginx -t || true
  die "Nginx configuration rejected. Previous site state restored; backup: $BACKUP_DIR"
fi

systemctl daemon-reload
systemctl enable --now vnstat
systemctl enable server-traffic-monitor-counter.service >/dev/null
systemctl restart server-traffic-monitor-counter.service

systemctl enable server-traffic-monitor-data.timer >/dev/null
systemctl restart server-traffic-monitor-data.timer

for action in refresh adjust package; do
  systemctl enable "server-traffic-monitor-admin-$action.path" >/dev/null
  systemctl restart "server-traffic-monitor-admin-$action.path"
done

systemctl start server-traffic-monitor-data.service
systemctl reload nginx

if [[ "$OPEN_UFW" == "1" ]] && command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q '^Status: active'; then
    ufw allow "$PORT/tcp"
    info "UFW rule added for TCP $PORT."
  fi
fi

echo
echo "============================================================"
echo " Server Traffic Monitor installed successfully"
echo "============================================================"
echo " Domain          : $DOMAIN"
echo " HTTPS port      : $PORT"
echo " Egress interface: $INTERFACE"
echo " Quota           : $QUOTA_GB GB"
echo " Reset day       : $RESET_DAY"
echo " Admin user      : admin"
if [[ "$PASSWORD_STATUS" == "preserved" ]]; then
  echo " Admin password  : unchanged (existing hash preserved)"
else
  echo " Admin password  : $ADMIN_PASSWORD"
fi
echo " Backup          : $BACKUP_DIR"
echo
echo " Direct URL      : https://$DOMAIN:$PORT/"
echo
echo "If Cloudflare proxies https://$DOMAIN without an explicit port:"
echo "  1. Keep SSL/TLS mode at Full (strict)."
echo "  2. Create an Origin Rule for host $DOMAIN."
echo "  3. Rewrite the destination port to $PORT."
echo "  4. Allow TCP $PORT in your cloud security group / NSG."
echo
echo "The generated admin password is shown only in this terminal."
echo "Nginx stores only its password hash."
