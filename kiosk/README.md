# Lulem in-store kiosk (Raspberry Pi)

This folder turns a Raspberry Pi plugged into a TV/monitor into a
McDonald's-style advertising screen: it boots straight into the Lumen display,
plays only your ads, and nobody at the screen can close, minimise, navigate
away from or otherwise control it.

## How it works — three layers of lockdown

| Layer | File | What it stops |
| --- | --- | --- |
| **Browser** | `start-kiosk.sh` | Chromium runs in `--kiosk` fullscreen mode with no tabs, no address bar, no dialogs, no crash-restore bubbles, no translate popups. If Chromium exits for any reason it is relaunching within 3 seconds. The mouse cursor is hidden and the screen never blanks/sleeps. |
| **Page** | `../frontend/kiosk-guard.js` (activated by `?kiosk=1`) | Right-click menu, text selection, drag-and-drop of ad artwork, breakout keyboard shortcuts (F11/F12/Escape/Ctrl+W/T/N/Alt+arrow/zoom), `window.open`, and Back/Forward navigation are all blocked. A **self-heal reload every 6 hours** guarantees a wedged player or crashed YouTube iframe recovers on its own. |
| **OS** | `setup-kiosk.sh` + systemd | Desktop auto-login, kiosk launched on every login, `lulem-backend.service` keeps FastAPI alive across crashes and power cuts, and systemd/logind are configured so the machine never idles to sleep. With no keyboard or mouse plugged in (recommended), there is simply no way to interact with it. |

## Requirements

- Raspberry Pi (3 or newer recommended) with Raspberry Pi OS (Bookworm or newer)
- A monitor/TV connected over HDMI
- Network (Ethernet preferred) so ads and YouTube load
- A second device for setup (SSH or keyboard, temporarily)

## Install (once)

```bash
cd ~/Lulem          # or wherever the repo lives
git pull
sudo ./kiosk/setup-kiosk.sh
sudo reboot
```

(If the scripts are not executable on your checkout, run
`sudo bash ./kiosk/setup-kiosk.sh` instead — the repo's `.gitattributes` and
executable bits should make the direct form work.)

The installer is idempotent — re-run it after pulling updates if anything in
`kiosk/` changes.

After reboot you should see: desktop auto-login → Chromium fullscreen on your
`http://127.0.0.1:8000/?kiosk=1` display → ads playing. Nothing else.

## What the store staff / customers can (and cannot) do

- **Cannot:** close the window, minimise it, open a tab, see the address bar,
  right-click, Alt+Tab away, reload to something else, or reach a desktop.
- **Can:** nothing, if you follow the physical lockdown advice below.

### Physical lockdown (recommended, do this)

1. **Do not leave a keyboard or mouse plugged into the Pi.** Setup happens
   over SSH; the in-store unit needs no input devices.
2. If ports must stay open, tuck the Pi behind the TV where customers cannot
   reach it, or use a case with covered USB ports.
3. Power: plug the Pi into a socket the public cannot switch off.

## Day-to-day operations

Everything runs automatically. Useful commands (over SSH):

```bash
# Backend status / logs
systemctl status lulem-backend
journalctl -u lulem-backend -f

# Update the ads or code
cd ~/Lulem && git pull
sudo systemctl restart lulem-backend

# Take the screen down for maintenance (Chromium keeps running)
sudo systemctl stop lulem-backend

# Bring it back
sudo systemctl start lulem-backend

# Hard-restart the whole display
sudo reboot
```

To temporarily get a normal desktop on the Pi for debugging: SSH in and remove
the `@.../kiosk/start-kiosk.sh` line from
`~/.config/labwc/autostart` (Bookworm/Wayland) or
`~/.config/lxsession/LXDE-pi/autostart` (older/X11), then log out and back in.

## Configuration

| Setting | Where | Default |
| --- | --- | --- |
| Backend URL | `DISPLAY_URL` env var passed to `start-kiosk.sh` / `kiosk.service` | `http://127.0.0.1:8000` |
| Self-heal reload interval | URL: `?kiosk=1&reload_hours=N` (`0` disables) | `6` hours |
| Restart delay after a Chromium crash | `KIOSK_RESTART_SECONDS` env var | `3` seconds |
| Content (ads, durations, playlists) | `frontend/media.json` or Zuke `/api/display-ads/export` | see main README |

The display URL deliberately carries `?kiosk=1` — without it
`kiosk-guard.js` stays inert so normal browser development is unaffected.

## Alternative launcher: systemd (`kiosk.service`)

By default the browser is started by the **desktop session autostart**, which
works on both X11 and Wayland (Bookworm default). `kiosk.service` is an
alternative for X11-only setups that prefer systemd supervision — **do not run
both launchers at once** or you would get two Chromium instances.
`setup-kiosk.sh` renders the `{{REPO_DIR}}`/`{{KIOSK_USER}}`/`{{KIOSK_HOME}}`
placeholders into `/etc/systemd/system/kiosk.service` but leaves it disabled.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Black screen after boot | `systemctl status lulem-backend`; check HDMI/TV input; check `~/.xsession-errors` for launcher output |
| "Backend not reachable" in logs | Backend crashed — `journalctl -u lulem-backend -f`; confirm `frontend/media.json` exists |
| Screen blanks after a while | Re-run `sudo ./kiosk/setup-kiosk.sh` (logind IdleAction) and disable *Screen Blanking* in `raspi-config` → Display Options |
| YouTube never plays | Needs internet; check `youtube_playlist_id` in `frontend/media.json` and outbound HTTPS |
| Need to see what the page sees | Open the same URL in a desktop browser: `http://<pi-ip>:8000/?kiosk=1` |

## Known limits

- A few Chromium-reserved shortcut combos are owned by the browser, not the
  page. In practice this is irrelevant when no keyboard is attached; the
  `--kiosk` flags and page guard cover everything reachable from the screen.
- If someone has physical **and** SSH access to the Pi, no software kiosk can
  stop them — that is an inventory/security problem, not a software one.
- SD cards wear over years of 24/7 operation; use a quality card and hold OS
  auto-updates (`sudo apt-mark hold chromium`).

