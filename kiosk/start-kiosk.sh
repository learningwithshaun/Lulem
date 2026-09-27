#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Lulem in-store kiosk launcher (Raspberry Pi).
#
# Starts Chromium in full kiosk mode showing ONLY the Lumen signage UI and
# keeps it running forever:
#   * waits for the FastAPI backend so a boot race never shows an error page
#   * relaunches Chromium automatically if it crashes or is closed
#   * hides the mouse cursor (unclutter) and stops the screen blanking/sleeping
#   * opens the display with `?kiosk=1` so frontend/kiosk-guard.js locks the
#     page down (no right-click menu, no breakout shortcuts, no navigation)
#
# Environment overrides:
#   DISPLAY_URL           Base URL of the FastAPI server
#                         (default http://127.0.0.1:8000)
#   KIOSK_RESTART_SECONDS Delay between relaunches after a crash (default 3)
# ============================================================================
DISPLAY_URL="${DISPLAY_URL:-http://127.0.0.1:8000}"
RESTART_SECONDS="${KIOSK_RESTART_SECONDS:-3}"
KIOSK_URL="${DISPLAY_URL%/}/?kiosk=1"

log() { echo "[lulem-kiosk] $*"; }

# 1. Locate Chromium (the package name changed across Raspberry Pi OS versions).
CHROMIUM=""
for candidate in chromium chromium-browser google-chrome-stable; do
  if command -v "$candidate" >/dev/null 2>&1; then
    CHROMIUM="$candidate"
    break
  fi
done
if [ -z "$CHROMIUM" ]; then
  log "ERROR: no Chromium binary found. Install it with: sudo apt install chromium"
  exit 1
fi
log "Using browser: $CHROMIUM"

# 2. Wait for the backend (max ~2 minutes) before showing anything.
log "Waiting for backend at $DISPLAY_URL ..."
backend_up=false
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 -o /dev/null "$DISPLAY_URL/api/media" 2>/dev/null; then
    backend_up=true
    break
  fi
  sleep 2
done
if [ "$backend_up" = true ]; then
  log "Backend is up."
else
  log "WARN: backend not reachable yet; launching anyway (it may still be starting)."
fi

# 3. Session comfort. Guarded so the script also works under a Wayland session
#    where xset/unclutter are unavailable (no-ops on purpose).
if command -v unclutter >/dev/null 2>&1; then
  unclutter -idle 1 -root >/dev/null 2>&1 &
fi
xset s off >/dev/null 2>&1 || true
xset s noblank >/dev/null 2>&1 || true
xset -dpms >/dev/null 2>&1 || true

# 4. Run Chromium forever, restarting whenever it exits for any reason.
while true; do
  set +e
  "$CHROMIUM" \
    --kiosk \
    --fullscreen \
    --noerrdialogs \
    --test-type \
    --no-first-run \
    --no-default-browser-check \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --hide-crash-restore-bubble \
    --disable-translate \
    --disable-features=Translate,TranslateUI \
    --disable-notifications \
    --disable-pinch \
    --overscroll-history-navigation=0 \
    --autoplay-policy=no-user-gesture-required \
    --disable-dev-shm-usage \
    --hide-scrollbars \
    --password-store=basic \
    --check-for-update-interval=31536000 \
    --ozone-platform-hint=auto \
    "$KIOSK_URL"
  rc=$?
  set -e
  log "Chromium exited (code ${rc}); restarting in ${RESTART_SECONDS}s."
  sleep "$RESTART_SECONDS"
done


