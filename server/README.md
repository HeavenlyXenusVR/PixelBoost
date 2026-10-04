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
- `POST /log/actions` — batched `/log/action` (the app buffers events and
  flushes them together; at most 200 per request)
- `POST /log/snapshot` — one ambient `device_snapshots` row (thermal state,
  Low Power Mode, battery, memory, free disk, session uptime), sampled on a
  timer and at launch/foreground/background/thermal change/memory warning
  rather than tied to any one action
- `GET /log/snapshots?device_id=...&limit=&offset=`

**Per-model comparison telemetry**
- `POST /log/comparison` — one Compare Models / Auto sweep: every model that
  ran side by side on the same photo, plus a `model_comparison_candidates`
  row each (score, timing, fidelity, tile reuse, error). The candidate runs
  are *also* in `upscale_history`, tagged with the same `comparison_id` and
  `run_kind='compare'`. Upserts on `comparison_id` (the client generates it
  up front so each candidate's history row can carry it), and replaces the
  sweep's candidate rows rather than appending, so a retry can't duplicate
  them.
- `POST /log/comparison/{comparison_id}/pick` — which result the user
  actually chose (`{"model_name": "..."}`). Posted separately because the
  choice happens later, in `ModelComparisonView`, and may never happen at
  all — a sweep with a NULL `picked_model` means every model's output was
  rejected, which is worth being able to count. 404 if the sweep was never
  posted.
- `GET /log/comparisons?device_id=&limit=&offset=` — sweeps with their
  candidates nested.

This exists because the user's pick is the only non-proxy signal this app
has about model quality: `sharpness_score` is a heuristic standing in for
"looks better", and a human choosing one of six results they can all see is
the actual answer. `model_comparisons.auto_pick_model` stores the app's own
ranking winner next to it, so the two can be compared directly — if they
disagree often, the ranking is not measuring what people prefer.

**Cross-device overview**
- `GET /log/overview?days=` (1-90, default 7) — fleet-wide health,
  aggregated across every device: totals, per-`run_kind`/per-model timing
  (p95 included) and failure counts, per-app-version rollup, top errors,
  action/outcome counts, the model-pick table above, auto-pick agreement
  rate, and thermal-state distribution.

  Every other read endpoint here is scoped to a single `device_id`, and
  there's no way to enumerate device ids — so until this existed, all of
  this telemetry was being collected and was effectively unreadable in
  aggregate: answering "is any model failing?" or "did the last release
  regress timing?" required already knowing which device to ask. It
  deliberately returns no `device_id` values and no per-device rows, only
  counts and distributions; `/log/history?device_id=` is still the way to
  look at one install you already know.

`upscale_history` also carries `run_kind` ('single' | 'batch' | 'compare' |
'intent'), which closes a real hole in every aggregate over this table:
Auto mode and Compare Models run *every* bundled model over the full photo,
and each of those candidate runs used to land here looking exactly like a
deliberate single upscale — so `success_rate`, `avg_processing_ms` and any
per-model timing silently mixed one requested run in with a six-model sweep
the user never asked for individually. `was_batch` is kept and still set
alongside it. Also added: `fidelity_psnr`, `tiles_reused` and
`output_was_capped` (all three were already being computed per run on the
client and then discarded at the log boundary — see `UpscaleResult`),
`render_denoise_applied` (whether the pass actually *ran*, not whether it
was requested — it's best-effort and falls back silently),
`source_noise_sigma` (the measurement that decided it, so a badly-set
threshold is visible rather than just its consequences), and `free_disk_mb`.

`peak_memory_mb` is now an actual in-run high-water mark, sampled per tile
batch and across the final stitch (see `CoreMLTileUpscaler`). It used to be
a single reading taken at log time — i.e. after the run finished and every
tile buffer had been released — which on real telemetry reported 76-198MB
for 4x upscales whose own memory warnings had recorded 2,160MB. It was
measuring the idle footprint and calling it a peak. Strategies that don't
sample (Lanczos, and failed runs that never got far enough) still fall back
to the old after-the-fact reading.

Note also that a Compare Models sweep writes a history row per candidate
but uploads **no** candidate images: uploading per run meant one sweep
pushed the source once per candidate (byte-identical copies) plus every
candidate result — ~48MB for a single sweep of a 498x336 photo, of which
the user keeps one image. The chosen result is uploaded once, on the pick.

`upscale_history` also carries per-run context beyond the original
dimensions/timing columns: `detail_level`, `model_input_width/height` (what
the model actually saw, after any detail-budget downscale — the column that
makes a v3.26.13-style "weak upscale" regression visible instead of
invisible between source and output), `requested_scale`, the
strength/anti-aliasing/sharpen/denoise settings the run used, `was_batch`,
`cancelled`, thermal state before and after, Low Power Mode, battery level
and memory. `action_log` gains `session_id`, `outcome`, `duration_ms` and
`thermal_state`.

All of it is switchable off in the app (Settings > Diagnostics), and
nothing is sent at all without a server URL configured.

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
- `DELETE /export?device_id=...` / `DELETE /import?device_id=...` — delete
  this device's stored images now rather than waiting for expiry
- `GET /storage/usage?device_id=...` — count, total bytes and next expiry
  per kind

Both `POST /import` and `POST /export` also take `is_auto` (an automatic
per-upscale copy vs. a deliberate one-off) and an optional `label`. The
app's **Temporary Cloud Save** setting (on by default, results only) posts
every upscale result here with `ttl_hours` from Settings — a day unless
changed — which is what the Cloud tab lists and what the cleanup loop
below deletes on expiry.

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
