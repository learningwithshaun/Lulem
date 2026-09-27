#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Lulem kiosk installer — turns a Raspberry Pi OS install into a locked-down
# in-store advertising display (boots straight into the ads, no desktop, no
# way for customers to close or minimise anything).
#
# Usage (from anywhere on the Pi):
#   sudo ./kiosk/setup-kiosk.sh
#
# What it does (idempotent — safe to re-run):
#   1. Installs Chromium, unclutter, xset, curl and the Python environment
#   2. Installs + enables the lulem-backend systemd service (FastAPI on :8000)
#   3. Enables desktop auto-login so the kiosk session starts at every boot
#   4. Adds start-kiosk.sh to the desktop session autostart (X11 and Wayland)
#   5. Stops the OS from ever blanking or sleeping the screen
#   6. Installs kiosk.service as an optional alternative launcher (disabled)
# ============================================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "This installer must run as root:  sudo $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
KIOSK_USER="${SUDO_USER:-}"
if [ -z "$KIOSK_USER" ] || [ "$KIOSK_USER" = "root" ]; then
  KIOSK_USER="pi"
fi
KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
if [ -z "$KIOSK_HOME" ]; then
  echo "Could not resolve the home directory for user '$KIOSK_USER'." >&2
  exit 1
fi

echo "==> Repository: $REPO_DIR"
echo "==> Kiosk user: $KIOSK_USER ($KIOSK_HOME)"

# ── 1. Packages ──────────────────────────────────────────────────────────────
echo "==> Installing system packages"
apt-get update -y
apt-get install -y curl unclutter x11-xserver-utils
# The Chromium package name differs across Raspberry Pi OS versions.
apt-get install -y chromium || apt-get install -y chromium-browser

echo "==> Preparing Python environment"
apt-get install -y python3-venv python3-pip
if [ ! -x "$REPO_DIR/.venv/bin/python" ]; then
  python3 -m venv "$REPO_DIR/.venv"
fi
"$REPO_DIR/.venv/bin/pip" install --upgrade pip >/dev/null
"$REPO_DIR/.venv/bin/pip" install -r "$REPO_DIR/backend/requirements.txt"
# gpiozero is only needed for GPIO_MODE=real, but this IS a Raspberry Pi.
"$REPO_DIR/.venv/bin/pip" install gpiozero >/dev/null

if [ ! -f "$REPO_DIR/.env" ] && [ -f "$REPO_DIR/.env.example" ]; then
  echo "==> Creating .env from .env.example"
  cp "$REPO_DIR/.env.example" "$REPO_DIR/.env"
fi

# ── 2. systemd services ──────────────────────────────────────────────────────
echo "==> Installing systemd units"
render_unit() {
  local template="$1" target="$2"
  sed -e "s|{{REPO_DIR}}|$REPO_DIR|g" \
      -e "s|{{KIOSK_USER}}|$KIOSK_USER|g" \
      -e "s|{{KIOSK_HOME}}|$KIOSK_HOME|g" \
      "$template" > "$target"
}
render_unit "$SCRIPT_DIR/lulem-backend.service" /etc/systemd/system/lulem-backend.service
render_unit "$SCRIPT_DIR/kiosk.service" /etc/systemd/system/kiosk.service
# kiosk.service is an ALTERNATIVE launcher for X11-only setups; the session
# autostart below owns the browser by default so we do not run two Chromium
# instances. Leave it installed but disabled.
systemctl disable kiosk.service >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable lulem-backend.service
systemctl restart lulem-backend.service

# ── 3. Desktop auto-login ────────────────────────────────────────────────────
echo "==> Enabling desktop auto-login"
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_boot_behaviour B4 || true
fi

# ── 4. Session autostart: launch the kiosk on every login ────────────────────
echo "==> Configuring session autostart"
chmod +x "$SCRIPT_DIR"/*.sh

append_once() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  touch "$file"
  for line in "$@"; do
    grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
  done
  chown "$KIOSK_USER" "$file"
  chgrp "$KIOSK_USER" "$file" 2>/dev/null || true
}

# LXDE session (Raspberry Pi OS up to Bullseye / X11). Lines need the "@"
# prefix that lxsession understands. The launcher itself starts unclutter and
# the xset calls again, but pre-login lines make the session safe even if the
# script is stopped for maintenance.
append_once "$KIOSK_HOME/.config/lxsession/LXDE-pi/autostart" \
  "@xset s off" \
  "@xset -dpms" \
  "@xset s noblank" \
  "@$SCRIPT_DIR/kiosk/start-kiosk.sh"

# labwc session (Raspberry Pi OS Bookworm+ / Wayland). Plain command lines.
append_once "$KIOSK_HOME/.config/labwc/autostart" \
  "$SCRIPT_DIR/kiosk/start-kiosk.sh"

# ── 5. Never blank or sleep ──────────────────────────────────────────────────
echo "==> Disabling idle blanking / sleep (logind)"
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-lulem-noidle.conf <<'EOF'
[Login]
IdleAction=ignore
EOF
systemctl restart systemd-logind || true

# ── 6. Copy the ads data the display will play ───────────────────────────────
if [ ! -f "$REPO_DIR/frontend/media.json" ]; then
  echo "WARN: frontend/media.json is missing — the display has nothing to play." >&2
fi

echo
echo "=============================================================="
echo " Lulem kiosk setup complete."
echo
echo " Reboot to start the display:     sudo reboot"
echo " Backend status:                   systemctl status lulem-backend"
echo " Kiosk launcher output:            tail -f ~/.xsession-errors   (as $KIOSK_USER)"
echo " Stop everything for maintenance:  sudo systemctl stop lulem-backend"
echo " Full guide:                       $REPO_DIR/kiosk/README.md"
echo "=============================================================="
