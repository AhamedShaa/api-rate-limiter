variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
  # If you don't provide a value, this default is used
}

variable "project_name" {
  description = "Prefix for all resource names — keeps things organized in AWS console"
  type        = string
  default     = "rate-limiter"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "rate_limit_requests" {
  description = "Max tokens per user (max requests per window)"
  type        = number
  default     = 10
}

variable "rate_limit_window_seconds" {
  description = "Time window in seconds before tokens refill"
  type        = number
  default     = 60
}