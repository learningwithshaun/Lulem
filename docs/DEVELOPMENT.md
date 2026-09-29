# Lumen (Lulem) — Developer Guide

A hands-on guide for developers working on **Lumen** (repository: `Lulem`), the
MVP digital-signage system for retail TVs. Read this together with
[`README.md`](../README.md) (quickstart & deployment) and
[`API.md`](API.md) (data contract & API reference).

## Table of contents

1. [System overview](#1-system-overview)
2. [Repository layout](#2-repository-layout)
3. [Local development environment](#3-local-development-environment)
4. [How the pieces fit together](#4-how-the-pieces-fit-together)
5. [Configuration reference](#5-configuration-reference)
6. [Testing](#6-testing)
7. [Code conventions](#7-code-conventions)
8. [Common developer tasks](#8-common-developer-tasks)
9. [Deployment quick-reference](#9-deployment-quick-reference)
10. [Troubleshooting / FAQ](#10-troubleshooting--faq)
11. [Documentation index](#11-documentation-index)

---

## 1. System overview

Lumen is an MVP digital-signage application for retail TVs:

- A **TV signage frontend** (`frontend/`) plays eligible image/video adverts,
  overlays each one with a Paystack payment QR code, and switches to YouTube
  entertainment between advertising cycles (or whenever no valid ads exist).
- A **FastAPI backend** (`backend/`) serves the *validated* media configuration
  at `GET /api/media` and processes Paystack webhooks that can physically unlock
  a product shelf via GPIO.
- An optional **Raspberry Pi kiosk** (`kiosk/`) turns the frontend into a
  locked-down, self-healing in-store display.
- **Spark/Zuke** is the eventual advertising management platform that publishes
  campaign data. Until then the system runs in development mode using the local
  `frontend/media.json` contract, and can optionally poll Zuke's export
  endpoint through the subscription adapter.

### Component flow

```text
  Spark/Zuke platform (future)          local dev data
       │ campaigns                            │
       ▼ (poll every 30s)                     ▼
  subscription-adapter.js ◄──────────  frontend/media.json
       │                                      │
       └──────────► TV signage frontend ◄─────┼──── GET /api/media
                         ▲                    │
                         │                    ▼
                         │        FastAPI backend
                         │          (serves UI at "/")
                         │                    │
                         │                    ▼
                         │        POST /api/paystack/webhook
                         │                    │
                         │                    ▼
              …YouTube entertainment   ShelfService ─► GPIO relay unlock
                                       (real Pi) or mock controller
```

### Key invariants

- **Garbage never crashes the system.** Every layer validates defensively and
  falls back quietly: malformed JSON, missing fields, broken URLs, unpaid or
  inactive ads are filtered out rather than raised. See
  [Error handling](API.md#9-error-handling) in the API docs.
- **The frontend only renders what it trusts.** `frontend/app.js` re-validates
  media (`usable()`) even though the backend already validated it.
- **Ads are capped at a five-minute cycle.** `MAX_AD_CYCLE_MS` in
  `frontend/app.js` bounds how long advertising can run before returning to
  YouTube entertainment.
- **GPIO is never touched by accident.** Unlock requests only work for products
  mapped in `hardware/gpio_mapping.py`; everything else is rejected with a 422
  before any controller call.

---

## 2. Repository layout

```text
Lulem/
├── api/index.py                Vercel serverless entry point (imports backend.app.main:app)
├── backend/
│   ├── app/
│   │   ├── main.py             FastAPI app factory (create_app) + module-level `app`
│   │   ├── config/settings.py  Env-driven settings(.env) and path constants
│   │   ├── routes/
│   │   │   ├── media.py        GET /api/media
│   │   │   └── paystack.py     POST /api/paystack/webhook
│   │   └── services/
│   │       ├── media_service.py     Media contract validation + safe fallbacks
│   │       ├── paystack_service.py  Webhook HMAC signature + product_id extraction
│   │       └── shelf_service.py     product_id → GPIO pin unlock
│   └── requirements.txt
├── docs/
│   ├── API.md                  Data contract & API reference
│   └── DEVELOPMENT.md          ← this guide
├── frontend/                   Vanilla JS signage UI (no build step)
│   ├── index.html
│   ├── style.css
│   ├── app.js                  Playback engine
│   ├── subscription-adapter.js Transport seam (HTTP poll now, RabbitMQ later)
│   ├── kiosk-guard.js          Page lockdown (active only with ?kiosk=1)
│   └── media.json              Local development media contract
├── hardware/
│   ├── gpio_controller.py          Real Raspberry Pi relay controller (gpiozero)
│   ├── mock_gpio_controller.py     In-memory simulation for PC / cloud / tests
│   └── gpio_mapping.py             Authoritative product_id → GPIO pin map
├── kiosk/                      Raspberry Pi installer / launcher / systemd units
│   ├── setup-kiosk.sh
│   ├── start-kiosk.sh
│   ├── lulem-backend.service
│   ├── kiosk.service
│   └── README.md               Full kiosk guide
├── tests/
│   ├── test_media.py
│   ├── test_webhook.py
│   └── test_gpio.py
├── Dockerfile                  Container image (Render / any Docker host)
├── render.yaml                 Render blueprint
├── vercel.json                 Vercel serverless configuration
├── .env.example                Template for local environment variables
└── README.md                   Quickstart + deployment overview
```

---

## 3. Local development environment

### Prerequisites

- Python 3.10 or newer (the Docker image uses 3.11)
- A modern browser (Chrome recommended) — **no Node.js/bundler is required**

### One-time setup (Windows PowerShell)

```powershell
cd C:\Users\Amanda\Lulem
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r backend\requirements.txt
Copy-Item .env.example .env
uvicorn backend.app.main:app --reload
```

### One-time setup (macOS / Linux)

```bash
cd Lulem
python3 -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
cp .env.example .env
uvicorn backend.app.main:app --reload
```

### What to open

| URL | Purpose |
| --- | --- |
| `http://127.0.0.1:8000` | The TV signage display |
| `http://127.0.0.1:8000/docs` | FastAPI interactive API documentation |
| `http://127.0.0.1:8000/api/media` | Validated media configuration JSON |
| `http://127.0.0.1:8000/api/paystack/webhook` | Webhook endpoint (POST; see webhook section) |

### Run the frontend without the backend (optional)

`frontend/app.js` first asks `/api/media`, then falls back to the static
`media.json` if the backend is unavailable or you are serving `frontend/` with
any static web server. This is handy for pure UI work:

```bash
# from the frontend/ folder, e.g.
python -m http.server 8080 --directory frontend
# then open http://127.0.0.1:8080
```

### Exercise the kiosk lockdown in a normal browser

Appending `?kiosk=1` (e.g. `http://127.0.0.1:8000/?kiosk=1`) activates
`frontend/kiosk-guard.js`: context menu, breakout shortcuts, new windows and
Back/Forward navigation are blocked and a self-heal reload runs every 6 hours.
Keep the query parameter **off** during normal development so the page behaves
like a regular website.

---

## 4. How the pieces fit together

### 4.1 Media pipeline & validation

1. `media_service.load_media_configuration()` reads `frontend/media.json`
   (path from `backend/app/config/settings.py` → `MEDIA_FILE`).
2. Every media record must pass `is_valid_media()`: all required fields
   present, `status == "active"`, `payment_status == "paid"`,
   `media_type` in `image | video`, valid `http(s)` URLs for `media_url` and
   `paystack_url`, positive whole-number `play_count`, and an optional
   `orientation` in `landscape | portrait | square`.
3. Records that fail validation are silently dropped — never fatal.
4. Playback numbers are clamped: `ad_duration_seconds` (default 30, max 300)
   and `youtube_duration_minutes` (default 10, max 120). Malformed JSON returns
   an empty, safe response with defaults.
5. `GET /api/media` returns the validated payload, which the frontend consumes
   and re-validates before rendering.

Full field rules: [docs/API.md](API.md).

### 4.2 Playback engine (`frontend/app.js`)

A single-file IIFE that runs the whole show:

- **Loading** (`loadMedia`): prefer Zuke content delivered by the subscription
  adapter, then `GET /api/media`, then the static `media.json`.
- **Time-slot filtering**: media `time` is matched against the current schedule
  slot (`morning` / `afternoon` / `evening`). `"all"` matches any slot and items
  without a `time` always play.
- **Cycle building** (`buildCyclePlaylist`): expands each ad by its `play_count`
  (capped by `MAX_AD_CYCLE_MS`), shuffles the order, and avoids immediately
  repeating the last ad id.
- **Playback**: images (with zoom), muted autoplay videos, a caption + brand
  bar, a Paystack QR code rendered with `qrcodejs`, and a progress bar.
- **Master mute** (`#master-mute`): toggles and persists to
  `localStorage["masterMuted"]`.
- **YouTube entertainment**: plays full-screen between ad cycles and whenever no
  eligible ads exist; supports `youtube_mode` = `normal` | `api` | `both` and an
  optional fallback playlist list.
- **Robustness**: a broken image/video fires `onerror` and immediately advances
  to the next ad; an empty eligible set drops straight to entertainment rather
  than crashing.

### 4.3 Subscription adapter (`frontend/subscription-adapter.js`)

A transport-agnostic seam so the playback engine does not care *where* content
comes from:

- `createSubscriptionAdapter({ url, intervalMs })` returns
  `{ subscribe, start, stop, getCurrent }`.
- **HTTP polling adapter (today)**: polls the configured URL every 30 seconds
  with an `If-None-Match` header keyed on the payload's numeric `revision`. A
  `304` means “nothing changed”; a newer `revision` fires listeners. `revision`
  is the idempotency key for at-least-once delivery.
- **RabbitMQ adapter (placeholder)**: implements the same interface but throws
  until implemented. Swap transports by passing `adapter: "rabbitmq"` or a
  global `LUMEN_ADAPTER` / `SMART_RETAIL_ADAPTER` flag.
- **Default export URL**: `https://app.zuke.co.za/api/display-ads/export`,
  overridable per request with `?zuke=https://...` or via
  `window.ZUKE_EXPORT_URL`.

### 4.4 Paystack webhook → shelf unlock

- `POST /api/paystack/webhook` verifies the `x-paystack-signature` header
  (HMAC-SHA512 over the **raw request body** using `PAYSTACK_SECRET_KEY`),
  parses the JSON event, and only processes `charge.success`.
- The product is identified by `data.metadata.product_id`.
- `ShelfService.unlock_product()` resolves the GPIO pin from
  `hardware/gpio_mapping.py` (`PRODUCT_GPIO_MAP`) and pulses the relay for
  `UNLOCK_DURATION_SECONDS`, then reports the pin back to Paystack.
- `GPIO_MODE=mock` (default) uses `MockGPIOController`, an in-memory simulation
  that is perfect for PCs, cloud hosts and tests. `GPIO_MODE=real` uses
  `RealGPIOController` (gpiozero) on a Raspberry Pi.
- Unknown products raise `422` and never call into the controller.

### 4.5 Kiosk mode (Raspberry Pi)

`kiosk/` turns a Raspberry Pi into a locked-down in-store display:

- `setup-kiosk.sh` installs Chromium + Python deps, enables desktop auto-login,
  installs two systemd units, and disables screen blanking/sleep.
- `lulem-backend.service` keeps FastAPI alive across crashes and power cuts.
- `start-kiosk.sh` launches Chromium in `--kiosk` with `?kiosk=1`, waits for the
  backend, hides the cursor, and auto-relaunches Chromium after any crash.
- `frontend/kiosk-guard.js` locks the page down once `?kiosk=1` is present.

Full guide, maintenance commands and troubleshooting:
[kiosk/README.md](../kiosk/README.md).

---

## 5. Configuration reference

### Environment variables (`.env` — see `.env.example`)

| Variable | Default | Purpose |
| --- | --- | --- |
| `GPIO_MODE` | `mock` | `mock` for PC / cloud / tests, `real` on the Raspberry Pi shelf controller |
| `UNLOCK_DURATION_SECONDS` | `5` | Relay pulse duration when a product is unlocked |
| `YOUTUBE_MODE` | `both` | `normal` (IFrame embed, no key), `api` (Data API v3, needs key), `both` (API first, IFrame fallback) |
| `YOUTUBE_API_KEY` | *(empty)* | YouTube Data API v3 key for `api` / `both` modes |
| `PAYSTACK_SECRET_KEY` | *(empty)* | Secret used to verify webhook signatures |

Never commit `.env` values or put secrets inside `media.json`.

### `media.json` top-level keys

| Key | Type | Notes |
| --- | --- | --- |
| `media` | array | Advert records — every field documented in [docs/API.md](API.md) |
| `schedule` | object | Named time slots such as `morning` / `afternoon` / `evening`, each `{ "start", "end" }` in `HH:MM` |
| `youtube_playlist_id` | string | Default playlist for the YouTube entertainment block |
| `ad_duration_seconds` | int, ≤ 300 | Seconds each advert displays (default `30`) |
| `youtube_duration_minutes` | int, ≤ 120 | Length of the entertainment block (default `10`) |
| `youtube_mode` | string | Optional per-payload override of the env `YOUTUBE_MODE` |
| `youtube_api_key` | string | Optional per-payload override of the env `YOUTUBE_API_KEY` |

---

## 6. Testing

With the virtual environment active:

```powershell
pytest                 # whole suite
pytest -q              # quiet output
pytest tests/test_media.py
```

### What is covered

| File | Area |
| --- | --- |
| `tests/test_media.py` | `/api/media` filtering (only active + paid + valid adverts), JSON/config fallbacks, YouTube mode & API key resolution, orientation and schedule/time/category handling |
| `tests/test_webhook.py` | HMAC signature verification, a valid `charge.success` unlocking the mapped pin, invalid signature → 401, unknown product → 422 |
| `tests/test_gpio.py` | `pin_for_product` mapping, the mock unlock/deactivate cycle, unknown products never driving GPIO |

### Conventions to follow

- Use `MockGPIOController(sleep_fn=lambda _: None)` so tests never actually wait.
- Build the app per test with `create_app(controller)` so each test owns its
  controller instance (see `tests/test_webhook.py`).
- Write `media.json` fixtures into `tmp_path` and `monkeypatch` `MEDIA_FILE`
  where needed (see `tests/test_media.py`).
- Patch `settings` values with `monkeypatch` rather than relying on a real
  `.env` file.

### Not covered by the automated suite

Browser timing, QR rendering, remote media availability, YouTube playback and
physical Raspberry Pi GPIO must be verified manually in their target
environments.

---

## 7. Code conventions

### Python (backend, hardware, tests)

- **Python 3.10+ typing** — use modern unions such as `int | None` and
  parameterized generics (`dict[int, object]`), as in the existing code.
- **Small, pure functions in `services/`** — validation lives in
  `media_service.py` / `paystack_service.py` with constants at module top;
  no I/O at import time (only inside functions, e.g. `read_text`).
- **Module logging** — `logger = logging.getLogger(__name__)`; keep one shared
  `logging.basicConfig(...)` in `main.py`.
- **Factories over globals** — the FastAPI app is built by `create_app(...)`,
  which accepts an optional controller so tests can inject mocks. The
  module-level `app = create_app()` is the production instance.
- **Docstrings** for modules with special runtime behavior (e.g.
  `hardware/gpio_controller.py` documents that gpiozero is imported lazily).

### JavaScript (frontend)

- **Vanilla ES6+ inside an IIFE with `"use strict"`**; no framework, no
  bundler, no npm step.
- **Group DOM references** into a single `elements` object near the top of
  `app.js`.
- **Defensive validation first** — the entire system must never crash on bad
  data: validate early (`usable`, `positive`, `validUrl`, `validateSchedule`),
  then fall back quietly and keep looping.
- **`window.*` globals only for deliberate seams** — `createSubscriptionAdapter`,
  `window.ZUKE_EXPORT_URL`, `window.YOUTUBE_API_KEY`, and the adapter-kind flags
  are the intended extension points.
- **Comment style** — friendly banner headers for standalone modules (see
  `subscription-adapter.js` and `kiosk-guard.js`).

### General

- Update `docs/` when the data contract, environment variables or deployment
  steps change. Never leave a secret in a committed file.
- Keep `.env`, `.venv/`, `__pycache__/` and pytest caches out of commits (already
  listed in `.gitignore`).

---

## 8. Common developer tasks

### Add an advert

1. Add a record under `media` in `frontend/media.json` with all required
   fields — see the [data contract](API.md). In particular `status: "active"`,
   `payment_status: "paid"`, valid `http(s)` `media_url` + `paystack_url`, and
   `play_count >= 1`.
2. Optionally set `orientation` (`landscape` / `portrait` / `square`), `time`
   (a schedule slot, `"all"`, or omit), and `category`.
3. Reload the page — the display re-fetches the configuration each cycle, so no
   restart is needed.

### Add a product that unlocks a physical shelf

1. Add `"product_XXX": <BCM pin>` to `PRODUCT_GPIO_MAP` in
   `hardware/gpio_mapping.py`.
2. Make sure Paystack webhook metadata carries `product_id: "product_XXX"`.
3. Verify with the mock controller (fast test path) or `GPIO_MODE=real` on a Pi
   while watching the logs.

### Change entertainment playlists

Set `youtube_playlist_id` in `frontend/media.json`. `app.js` also reads
`fallbackPlaylists` for additional choices and picks one at random.

### Point the display at live Zuke content

`http://<host>/?zuke=https://app.zuke.co.za/api/display-ads/export` or set
`window.ZUKE_EXPORT_URL` before `app.js` loads. The adapter polls that URL
every 30 s.

### Switch YouTube mode or add an API key

Set `YOUTUBE_MODE` (`normal` / `api` / `both`) and optionally
`YOUTUBE_API_KEY` in `.env`, or override both per payload in `media.json`.

### Enable physical GPIO on a Raspberry Pi

1. `sudo ./kiosk/setup-kiosk.sh` (installs `gpiozero` into the repo venv).
2. Set `GPIO_MODE=real` in `.env`.
3. Verify relay wiring and, if needed, the `active_high` flag in
   `hardware/gpio_controller.py`.

### Swap the content transport

Implement the same `subscribe/start/stop/getCurrent` interface as the HTTP
adapter (the RabbitMQ placeholder in `frontend/subscription-adapter.js` shows
the shape), then select it via `adapter: "rabbitmq"` or `LUMEN_ADAPTER`. Nothing
in `app.js` changes.

---

## 9. Deployment quick-reference

| Target | How | Notes |
| --- | --- | --- |
| **Render** | Blueprint: `render.yaml`. Manual: Web Service → **Docker** runtime | `Dockerfile` runs uvicorn on `${PORT:-10000}`; `PAYSTACK_SECRET_KEY` is auto-generated by the blueprint |
| **Vercel** | Import repo, Root Directory = repository root, preset **Other**, no output directory | `api/index.py` is the Python serverless function; `vercel.json` bundles `frontend/**`; no GPIO available |
| **Generic Docker** | `docker build -t lumen . && docker run -p 8000:10000 -e GPIO_MODE=mock lumen` | Map the container port to whatever you prefer |
| **Raspberry Pi** | `sudo ./kiosk/setup-kiosk.sh && sudo reboot` | Full locked-down in-store display — see [kiosk/README.md](../kiosk/README.md) |

> Cloud deployments must keep `GPIO_MODE=mock`. The physical GPIO controller
> (`gpiozero`) only makes sense on the Raspberry Pi.

Full deployment walkthroughs, including environment variables per target:
[README.md](../README.md#deployment).

---

## 10. Troubleshooting / FAQ

| Symptom | Likely cause / fix |
| --- | --- |
| `/api/media` returns `{"media": []}` | No advert passed validation. Check `status`, `payment_status`, URLs, `play_count`, and required fields in `frontend/media.json`; inspect via `/api/media` in the browser. |
| Display shows *“Fresh offers are on their way.”* | Same as above — an empty eligible set falls back to entertainment / the empty state by design. |
| YouTube never plays | Missing or wrong `youtube_playlist_id`, or no outbound internet. In `api` mode, validate `YOUTUBE_API_KEY`. |
| Webhook returns **401** | `PAYSTACK_SECRET_KEY` must match the key Paystack signed with, and the signature must be computed over the **exact raw bytes** of the request body. |
| Webhook returns **422** | `data.metadata.product_id` is missing, or the product is not in `PRODUCT_GPIO_MAP`. |
| CORS errors from the dashboard | Add the origin to `allow_origins` in `backend/app/main.py` (`create_app`). |
| `GPIO_MODE=real` raises `ImportError: gpiozero` | Expected on non-Pi hosts — `gpiozero` is intentionally optional (`backend/requirements.txt` comment). Install it only on the Raspberry Pi. |
| Static host, but media never updates | `app.js` falls back to `media.json` when `/api/media` is unreachable — that is by design for static hosting. | 

---

## 11. Documentation index

| Doc | Purpose | Read it when… |
| --- | --- | --- |
| [`README.md`](../README.md) | Overview, quickstart, environment variables, deployment | You are new to the project or deploying it |
| [`docs/API.md`](API.md) | Data contract, endpoint reference, error handling, future Zuke integration | You are changing the data schema or API |
| **`docs/DEVELOPMENT.md`** (this file) | Architecture, codebase walkthrough, conventions, testing, how-tos | You are writing or extending code |
| [`kiosk/README.md`](../kiosk/README.md) | Raspberry Pi kiosk install, operations, troubleshooting | You maintain the in-store displays |