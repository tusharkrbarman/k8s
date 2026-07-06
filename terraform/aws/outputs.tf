output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint."
  value       = module.eks.cluster_endpoint
}

output "gateway_ecr_repository_url" {
  description = "ECR repository URL for the OpenVINO LLM gateway image."
  value       = aws_ecr_repository.gateway.repository_url
}

output "model_bucket_name" {
  description = "S3 bucket name for model artifacts."
  value       = aws_s3_bucket.models.bucket
}

output "gateway_api_key_secret_arn" {
  description = "Secrets Manager secret ARN for the gateway API key."
  value       = aws_secretsmanager_secret.gateway_api_key.arn
}

output "gateway_service_account_role_arn" {
  description = "IAM role ARN for the llm-inference/llm-gateway service account."
  value       = module.gateway_irsa.iam_role_arn
}

output "ovms_model_reader_service_account_role_arn" {
  description = "IAM role ARN for the llm-inference/ovms-model-reader service account."
  value       = module.ovms_model_reader_irsa.iam_role_arn
}

output "internal_alb_security_group_id" {
  description = "Security group ID for the internal gateway ALB."
  value       = aws_security_group.internal_alb.id
}
