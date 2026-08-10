# upscaler-bridge

A small FastAPI service backing the app's optional server-side features —
debug logging, temporary cloud storage for imports/exports, custom presets,
device settings backup, and a model registry — mirroring Lumisound's
`ios-bridge` pattern. **Live**: deployed at
`https://upscaler-bridge.xenusanimations.studio` (see `docker-compose.yml`
in the `music` compose project, `upscaler-bridge` service).

**PostgreSQL**, not MariaDB/MySQL — migrated (see git history for the
MariaDB-era version of this file/schema if needed) onto the same shared
Postgres instance the music bots and Lumisound's `ios-bridge` already run
against, in its own `image_upscaler` database. `db.py` uses `aiopg`
(wraps `psycopg2`, same `%s`-placeholder/`cursor.execute()` API `aiomysql`
had) rather than `asyncpg`, specifically so this port didn't need to
rewrite every parameterized query in `main.py` for `asyncpg`'s incompatible
`$1`/`$2` placeholders — same approach `ios-bridge` took for its own
MySQL->Postgres migration. `schema.sql` is plain Postgres DDL (`BYTEA` not
`LONGBLOB`, standalone `CREATE INDEX` statements not inline `INDEX(...)`,
`ON CONFLICT ... DO UPDATE` not `ON DUPLICATE KEY UPDATE`) — see that
file's comments for anything non-obvious in the conversion.

The MariaDB->Postgres migration was verified end-to-end against the actual
live deployed instance (not just a throwaway test container) before being
declared done: real INSERT/SELECT round-trips through `log/upscale` +
`log/history`, `log/stats`'s `COUNT(*) FILTER (WHERE success)`/`SUM`/`AVG`
aggregates, both `ON CONFLICT DO UPDATE` upserts (`custom_presets`,
`device_settings` — including `updated_at` actually advancing on a second
upsert), and a byte-exact `BYTEA` image upload/download/delete round-trip
with `make_interval()`-computed `expires_at`. Every converted SQL
statement was actually exercised, not just reviewed for syntax.

## Endpoints

**Debug logging**
- `POST /log/upscale` — records one upscale attempt (see `UpscaleLogEntry`)
- `GET /log/history?device_id=...&limit=&offset=` — recent entries
- `POST /log/action` — records one non-upscale action (Save, Compare Models,
  Cutout, a Settings change, ...) with a free-form `detail` JSON string
  (see `ActionLogEntry`)
- `GET /log/action-history?device_id=...&action=...&limit=&offset=` —
  recent action entries

**Temporary image storage** (imports = pre-upscale, exports = post-upscale;
both auto-expire — see "Expiry" below)
- `POST /import` (multipart: `device_id`, `ttl_hours` optional, `file`)
- `GET /import/{id}` — raw image bytes
- `GET /import?device_id=...` — metadata list (no image bytes)
- `DELETE /import/{id}`
- `POST /export` (multipart: `device_id`, `history_id` optional, `ttl_hours`
  optional, `file`) — `history_id` links back to the `upscale_history` row
  that produced this result
- `GET /export/{id}`, `GET /export?device_id=...`, `DELETE /export/{id}`

**Custom presets** (named model+overlap combos, permanent — not TTL'd)
- `POST /presets` — upsert by `(device_id, name)`, returns the stored `id`
- `GET /presets?device_id=...`
- `DELETE /presets/{id}`

**Device settings backup/restore** (manually-triggered — no accounts, so
this is a per-device_id backup slot, not automatic multi-device sync)
- `PUT /device-settings` — upsert
- `GET /device-settings?device_id=...` — 404 if never backed up

**Model registry**
- `GET /models` — metadata for available models (display name, description,
  license, tile size, scale factor)

`GET /health` needs no auth; everything else requires
`Authorization: Bearer <key>` if `UPSCALER_BRIDGE_API_KEY` is set.

## Expiry

`image_imports`/`image_exports` rows carry an `expires_at`; a background
loop (started in the FastAPI `lifespan`) deletes expired rows hourly, and
every import/export write also triggers a best-effort opportunistic
cleanup pass — so expiry doesn't solely depend on the hourly timer.
`ttl_hours` defaults to 24, capped at 168 (7 days). This is scratch
storage, not a photo library — nothing here is meant to be permanent.

## Uploads

Capped at 60MB per file (`MAX_UPLOAD_BYTES` in `main.py`) — a 4x-upscaled
photo with real transparency (a Cutout result) still uploads as lossless
PNG and can clear 50MP, so the old 20MB cap was a real, hit-in-practice
limit ("Backup to Cloud" failing on large results), not just a
theoretical ceiling. Postgres has no MariaDB-`max_allowed_packet`-style
message-size ceiling to raise alongside this one — that whole second
moving part the MariaDB era needed (and the host-level `sudo`-gated config
edit it required) is gone now that this runs on Postgres. Image dimensions
are read server-side via Pillow rather than trusted from client-supplied
metadata.

The client side halves this problem independently: `ImportExportService`
now reuses `PhotoLibrarySaver`'s format-aware encoding (JPEG for an opaque
result, PNG only when there's real alpha to preserve) instead of always
uploading lossless PNG — most upscaled photos have no transparency, so this
alone cuts a typical upload to a fraction of its old size.

## Running

Environment variables (all have dev-friendly defaults except `DB_PASSWORD`,
which has none on purpose — set it explicitly):

| Variable | Default |
|---|---|
| `DB_HOST` | `127.0.0.1` |
| `DB_PORT` | `5432` |
| `DB_USER` | `upscaler` |
| `DB_PASSWORD` | *(none — required)* |
| `DB_NAME` | `image_upscaler` |
| `UPSCALER_BRIDGE_API_KEY` | *(none — auth disabled)* |
| `PORT` | `8003` |

```bash
pip install -r requirements.txt
DB_PASSWORD=... uvicorn main:app --host 0.0.0.0 --port 8003
```

Or via Docker:

```bash
docker build -t upscaler-bridge .
docker run -p 8003:8003 -e DB_HOST=... -e DB_PASSWORD=... upscaler-bridge
```
