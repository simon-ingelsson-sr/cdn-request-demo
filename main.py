import hashlib
import json
import logging
import time
from dataclasses import dataclass
from threading import Lock

from fastapi import FastAPI, Request, Response, HTTPException
from fastapi.responses import JSONResponse

_PROBE_PATHS = {"/healthz/live", "/healthz/ready"}


class _SuppressProbes(logging.Filter):
    """Drop uvicorn access-log entries for Kubernetes probe endpoints."""

    def filter(self, record: logging.LogRecord) -> bool:
        # uvicorn formats the access log message as:
        #   '<ip>:<port> - "GET /healthz/live HTTP/1.1" 200'
        msg = record.getMessage()
        return not any(path in msg for path in _PROBE_PATHS)


logging.getLogger("uvicorn.access").addFilter(_SuppressProbes())

_CACHE_CONTROL = "public, max-age=86400, s-maxage=60, stale-while-revalidate=86340"

app = FastAPI(title="ETag Cache Demo")

# Simulated data store — in production this would be a real database
_ITEMS: dict[str, dict] = {
    "widget": {"id": "widget", "name": "Widget", "price": 9.99, "stock": 42},
    "gadget": {"id": "gadget", "name": "Gadget", "price": 24.99, "stock": 7},
}

# Track when the app became ready (simulate an async startup delay)
_START_TIME = time.monotonic()
_READY_AFTER_SECONDS = 2

# Simulated database latency — makes the cache benefit clearly observable
_DB_LATENCY_SECONDS = 5


# ---------------------------------------------------------------------------
# In-memory cache
# ---------------------------------------------------------------------------

@dataclass
class _CacheEntry:
    item: dict
    etag: str


class _ItemCache:
    """
    Thread-safe in-memory cache for item data and pre-computed ETags.

    NOTE: this is a single-process cache. With multiple uvicorn workers
    each process has its own cache; use Redis or similar for multi-process
    deployments.
    """

    def __init__(self) -> None:
        self._store: dict[str, _CacheEntry] = {}
        self._lock = Lock()

    def get(self, item_id: str) -> _CacheEntry | None:
        with self._lock:
            return self._store.get(item_id)

    def set(self, item_id: str, item: dict, etag: str) -> None:
        with self._lock:
            self._store[item_id] = _CacheEntry(item=item, etag=etag)

    def purge(self, item_id: str) -> None:
        with self._lock:
            self._store.pop(item_id, None)


_cache = _ItemCache()


def _etag_for(data: dict) -> str:
    """Compute a stable ETag from the JSON representation of data."""
    payload = json.dumps(data, sort_keys=True).encode()
    return f'"{hashlib.sha256(payload).hexdigest()[:16]}"'


def _load_item(item_id: str) -> _CacheEntry | None:
    """Return a cache entry, populating the cache from the DB on a miss."""
    entry = _cache.get(item_id)
    if entry is not None:
        return entry

    # Cache miss — simulate a slow database round-trip
    time.sleep(_DB_LATENCY_SECONDS)

    item = _ITEMS.get(item_id)
    if item is None:
        return None

    etag = _etag_for(item)
    _cache.set(item_id, item, etag)
    return _cache.get(item_id)


# ---------------------------------------------------------------------------
# Kubernetes probes
# ---------------------------------------------------------------------------

@app.get("/healthz/live", tags=["probes"], summary="Liveness probe")
def liveness():
    """Always returns 200 while the process is alive."""
    return {"status": "alive"}


@app.get("/healthz/ready", tags=["probes"], summary="Readiness probe")
def readiness():
    """Returns 200 once the app has finished its startup delay."""
    elapsed = time.monotonic() - _START_TIME
    if elapsed < _READY_AFTER_SECONDS:
        raise HTTPException(status_code=503, detail="starting up")
    return {"status": "ready"}


# ---------------------------------------------------------------------------
# Item resource — GET + HEAD with ETag / conditional-request support
# ---------------------------------------------------------------------------

@app.get("/items/{item_id}", tags=["items"])
def get_item(item_id: str, request: Request, response: Response):
    """
    Return an item with full ETag and Cache-Control headers.

    Conditional-request flow:
    - If ``If-None-Match`` matches the cached ETag → 304 immediately, no DB access.
    - Otherwise ``_load_item`` is called (cache hit or DB fallback).
    """
    # Fast path: if the client's ETag matches what's already in cache we can
    # return 304 without touching the DB or deserialising the item at all.
    if_none_match = request.headers.get("if-none-match")
    if if_none_match:
        cached = _cache.get(item_id)
        if cached is not None and cached.etag == if_none_match:
            return Response(status_code=304, headers={
                "ETag": cached.etag,
                "Cache-Control": _CACHE_CONTROL,
            })

    entry = _load_item(item_id)
    if entry is None:
        raise HTTPException(status_code=404, detail=f"Item '{item_id}' not found")

    response.headers["ETag"] = entry.etag
    response.headers["Cache-Control"] = _CACHE_CONTROL

    if request.method == "HEAD":
        return Response(headers=dict(response.headers))

    return entry.item


@app.head("/items/{item_id}", include_in_schema=False)
def head_item(item_id: str, request: Request, response: Response):
    """HEAD variant — same logic as GET but body is never serialised."""
    return get_item(item_id, request, response)


@app.put("/items/{item_id}", tags=["items"])
def update_item(item_id: str, request: Request, body: dict):
    """
    Update an item with optimistic-concurrency via ``If-Match``.

    - If the client sends ``If-Match`` that does *not* match the current ETag → 412 Precondition Failed.
    - On success the cache entry is purged and the response carries the new ETag.
    """
    entry = _load_item(item_id)
    if entry is None:
        raise HTTPException(status_code=404, detail=f"Item '{item_id}' not found")

    if_match = request.headers.get("if-match")
    if if_match and if_match != entry.etag:
        raise HTTPException(
            status_code=412,
            detail="Precondition Failed — ETag mismatch; fetch the latest version first",
        )

    updated = {**entry.item, **body, "id": item_id}
    _ITEMS[item_id] = updated

    # Purge stale cache entry so the next read fetches fresh data
    _cache.purge(item_id)

    new_etag = _etag_for(updated)
    return JSONResponse(content=updated, headers={
        "ETag": new_etag,
        "Cache-Control": "no-cache",
    })


@app.delete("/items/{item_id}", tags=["items"], status_code=204)
def delete_item(item_id: str, request: Request):
    """
    Delete an item with optimistic-concurrency via ``If-Match``.

    - If the client sends ``If-Match`` that does *not* match the current ETag → 412 Precondition Failed.
    - On success the item is removed from the DB and the cache entry is purged.
    - Returns 204 No Content.
    """
    entry = _load_item(item_id)
    if entry is None:
        raise HTTPException(status_code=404, detail=f"Item '{item_id}' not found")

    if_match = request.headers.get("if-match")
    if if_match and if_match != entry.etag:
        raise HTTPException(
            status_code=412,
            detail="Precondition Failed — ETag mismatch; fetch the latest version first",
        )

    del _ITEMS[item_id]
    _cache.purge(item_id)


# ---------------------------------------------------------------------------
# Cache management
# ---------------------------------------------------------------------------

@app.delete("/cache/items/{item_id}", tags=["cache"], status_code=204,
            summary="Purge item from ETag cache")
def purge_cache(item_id: str):
    """
    Evict a single item from the in-memory ETag cache.

    The item itself is **not** deleted — only the cached representation is
    dropped. The next GET/HEAD will perform a fresh DB read and repopulate
    the cache.

    Returns 204 whether or not the item was present in the cache.
    """
    _cache.purge(item_id)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
