variable "region" {
  description = "AWS region for the EKS OpenVINO LLM POC."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "openvino-llm-poc"
}

variable "vpc_cidr" {
  description = "CIDR block for the EKS VPC."
  type        = string
  default     = "10.80.0.0/16"
}

variable "trusted_private_cidrs" {
  description = "Private CIDR ranges allowed to reach the internal gateway ALB over HTTP port 80 for the first POC. Replace with VPN, Direct Connect, or client CIDRs for a real deployment."
  type        = list(string)
  default     = ["10.80.0.0/16"]
}

variable "gateway_image_name" {
  description = "Name of the ECR repository for the OpenVINO LLM gateway image."
  type        = string
  default     = "openvino-llm-gateway"
}

variable "model_bucket_name" {
  description = "Globally unique S3 bucket name for model artifacts."
  type        = string
}

variable "system_instance_types" {
  description = "Instance types for platform and gateway nodes."
  type        = list(string)
  default     = ["m7i-flex.xlarge"]
}

variable "inference_instance_types" {
  description = "Instance types for OpenVINO CPU inference nodes."
  type        = list(string)
  default     = ["m7i.2xlarge"]
}

variable "ebs_csi_addon_version" {
  description = "Pinned AWS EBS CSI Driver EKS add-on version."
  type        = string
  default     = "v1.34.0-eksbuild.1"
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Pinned AWS Load Balancer Controller Helm chart version."
  type        = string
  default     = "1.8.2"
}

variable "secrets_store_csi_driver_chart_version" {
  description = "Pinned Secrets Store CSI Driver Helm chart version."
  type        = string
  default     = "1.4.8"
}

variable "aws_secrets_provider_chart_version" {
  description = "Pinned AWS Secrets Manager CSI provider Helm chart version."
  type        = string
  default     = "1.0.1"
}

variable "argo_cd_chart_version" {
  description = "Pinned Argo CD Helm chart version."
  type        = string
  default     = "7.6.12"
}
