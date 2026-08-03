data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

locals {
  gateway_pod_identity_assume_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEksAuthToAssumeRoleForPodIdentity"
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession",
      ]
    }]
  })

  workload_pod_identity_assume_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession",
      ]
    }]
  })
}

resource "aws_iam_role" "cluster" {
  name               = var.cluster_role_name
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role" "node" {
  name               = var.node_role_name
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role" "gateway" {
  name               = var.gateway_role_name
  assume_role_policy = local.gateway_pod_identity_assume_policy
}

resource "aws_iam_role" "ovms" {
  name               = var.ovms_role_name
  description        = "Allows pods running in Amazon EKS cluster to access AWS resources."
  assume_role_policy = local.workload_pod_identity_assume_policy
}

resource "aws_iam_role" "load_balancer_controller" {
  name               = var.load_balancer_controller_role_name
  description        = "Allows pods running in Amazon EKS cluster to access AWS resources."
  assume_role_policy = local.workload_pod_identity_assume_policy
}

locals {
  cluster_policy_arns = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicyV2",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
  ])

  node_policy_arns = toset([
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:aws:iam::aws:policy/AmazonElasticContainerRegistryPublicReadOnly",
  ])
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = local.cluster_policy_arns

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = local.node_policy_arns

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "gateway_secret_read" {
  statement {
    sid = "ReadGatewayApiKey"

    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]

    resources = [aws_secretsmanager_secret.gateway_api_key.arn]
  }
}

data "aws_iam_policy" "gateway_secret_read_existing" {
  count = var.adopt_existing ? 1 : 0
  arn   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.cluster_name}-gateway-secret-read"
}

data "aws_iam_policy" "model_artifact_read_existing" {
  count = var.adopt_existing ? 1 : 0
  arn   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.cluster_name}-model-read"
}

locals {
  gateway_secret_read_policy = var.adopt_existing ? data.aws_iam_policy.gateway_secret_read_existing[0].policy : data.aws_iam_policy_document.gateway_secret_read.json
}

resource "aws_iam_policy" "gateway_secret_read" {
  name   = "${var.cluster_name}-gateway-secret-read"
  policy = local.gateway_secret_read_policy
}

resource "aws_iam_role_policy_attachment" "gateway" {
  role       = aws_iam_role.gateway.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.cluster_name}-gateway-secret-read"
}

data "aws_iam_policy_document" "model_artifact_read" {
  statement {
    sid       = "ListModelPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.models.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [var.model_prefix, "${var.model_prefix}/*"]
    }
  }

  statement {
    sid       = "ReadModelObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.models.arn}/${var.model_prefix}/*"]
  }
}

locals {
  model_artifact_read_policy = var.adopt_existing ? data.aws_iam_policy.model_artifact_read_existing[0].policy : data.aws_iam_policy_document.model_artifact_read.json
}

resource "aws_iam_policy" "model_artifact_read" {
  name   = "${var.cluster_name}-model-read"
  policy = local.model_artifact_read_policy
}

resource "aws_iam_role_policy_attachment" "ovms" {
  role       = aws_iam_role.ovms.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.cluster_name}-model-read"
}

data "aws_iam_policy" "load_balancer_controller" {
  arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/AWSLoadBalancerControllerIAMPolicy"
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = data.aws_iam_policy.load_balancer_controller.arn
}

resource "aws_eks_pod_identity_association" "gateway" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "llm-inference"
  service_account = "llm-gateway"
  role_arn        = aws_iam_role.gateway.arn
}

resource "aws_eks_pod_identity_association" "ovms" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "llm-inference"
  service_account = "ovms-model-reader"
  role_arn        = aws_iam_role.ovms.arn
}

resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.load_balancer_controller.arn
}
