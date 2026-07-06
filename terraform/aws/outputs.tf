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

output "internal_alb_security_group_id" {
  description = "Security group ID for the internal gateway ALB."
  value       = aws_security_group.internal_alb.id
}
