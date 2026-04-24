# ─────────────────────────────────────────────────────────
# PACKAGE THE RATE LIMITER LAMBDA
#
# archive_file is a Terraform "data source"
# Data sources READ information — they don't create resources
# archive_file reads your files and creates a ZIP
# ─────────────────────────────────────────────────────────
data "archive_file" "rate_limiter_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/rate_limiter/package"
  # path.module = the terraform/ directory
  # ../lambda/rate_limiter/package = where pip installs dependencies
  output_path = "${path.module}/../lambda/rate_limiter/rate_limiter.zip"
  # Where the ZIP file gets created
}

data "archive_file" "api_handler_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/api_handler"
  output_path = "${path.module}/../lambda/api_handler/api_handler.zip"
}

# ─────────────────────────────────────────────────────────
# IAM ROLE FOR LAMBDA
#
# Every Lambda needs a role.
# This role has two parts:
# 1. Trust policy  → Lambda service can assume this role
# 2. Permissions   → what the role can do
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  # TRUST POLICY
  # Written in JSON — this is AWS's policy language
  # "Who can use this role?"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
          # Only the Lambda SERVICE can assume this role
          # Not EC2, not a human, not anything else
        }
        Action = "sts:AssumeRole"
        # sts = Security Token Service
        # AssumeRole = "pick up this role and use it"
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-lambda-role"
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────
# ATTACH PERMISSIONS TO THE ROLE
#
# aws_iam_role_policy_attachment links a role to a policy
# We use AWS managed policies (pre-built by Amazon)
#
# AWSLambdaVPCAccessExecutionRole gives Lambda:
#   → Create network interfaces (to join the VPC)
#   → Write logs to CloudWatch
# ─────────────────────────────────────────────────────────
resource "aws_iam_role_policy_attachment" "lambda_vpc_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  # ARN = Amazon Resource Name
  # It's a unique identifier for any AWS resource
  # Format: arn:aws:SERVICE::ACCOUNT:RESOURCE
  # "aws:policy" means this is a built-in AWS managed policy
}

# ─────────────────────────────────────────────────────────
# RATE LIMITER LAMBDA FUNCTION
# ─────────────────────────────────────────────────────────
resource "aws_lambda_function" "rate_limiter" {
  function_name = "${var.project_name}-rate-limiter"
  
  filename      = data.archive_file.rate_limiter_zip.output_path
  # The ZIP file Terraform created above
  
  source_code_hash = data.archive_file.rate_limiter_zip.output_base64sha256
  # A fingerprint of your ZIP file
  # If the file changes → hash changes → Terraform redeploys
  # If file unchanged → hash same → Terraform skips upload
  # This prevents unnecessary redeployments

  role    = aws_iam_role.lambda_role.arn
  # The IAM role we created above
  # Lambda picks this up and uses it for all AWS calls

  runtime = "python3.12"
  handler = "handler.handler"
  # FORMAT: "filename.function_name"
  # "handler.handler" means:
  #   → look in handler.py
  #   → call the function named handler()

  timeout     = 10
  # Kill the function if it runs longer than 10 seconds
  # Protects against infinite loops + runaway costs
  # Rate limiter should never need more than 1-2 seconds
  
  memory_size = 256
  # MB of RAM allocated
  # More RAM = more CPU too (Lambda ties them together)
  # 256MB is plenty for Redis operations

  # ── VPC CONFIGURATION ──────────────────────────────────
  # This is what puts Lambda INSIDE our VPC
  # Without this, Lambda cannot reach Redis
  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    # Lambda can run in either subnet
    # AWS picks one automatically per invocation
    
    security_group_ids = [aws_security_group.lambda_sg.id]
    # Attach our firewall
    # This SG is what Redis's SG allows on port 6379
  }

  # ── ENVIRONMENT VARIABLES ──────────────────────────────
  # These get injected into Lambda's runtime
  # Accessible via os.environ in Python
  environment {
    variables = {
      REDIS_HOST  = aws_elasticache_cluster.redis.cache_nodes[0].address
      # The Redis endpoint we got from our earlier output
      # Terraform injects the real value automatically
      
      REDIS_PORT  = tostring(aws_elasticache_cluster.redis.port)
      RATE_LIMIT  = tostring(var.rate_limit_requests)
      WINDOW_SECS = tostring(var.rate_limit_window_seconds)
    }
  }

  tags = {
    Name        = "${var.project_name}-rate-limiter"
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────
# API HANDLER LAMBDA FUNCTION
# Your actual business logic
# Only runs if rate limiter returns 200
# ─────────────────────────────────────────────────────────
resource "aws_lambda_function" "api_handler" {
  function_name    = "${var.project_name}-api-handler"
  filename         = data.archive_file.api_handler_zip.output_path
  source_code_hash = data.archive_file.api_handler_zip.output_base64sha256
  role             = aws_iam_role.lambda_role.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 30
  # API handler gets more time than rate limiter
  # It might do database calls, processing, etc.
  memory_size      = 256

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      ENVIRONMENT = var.environment
    }
  }

  tags = {
    Name        = "${var.project_name}-api-handler"
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────
# CLOUDWATCH LOG GROUPS
# Lambda automatically creates these but then never deletes them
# By defining them in Terraform:
#   → We control the retention period
#   → Terraform cleans them up on destroy
#   → No orphaned log groups in your account
# ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "rate_limiter_logs" {
  name              = "/aws/lambda/${aws_lambda_function.rate_limiter.function_name}"
  # AWS expects this exact naming format for Lambda logs
  retention_in_days = 14
  # Delete logs older than 14 days
  # Logs cost money. Don't keep them forever in dev.

  tags = {
    Name        = "${var.project_name}-rate-limiter-logs"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_log_group" "api_handler_logs" {
  name              = "/aws/lambda/${aws_lambda_function.api_handler.function_name}"
  retention_in_days = 14

  tags = {
    Name        = "${var.project_name}-api-handler-logs"
    Environment = var.environment
  }
}