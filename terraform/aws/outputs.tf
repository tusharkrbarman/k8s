output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_region" {
  description = "AWS region containing the EKS cluster."
  value       = var.region
}

output "cluster_endpoint" {
  description = "EKS API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "vpc_id" {
  description = "VPC ID used by the EKS cluster."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs used by the EKS cluster."
  value       = { for az, subnet in aws_subnet.private : az => subnet.id }
}

output "gateway_ecr_repository_url" {
  description = "ECR repository URL for the OpenVINO LLM gateway image."
  value       = aws_ecr_repository.gateway.repository_url
}

output "gateway_image_reference" {
  description = "Immutable gateway image reference when a digest is configured."
  value       = var.gateway_image_digest == "" ? aws_ecr_repository.gateway.repository_url : "${aws_ecr_repository.gateway.repository_url}@${var.gateway_image_digest}"
}

output "model_bucket_name" {
  description = "S3 bucket name for model artifacts."
  value       = aws_s3_bucket.models.bucket
}

output "model_prefix" {
  description = "S3 prefix containing the OpenVINO model."
  value       = var.model_prefix
}

output "gateway_api_key_secret_arn" {
  description = "Secrets Manager ARN for the gateway API key."
  value       = aws_secretsmanager_secret.gateway_api_key.arn
  sensitive   = true
}

output "gateway_api_key_secret_name" {
  description = "Secrets Manager name for the gateway API key."
  value       = aws_secretsmanager_secret.gateway_api_key.name
}

output "internal_alb_security_group_id" {
  description = "Security group ID for the internal gateway ALB."
  value       = aws_security_group.internal_alb.id
}

output "gateway_pod_identity_role_arn" {
  description = "Pod Identity role ARN for the gateway service account."
  value       = aws_iam_role.gateway.arn
}

output "ovms_pod_identity_role_arn" {
  description = "Pod Identity role ARN for the OVMS service account."
  value       = aws_iam_role.ovms.arn
}

output "load_balancer_controller_pod_identity_role_arn" {
  description = "Pod Identity role ARN for the AWS Load Balancer Controller."
  value       = aws_iam_role.load_balancer_controller.arn
}
