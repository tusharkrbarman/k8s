resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = false
    }

    service_ipv4_cidr = var.service_ipv4_cidr
    ip_family         = "ipv4"
  }

  control_plane_scaling_config {
    tier = "standard"
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  zonal_shift_config {
    enabled = false
  }

  vpc_config {
    endpoint_private_access = var.cluster_endpoint_private_access
    endpoint_public_access  = var.cluster_endpoint_public_access
    public_access_cidrs     = var.cluster_public_access_cidrs
    subnet_ids              = values(aws_subnet.private)[*].id
  }

  enabled_cluster_log_types = var.cluster_enabled_log_types

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
  ]
}

resource "aws_eks_node_group" "inference" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = var.node_group_name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = values(aws_subnet.private)[*].id

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  disk_size      = var.node_disk_size
  instance_types = var.node_instance_types
  version        = var.cluster_version

  scaling_config {
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
    min_size     = var.node_min_size
  }

  update_config {
    max_unavailable = 1
    update_strategy = "DEFAULT"
  }

  node_repair_config {
    enabled = false
  }

  labels = {
    nodepool  = "m7i-inference"
    inference = "openvino-cpu"
    hardware  = "intel-cpu"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
  ]
}

resource "aws_eks_access_entry" "node" {
  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = aws_iam_role.node.arn
  type              = "EC2_LINUX"
  kubernetes_groups = ["system:nodes"]
  user_name         = "system:node:{{EC2PrivateDNSName}}"
}

resource "aws_eks_access_entry" "admin" {
  count = var.cluster_admin_principal_arn == null ? 0 : 1

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.cluster_admin_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  count = var.cluster_admin_principal_arn == null ? 0 : 1

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.cluster_admin_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_addon" "this" {
  for_each = var.managed_addon_versions

  cluster_name  = aws_eks_cluster.this.name
  addon_name    = each.key
  addon_version = each.value

  dynamic "pod_identity_association" {
    for_each = each.key == "aws-ebs-csi-driver" && var.ebs_csi_pod_identity_role_arn != null ? [1] : []

    content {
      role_arn        = var.ebs_csi_pod_identity_role_arn
      service_account = "ebs-csi-controller-sa"
    }
  }

  depends_on = [aws_eks_cluster.this]
}
