#!/usr/bin/env bash
# demo.sh — walks through every caching / ETag scenario end-to-end.
# Usage:
#   ./demo.sh                  # targets Varnish on localhost:8080
#   BASE=http://localhost:8000 ./demo.sh   # hit the app directly

set -euo pipefail

BASE="${BASE:-http://localhost:8080}"

# ── colours ────────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
DIM='\033[2m'
RESET='\033[0m'

header()  { echo -e "\n${CYAN}━━━  $*  ${RESET}"; }
label()   { echo -e "${BOLD}▶ $*${RESET}"; }
comment() { echo -e "${DIM}    # $*${RESET}"; }
ok()      { echo -e "${GREEN}    ✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}    ! $*${RESET}"; }

run() {
    echo -e "${DIM}    \$ $*${RESET}"
    # Inject -w so curl appends the total request time after the response body
    "$@" -w "\nTotal: %{time_total}s\n" 2>&1 | sed 's/^/    /'
    echo
}

run_filtered() {
    # Like run but only prints lines matching a grep pattern.
    # Usage: run_filtered <pattern> <curl args...>
    local pattern="$1"; shift
    echo -e "${DIM}    \$ $*${RESET}"
    local out
    out=$("$@" -w "\nTotal: %{time_total}s\n" 2>&1)
    echo "$out" | grep -E "$pattern" | sed 's/^/    /' || true
    echo "$out" | grep 'Total:' | sed 's/^/    /'
    echo
}

echo -e "\n${BOLD}cdn-request-demo — end-to-end scenario walkthrough${RESET}"
echo -e "${DIM}Target: ${BASE}${RESET}"

# ── wait for the stack to be up ────────────────────────────────────────────
header "0. Waiting for the stack to be ready"
label "Polling $BASE/healthz/ready ..."
for i in $(seq 1 30); do
    if curl -sf "$BASE/healthz/ready" > /dev/null 2>&1; then
        ok "Stack is ready (attempt $i)"
        break
    fi
    echo -e "${DIM}    attempt $i — not ready yet, waiting 2 s...${RESET}"
    sleep 2
    if [[ $i -eq 30 ]]; then
        warn "Stack did not become ready in time. Is 'podman compose up' running?"
        exit 1
    fi
done

# ── 1. health probes ───────────────────────────────────────────────────────
header "1. Kubernetes health probes"

label "Liveness — always 200"
run curl -si "$BASE/healthz/live"

label "Readiness — 200 once startup delay has passed"
run curl -si "$BASE/healthz/ready"

# ── 2. plain GET ───────────────────────────────────────────────────────────
header "2. GET an item"

label "First request — Varnish MISS, app cache MISS (expect ~5 s due to simulated DB latency)"
run curl -si "$BASE/items/widget"

label "Second request — Varnish HIT (X-Cache: HIT, instant)"
run curl -si "$BASE/items/widget"

label "Non-existent item → 404"
run curl -si "$BASE/items/ghost"

# ── 3. HEAD ────────────────────────────────────────────────────────────────
header "3. HEAD — fetch headers without a body"

comment "Same ETag and Cache-Control as GET; Content-Length is 0"
run curl -si --head "$BASE/items/widget"

# ── 4. conditional GET — 304 ──────────────────────────────────────────────
header "4. Conditional GET — If-None-Match"

ETAG=$(curl -si "$BASE/items/widget" | grep -i '^etag:' | tr -d '\r' | awk '{print $2}')
echo -e "    Captured ETag: ${BOLD}${ETAG}${RESET}\n"

label "Send matching ETag → 304 Not Modified (zero bytes, instant even after purge)"
run curl -si -H "If-None-Match: $ETAG" "$BASE/items/widget"

label "Send stale ETag → 200 with full body"
run curl -si -H 'If-None-Match: "stalevalue"' "$BASE/items/widget"

# ── 5. optimistic-concurrency update ──────────────────────────────────────
header "5. Optimistic-concurrency update — If-Match"

label "PUT with correct ETag → 200, new ETag issued"
NEW_RESPONSE=$(curl -si -X PUT \
    -H 'Content-Type: application/json' \
    -H "If-Match: $ETAG" \
    -d '{"price": 4.99}' \
    "$BASE/items/widget")
echo "$NEW_RESPONSE" | sed 's/^/    /'
echo

NEW_ETAG=$(echo "$NEW_RESPONSE" | grep -i '^etag:' | tr -d '\r' | awk '{print $2}')
echo -e "    New ETag: ${BOLD}${NEW_ETAG}${RESET}\n"

label "PUT with the now-stale original ETag → 412 Precondition Failed"
run curl -si -X PUT \
    -H 'Content-Type: application/json' \
    -H "If-Match: $ETAG" \
    -d '{"price": 9.99}' \
    "$BASE/items/widget"

label "PUT without If-Match (no concurrency check) → 200"
run curl -si -X PUT \
    -H 'Content-Type: application/json' \
    -d '{"price": 9.99}' \
    "$BASE/items/widget"

# ── 6. app cache purge ────────────────────────────────────────────────────
header "6. App in-memory cache purge"

comment "Prime the cache first"
curl -s "$BASE/items/gadget" > /dev/null

label "Purge gadget from app cache → 204"
run curl -si -X DELETE "$BASE/cache/items/gadget"

label "Next GET is a cache miss again (expect ~5 s DB delay)"
run curl -si "$BASE/items/gadget"

label "Purging an item not in cache is a no-op → still 204"
run curl -si -X DELETE "$BASE/cache/items/ghost"

# ── 7. Varnish PURGE ──────────────────────────────────────────────────────
header "7. Varnish cache purge (PURGE method, trusted IPs only)"

comment "This is only accepted from within the Docker/Podman network or localhost"
comment "Has no effect when running against the app directly (BASE=:8000)"
label "PURGE widget from Varnish → 200 (or 405 if hitting the app directly)"
run curl -si -X PURGE "$BASE/items/widget"

label "Next GET after Varnish purge is a MISS again"
run_filtered 'x-cache|etag|HTTP' curl -si "$BASE/items/widget"

# ── 8. full lifecycle ─────────────────────────────────────────────────────
header "8. Full caching lifecycle"

comment "Reset widget to a known state"
curl -s -X PUT -H 'Content-Type: application/json' \
    -d '{"price": 9.99, "stock": 42}' \
    "$BASE/items/widget" > /dev/null
curl -si -X PURGE "$BASE/items/widget" > /dev/null
curl -si -X DELETE "$BASE/cache/items/widget" > /dev/null

label "Step 1 — cold start (Varnish MISS + app cache MISS, slow)"
run curl -si "$BASE/items/widget"

ETAG=$(curl -si "$BASE/items/widget" | grep -i '^etag:' | tr -d '\r' | awk '{print $2}')
echo -e "    ETag: ${BOLD}${ETAG}${RESET}\n"

label "Step 2 — Varnish HIT, instant"
run_filtered 'x-cache|X-Cache not present' curl -si "$BASE/items/widget" || \
    echo "    (X-Cache not present — running without Varnish)"

label "Step 3 — Simulate CDN revalidation (If-None-Match) → 304, no body"
run curl -si -H "If-None-Match: $ETAG" "$BASE/items/widget"

label "Step 4 — Update item (new ETag, app cache purged automatically)"
run curl -si -X PUT \
    -H 'Content-Type: application/json' \
    -H "If-Match: $ETAG" \
    -d '{"stock": 100}' \
    "$BASE/items/widget"

label "Step 5 — Purge Varnish so it picks up the new version immediately"
run curl -si -X PURGE "$BASE/items/widget"

label "Step 6 — Next GET is a MISS with fresh data and new ETag"
run_filtered 'x-cache|etag|HTTP|\{' curl -si "$BASE/items/widget"

echo -e "\n${GREEN}${BOLD}All scenarios complete.${RESET}\n"
