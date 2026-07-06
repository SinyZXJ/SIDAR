#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script with sudo on the workstation." >&2
  exit 1
fi

SIDAR_USER="${SIDAR_USER:-siny}"
SIDAR_REPO_DIR="${SIDAR_REPO_DIR:-/home/siny/Repos/SIDAR}"
SIDAR_OUTPUT_DIR="${SIDAR_OUTPUT_DIR:-/data/sidar/scenes}"
SIDAR_RECEIVER_HOST="${SIDAR_RECEIVER_HOST:-10.66.66.3}"
SIDAR_RECEIVER_PORT="${SIDAR_RECEIVER_PORT:-8765}"
SIDAR_VALIDATE="${SIDAR_VALIDATE:-true}"

if ! id "$SIDAR_USER" >/dev/null 2>&1; then
  echo "User does not exist: $SIDAR_USER" >&2
  exit 1
fi

if [[ ! -d "$SIDAR_REPO_DIR" ]]; then
  cat >&2 <<EOF
Repository directory does not exist: $SIDAR_REPO_DIR

Clone SIDAR on the workstation first, for example:
  sudo -u "$SIDAR_USER" git clone https://github.com/SinyZXJ/SIDAR.git "$SIDAR_REPO_DIR"
EOF
  exit 1
fi

USER_HOME="$(getent passwd "$SIDAR_USER" | cut -d: -f6)"
CONFIG_DIR="$USER_HOME/.config/sidar"
ENV_FILE="$CONFIG_DIR/receiver.env"
VENV_DIR="$SIDAR_REPO_DIR/.venv"
SERVICE_FILE="/etc/systemd/system/sidar-receiver.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="$ROOT_DIR/deploy/sidar-receiver.service.template"

existing_token=""
if [[ -f "$ENV_FILE" ]]; then
  existing_token="$(grep -E '^SIDAR_TOKEN=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true)"
fi

TOKEN_WAS_GENERATED=0
if [[ -z "${SIDAR_TOKEN:-}" ]]; then
  if [[ -n "$existing_token" ]]; then
    SIDAR_TOKEN="$existing_token"
  else
    SIDAR_TOKEN="$(openssl rand -hex 24)"
    TOKEN_WAS_GENERATED=1
  fi
fi

case "${SIDAR_VALIDATE,,}" in
  1|true|yes|on)
    SIDAR_VALIDATE_FLAG="--validate"
    ;;
  0|false|no|off)
    SIDAR_VALIDATE_FLAG=""
    ;;
  *)
    echo "SIDAR_VALIDATE must be true or false, got: $SIDAR_VALIDATE" >&2
    exit 1
    ;;
esac

apt-get update
apt-get install -y \
  bash \
  build-essential \
  ca-certificates \
  curl \
  git \
  openssl \
  python3 \
  python3-dev \
  python3-pip \
  python3-venv

mkdir -p "$SIDAR_OUTPUT_DIR" "$CONFIG_DIR"
chown -R "$SIDAR_USER:$SIDAR_USER" "$SIDAR_OUTPUT_DIR" "$CONFIG_DIR"

runuser -u "$SIDAR_USER" -- python3 -m venv "$VENV_DIR"
runuser -u "$SIDAR_USER" -- "$VENV_DIR/bin/python" -m pip install -U pip
runuser -u "$SIDAR_USER" -- "$VENV_DIR/bin/python" -m pip install -e "$SIDAR_REPO_DIR"

cat >"$ENV_FILE" <<EOF
SIDAR_USER="$SIDAR_USER"
SIDAR_REPO_DIR="$SIDAR_REPO_DIR"
SIDAR_OUTPUT_DIR="$SIDAR_OUTPUT_DIR"
SIDAR_RECEIVER_HOST="$SIDAR_RECEIVER_HOST"
SIDAR_RECEIVER_PORT="$SIDAR_RECEIVER_PORT"
SIDAR_TOKEN="$SIDAR_TOKEN"
SIDAR_VALIDATE="$SIDAR_VALIDATE"
EOF
chown "$SIDAR_USER:$SIDAR_USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

if [[ -f "$TEMPLATE_FILE" ]]; then
  sed \
    -e "s|{{SIDAR_USER}}|$SIDAR_USER|g" \
    -e "s|{{SIDAR_REPO_DIR}}|$SIDAR_REPO_DIR|g" \
    -e "s|{{SIDAR_OUTPUT_DIR}}|$SIDAR_OUTPUT_DIR|g" \
    -e "s|{{SIDAR_RECEIVER_HOST}}|$SIDAR_RECEIVER_HOST|g" \
    -e "s|{{SIDAR_RECEIVER_PORT}}|$SIDAR_RECEIVER_PORT|g" \
    -e "s|{{SIDAR_VALIDATE_FLAG}}|$SIDAR_VALIDATE_FLAG|g" \
    "$TEMPLATE_FILE" >"$SERVICE_FILE"
else
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=SIDAR phone scene receiver
After=network-online.target wg-quick@wg0.service
Wants=network-online.target
Requires=wg-quick@wg0.service

[Service]
Type=simple
User=$SIDAR_USER
EnvironmentFile=$ENV_FILE
WorkingDirectory=$SIDAR_REPO_DIR
ExecStart=/bin/bash -lc 'exec "\$SIDAR_REPO_DIR/.venv/bin/phone-scene" receive --output-dir "\$SIDAR_OUTPUT_DIR" --host "\$SIDAR_RECEIVER_HOST" --port "\$SIDAR_RECEIVER_PORT" --token "\$SIDAR_TOKEN" $SIDAR_VALIDATE_FLAG'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable --now sidar-receiver

cat <<EOF

SIDAR receiver installed.
Service:
  systemctl status sidar-receiver --no-pager -l
  journalctl -u sidar-receiver -f

Receiver token:
  $SIDAR_TOKEN

Token env file:
  $ENV_FILE

Workstation test commands:
  curl http://$SIDAR_RECEIVER_HOST:$SIDAR_RECEIVER_PORT/health
  curl -H "X-SIDAR-Token: $SIDAR_TOKEN" http://$SIDAR_RECEIVER_HOST:$SIDAR_RECEIVER_PORT/api/uploads/auth-check
EOF

if [[ "$TOKEN_WAS_GENERATED" -eq 1 ]]; then
  cat <<'EOF'

A new SIDAR_TOKEN was generated. Save it somewhere private and enter it in the iPhone app Upload Settings.
EOF
fi
