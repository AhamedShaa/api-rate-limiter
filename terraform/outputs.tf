output "redis_endpoint" {
  description = "Redis connection endpoint — Lambda uses this to connect"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "redis_port" {
  description = "Redis port (always 6379)"
  value       = aws_elasticache_cluster.redis.port
}

output "vpc_id" {
  description = "VPC ID — useful for debugging"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Subnet IDs — Lambda needs these to join the VPC"
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "lambda_security_group_id" {
  description = "Lambda SG ID — needed when creating Lambda functions"
  value       = aws_security_group.lambda_sg.id
}

output "api_endpoint" {
  description = "Public URL of your API — use this for testing"
  value       = aws_apigatewayv2_stage.default.invoke_url
}