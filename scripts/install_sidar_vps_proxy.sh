#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script with sudo on the VPS." >&2
  exit 1
fi

SIDAR_PUBLIC_PORT="${SIDAR_PUBLIC_PORT:-8765}"
SIDAR_BACKEND_HOST="${SIDAR_BACKEND_HOST:-10.66.66.3}"
SIDAR_BACKEND_PORT="${SIDAR_BACKEND_PORT:-8765}"
SIDAR_SERVER_NAME="${SIDAR_SERVER_NAME:-_}"
SIDAR_PUBLIC_HOST="${SIDAR_PUBLIC_HOST:-45.32.115.105}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="$ROOT_DIR/deploy/nginx-sidar.conf.template"
NGINX_SITE="/etc/nginx/sites-available/sidar"

apt-get update
apt-get install -y ca-certificates curl nginx

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

if [[ -f "$TEMPLATE_FILE" ]]; then
  sed \
    -e "s|{{SIDAR_PUBLIC_PORT}}|$SIDAR_PUBLIC_PORT|g" \
    -e "s|{{SIDAR_BACKEND_HOST}}|$SIDAR_BACKEND_HOST|g" \
    -e "s|{{SIDAR_BACKEND_PORT}}|$SIDAR_BACKEND_PORT|g" \
    -e "s|{{SIDAR_SERVER_NAME}}|$SIDAR_SERVER_NAME|g" \
    "$TEMPLATE_FILE" >"$NGINX_SITE"
else
  cat >"$NGINX_SITE" <<EOF
server {
    listen $SIDAR_PUBLIC_PORT;
    server_name $SIDAR_SERVER_NAME;

    client_max_body_size 0;
    client_body_timeout 3600s;
    send_timeout 3600s;

    location / {
        proxy_pass http://$SIDAR_BACKEND_HOST:$SIDAR_BACKEND_PORT;

        proxy_http_version 1.1;

        proxy_request_buffering off;
        proxy_buffering off;

        proxy_connect_timeout 30s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
fi

ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/sidar
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx || systemctl restart nginx

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow "$SIDAR_PUBLIC_PORT/tcp"
fi

cat <<EOF

SIDAR VPS proxy installed.
This VPS only streams requests to the workstation receiver:
  public :$SIDAR_PUBLIC_PORT -> http://$SIDAR_BACKEND_HOST:$SIDAR_BACKEND_PORT

Test commands:
  curl http://127.0.0.1:$SIDAR_PUBLIC_PORT/health
  curl http://$SIDAR_PUBLIC_HOST:$SIDAR_PUBLIC_PORT/health

Token check example:
  curl -H "X-SIDAR-Token: <TOKEN>" http://$SIDAR_PUBLIC_HOST:$SIDAR_PUBLIC_PORT/api/uploads/auth-check
EOF
