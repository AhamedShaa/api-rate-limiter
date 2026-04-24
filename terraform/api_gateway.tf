# ─────────────────────────────────────────────────────────
# API GATEWAY
# The public-facing HTTP endpoint.
# Receives requests → triggers rate limiter Lambda
# ─────────────────────────────────────────────────────────
resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
  # HTTP API (v2) — newer, faster, cheaper than REST API (v1)

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PUT", "DELETE"]
    allow_headers = ["*"]
  }

  tags = {
    Name        = "${var.project_name}-api"
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────
# INTEGRATION — API Gateway → Rate Limiter Lambda
# Tells API Gateway which Lambda to call
# ─────────────────────────────────────────────────────────
resource "aws_apigatewayv2_integration" "rate_limiter" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "AWS_PROXY"
  # AWS_PROXY = pass the full request to Lambda as-is
  # Lambda gets everything: headers, body, path, method
  
  integration_uri    = aws_lambda_function.rate_limiter.invoke_arn
  payload_format_version = "2.0"
}

# ─────────────────────────────────────────────────────────
# ROUTE — which paths trigger which integration
# $default catches ALL paths and methods
# ─────────────────────────────────────────────────────────
resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "$default"
  # $default = catch-all
  # Every request to this API hits the rate limiter first
  
  target = "integrations/${aws_apigatewayv2_integration.rate_limiter.id}"
}

# ─────────────────────────────────────────────────────────
# STAGE — a deployment environment for the API
# "auto_deploy = true" means every change deploys instantly
# ─────────────────────────────────────────────────────────
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_logs.arn
    format = jsonencode({
    requestId      = "$context.requestId"
    sourceIp       = "$context.identity.sourceIp"
    requestTime    = "$context.requestTime"
    httpMethod     = "$context.httpMethod"
    routeKey       = "$context.routeKey"
    status         = "$context.status"
    responseLength = "$context.responseLength"
    })
  }

  tags = {
    Name        = "${var.project_name}-stage"
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────
# CLOUDWATCH LOG GROUP FOR API GATEWAY
# ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "api_gateway_logs" {
  name              = "/aws/apigateway/${var.project_name}"
  retention_in_days = 14

  tags = {
    Name        = "${var.project_name}-apigw-logs"
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────
# PERMISSION — Allow API Gateway to invoke Lambda
# Without this, API Gateway gets "AccessDenied" 
# when trying to call your Lambda function
# ─────────────────────────────────────────────────────────
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rate_limiter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
  # execution_arn/*/* = allow from any stage, any route
}