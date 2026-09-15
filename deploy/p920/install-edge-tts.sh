#!/usr/bin/env bash
# Run this once on P920. It installs the reader's existing Edge TTS endpoint
# as a user service and privately exposes it to this Tailscale tailnet.
set -euo pipefail

APP_DIR="${EDGE_TTS_APP_DIR:-$HOME/reader-edge-tts}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/reader-edge-tts.service"
TTS_PORT="${EDGE_TTS_PORT:-8767}"
SERVE_PORT="${EDGE_TTS_SERVE_PORT:-8443}"

command -v python3 >/dev/null || { echo 'python3 is required.' >&2; exit 1; }
command -v tailscale >/dev/null || { echo 'tailscale is required.' >&2; exit 1; }

mkdir -p "$APP_DIR" "$SERVICE_DIR"
install -m 0644 "$SOURCE_DIR/scripts/reader_app_server.py" "$APP_DIR/reader_app_server.py"
install -m 0644 "$SOURCE_DIR/requirements.txt" "$APP_DIR/requirements.txt"

python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --disable-pip-version-check --quiet -r "$APP_DIR/requirements.txt"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ReadMaster Edge TTS service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=$APP_DIR/.venv/bin/python $APP_DIR/reader_app_server.py $APP_DIR $TTS_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now reader-edge-tts.service
# Keep the user service alive after logout and across reboots when the host
# permits user-managed lingering.
loginctl enable-linger "$USER" 2>/dev/null || echo 'Warning: could not enable user lingering; the service may need a login after reboot.' >&2

# Use a dedicated HTTPS port so a pre-existing Serve configuration on 443 is
# never overwritten. This remains private to the tailnet; it is not Funnel.
# Some Linux installations require sudo unless `tailscale set --operator` was
# configured, so retry with sudo when the user-level command is rejected.
tailscale serve --bg --https="$SERVE_PORT" "http://127.0.0.1:$TTS_PORT" \
  || sudo tailscale serve --bg --https="$SERVE_PORT" "http://127.0.0.1:$TTS_PORT"

echo
echo 'Edge TTS service is ready:'
tailscale serve status
echo "Health endpoint: https://p920.tail1462ad.ts.net:$SERVE_PORT/api/tts/edge"
