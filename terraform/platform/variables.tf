variable "region" {
  description = "AWS region containing the EKS cluster."
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "openvino-llm-poc"
}

variable "vpc_id" {
  description = "VPC ID passed to the AWS Load Balancer Controller."
  type        = string
  default     = "vpc-09f5d3038235fc21d"
}

variable "adopt_existing" {
  description = "Adopt the existing Helm release instead of creating it."
  type        = bool
  default     = false
}

variable "controller_release_name" {
  description = "Helm release name for the AWS Load Balancer Controller."
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "controller_chart_version" {
  description = "Pinned AWS Load Balancer Controller chart version."
  type        = string
  default     = "1.14.0"
}
