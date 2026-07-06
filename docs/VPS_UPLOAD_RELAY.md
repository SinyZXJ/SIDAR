# SIDAR VPS Upload Relay

This guide deploys a public HTTP upload endpoint on a small VPS while keeping all
`.phonescene` data on the Ubuntu workstation.

## Architecture

```text
iPhone SIDAR App
    |
    v
http://45.32.115.105:8765
    |
    | Nginx streaming reverse proxy on VPS
    v
http://10.66.66.3:8765
    |
    | phone-scene receive on workstation
    v
/data/sidar/scenes
```

The VPS is only a public entrypoint and streaming relay. It should not run
`phone-scene receive`, and it should not store full multi-GB scene uploads.

## Prerequisites

- VPS has a public IP: `45.32.115.105`.
- VPS and workstation are connected by WireGuard.
- VPS WireGuard IP: `10.66.66.1`.
- Workstation WireGuard IP: `10.66.66.3`.
- Mac WireGuard IP: `10.66.66.2`.
- iPhone does not need WireGuard. It only needs to reach the public VPS.
- Workstation must be online, and WireGuard must be active.
- Workstation has enough disk space under `/data/sidar/scenes`.

Do not commit WireGuard private keys, generated receiver tokens, passwords, or
other secrets to Git.

## Workstation Deployment

Run this on the Ubuntu workstation, not on the VPS.

```bash
sudo mkdir -p /home/siny/Repos
sudo chown -R siny:siny /home/siny/Repos
sudo -u siny git clone https://github.com/SinyZXJ/SIDAR.git /home/siny/Repos/SIDAR
cd /home/siny/Repos/SIDAR
sudo scripts/install_sidar_receiver_workstation.sh
```

The script installs Python dependencies, creates `/data/sidar/scenes`, creates a
venv under `/home/siny/Repos/SIDAR/.venv`, writes
`/home/siny/.config/sidar/receiver.env`, and starts `sidar-receiver.service`.

If `SIDAR_TOKEN` is not provided, the script generates one and prints it. Save
that token privately; it is the value you will enter in the iPhone app.

Optional configuration:

```bash
sudo SIDAR_USER=siny \
  SIDAR_REPO_DIR=/home/siny/Repos/SIDAR \
  SIDAR_OUTPUT_DIR=/data/sidar/scenes \
  SIDAR_RECEIVER_HOST=10.66.66.3 \
  SIDAR_RECEIVER_PORT=8765 \
  SIDAR_VALIDATE=true \
  scripts/install_sidar_receiver_workstation.sh
```

Inspect the service:

```bash
systemctl status sidar-receiver --no-pager -l
journalctl -u sidar-receiver -f
```

Read the token if needed:

```bash
sudo grep SIDAR_TOKEN /home/siny/.config/sidar/receiver.env
```

Test on the workstation:

```bash
curl http://10.66.66.3:8765/health
curl -H "X-SIDAR-Token: <TOKEN>" \
  http://10.66.66.3:8765/api/uploads/auth-check
```

Both commands should return JSON with `"status": "ok"`.

## VPS Deployment

Run this on the Vultr Ubuntu VPS.

```bash
cd /opt/SIDAR
sudo scripts/install_sidar_vps_proxy.sh
```

The script installs Nginx and writes `/etc/nginx/sites-available/sidar`.

Optional configuration:

```bash
sudo SIDAR_PUBLIC_PORT=8765 \
  SIDAR_BACKEND_HOST=10.66.66.3 \
  SIDAR_BACKEND_PORT=8765 \
  SIDAR_SERVER_NAME=_ \
  scripts/install_sidar_vps_proxy.sh
```

Inspect Nginx:

```bash
nginx -t
systemctl status nginx --no-pager -l
```

Test on the VPS:

```bash
curl http://127.0.0.1:8765/health
curl -H "X-SIDAR-Token: <TOKEN>" \
  http://127.0.0.1:8765/api/uploads/auth-check
```

Test from the Mac or any external device:

```bash
curl http://45.32.115.105:8765/health
curl -H "X-SIDAR-Token: <TOKEN>" \
  http://45.32.115.105:8765/api/uploads/auth-check
```

## iPhone App Settings

Open SIDAR on the iPhone:

```text
Gallery -> Upload Settings
```

Use:

```text
Receiver URL: http://45.32.115.105:8765
Token:        <TOKEN from /home/siny/.config/sidar/receiver.env>
```

Tap **Test Receiver** first. If it succeeds, upload a small scene before trying
a large scan.

## Large File Notes

The Nginx relay is configured for streaming uploads:

- `proxy_request_buffering off`
- `proxy_buffering off`
- `client_max_body_size 0`
- upload/read/send timeouts set to `3600s`

This is important because the VPS should not cache complete scene files before
forwarding them to the workstation.

Watch receiver progress on the workstation:

```bash
journalctl -u sidar-receiver -f
```

The final scene appears under:

```text
/data/sidar/scenes/<scene_name>.phonescene
```

## Security Notes

- This HTTP setup sends the token and scene data in plaintext.
- It is acceptable for short-term testing on a controlled endpoint.
- For long-term use, buy a domain and place HTTPS in front of the same Nginx
  relay, for example `https://upload.example.com`.
- Never commit `SIDAR_TOKEN`, WireGuard private keys, server passwords, or
  generated configs containing secrets to Git.
- Later hardening can add rate limiting, fail2ban, or additional auth, but the
  initial deployment intentionally stays simple.

## Troubleshooting

### iPhone Test Receiver Fails

Test each hop:

```bash
# Mac or another external device
curl http://45.32.115.105:8765/health

# VPS
curl http://10.66.66.3:8765/health

# Workstation
curl http://10.66.66.3:8765/health
```

If only the public URL fails, check VPS firewall rules and Nginx.
If the VPS cannot reach `10.66.66.3`, check WireGuard and the workstation
receiver service.

### Auth Check Fails

Verify the token:

```bash
sudo grep SIDAR_TOKEN /home/siny/.config/sidar/receiver.env
curl -H "X-SIDAR-Token: <TOKEN>" \
  http://45.32.115.105:8765/api/uploads/auth-check
```

The header name must be `X-SIDAR-Token`, and the iPhone token must match the
workstation token exactly.

### Small Files Work, Large Files Fail

Check:

- iOS upload request timeout is long enough.
- Nginx has `proxy_request_buffering off`.
- Nginx has `proxy_read_timeout`, `proxy_send_timeout`, and
  `client_body_timeout` set to `3600s`.
- WireGuard stayed connected during the upload.
- Workstation disk has enough space.

### Upload Completes But Files Are Missing

Check:

```bash
ls -lah /data/sidar/scenes
ls -lah /data/sidar/scenes/.sidar_uploads
journalctl -u sidar-receiver -n 200 --no-pager
```

Staging uploads live under `.sidar_uploads` until `/api/uploads/finish`
validates and moves the scene into place.

### 502 Bad Gateway

Likely causes:

- `sidar-receiver` is not running.
- WireGuard is down.
- `10.66.66.3:8765` is not reachable from the VPS.

Run:

```bash
systemctl status sidar-receiver --no-pager -l
curl http://10.66.66.3:8765/health
```

### 413 Request Entity Too Large

Nginx is missing:

```nginx
client_max_body_size 0;
```

Re-run `scripts/install_sidar_vps_proxy.sh`, then `nginx -t` and reload Nginx.
