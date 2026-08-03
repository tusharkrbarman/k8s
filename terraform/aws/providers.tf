provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  tags = {
    Project     = "openvino-llm-poc"
    Environment = "poc"
    ManagedBy   = "terraform"
  }

  private_subnet_specs = {
    for index, az in var.availability_zones : az => {
      cidr = var.private_subnet_cidrs[index]
    }
  }

  public_subnet_specs = {
    for index, az in var.availability_zones : az => {
      cidr = var.public_subnet_cidrs[index]
    }
  }

  interface_endpoint_services = toset([
    "ecr.api",
    "ecr.dkr",
    "ec2",
    "secretsmanager",
    "sts",
    "logs",
    "monitoring",
    "eks-auth",
  ])

  adopted_tags = var.adopt_existing ? null : local.tags
}
