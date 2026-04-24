# API Rate Limiter — AWS Serverless

A serverless API rate limiter built on AWS using a **token bucket algorithm** backed by Redis (ElastiCache). Every incoming request passes through a rate-limiter Lambda before reaching the actual API handler — enforcing per-client request limits with atomic, race-condition-free counting via a Redis Lua script.

---

## Architecture

<!-- Add your architecture diagram image here -->
![Architecture Diagram](E:\System_design_projects\api-rate-limiter/Architecture.png)

---

## How It Works

1. **Client** sends a request to API Gateway.
2. **API Gateway** routes all traffic (`$default`) to the **Rate Limiter Lambda**.
3. The Rate Limiter Lambda identifies the client (by `x-api-key` header, IP, or "anonymous") and runs an atomic **Lua script** against **Redis (ElastiCache)**.
4. If tokens remain → request is forwarded to the **API Handler Lambda** and a `200` is returned.
5. If the bucket is empty → `429 Too Many Requests` is returned immediately.
6. If Redis is unreachable → **fail-open**: the request is allowed through (uptime over rate limiting).

### Token Bucket via Redis Lua Script

The core rate-limiting logic runs atomically in Redis using a Lua script — no race conditions, no double-counting across concurrent Lambda invocations:

```lua
local current = redis.call('GET', KEYS[1])

if current == false then
    redis.call('SET', KEYS[1], ARGV[1])   -- initialize bucket
    redis.call('EXPIRE', KEYS[1], ARGV[2])
    return tonumber(ARGV[1]) - 1
end

local count = tonumber(current)
if count <= 0 then return -1 end          -- bucket empty → deny

redis.call('DECR', KEYS[1])
redis.call('EXPIRE', KEYS[1], ARGV[2])
return count - 1                          -- tokens remaining
```

---

## Project Structure

```
api-rate-limiter/
├── lambda/
│   ├── api_handler/
│   │   └── handler.py          # Business logic Lambda (runs after rate check passes)
│   └── rate_limiter/
│       ├── handler.py          # Rate limiter Lambda — core logic
│       ├── requirements.txt    # Python dependencies (redis-py)
│       └── package/            # Bundled dependencies for Lambda deployment
├── terraform/
│   ├── main.tf                 # Provider and Terraform version config
│   ├── variables.tf            # All configurable inputs
│   ├── vpc.tf                  # VPC, subnets, security groups
│   ├── lambda.tf               # Lambda functions and IAM role
│   ├── elasticache.tf          # Redis cluster configuration
│   ├── api_gateway.tf          # HTTP API Gateway routes
│   └── outputs.tf              # Exported values (API URL, Redis endpoint, etc.)
└── tests/
    └── load_test.js            # k6 load test (steady traffic + burst scenarios)
```

---

## AWS Services Used

| Service | Role |
|---|---|
| **API Gateway v2 (HTTP)** | Public endpoint — receives all requests |
| **Lambda (Rate Limiter)** | Checks token bucket; allows or rejects |
| **Lambda (API Handler)** | Actual business logic, only reached if allowed |
| **ElastiCache (Redis 7)** | Token bucket store — atomic, sub-millisecond |
| **VPC + Private Subnets** | Network isolation — Redis unreachable from internet |
| **Security Groups** | Firewall: only Lambda SG can reach Redis on port 6379 |
| **CloudWatch Logs** | Structured logs for API Gateway and both Lambdas |
| **IAM Role** | Least-privilege role for Lambda VPC + CloudWatch access |

---

## Configuration

All tuneable parameters are in `terraform/variables.tf`:

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region to deploy into |
| `project_name` | `rate-limiter` | Prefix for all AWS resource names |
| `environment` | `dev` | Deployment environment tag |
| `rate_limit_requests` | `10` | Max requests per client per window |
| `rate_limit_window_seconds` | `60` | Window duration in seconds |

---

## Response Headers

Every response includes rate limit headers so clients can self-throttle:

```
X-RateLimit-Limit: 10
X-RateLimit-Remaining: 7
X-RateLimit-Window: 60
```

---

## Deployment

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.3.0
- [AWS CLI](https://aws.amazon.com/cli/) configured with credentials
- Python 3.12 (for local Lambda development)

### Steps

```bash
# 1. Install Lambda dependencies
cd lambda/rate_limiter
pip install -r requirements.txt -t package/

# Copy handler into package dir
cp handler.py package/

# 2. Deploy infrastructure
cd ../../terraform
terraform init
terraform plan
terraform apply
```

Terraform will output the public API URL on completion:

```
api_endpoint = "https://<id>.execute-api.us-east-1.amazonaws.com/"
```

### Destroy

```bash
terraform destroy
```

---

## Load Testing

The project includes a [k6](https://k6.io/) load test with two scenarios:

- **Steady traffic** — 5 req/s for 30s (should stay under limit)
- **Burst traffic** — 20 req/s for 30s (should trigger `429`s)

```bash
# Update API_URL in tests/load_test.js first
k6 run tests/load_test.js
```

---

## Client Identification Priority

| Priority | Source | Redis Key Format |
|---|---|---|
| 1 | `x-api-key` header | `tokens:apikey:<key>` |
| 2 | `X-Forwarded-For` IP | `tokens:ip:<ip>` |
| 3 | Fallback | `tokens:anonymous` |

---

## Design Decisions

**Why Lua script instead of Redis transactions?**  
Lua scripts execute atomically on the Redis server — no round trips between GET and DECR, so two concurrent Lambdas can never both see the same token count and both decrement it.

**Why fail-open on Redis errors?**  
If Redis goes down and we block all requests, the entire API goes down with it. Failing open means rate limiting is temporarily suspended but the service stays up. This is a deliberate availability-over-correctness tradeoff.

**Why module-level Redis connection in Lambda?**  
Lambda reuses execution environments ("warm starts"). Connecting at module level means one TCP connection is established on first invocation and reused for all subsequent warm invocations — reducing latency and connection overhead.

**Why private subnets for Redis?**  
ElastiCache has no built-in authentication in this config. Putting it in a private subnet with a security group that only allows Lambda's SG is the primary security control — Redis is never reachable from the internet.
