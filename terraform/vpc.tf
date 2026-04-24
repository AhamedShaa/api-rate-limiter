# ─────────────────────────────────────────────────────────
# THE VPC
# This is your private network on AWS.
# Everything else we build lives inside this.
# ─────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  # CIDR = IP range this VPC owns
  # 10.0.0.0/16 = 65,536 private IP addresses
  # We'll carve subnets out of this pool

  enable_dns_hostnames = true
  enable_dns_support   = true
  # These two allow resources inside the VPC
  # to resolve AWS service domain names
  # Lambda needs this to call AWS APIs internally

  tags = {
    Name        = "${var.project_name}-vpc"
    Environment = var.environment
    # Tags are just metadata — labels in AWS console
    # Always tag resources. Future you will be thankful.
  }
}

# ─────────────────────────────────────────────────────────
# PRIVATE SUBNET A  (Availability Zone A)
# Redis will live in these subnets.
# "Private" means no direct route to internet.
# ─────────────────────────────────────────────────────────
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  # Connect this subnet to our VPC
  # aws_vpc.main.id = reference to the VPC we just created above
  # Terraform resolves this automatically — no manual copy-pasting of IDs

  cidr_block        = "10.0.1.0/24"
  # This subnet owns 10.0.1.0 → 10.0.1.255
  # 256 IPs — more than enough for our Redis nodes

  availability_zone = "${var.aws_region}a"
  # "us-east-1a" — physical data center A

  tags = {
    Name = "${var.project_name}-private-subnet-a"
  }
}

# ─────────────────────────────────────────────────────────
# PRIVATE SUBNET B  (Availability Zone B)
# Second subnet in a different AZ.
# ElastiCache requires 2 AZs minimum for its subnet group.
# ─────────────────────────────────────────────────────────
resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  # Different range from subnet A — no overlapping IPs allowed
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "${var.project_name}-private-subnet-b"
  }
}

# ─────────────────────────────────────────────────────────
# SECURITY GROUP — LAMBDA
# Attached to our Lambda functions.
# Lambda needs to REACH OUT to Redis and AWS services.
# It doesn't receive direct inbound connections.
# ─────────────────────────────────────────────────────────
resource "aws_security_group" "lambda_sg" {
  name        = "${var.project_name}-lambda-sg"
  description = "Controls traffic for Lambda functions"
  vpc_id      = aws_vpc.main.id

  # No inbound rules needed
  # Lambda is invoked by API Gateway through AWS internals
  # not through direct network connections

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    # -1 = all protocols (TCP, UDP, everything)
    cidr_blocks = ["0.0.0.0/0"]
    # 0.0.0.0/0 = anywhere
    # Lambda can reach out to anything
    # This includes: Redis, CloudWatch, other AWS services
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${var.project_name}-lambda-sg"
  }
}

# ─────────────────────────────────────────────────────────
# SECURITY GROUP — REDIS
# Attached to our ElastiCache cluster.
# Only Lambda should be able to reach Redis.
# Nothing else. Not the internet. Not your laptop.
# ─────────────────────────────────────────────────────────
resource "aws_security_group" "redis_sg" {
  name        = "${var.project_name}-redis-sg"
  description = "Controls traffic for ElastiCache Redis"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port = 6379
    to_port   = 6379
    protocol  = "tcp"
    # Port 6379 is Redis's default port
    # Like how port 443 is HTTPS, port 6379 is Redis

    security_groups = [aws_security_group.lambda_sg.id]
    # KEY POINT: instead of allowing an IP range,
    # we allow a specific SECURITY GROUP (Lambda's).
    # This means: "only resources attached to lambda_sg
    # can connect to Redis"
    # Even if Lambda's IP changes — this rule still works.

    description = "Redis access from Lambda only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "${var.project_name}-redis-sg"
  }
}

# ─────────────────────────────────────────────────────────
# VPC ENDPOINT FOR CLOUDWATCH LOGS
# Here's the problem:
#   Lambda is INSIDE the VPC (private network)
#   CloudWatch Logs is an AWS service OUTSIDE the VPC
#   Private network = no internet access
#   So Lambda can't send logs to CloudWatch?
#
# Solution: VPC Endpoint
#   A private tunnel from your VPC directly to AWS services
#   Traffic never leaves the AWS network
#   No internet required
# ─────────────────────────────────────────────────────────
resource "aws_vpc_endpoint" "cloudwatch_logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  # "Interface" type = creates a private network interface
  # inside your VPC that routes to the AWS service

  subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids = [aws_security_group.lambda_sg.id]

  private_dns_enabled = true
  # Lambda calls logs.us-east-1.amazonaws.com
  # With this enabled, that domain resolves to
  # the private endpoint — not the public internet

  tags = {
    Name = "${var.project_name}-cloudwatch-endpoint"
  }
}