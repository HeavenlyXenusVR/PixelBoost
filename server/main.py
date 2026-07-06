import logging
import os
import uuid
from contextlib import asynccontextmanager
from typing import Optional

import aiomysql
from fastapi import FastAPI, HTTPException, Query, Request
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


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


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
    # DictCursor so the response rows can be returned as-is, rather than
    # aiomysql's default plain tuples.
    async with pool.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
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
    # MariaDB's BOOLEAN is a TINYINT under the hood, so aiomysql hands back a
    # plain 0/1 int here — coerce to a real bool so the JSON response is
    # `true`/`false` rather than `1`/`0` (Swift's Codable Bool decoder
    # rejects the latter outright).
    for row in rows:
        row["success"] = bool(row["success"])
    return {"entries": rows}
