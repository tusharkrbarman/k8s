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
  description = "Private CIDR ranges allowed to reach the internal gateway ALB."
  type        = list(string)
  default     = ["10.0.0.0/8"]
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
