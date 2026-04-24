# cdn-request-demo

A FastAPI application demonstrating ETags, HTTP caching, and Kubernetes health
probes, fronted by Varnish as a local CDN simulator.

```
client → :8080  Varnish (CDN layer)  → :8000  FastAPI app
                                       :8000  also reachable directly
```

---

## Running

### Local (uv)

```bash
uv sync
uv run uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

### Docker Compose / Podman Compose

```bash
# start everything
podman compose up --build        # or: docker compose up --build

# stop
podman compose down
```

Set `BASE=http://localhost:8080` in the examples below to test through Varnish,
or `BASE=http://localhost:8000` to hit the app directly.

---

## Demo script

`demo.sh` walks through every scenario automatically with coloured output:

```bash
# against Varnish (default)
./demo.sh

# against the app directly
BASE=http://localhost:8000 ./demo.sh
```

---

## curl examples

```bash
BASE=http://localhost:8080   # via Varnish (CDN simulation)
# BASE=http://localhost:8000 # direct to app
```

---

### Kubernetes probes

```bash
# Liveness — always 200 while the process is alive
curl -si $BASE/healthz/live

# Readiness — 503 for ~2 s on startup, then 200
curl -si $BASE/healthz/ready
```

---

### GET an item

```bash
# First request — Varnish cache MISS, app populates in-memory cache
curl -si $BASE/items/widget

# Second request — Varnish cache HIT (X-Cache: HIT in response headers)
curl -si $BASE/items/widget

# Non-existent item → 404
curl -si $BASE/items/ghost
```

---

### HEAD — validate cache without fetching a body

```bash
# Returns same headers as GET but with no body
curl -si --head $BASE/items/widget
```

---

### Conditional requests (ETag / If-None-Match)

```bash
# Capture the current ETag
ETAG=$(curl -si $BASE/items/widget | grep -i '^etag:' | tr -d '\r' | awk '{print $2}')
echo "ETag: $ETAG"

# Send it back — content unchanged → 304 Not Modified, zero bytes transferred
curl -si -H "If-None-Match: $ETAG" $BASE/items/widget

# Stale ETag → 200 with full body
curl -si -H 'If-None-Match: "stalevalue"' $BASE/items/widget
```

---

### Optimistic-concurrency update (If-Match)

```bash
# Capture current ETag
ETAG=$(curl -si $BASE/items/widget | grep -i '^etag:' | tr -d '\r' | awk '{print $2}')

# Update with correct ETag → 200 with new ETag
curl -si -X PUT \
  -H 'Content-Type: application/json' \
  -H "If-Match: $ETAG" \
  -d '{"price": 4.99}' \
  $BASE/items/widget

# Update with wrong ETag → 412 Precondition Failed
curl -si -X PUT \
  -H 'Content-Type: application/json' \
  -H 'If-Match: "wrongetag"' \
  -d '{"price": 4.99}' \
  $BASE/items/widget

# Update without If-Match (no concurrency check) → 200
curl -si -X PUT \
  -H 'Content-Type: application/json' \
  -d '{"price": 4.99}' \
  $BASE/items/widget
```

---

### DELETE an item

```bash
# Capture current ETag
ETAG=$(curl -si $BASE/items/gadget | grep -i '^etag:' | tr -d '\r' | awk '{print $2}')

# Delete with correct ETag → 204, item and cache entry removed
curl -si -X DELETE -H "If-Match: $ETAG" $BASE/items/gadget

# Delete with wrong ETag → 412 Precondition Failed
curl -si -X DELETE -H 'If-Match: "wrongetag"' $BASE/items/widget

# Delete without If-Match (no concurrency check) → 204
curl -si -X DELETE $BASE/items/widget

# Deleted item → 404
curl -si $BASE/items/gadget
```

---



```bash
# Purge a single item from the app's in-memory ETag cache → 204
# The next GET will do a fresh DB read and repopulate the cache.
curl -si -X DELETE $BASE/cache/items/widget

# Purging an item not in cache is a no-op → still 204
curl -si -X DELETE $BASE/cache/items/ghost
```

---

### Observing the full caching lifecycle

The sequence below shows a complete round-trip through Varnish:

```bash
BASE=http://localhost:8080

# 1. Cold start — Varnish MISS, app cache MISS
curl -si $BASE/items/widget | grep -E 'x-cache|etag|cache-control'

# 2. Varnish HIT within the 60 s s-maxage window
curl -si $BASE/items/widget | grep 'x-cache'
# → X-Cache: HIT

# 3. After 60 s Varnish TTL expires — Varnish revalidates with the app
#    using If-None-Match. App returns 304, Varnish resets its TTL.
#    (Simulate by sending the ETag yourself:)
ETAG=$(curl -si $BASE/items/widget | grep -i '^etag:' | tr -d '\r' | awk '{print $2}')
curl -si -H "If-None-Match: $ETAG" $BASE/items/widget | head -3
# → HTTP/1.1 304 Not Modified

# 4. Update the item — purges app in-memory cache, new ETag issued
curl -si -X PUT \
  -H 'Content-Type: application/json' \
  -H "If-Match: $ETAG" \
  -d '{"stock": 100}' \
  $BASE/items/widget | grep etag

# 5. Purge Varnish cache entry via PURGE method (from a trusted IP)
curl -si -X PURGE $BASE/items/widget | head -2

# 6. Next GET is a fresh MISS with the updated data and new ETag
curl -si $BASE/items/widget | grep -E 'x-cache|etag|\{'
```

---

## Cache-Control header breakdown

```
Cache-Control: public, max-age=86400, s-maxage=60, stale-while-revalidate=86340
```

| Directive | Audience | Behaviour |
|---|---|---|
| `max-age=86400` | Browser | Cache for 1 day |
| `s-maxage=60` | CDN / Varnish | Fresh for 60 s, then revalidate with origin |
| `stale-while-revalidate=86340` | CDN / Varnish | Serve stale while revalidating in background for up to 86 340 s more (total 1 day) |

In Varnish these map to `beresp.ttl = 60s` and `beresp.grace = 86340s`.
