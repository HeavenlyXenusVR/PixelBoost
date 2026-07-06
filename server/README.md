# upscaler-bridge

A small FastAPI service that logs every upscale attempt the app makes —
source image size, technique used (Core ML model vs. Lanczos fallback),
tile config, timing, success/failure — to a MariaDB table, mirroring
Lumisound's `ios-bridge` pattern. Verified locally end-to-end against a
throwaway MariaDB container (schema auto-applies on startup, `POST
/log/upscale` + `GET /log/history` both round-tripped correctly) — **not
yet deployed anywhere**.

## Endpoints

- `GET /health`
- `POST /log/upscale` — records one upscale attempt (see `UpscaleLogEntry`
  in `main.py` for the full field list)
- `GET /log/history?device_id=...&limit=&offset=` — recent entries,
  optionally filtered to one device

Auth: if `UPSCALER_BRIDGE_API_KEY` is set, all endpoints require
`Authorization: Bearer <key>` — same pattern as `ios-bridge`. Unset (the
default) means no auth, fine for a private/internal deployment.

## Running

Environment variables (all have dev-friendly defaults except `DB_PASSWORD`,
which has none on purpose — set it explicitly):

| Variable | Default |
|---|---|
| `DB_HOST` | `127.0.0.1` |
| `DB_PORT` | `3306` |
| `DB_USER` | `upscaler` |
| `DB_PASSWORD` | *(none — required)* |
| `DB_NAME` | `image_upscaler` |
| `UPSCALER_BRIDGE_API_KEY` | *(none — auth disabled)* |

```bash
pip install -r requirements.txt
DB_PASSWORD=... uvicorn main:app --host 0.0.0.0 --port 8003
```

Or via Docker:

```bash
docker build -t upscaler-bridge .
docker run -p 8003:8003 -e DB_HOST=... -e DB_PASSWORD=... upscaler-bridge
```

## Deploying

Not wired into any docker-compose file yet — this needs a real MariaDB to
point at (either a new database on Lumisound's existing shared MariaDB
instance, or its own), and that's a deployment decision, not a code one.
