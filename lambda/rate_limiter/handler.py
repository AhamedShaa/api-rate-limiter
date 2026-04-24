import json
import os
import redis

# ─────────────────────────────────────────────────────────
# REDIS CONNECTION
# We create this OUTSIDE the handler function.
#
# Why? Lambda reuses the same execution environment
# for multiple invocations (when it's "warm").
# 
# If we connected inside the handler:
#   Every single request = new connection = slow + wasteful
#
# If we connect outside (module level):
#   First request  = create connection
#   Next requests  = reuse same connection
#   Much faster.
#
# This is called "connection reuse" — important pattern.
# ─────────────────────────────────────────────────────────
REDIS_HOST = os.environ['REDIS_HOST']
REDIS_PORT = int(os.environ.get('REDIS_PORT', 6379))
RATE_LIMIT  = int(os.environ.get('RATE_LIMIT', 10))
WINDOW_SECS = int(os.environ.get('WINDOW_SECS', 60))

# Global connection — created once, reused across invocations
redis_client = None

def get_redis_client():
    """
    Returns Redis client, creating it if it doesn't exist yet.
    This pattern is called a "singleton" —
    only one instance exists no matter how many times you call this.
    """
    global redis_client
    if redis_client is None:
        redis_client = redis.Redis(
            host=REDIS_HOST,
            port=REDIS_PORT,
            decode_responses=True,
            # decode_responses=True means Redis returns Python strings
            # instead of bytes. Much easier to work with.
            socket_connect_timeout=2,
            # If Redis doesn't respond in 2 seconds, fail fast
            # Don't let one slow Redis call hang your entire API
            socket_timeout=2
        )
    return redis_client

# ─────────────────────────────────────────────────────────
# THE LUA SCRIPT
# Defined as a constant — it never changes.
# Redis will execute this atomically.
# ─────────────────────────────────────────────────────────
RATE_LIMIT_LUA = """
local current = redis.call('GET', KEYS[1])

if current == false then
    redis.call('SET', KEYS[1], ARGV[1])
    redis.call('EXPIRE', KEYS[1], ARGV[2])
    return tonumber(ARGV[1]) - 1
end

local count = tonumber(current)

if count <= 0 then
    return -1
end

redis.call('DECR', KEYS[1])
redis.call('EXPIRE', KEYS[1], ARGV[2])

return count - 1
"""

def get_client_identifier(event):
    """
    Extract a unique identifier for the requester.
    
    Priority:
    1. x-api-key header  → specific client identifier
    2. X-Forwarded-For   → their IP address (fallback)
    3. "anonymous"       → last resort
    """
    headers = event.get('headers') or {}

    # Headers can come in any case — normalize to lowercase
    # "X-Api-Key" and "x-api-key" are the same header
    headers_lower = {k.lower(): v for k, v in headers.items()}

    if 'x-api-key' in headers_lower:
        api_key = headers_lower['x-api-key']
        return f"apikey:{api_key}"
        # prefix with "apikey:" so Redis key is clear
        # Redis key will be: "tokens:apikey:user-abc-123"

    if 'x-forwarded-for' in headers_lower:
        # X-Forwarded-For can contain multiple IPs:
        # "203.0.113.1, 10.0.0.1, 172.16.0.1"
        # The FIRST one is the real client IP
        ip = headers_lower['x-forwarded-for'].split(',')[0].strip()
        return f"ip:{ip}"
        # Redis key: "tokens:ip:203.0.113.1"

    return "anonymous"

def build_response(status_code, message, remaining, limit=RATE_LIMIT):
    """
    Build the response object API Gateway expects.
    Always include rate limit headers — good API practice.
    """
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "X-RateLimit-Limit": str(limit),
            # How many requests max per window
            "X-RateLimit-Remaining": str(max(0, remaining)),
            # How many left (never show negative)
            "X-RateLimit-Window": str(WINDOW_SECS),
            # Window size in seconds
        },
        "body": json.dumps({
            "message": message,
            "limit": limit,
            "remaining": max(0, remaining),
            "window_seconds": WINDOW_SECS
        })
    }

def handler(event, context):
    """
    Main Lambda handler — entry point for every request.
    
    event   = the request data (headers, body, path, etc.)
    context = Lambda metadata (function name, timeout remaining, etc.)
    """
    
    # ── Step 1: Identify the client ──────────────────────
    client_id = get_client_identifier(event)
    redis_key = f"tokens:{client_id}"
    # Final key example: "tokens:apikey:user-abc-123"
    # This is what gets stored in Redis

    # ── Step 2: Connect to Redis ─────────────────────────
    try:
        r = get_redis_client()
    except Exception as e:
        # Redis is unreachable
        # FAIL OPEN: let the request through
        # 
        # Why fail open?
        # If Redis goes down and we fail closed (block everyone),
        # our entire API goes down with it.
        # Better to have no rate limiting than no service.
        # This is a deliberate product decision.
        print(f"Redis connection failed: {str(e)}")
        return build_response(200, "allowed (cache unavailable)", RATE_LIMIT)

    # ── Step 3: Run the atomic Lua script ────────────────
    try:
        remaining = r.eval(
            RATE_LIMIT_LUA,
            1,               # number of KEYS arguments
            redis_key,       # KEYS[1]
            RATE_LIMIT,      # ARGV[1] — max tokens
            WINDOW_SECS      # ARGV[2] — expiry seconds
        )
        # remaining = tokens left after this request
        # remaining = -1 means bucket was empty (DENIED)

    except Exception as e:
        # Lua script failed — fail open
        print(f"Rate limit check failed: {str(e)}")
        return build_response(200, "allowed (rate limit error)", RATE_LIMIT)

    # ── Step 4: Allow or Deny ─────────────────────────────
    if remaining == -1:
        # Bucket empty — reject this request
        print(f"Rate limit exceeded for {client_id}")
        return build_response(
            429,
            "Rate limit exceeded. Try again later.",
            0
        )

    # Request is allowed
    print(f"Request allowed for {client_id}. Tokens remaining: {remaining}")
    return build_response(
        200,
        "allowed",
        remaining
    )