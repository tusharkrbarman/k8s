provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  private_subnets = [
    for index in range(2) : cidrsubnet(var.vpc_cidr, 4, index)
  ]

  public_subnets = [
    for index in range(2) : cidrsubnet(var.vpc_cidr, 4, index + 8)
  ]

  tags = {
    Project     = "openvino-llm-poc"
    Environment = "poc"
    ManagedBy   = "terraform"
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway = true
  single_nat_gateway = true

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  tags = local.tags
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

module "aws_load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.cluster_name}-aws-lbc"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.36"

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = false

  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    system_gateway = {
      name = "system-gateway"

      min_size     = 2
      max_size     = 2
      desired_size = 2

      instance_types = var.system_instance_types

      labels = {
        nodepool = "system-gateway"
        workload = "platform"
      }
    }

    m7i_inference = {
      name = "m7i-inference"

      min_size     = 2
      max_size     = 2
      desired_size = 2

      instance_types = var.inference_instance_types

      labels = {
        nodepool  = "m7i-inference"
        inference = "openvino-cpu"
        hardware  = "intel-cpu"
      }
    }
  }

  tags = local.tags
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = var.ebs_csi_addon_version
  service_account_role_arn = module.ebs_csi_irsa.iam_role_arn

  depends_on = [
    module.eks,
    module.ebs_csi_irsa,
  ]

  tags = local.tags
}

resource "aws_eks_addon" "secrets_store_csi_driver_provider" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-secrets-store-csi-driver-provider"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [module.eks]

  tags = local.tags
}

resource "aws_ecr_repository" "gateway" {
  name                 = var.gateway_image_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_s3_bucket" "models" {
  bucket = var.model_bucket_name

  tags = local.tags
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket = aws_s3_bucket.models.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_secretsmanager_secret" "gateway_api_key" {
  name        = "/openvino-llm-poc/gateway/api-key"
  description = "Gateway API key placeholder. Populate the secret value outside Terraform."

  tags = local.tags
}

data "aws_iam_policy_document" "gateway_api_key_read" {
  statement {
    sid = "ReadGatewayApiKey"

    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]

    resources = [aws_secretsmanager_secret.gateway_api_key.arn]
  }
}

resource "aws_iam_policy" "gateway_api_key_read" {
  name        = "${var.cluster_name}-gateway-api-key-read"
  description = "Allow the gateway service account to read its API key secret."
  policy      = data.aws_iam_policy_document.gateway_api_key_read.json

  tags = local.tags
}

module "gateway_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-llm-gateway"

  role_policy_arns = {
    gateway_api_key_read = aws_iam_policy.gateway_api_key_read.arn
  }

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["llm-inference:llm-gateway"]
    }
  }

  tags = local.tags
}

data "aws_iam_policy_document" "model_artifact_read" {
  statement {
    sid = "ListModelBucket"

    actions = [
      "s3:ListBucket",
    ]

    resources = [aws_s3_bucket.models.arn]
  }

  statement {
    sid = "ReadModelArtifacts"

    actions = [
      "s3:GetObject",
    ]

    resources = ["${aws_s3_bucket.models.arn}/*"]
  }
}

resource "aws_iam_policy" "model_artifact_read" {
  name        = "${var.cluster_name}-model-artifact-read"
  description = "Allow the OVMS model reader service account to read approved model artifacts."
  policy      = data.aws_iam_policy_document.model_artifact_read.json

  tags = local.tags
}

module "ovms_model_reader_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-ovms-model-reader"

  role_policy_arns = {
    model_artifact_read = aws_iam_policy.model_artifact_read.arn
  }

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["llm-inference:ovms-model-reader"]
    }
  }

  tags = local.tags
}

resource "aws_security_group" "internal_alb" {
  name        = "${var.cluster_name}-internal-alb"
  description = "Allow trusted private HTTP traffic to the internal gateway ALB."
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Trusted private HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.trusted_private_cidrs
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-internal-alb"
  })
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.cluster_name}-vpc-endpoints"
  description = "Allow private HTTPS access to interface VPC endpoints."
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "VPC HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-vpc-endpoints"
  })
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-s3"
  })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset([
    "ecr.api",
    "ecr.dkr",
    "secretsmanager",
    "sts",
    "logs",
    "monitoring",
  ])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-${replace(each.key, ".", "-")}"
  })
}

resource "kubernetes_service_account" "aws_load_balancer_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = module.aws_load_balancer_controller_irsa.iam_role_arn
    }

    labels = {
      "app.kubernetes.io/name" = "aws-load-balancer-controller"
    }
  }

  automount_service_account_token = true
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_load_balancer_controller_chart_version
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.aws_load_balancer_controller.metadata[0].name
  }

  depends_on = [kubernetes_service_account.aws_load_balancer_controller]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"

  depends_on = [module.eks]
}

resource "helm_release" "argo_cd" {
  name       = "argo-cd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argo_cd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  depends_on = [kubernetes_namespace.argocd]
}
