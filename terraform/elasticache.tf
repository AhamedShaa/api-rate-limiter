# ─────────────────────────────────────────────────────────
# 1. PARAMETER GROUP
# Redis configuration settings for our cluster.
# We create a custom one instead of using AWS defaults
# so we control exactly how Redis behaves.
# ─────────────────────────────────────────────────────────
resource "aws_elasticache_parameter_group" "redis" {
  family = "redis7"
  # "family" = which Redis version this config applies to
  # redis7 = Redis version 7.x
  # Must match the engine_version in the cluster below

  name   = "${var.project_name}-redis-params"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
    # When RAM fills up:
    # Delete least recently used keys first
    # Perfect for rate limiting — old/inactive users get cleaned up
  }

  tags = {
    Name        = "${var.project_name}-redis-params"
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────
# 2. SUBNET GROUP
# Tells ElastiCache which subnets it's allowed to use.
# Must include subnets from at least 2 AZs.
# (We discussed why — failover capability)
# ─────────────────────────────────────────────────────────
resource "aws_elasticache_subnet_group" "redis" {
  name = "${var.project_name}-redis-subnet-group"

  subnet_ids = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id
    # Referencing the subnets we created in vpc.tf
    # Terraform knows to create vpc.tf resources FIRST
    # because of this reference — automatic dependency
  ]

  tags = {
    Name        = "${var.project_name}-redis-subnet-group"
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────
# 3. THE REDIS CLUSTER
# The actual Redis instance.
# Everything above was just configuration for this.
# ─────────────────────────────────────────────────────────
resource "aws_elasticache_cluster" "redis" {
  cluster_id = "${var.project_name}-redis"
  # The name of your cluster in AWS console

  engine         = "redis"
  engine_version = "7.0"
  # Using Redis 7.0 — latest stable
  # Must match the "family" in parameter group above

  node_type = "cache.t3.micro"
  # Smallest available — perfect for dev
  # 0.5 GB RAM is more than enough for token counts

  num_cache_nodes = 1
  # Single node for dev
  # Production: use aws_elasticache_replication_group
  # for multi-node with automatic failover

  parameter_group_name = aws_elasticache_parameter_group.redis.name
  # Attach our custom config (maxmemory-policy = allkeys-lru)

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  # Tell Redis which subnets it can live in

  security_group_ids = [aws_security_group.redis_sg.id]
  # Attach the firewall — only Lambda can reach port 6379
  # This references redis_sg from vpc.tf

  port = 6379
  # Default Redis port
  # Like how websites use 443 for HTTPS
  # Redis uses 6379

  # Maintenance window — when AWS can do updates
  # Pick a low-traffic time for your users
  maintenance_window = "sun:05:00-sun:06:00"
  # Every Sunday 5-6 AM UTC

  # Snapshot/backup window
  snapshot_window          = "04:00-05:00"
  snapshot_retention_limit = 1
  # Keep 1 day of backups
  # For rate limiting this isn't critical
  # (losing token counts just resets everyone's limits)
  # But good practice to always have backups

  tags = {
    Name        = "${var.project_name}-redis"
    Environment = var.environment
  }
}