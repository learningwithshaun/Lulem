#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Lulem in-store kiosk launcher (Raspberry Pi).
#
# Covers the screen IMMEDIATELY with the black kiosk splash page and keeps
# Chromium running forever:
#   * kiosk/splash.html loads from file:// and paints the screen black from
#     the first second — the desktop is never visible while the FastAPI
#     backend starts, and an outage can never flash an error page at startup
#   * the splash polls the backend and navigates to `/?kiosk=1` when it is up
#   * relaunches Chromium automatically if it crashes or is closed
#   * uses a dedicated throwaway profile, so session-restore, extensions and
#     first-run dialogs can never turn the kiosk into a normal window
#   * hides the mouse cursor (unclutter on X11, page CSS on Wayland) and
#     stops the screen blanking/sleeping
#   * frontend/kiosk-guard.js locks the page down (no right-click menu, no
#     breakout shortcuts, no navigation) once `?kiosk=1` is active
#
# Environment overrides:
#   DISPLAY_URL           Base URL of the FastAPI server
#                         (default http://127.0.0.1:8000)
#   KIOSK_RESTART_SECONDS Delay between relaunches after a crash (default 3)
# ============================================================================
DISPLAY_URL="${DISPLAY_URL:-http://127.0.0.1:8000}"
RESTART_SECONDS="${KIOSK_RESTART_SECONDS:-3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The splash page receives the backend URL as `?next=` and redirects there
# once the backend answers. Spaces in the script path are percent-encoded for
# the file:// URL; DISPLAY_URL is appended verbatim (assume a plain
# host[:port][/path] URL without "&" or "#").
SPLASH_URL="file://${SCRIPT_DIR}/splash.html?next=${DISPLAY_URL}"
SPLASH_URL="${SPLASH_URL// /%20}"
PROFILE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/lulem-kiosk"

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

# 2. Backend status is reported from the background while the screen is
#    already covered: splash.html polls $DISPLAY_URL itself and navigates to
#    the display the moment the backend answers, so startup never exposes the
#    desktop or a Chromium error page.
mkdir -p "$PROFILE_DIR" 2>/dev/null || true
(
  log "Polling backend at $DISPLAY_URL in the background (splash covers the screen)..."
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 -o /dev/null "$DISPLAY_URL/api/media" 2>/dev/null; then
      log "Backend is up."
      exit 0
    fi
    sleep 2
  done
  log "WARN: backend not reachable after 2 minutes; splash keeps polling."
) &

# 3. Session comfort. Guarded so the script also works under a Wayland session
#    where xset/unclutter are unavailable (no-ops on purpose). xsetroot gives
#    X11 a black backdrop during the rare Chromium relaunch gap now that the
#    panel/desktop managers are removed from the session autostart.
if command -v unclutter >/dev/null 2>&1; then
  unclutter -idle 1 -root >/dev/null 2>&1 &
fi
xset s off >/dev/null 2>&1 || true
xset s noblank >/dev/null 2>&1 || true
xset -dpms >/dev/null 2>&1 || true
xsetroot -solid '#000000' >/dev/null 2>&1 || true

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
    --user-data-dir="$PROFILE_DIR" \
    "$SPLASH_URL"
  rc=$?
  set -e
  log "Chromium exited (code ${rc}); restarting in ${RESTART_SECONDS}s."
  sleep "$RESTART_SECONDS"
done


