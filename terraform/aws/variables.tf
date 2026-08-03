variable "region" {
  description = "AWS region for the EKS OpenVINO LLM POC."
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "openvino-llm-poc"
}

variable "cluster_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.36"
}

variable "adopt_existing" {
  description = "Import the existing AWS environment instead of creating a new one."
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "CIDR block for the EKS VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability Zones used by the two-subnet POC."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs for private subnets, in availability-zone order."
  type        = list(string)
  default     = ["10.0.128.0/20", "10.0.144.0/20"]
}

variable "public_subnet_cidrs" {
  description = "CIDRs for public subnets, in availability-zone order."
  type        = list(string)
  default     = ["10.0.0.0/20", "10.0.16.0/20"]
}

variable "trusted_private_cidrs" {
  description = "CIDR ranges allowed to reach the internal gateway ALB over HTTP."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "cluster_endpoint_private_access" {
  description = "Enable private EKS API endpoint access."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Enable public EKS API endpoint access during bootstrap."
  type        = bool
  default     = true
}

variable "cluster_public_access_cidrs" {
  description = "CIDR ranges allowed to reach the public EKS API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_enabled_log_types" {
  description = "EKS control-plane log types enabled for the adopted cluster."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_admin_principal_arn" {
  description = "Existing IAM principal granted cluster-admin access."
  type        = string
  default     = null
  nullable    = true
}

variable "service_ipv4_cidr" {
  description = "Kubernetes service IPv4 CIDR."
  type        = string
  default     = "172.20.0.0/16"
}

variable "node_group_name" {
  description = "Managed node group name."
  type        = string
  default     = "m7i-inference"
}

variable "node_instance_types" {
  description = "Instance types for OpenVINO CPU inference nodes."
  type        = list(string)
  default     = ["m7i.xlarge"]
}

variable "node_disk_size" {
  description = "Root disk size in GiB for the inference node group."
  type        = number
  default     = 100
}

variable "node_min_size" {
  description = "Minimum inference node count."
  type        = number
  default     = 1
}

variable "node_desired_size" {
  description = "Desired inference node count."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum inference node count."
  type        = number
  default     = 1
}

variable "gateway_image_name" {
  description = "ECR repository name for the OpenVINO LLM gateway image."
  type        = string
  default     = "openvino-llm-gateway"
}

variable "gateway_image_digest" {
  description = "Immutable gateway image digest without the leading at-sign."
  type        = string
  default     = ""
}

variable "model_bucket_name" {
  description = "S3 bucket name for model artifacts."
  type        = string
  default     = "openvino-llm-models-654158184275-ap-south-1"
}

variable "model_prefix" {
  description = "S3 prefix containing the OpenVINO model."
  type        = string
  default     = "OpenVINO/Phi-3.5-mini-instruct-int4-ov"
}

variable "gateway_api_key_secret_name" {
  description = "Secrets Manager name for the gateway API key."
  type        = string
  default     = "/openvino-llm-poc/gateway/api-key"
}

variable "existing_gateway_api_key_secret_arn" {
  description = "Existing Secrets Manager ARN used when adopting the live secret."
  type        = string
  default     = null
  nullable    = true
}

variable "managed_addon_versions" {
  description = "Managed add-on versions adopted into Terraform."
  type        = map(string)
  default = {
    aws-ebs-csi-driver                    = "v1.63.1-eksbuild.1"
    aws-secrets-store-csi-driver-provider = "v3.1.1-eksbuild.2"
    coredns                               = "v1.14.3-eksbuild.3"
    eks-node-monitoring-agent             = "v1.6.7-eksbuild.1"
    eks-pod-identity-agent                = "v1.3.10-eksbuild.3"
    kube-proxy                            = "v1.36.0-eksbuild.13"
    metrics-server                        = "v0.9.0-eksbuild.5"
    vpc-cni                               = "v1.22.3-eksbuild.1"
  }
}

variable "ebs_csi_pod_identity_role_arn" {
  description = "Existing EBS CSI Pod Identity role ARN when adopting the managed add-on."
  type        = string
  default     = null
  nullable    = true
}

variable "existing_vpc_id" {
  description = "Existing VPC ID used when adopt_existing is true."
  type        = string
  default     = null
  nullable    = true
}

variable "existing_internet_gateway_id" {
  description = "Existing internet gateway ID used when adopt_existing is true."
  type        = string
  default     = null
  nullable    = true
}

variable "existing_private_subnet_ids" {
  description = "Existing private subnet IDs keyed by Availability Zone."
  type        = map(string)
  default     = {}
}

variable "existing_public_subnet_ids" {
  description = "Existing public subnet IDs keyed by Availability Zone."
  type        = map(string)
  default     = {}
}

variable "existing_private_route_table_id" {
  description = "Existing main/private route table ID."
  type        = string
  default     = null
  nullable    = true
}

variable "existing_public_route_table_id" {
  description = "Existing public route table ID."
  type        = string
  default     = null
  nullable    = true
}

variable "existing_nat_gateway_id" {
  description = "Existing NAT gateway ID."
  type        = string
  default     = null
  nullable    = true
}

variable "existing_nat_eip_allocation_id" {
  description = "Existing NAT EIP allocation ID."
  type        = string
  default     = null
  nullable    = true
}

variable "existing_vpc_endpoint_ids" {
  description = "Existing VPC endpoint IDs keyed by service suffix."
  type        = map(string)
  default     = {}
}

variable "existing_security_group_ids" {
  description = "Existing custom security group IDs keyed by purpose."
  type        = map(string)
  default     = {}
}

variable "existing_cluster_security_group_id" {
  description = "EKS-generated cluster security group ID."
  type        = string
  default     = null
  nullable    = true
}

variable "cluster_role_name" {
  description = "IAM role name used by the EKS control plane."
  type        = string
  default     = "openvino-llm-poc-cluster-role"
}

variable "node_role_name" {
  description = "IAM role name used by managed worker nodes."
  type        = string
  default     = "openvino-llm-poc-node-role"
}

variable "gateway_role_name" {
  description = "IAM role name used by the gateway Pod Identity association."
  type        = string
  default     = "openvino-llm-poc-llm-gateway"
}

variable "ovms_role_name" {
  description = "IAM role name used by the OVMS Pod Identity association."
  type        = string
  default     = "openvino-llm-poc-ovms-model-reader"
}

variable "load_balancer_controller_role_name" {
  description = "IAM role name used by the AWS Load Balancer Controller."
  type        = string
  default     = "openvino-llm-poc-aws-lbc"
}

variable "existing_pod_identity_association_ids" {
  description = "Existing workload Pod Identity association IDs keyed by workload."
  type        = map(string)
  default     = {}
}

variable "existing_access_entry_principals" {
  description = "Existing EKS access-entry principals to import."
  type        = map(string)
  default     = {}
}

variable "existing_access_policy_association_ids" {
  description = "Existing EKS access-policy association IDs keyed by principal and policy."
  type        = map(string)
  default     = {}
}
