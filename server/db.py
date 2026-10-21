import aiopg
import logging
import os
import pathlib

logger = logging.getLogger("upscaler-bridge.db")

# aiopg wraps psycopg2 and keeps the same %s-placeholder /
# cursor.execute()/fetchone()/fetchall() API aiomysql used, which is why
# this migration (MariaDB/MySQL -> PostgreSQL) swaps the driver here
# instead of rewriting every parameterized query call site in main.py for
# asyncpg's incompatible $1/$2 placeholders and row-object API — same
# approach Lumisound's ios-bridge took for the same migration. Postgres
# uses `dbname` (not `db`) and has no per-connection `charset` param
# (UTF-8 by default); the default port is 5432, not 3306.
DB_CONFIG = {
    "host": os.getenv("DB_HOST", "127.0.0.1"),
    "port": int(os.getenv("DB_PORT", "5432")),
    "user": os.getenv("DB_USER", "upscaler"),
    # No real default on purpose — set DB_PASSWORD in the environment
    # (compose file / .env / secret manager), never in source.
    "password": os.getenv("DB_PASSWORD", ""),
    "dbname": os.getenv("DB_NAME", "image_upscaler"),
}

_pool: aiopg.Pool | None = None


async def get_pool() -> aiopg.Pool:
    global _pool
    if _pool is None:
        # aiopg connections default to autocommit=True (verified against
        # the real driver), matching aiomysql's explicit autocommit=True
        # this pool used to pass — every plain cur.execute() below still
        # commits immediately with no code changes needed at main.py's
        # call sites. init_db() below is the one place that needs a real
        # multi-statement transaction, which it gets via explicit
        # BEGIN/COMMIT/ROLLBACK statements rather than driver-level
        # conn.begin()/commit()/rollback() — psycopg2/aiopg connections
        # raise "commit cannot be used in asynchronous mode" if you call
        # conn.commit()/rollback() directly instead of issuing the SQL.
        # No timezone pin needed either — unlike MariaDB (session
        # `time_zone` defaults to the host's local `SYSTEM` zone), this
        # Postgres instance's server-level `timezone` is already UTC
        # (confirmed via `SHOW timezone`), so every TIMESTAMP column reads/
        # writes UTC by default with no per-connection setup required.
        # Lowered from the original aiomysql-era default of 10: this pool's
        # connections sit on the SAME shared Postgres instance every one of
        # the 13 music bots + Aria + SwarmPanel + ios-bridge also connect
        # to, whose max_connections=100 was observed sitting at 102/100 in
        # production -- upscaler-bridge's actual traffic doesn't need
        # anywhere near 10 concurrent connections.
        pool_max = int(os.getenv("DB_POOL_MAX_SIZE", "4"))
        _pool = await aiopg.create_pool(**DB_CONFIG, minsize=1, maxsize=pool_max)
    return _pool


def _strip_sql_comments(sql: str) -> str:
    """Removes `--` line comments before the statements are split on `;` —
    a semicolon inside a comment would otherwise slice the comment in
    half. schema.sql has no `$$`-quoted blocks (no plpgsql functions/
    triggers), so a naive split on `;` after comment-stripping stays safe;
    see Lumisound's ios-bridge/db.py for the more general Lua-based
    splitter this app doesn't need."""
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
            await cur.execute("BEGIN")
            try:
                for stmt in sql.split(";"):
                    stmt = stmt.strip()
                    if stmt:
                        await cur.execute(stmt)
                await cur.execute("COMMIT")
            except Exception:
                await cur.execute("ROLLBACK")
                logger.exception("init_db failed; rolled back schema migration")
                raise
