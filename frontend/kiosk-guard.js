/* ============================================================================
 * kiosk-guard.js — page-level lockdown for the in-store display.
 *
 * The script is always loaded, but it only activates when the URL carries
 * `kiosk=1` (the Raspberry Pi launcher in kiosk/start-kiosk.sh appends it),
 * so normal browser development is completely unaffected.
 *
 * Layers of defence when active:
 *   1. Context menu, text selection and drag-start are blocked, so ad artwork
 *      cannot be right-click saved, copied or dragged off the screen.
 *   2. Breakout keyboard shortcuts are swallowed (fullscreen toggle, devtools,
 *      tab/window/address-bar shortcuts, Alt+arrow navigation, zoom).
 *      Note: Chromium itself still owns a handful of reserved combos; the
 *      browser `--kiosk` flags and unplugged peripherals are the outer layers
 *      of defence — this script is the inner one.
 *   3. window.open is neutralised so nothing can spawn a new tab or window.
 *   4. History is guarded so Back/Forward can never navigate off the display.
 *   5. Scheduled self-heal reload (default every 6 hours, override with
 *      `&reload_hours=N`, `0` disables) so a wedged player, leaked memory or
 *      crashed YouTube iframe always recovers on its own — an in-store screen
 *      must never stay stuck on a broken frame.
 * ========================================================================== */
(() => {
  "use strict";

  const params = new URLSearchParams(window.location.search);
  const kioskParam = (params.get("kiosk") || "").toLowerCase();
  if (kioskParam !== "1" && kioskParam !== "true") return;

  // ── 0. Cursor suppression ──────────────────────────────────────────────────
  // The kiosk page fills 100% of the screen, so hiding the cursor here works
  // on both X11 and Wayland without X11-only tools (unclutter is a no-op on
  // Bookworm's labwc/Wayland session). Known limit: the cross-origin YouTube
  // iframe draws its own cursor — leave the mouse unplugged in store.
  const cursorStyle = document.createElement("style");
  cursorStyle.textContent = "html, body, body * { cursor: none !important; }";
  document.head.appendChild(cursorStyle);

  // ── 1. Pointer lockdown ────────────────────────────────────────────────────
  ["contextmenu", "selectstart", "dragstart"].forEach((type) => {
    document.addEventListener(type, (event) => event.preventDefault());
  });

  // ── 2. Keyboard lockdown ───────────────────────────────────────────────────
  // Keys blocked even without modifiers (all lowercase — compared against
  // event.key.toLowerCase()).
  const BLOCKED_KEYS = new Set(["f11", "f12", "escape", "tab"]);
  // Ctrl/Alt combinations that could alter or escape the kiosk view.
  const BLOCKED_COMBOS = [
    { ctrl: true, shift: false, alt: false, keys: ["w", "t", "n", "l", "o", "p", "s", "j", "k"] },
    { ctrl: true, shift: true, alt: false, keys: ["i", "n", "w", "t", "j", "p"] },
    { ctrl: false, shift: false, alt: true, keys: ["arrowleft", "arrowright", "arrowup", "arrowdown", "f4", "d", " ", "tab"] }
  ];
  // Zoom shortcuts: Ctrl + "+", "=", "-", "_", "0".
  const ZOOM_KEYS = new Set(["+", "=", "-", "_", "0"]);

  document.addEventListener("keydown", (event) => {
    const key = (event.key || "").toLowerCase();
    const ctrl = event.ctrlKey || event.metaKey; // metaKey covers Linux Super/Mac Cmd.
    const alt = event.altKey;
    const shift = event.shiftKey;

    if (ctrl && !alt && ZOOM_KEYS.has(key)) {
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    for (const combo of BLOCKED_COMBOS) {
      if (combo.ctrl === ctrl && combo.alt === alt && combo.shift === shift && combo.keys.includes(key)) {
        event.preventDefault();
        event.stopPropagation();
        return;
      }
    }
    if (!ctrl && !alt && BLOCKED_KEYS.has(key)) {
      event.preventDefault();
      event.stopPropagation();
    }
  }, true);

  // ── 3. No new windows ──────────────────────────────────────────────────────
  window.open = () => null;

  // ── 4. History guard: Back/Forward can never leave the display ─────────────
  try {
    history.replaceState(null, "", window.location.href);
    window.addEventListener("popstate", () => {
      history.pushState(null, "", window.location.href);
    });
  } catch (error) {
    console.warn("[kiosk] History guard unavailable:", error);
  }

  // ── 5. Scheduled self-heal reload ──────────────────────────────────────────
  const parsedHours = parseFloat(params.get("reload_hours"));
  const reloadHours = Number.isFinite(parsedHours) ? parsedHours : 6;
  if (reloadHours > 0) {
    const reloadInMs = reloadHours * 60 * 60 * 1000;
    console.info(`[kiosk] Locked-down kiosk mode active; self-heal reload every ${reloadHours}h.`);
    window.setInterval(() => window.location.reload(), reloadInMs);
  } else {
    console.info("[kiosk] Locked-down kiosk mode active; scheduled reload disabled.");
  }
})();
