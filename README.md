# Lumen

An MVP digital-signage application for retail TVs. It consumes an advertising JSON contract, plays eligible image/video campaigns with a Paystack payment QR code, and switches to YouTube entertainment between advertising cycles.

Spark/Zuke will eventually provide the advertising data and business logic. This repository focuses on validating and displaying that data reliably.

## Features

- Active, paid advertisement filtering
- Image and muted video playback
- Paystack QR code overlay for every eligible advert
- Configurable advertising and YouTube durations
- `play_count` campaign frequency control
- Five-minute maximum advertising section
- In-store kiosk mode: locked-down, self-healing Raspberry Pi display
- Safe handling of empty, malformed, unpaid, inactive, and broken media
- FastAPI endpoint for serving validated media data
- Optional mock/real GPIO and Paystack webhook prototype retained separately

## Documentation

- [`docs/API.md`](docs/API.md) — data contract and API reference.
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — architecture, codebase
  walkthrough, testing conventions, and common developer tasks.
- [`kiosk/README.md`](kiosk/README.md) — Raspberry Pi in-store kiosk guide.

## Project structure

```text
frontend/            TV signage UI (HTML, CSS, Vanilla JavaScript)
  media.json         Development media contract
backend/app/         FastAPI media API and services
hardware/            Optional mock/real GPIO controllers
kiosk/               In-store kiosk mode: Pi installer, Chromium launcher, systemd units
tests/               Backend and GPIO tests
```

## Requirements

- Python 3.10 or newer
- Internet access for remote media, YouTube, and the client-side QR library

## Run locally

```powershell
cd C:\Users\Amanda\Smart-Retail-Display
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r backend\requirements.txt
Copy-Item .env.example .env
uvicorn backend.app.main:app --reload
```

Open the display at http://127.0.0.1:8000.

Useful endpoints:

- `GET /api/media` — validated display configuration and eligible advertisements
- `/docs` — FastAPI interactive API documentation
- `POST /api/paystack/webhook` — retained payment/GPIO prototype endpoint

## Advertising data contract

The display reads one JSON object from `frontend/media.json` (or ultimately from Spark/Zuke):

```json
{
  "schedule": {
    "morning": { "start": "09:00", "end": "11:30" },
    "afternoon": { "start": "11:30", "end": "18:00" },
    "evening": { "start": "18:00", "end": "21:00" }
  },
  "media": [
    {
      "id": "media_001",
      "business_id": "business_001",
      "business_name": "Amanda Cosmetics",
      "type": "product",
      "category": "beauty",
      "name": "Premium Lipstick Collection",
      "media_type": "image",
      "media_url": "https://cdn.example.com/lipstick.jpg",
      "paystack_url": "https://paystack.com/pay/lipstick-001",
      "payment_status": "paid",
      "play_count": 2,
      "status": "active",
      "orientation": "landscape",
      "time": "morning"
    }
  ],
  "youtube_playlist_id": "YOUR_PLAYLIST_ID",
  "ad_duration_seconds": 30,
  "youtube_duration_minutes": 10
}
```

### Field rules

All media fields shown above are required except `orientation`, `category`, and `time`.

| Field | Rule |
| --- | --- |
| `media_type` | `image` or `video` |
| `media_url`, `paystack_url` | Valid HTTP(S) URLs |
| `status` | Must be `active` to display |
| `payment_status` | Must be `paid` to display |
| `play_count` | Positive whole number |
| `orientation` | Optional: `landscape`, `portrait`, or `square` |
| `category` | Optional string categorizing the campaign (e.g. `beauty`, `tech`, `food`) |
| `time` | Optional time slot targeting: `morning`, `afternoon`, `evening`, or `all` |
| `schedule` | Optional root object defining time windows (`morning`, `afternoon`, `evening`) |

`orientation` describes the intended aspect ratio of an image or video. When omitted, existing media remains valid and keeps the original display behaviour. Landscape keeps the default cropped fill; portrait and square use a contained fit to avoid cropping. If supplied with any other value, that advert is ignored without stopping the display cycle.

The backend and frontend ignore invalid entries individually. They use safe defaults of 30 seconds for advertisements, 10 minutes for YouTube, and standard morning/afternoon/evening time slots if global durations or schedules are invalid. See [the API and data-contract documentation](docs/API.md) for the complete field reference, development API behaviour, error handling, and Spark/Zuke integration TBDs.

## Playback flow

1. Load and validate the JSON configuration.
2. Filter to complete, active, paid campaigns matching the current time slot (or all-day).
3. Expand each eligible advert according to `play_count`.
4. Apply Fisher-Yates deck shuffle to randomize rotation and prevent consecutive repetitions across cycles and days.
5. Limit the expanded advertising playlist to five minutes.
6. Play each image/video for `ad_duration_seconds` and generate a QR code encoding exactly its `paystack_url`.
7. Play the configured YouTube entertainment intermission for `youtube_duration_minutes` (non-repeating video queue in API mode).
8. Reload the media configuration and repeat.

`play_count` is deliberately used instead of advertising slots: it is simple, explicit, and easy for Spark/Zuke to generate without introducing an auction or scheduling system.

## In-store kiosk display (Raspberry Pi)

To run the display like a McDonald's in-store screen — a monitor that boots
straight into your ads with no tabs, no desktop, and no way for anyone at the
screen to close, minimise or control it — use the kiosk mode:

```bash
# On the Pi, from the repo root:
sudo ./kiosk/setup-kiosk.sh
sudo reboot
```

The installer wires up three lockdown layers (hardened `--kiosk` Chromium
launcher, a page guard that blocks right-click/shortcuts/navigation and
self-heals every 6 hours, and systemd services that survive crashes and power
cuts). See [kiosk/README.md](kiosk/README.md) for the full guide, physical
lockdown advice, maintenance commands and troubleshooting.

## Tests

With the virtual environment active:

```powershell
pytest
```

The suite covers media filtering/configuration fallback, webhook signature validation, product-to-pin mapping, and mock GPIO behavior. Browser timing, QR rendering, remote media availability, YouTube playback, and physical Raspberry Pi hardware must be verified in their target environments.

## Environment and configuration

Copy `.env.example` to `.env` to customize settings:

- `GPIO_MODE`: `mock` (default for PC / cloud) or `real` (Raspberry Pi GPIO shelf).
- `UNLOCK_DURATION_SECONDS`: GPIO pulse duration in seconds (default `5`).
- `YOUTUBE_MODE`: Toggle YouTube playback mode:
  - `normal`: Standard YouTube IFrame playlist/video embed (no API key required).
  - `api`: YouTube Data API v3 (fetches playlist videos dynamically; requires `YOUTUBE_API_KEY`).
  - `both` (default): Attempts YouTube Data API v3 first; automatically falls back to standard IFrame embed if the key is unset, exhausted, or encounters an error.
- `YOUTUBE_API_KEY`: Optional YouTube Data API v3 key.
- `PAYSTACK_SECRET_KEY`: Paystack secret key for the payment webhook prototype.

Do not commit `.env` or place secrets in `media.json`.
## Deployment

### Deploying to Render

This project is ready to be deployed to [Render](https://render.com/).

#### Option 1: Using the Render Blueprint (Easiest)

1. Fork this repository to your GitHub account.
2. Log in to Render and click **New** > **Blueprint**.
3. Connect your fork.
4. Render will automatically detect the `render.yaml` file and configure the service.
5. Set your `PAYSTACK_SECRET_KEY` in the Render dashboard environment variables.

#### Option 2: Manual Deployment

1. Create a new **Web Service** on Render.
2. Connect your repository.
3. Select **Docker** as the runtime.
4. Render will use the included `Dockerfile`.
5. Add the following environment variables:
   - `GPIO_MODE`: `mock`
   - `UNLOCK_DURATION_SECONDS`: `5`
   - `PAYSTACK_SECRET_KEY`: Your secret key from Paystack.

The application will be available at your Render URL (e.g., `https://lumen.onrender.com`).

### Deploying to Vercel

1. Fork/Push this repository to GitHub.
2. Connect the project to Vercel.
3. Vercel will use `vercel.json` to route `/api` to the Python serverless function and serve the `frontend` statically.
4. Add `PAYSTACK_SECRET_KEY` and `GPIO_MODE=mock` to your Vercel Environment Variables.


### Manual Docker Deployment

If you want to run the container locally or on another cloud provider:

```bash
docker build -t lumen .
docker run -p 8000:8000 -e GPIO_MODE=mock lumen
```

### Deploying to Vercel

The included `vercel.json` deploys the FastAPI application as a Python
serverless function, including the signage frontend served at `/`.

1. Import the repository into Vercel with the **Root Directory** set to the
   repository root.
2. Leave the framework preset as **Other** and do not set an output directory.
3. Add `PAYSTACK_SECRET_KEY` only if you will use the payment webhook. Set
   `GPIO_MODE` to `mock` (the default) for Vercel.
4. Redeploy the project after pushing these files.

Vercel serverless functions are intended for the display API and web UI. The
physical GPIO controller is not available in that environment.

