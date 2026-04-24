vcl 4.1;

import std;

# ---------------------------------------------------------------------------
# Backend — the FastAPI application
# ---------------------------------------------------------------------------
backend default {
    .host = "app";
    .port = "8000";

    # Use the readiness probe so Varnish marks the backend unhealthy during
    # startup and won't forward requests until the app is ready.
    .probe = {
        .url       = "/healthz/ready";
        .interval  = 5s;
        .timeout   = 2s;
        .window    = 5;
        .threshold = 3;
    }
}

# ---------------------------------------------------------------------------
# Trusted sources that may send PURGE requests
# NOTE: "0.0.0.0"/0 trusts all IPs — demo only, not for production.
#       In production, restrict to your CDN/load-balancer IPs.
# ---------------------------------------------------------------------------
acl purge_acl {
    "0.0.0.0"/0;
}

# ---------------------------------------------------------------------------
# Request handling
# ---------------------------------------------------------------------------
sub vcl_recv {
    # Health probe endpoints must never be served from cache
    if (req.url ~ "^/healthz/") {
        return(pass);
    }

    # Cache-management purge — only from trusted IPs
    if (req.method == "PURGE") {
        if (!client.ip ~ purge_acl) {
            return(synth(403, "Forbidden"));
        }
        return(purge);
    }

    # Only GET and HEAD are cacheable; pass writes straight through
    if (req.method != "GET" && req.method != "HEAD") {
        return(pass);
    }

    # Don't cache authenticated requests
    if (req.http.Authorization) {
        return(pass);
    }

    return(hash);
}

# ---------------------------------------------------------------------------
# Backend response — map our Cache-Control directives to Varnish internals
# ---------------------------------------------------------------------------
sub vcl_backend_response {
    # s-maxage drives how long Varnish considers the object fresh.
    # (Varnish 7 parses this automatically, but we set it explicitly so the
    # behaviour is clear and independent of version defaults.)
    if (beresp.http.Cache-Control ~ "s-maxage=(\d+)") {
        set beresp.ttl = std.duration(
            regsub(beresp.http.Cache-Control, ".*s-maxage=(\d+).*", "\1") + "s",
            60s   # fallback if parsing fails
        );
    }

    # stale-while-revalidate maps directly to Varnish grace: Varnish serves
    # the stale object immediately while fetching a fresh copy in the
    # background, exactly mirroring what a CDN does with this directive.
    if (beresp.http.Cache-Control ~ "stale-while-revalidate=(\d+)") {
        set beresp.grace = std.duration(
            regsub(beresp.http.Cache-Control, ".*stale-while-revalidate=(\d+).*", "\1") + "s",
            86340s   # fallback
        );
    }

    # Cache 404s briefly so a missing item doesn't hammer the backend
    if (beresp.status == 404) {
        set beresp.ttl   = 10s;
        set beresp.grace = 0s;
    }

    return(deliver);
}

# ---------------------------------------------------------------------------
# Deliver — add diagnostic headers so you can observe caching behaviour
# ---------------------------------------------------------------------------
sub vcl_deliver {
    if (obj.hits > 0) {
        set resp.http.X-Cache      = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
    } else {
        set resp.http.X-Cache = "MISS";
    }

    return(deliver);
}
