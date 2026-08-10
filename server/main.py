import asyncio
import contextlib
import io
import logging
import os
import uuid
from contextlib import asynccontextmanager
from typing import Optional

import psycopg2.extras
from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import Response
from PIL import Image
from pydantic import BaseModel

from db import get_pool, init_db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("upscaler-bridge")

VERSION = "1.0.0"
API_KEY: str = os.getenv("UPSCALER_BRIDGE_API_KEY", "")

# ---------------------------------------------------------------------------
# Temporary image storage (imports/exports) config
# ---------------------------------------------------------------------------

MAX_UPLOAD_BYTES = 60 * 1024 * 1024  # 60MB — a 4x-upscaled photo with real
# transparency (a Cutout result) still has to go through as PNG (see the
# app-side encodedData()/hasAlphaChannel logic — only an opaque result gets
# re-encoded as JPEG before upload), and a 4x upscale of a modern phone
# photo easily clears 50MP; lossless PNG at that resolution can exceed the
# old 20MB cap on its own. Raised alongside MariaDB's max_allowed_packet
# (also bumped to 64MB on the host — see server/README.md) to comfortably
# clear this with multipart overhead room to spare.
DEFAULT_TTL_HOURS = 24
MAX_TTL_HOURS = 24 * 7
_CLEANUP_INTERVAL_SECONDS = 3600  # hourly


def _resolve_ttl_hours(ttl_hours: Optional[int]) -> int:
    if ttl_hours is None:
        return DEFAULT_TTL_HOURS
    return max(1, min(ttl_hours, MAX_TTL_HOURS))


async def _cleanup_expired_once() -> None:
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute("DELETE FROM image_imports WHERE expires_at < NOW()")
            deleted_imports = cur.rowcount
            await cur.execute("DELETE FROM image_exports WHERE expires_at < NOW()")
            deleted_exports = cur.rowcount
    if deleted_imports or deleted_exports:
        logger.info(
            "cleanup: deleted %d expired imports, %d expired exports",
            deleted_imports, deleted_exports,
        )


async def _cleanup_loop() -> None:
    """Runs until cancelled at shutdown, deleting expired image_imports/
    image_exports rows on an interval. Each import/export write also
    triggers one best-effort opportunistic pass, so expiry isn't solely
    dependent on this loop's timer firing."""
    while True:
        try:
            await _cleanup_expired_once()
        except Exception:
            logger.exception("cleanup loop iteration failed")
        await asyncio.sleep(_CLEANUP_INTERVAL_SECONDS)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    cleanup_task = asyncio.create_task(_cleanup_loop())
    try:
        yield
    finally:
        cleanup_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await cleanup_task


app = FastAPI(title="upscaler-bridge", lifespan=lifespan)


async def check_auth(request: Request) -> None:
    """If UPSCALER_BRIDGE_API_KEY is set, require a matching Bearer token —
    same pattern as Lumisound's ios-bridge."""
    if not API_KEY:
        return
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    token = auth_header[len("Bearer "):]
    if token != API_KEY:
        raise HTTPException(status_code=403, detail="Invalid API key")


class UpscaleLogEntry(BaseModel):
    device_id: str
    source_width: int
    source_height: int
    source_file_size_bytes: Optional[int] = None
    technique: str
    model_name: Optional[str] = None
    tile_size: Optional[int] = None
    overlap: Optional[int] = None
    scale_factor: int
    tile_count: Optional[int] = None
    output_width: Optional[int] = None
    output_height: Optional[int] = None
    processing_ms: int
    success: bool
    error_message: Optional[str] = None
    app_version: Optional[str] = None
    os_version: Optional[str] = None
    device_model: Optional[str] = None


@app.get("/health")
async def health():
    return {"status": "ok", "version": VERSION}


@app.post("/log/upscale")
async def log_upscale(entry: UpscaleLogEntry, request: Request):
    await check_auth(request)
    pool = await get_pool()
    entry_id = uuid.uuid4().hex
    async with pool.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                """
                INSERT INTO upscale_history (
                    id, device_id, source_width, source_height, source_file_size_bytes,
                    technique, model_name, tile_size, overlap, scale_factor, tile_count,
                    output_width, output_height, processing_ms, success, error_message,
                    app_version, os_version, device_model
                ) VALUES (
                    %s, %s, %s, %s, %s,
                    %s, %s, %s, %s, %s, %s,
                    %s, %s, %s, %s, %s,
                    %s, %s, %s
                )
                """,
                (
                    entry_id, entry.device_id, entry.source_width, entry.source_height,
                    entry.source_file_size_bytes,
                    entry.technique, entry.model_name, entry.tile_size, entry.overlap,
                    entry.scale_factor, entry.tile_count,
                    entry.output_width, entry.output_height, entry.processing_ms,
                    entry.success, entry.error_message,
                    entry.app_version, entry.os_version, entry.device_model,
                ),
            )
    return {"id": entry_id}


@app.get("/log/history")
async def get_history(
    request: Request,
    device_id: Optional[str] = Query(None, description="Filter to one device's history"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
):
    await check_auth(request)
    pool = await get_pool()
    where = "WHERE device_id = %s" if device_id else ""
    params: tuple = (device_id, limit, offset) if device_id else (limit, offset)
    # RealDictCursor so the response rows come back as plain dicts, rather
    # than psycopg2's default plain tuples.
    async with pool.acquire() as conn:
        async with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            await cur.execute(
                f"""
                SELECT id, device_id, created_at, source_width, source_height,
                       source_file_size_bytes, technique, model_name, tile_size,
                       overlap, scale_factor, tile_count, output_width, output_height,
                       processing_ms, success, error_message, app_version, os_version,
                       device_model
                FROM upscale_history
                {where}
                ORDER BY created_at DESC
                LIMIT %s OFFSET %s
                """,
                params,
            )
            rows = await cur.fetchall()
    # Postgres's BOOLEAN comes back as a real Python bool via psycopg2
    # already (unlike MariaDB's TINYINT-backed BOOLEAN, which aiomysql used
    # to hand back as a plain 0/1 int) — this coercion is now a no-op, kept
    # only as cheap insurance against `success` ever changing type upstream,
    # since Swift's Codable Bool decoder rejects `1`/`0` outright.
    for row in rows:
        row["success"] = bool(row["success"])
    return {"entries": rows}


@app.delete("/log/history/{entry_id}")
async def delete_history_entry(entry_id: str, request: Request):
    await check_auth(request)
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute("DELETE FROM upscale_history WHERE id = %s", (entry_id,))
            deleted = cur.rowcount
    if not deleted:
        raise HTTPException(status_code=404, detail="History entry not found")
    return {"deleted": True}


@app.delete("/log/history")
async def clear_history(request: Request, device_id: str = Query(...)):
    await check_auth(request)
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute("DELETE FROM upscale_history WHERE device_id = %s", (device_id,))
            deleted = cur.rowcount
    return {"deleted_count": deleted}


class ActionLogEntry(BaseModel):
    device_id: str
    action: str
    detail: Optional[str] = None
    app_version: Optional[str] = None
    os_version: Optional[str] = None
    device_model: Optional[str] = None


@app.post("/log/action")
async def log_action(entry: ActionLogEntry, request: Request):
    await check_auth(request)
    pool = await get_pool()
    entry_id = uuid.uuid4().hex
    async with pool.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                """
                INSERT INTO action_log (
                    id, device_id, action, detail, app_version, os_version, device_model
                ) VALUES (%s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    entry_id, entry.device_id, entry.action, entry.detail,
                    entry.app_version, entry.os_version, entry.device_model,
                ),
            )
    return {"id": entry_id}


@app.get("/log/action-history")
async def get_action_history(
    request: Request,
    device_id: Optional[str] = Query(None, description="Filter to one device's history"),
    action: Optional[str] = Query(None, description="Filter to one action name"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
):
    await check_auth(request)
    pool = await get_pool()
    clauses = []
    params: list = []
    if device_id:
        clauses.append("device_id = %s")
        params.append(device_id)
    if action:
        clauses.append("action = %s")
        params.append(action)
    where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    params += [limit, offset]
    async with pool.acquire() as conn:
        async with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            await cur.execute(
                f"""
                SELECT id, device_id, action, detail, created_at, app_version, os_version, device_model
                FROM action_log
                {where}
                ORDER BY created_at DESC
                LIMIT %s OFFSET %s
                """,
                tuple(params),
            )
            rows = await cur.fetchall()
    return {"entries": rows}


@app.get("/log/stats")
async def get_stats(request: Request, device_id: str = Query(...)):
    """Aggregates over the FULL history for this device, not the capped/
    paginated /log/history — that endpoint's own limit<=200 would silently
    undercount "total upscales" once a device crosses 200 lifetime
    attempts, which is a very plausible count over an app's lifetime."""
    await check_auth(request)
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            await cur.execute(
                """
                SELECT
                    COUNT(*) AS total,
                    COUNT(*) FILTER (WHERE success) AS successes,
                    AVG(processing_ms) AS avg_processing_ms,
                    SUM(CASE WHEN success THEN output_width * output_height ELSE 0 END) AS total_output_pixels
                FROM upscale_history WHERE device_id = %s
                """,
                (device_id,),
            )
            row = await cur.fetchone()
    # Unlike MariaDB (where BOOLEAN is really TINYINT under the hood, so
    # `SUM(success)` just worked), Postgres's real BOOLEAN type has no
    # `SUM()` — `COUNT(*) FILTER (WHERE success)` above is the idiomatic
    # Postgres replacement. SUM()/AVG() still come back as Decimal via
    # psycopg2's type conversion either way, not plain int/float —
    # normalize explicitly so the JSON response (and the Swift client
    # decoding it) gets predictable int/float types rather than a
    # Decimal-derived string.
    total = int(row["total"] or 0)
    successes = int(row["successes"] or 0)
    return {
        "total": total,
        "successes": successes,
        "failures": total - successes,
        "success_rate": (successes / total) if total else None,
        "avg_processing_ms": float(row["avg_processing_ms"]) if row["avg_processing_ms"] is not None else None,
        "total_output_pixels": int(row["total_output_pixels"] or 0),
    }


# ---------------------------------------------------------------------------
# Temporary image storage: imports (pre-upscale) and exports (post-upscale)
# ---------------------------------------------------------------------------
#
# Opt-in scratch storage, not a sync mechanism — the on-device upscale flow
# never touches this. Rows auto-expire (see _cleanup_loop above); this is
# storage measured in hours/days, not a photo library.


async def _create_stored_image(
    table: str,
    device_id: str,
    file: UploadFile,
    ttl_hours: Optional[int],
    default_content_type: str,
    extra_columns: dict,
) -> dict:
    data = await file.read()
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail=f"Upload exceeds {MAX_UPLOAD_BYTES}-byte limit")
    try:
        width, height = Image.open(io.BytesIO(data)).size
    except Exception:
        raise HTTPException(status_code=400, detail="Could not read image data")

    hours = _resolve_ttl_hours(ttl_hours)
    entry_id = uuid.uuid4().hex
    columns = ["id", "device_id", "expires_at", "filename", "content_type", "width", "height", "file_size_bytes", "image_data"]
    columns += list(extra_columns.keys())
    # NOW() + make_interval(hours => %s) — Postgres's equivalent of MySQL's
    # DATE_ADD(NOW(), INTERVAL %s HOUR). make_interval takes a plain integer
    # arg (not a string to concatenate/cast), so this stays just as
    # injection-safe as every other %s placeholder here.
    placeholders = ["%s", "%s", "NOW() + make_interval(hours => %s)"] + ["%s"] * (len(columns) - 3)
    values = [
        entry_id, device_id, hours, file.filename, file.content_type or default_content_type,
        width, height, len(data), data,
    ] + list(extra_columns.values())

    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join(placeholders)})",
                values,
            )
    # Best-effort — never let a cleanup hiccup fail the upload it rode in on.
    asyncio.create_task(_cleanup_expired_once())
    return {"id": entry_id, "expires_in_hours": hours, "width": width, "height": height}


async def _get_stored_image(table: str, item_id: str) -> Response:
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            await cur.execute(
                f"SELECT image_data, content_type FROM {table} WHERE id = %s AND expires_at > NOW()",
                (item_id,),
            )
            row = await cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Not found or expired")
    return Response(content=row["image_data"], media_type=row["content_type"])


async def _list_stored_images(table: str, device_id: str) -> dict:
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            await cur.execute(
                f"""
                SELECT id, device_id, created_at, expires_at, filename, content_type, width, height, file_size_bytes
                FROM {table} WHERE device_id = %s AND expires_at > NOW()
                ORDER BY created_at DESC
                """,
                (device_id,),
            )
            rows = await cur.fetchall()
    return {"entries": rows}


async def _delete_stored_image(table: str, item_id: str) -> dict:
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(f"DELETE FROM {table} WHERE id = %s", (item_id,))
            deleted = cur.rowcount
    if not deleted:
        raise HTTPException(status_code=404, detail="Not found")
    return {"deleted": True}


@app.post("/import")
async def create_import(
    request: Request,
    device_id: str = Form(...),
    ttl_hours: Optional[int] = Form(None),
    file: UploadFile = File(...),
):
    await check_auth(request)
    return await _create_stored_image("image_imports", device_id, file, ttl_hours, "image/jpeg", {})


@app.get("/import/{import_id}")
async def get_import(import_id: str, request: Request):
    await check_auth(request)
    return await _get_stored_image("image_imports", import_id)


@app.get("/import")
async def list_imports(request: Request, device_id: str = Query(...)):
    await check_auth(request)
    return await _list_stored_images("image_imports", device_id)


@app.delete("/import/{import_id}")
async def delete_import(import_id: str, request: Request):
    await check_auth(request)
    return await _delete_stored_image("image_imports", import_id)


@app.post("/export")
async def create_export(
    request: Request,
    device_id: str = Form(...),
    history_id: Optional[str] = Form(None),
    ttl_hours: Optional[int] = Form(None),
    file: UploadFile = File(...),
):
    await check_auth(request)
    return await _create_stored_image(
        "image_exports", device_id, file, ttl_hours, "image/png",
        {"history_id": history_id} if history_id else {},
    )


@app.get("/export/{export_id}")
async def get_export(export_id: str, request: Request):
    await check_auth(request)
    return await _get_stored_image("image_exports", export_id)


@app.get("/export")
async def list_exports(request: Request, device_id: str = Query(...)):
    await check_auth(request)
    return await _list_stored_images("image_exports", device_id)


@app.delete("/export/{export_id}")
async def delete_export(export_id: str, request: Request):
    await check_auth(request)
    return await _delete_stored_image("image_exports", export_id)


# ---------------------------------------------------------------------------
# Custom presets
# ---------------------------------------------------------------------------


class PresetCreate(BaseModel):
    device_id: str
    name: str
    model_name: str
    overlap: int


@app.post("/presets")
async def create_preset(preset: PresetCreate, request: Request):
    await check_auth(request)
    pool = await get_pool()
    preset_id = uuid.uuid4().hex
    async with pool.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                """
                INSERT INTO custom_presets (id, device_id, name, model_name, overlap)
                VALUES (%s, %s, %s, %s, %s)
                ON CONFLICT (device_id, name) DO UPDATE SET model_name = EXCLUDED.model_name, overlap = EXCLUDED.overlap
                """,
                (preset_id, preset.device_id, preset.name, preset.model_name, preset.overlap),
            )
            # Re-select rather than trust preset_id: ON CONFLICT DO UPDATE
            # leaves an existing row's original id untouched, so a
            # same-name update would otherwise return an id that doesn't
            # match what's actually stored.
            await cur.execute(
                "SELECT id FROM custom_presets WHERE device_id = %s AND name = %s",
                (preset.device_id, preset.name),
            )
            row = await cur.fetchone()
    return {"id": row[0]}


@app.get("/presets")
async def list_presets(request: Request, device_id: str = Query(...)):
    await check_auth(request)
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            await cur.execute(
                """
                SELECT id, device_id, name, model_name, overlap, created_at
                FROM custom_presets WHERE device_id = %s ORDER BY created_at DESC
                """,
                (device_id,),
            )
            rows = await cur.fetchall()
    return {"entries": rows}


@app.delete("/presets/{preset_id}")
async def delete_preset(preset_id: str, request: Request):
    await check_auth(request)
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute("DELETE FROM custom_presets WHERE id = %s", (preset_id,))
            deleted = cur.rowcount
    if not deleted:
        raise HTTPException(status_code=404, detail="Preset not found")
    return {"deleted": True}


# ---------------------------------------------------------------------------
# Device settings backup/restore
# ---------------------------------------------------------------------------
# Manually-triggered (Settings' Backup/Restore actions) — there's no account
# system, so this is a per-device_id backup slot, not automatic sync.


class DeviceSettingsUpsert(BaseModel):
    device_id: str
    haptics_enabled: bool = True
    model_choice: str = "generalPhoto"
    quality: str = "standard"


@app.put("/device-settings")
async def upsert_device_settings(settings: DeviceSettingsUpsert, request: Request):
    await check_auth(request)
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                """
                INSERT INTO device_settings (device_id, haptics_enabled, model_choice, quality)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (device_id) DO UPDATE SET
                    haptics_enabled = EXCLUDED.haptics_enabled,
                    model_choice = EXCLUDED.model_choice,
                    quality = EXCLUDED.quality,
                    updated_at = CURRENT_TIMESTAMP
                """,
                (settings.device_id, settings.haptics_enabled, settings.model_choice, settings.quality),
            )
    return {"saved": True}


@app.get("/device-settings")
async def get_device_settings(request: Request, device_id: str = Query(...)):
    await check_auth(request)
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            await cur.execute(
                """
                SELECT device_id, haptics_enabled, model_choice, quality, updated_at
                FROM device_settings WHERE device_id = %s
                """,
                (device_id,),
            )
            row = await cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="No backup found for this device")
    row["haptics_enabled"] = bool(row["haptics_enabled"])
    return row


# ---------------------------------------------------------------------------
# Model registry
# ---------------------------------------------------------------------------


@app.get("/models")
async def list_models(request: Request):
    await check_auth(request)
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            await cur.execute(
                """
                SELECT model_name, display_name, description, license, tile_size, scale_factor, is_active
                FROM model_registry WHERE is_active = TRUE
                """
            )
            rows = await cur.fetchall()
    for row in rows:
        row["is_active"] = bool(row["is_active"])
    return {"entries": rows}
