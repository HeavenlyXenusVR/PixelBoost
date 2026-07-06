import aiomysql
import logging
import os
import pathlib

logger = logging.getLogger("upscaler-bridge.db")

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "127.0.0.1"),
    "port": int(os.getenv("DB_PORT", "3306")),
    "user": os.getenv("DB_USER", "upscaler"),
    # No real default on purpose — set DB_PASSWORD in the environment
    # (compose file / .env / secret manager), never in source.
    "password": os.getenv("DB_PASSWORD", ""),
    "db": os.getenv("DB_NAME", "image_upscaler"),
    "charset": "utf8mb4",
    "autocommit": True,
}

_pool: aiomysql.Pool | None = None


async def get_pool() -> aiomysql.Pool:
    global _pool
    if _pool is None:
        _pool = await aiomysql.create_pool(**DB_CONFIG, minsize=1, maxsize=10)
    return _pool


def _strip_sql_comments(sql: str) -> str:
    """Removes `--` line comments before the statements are split on `;` —
    see Lumisound's ios-bridge/db.py for why this matters (a semicolon
    inside a comment would otherwise slice the comment in half)."""
    lines: list[str] = []
    for line in sql.splitlines():
        idx = line.find("--")
        lines.append(line[:idx] if idx != -1 else line)
    return "\n".join(lines)


async def init_db():
    """Create tables if they don't exist, wrapped in a transaction."""
    pool = await get_pool()
    raw = pathlib.Path(__file__).parent.joinpath("schema.sql").read_text()
    sql = _strip_sql_comments(raw)
    async with pool.acquire() as conn:
        async with conn.cursor() as cur:
            await conn.begin()
            try:
                for stmt in sql.split(";"):
                    stmt = stmt.strip()
                    if stmt:
                        await cur.execute(stmt)
                await conn.commit()
            except Exception:
                await conn.rollback()
                logger.exception("init_db failed; rolled back schema migration")
                raise
