import {
  for_each = var.adopt_existing && var.existing_vpc_id != null ? { current = var.existing_vpc_id } : {}
  to       = aws_vpc.this
  id       = each.value
}

import {
  for_each = var.adopt_existing && var.existing_internet_gateway_id != null ? { current = var.existing_internet_gateway_id } : {}
  to       = aws_internet_gateway.this
  id       = each.value
}

import {
  for_each = var.adopt_existing ? var.existing_private_subnet_ids : {}
  to       = aws_subnet.private[each.key]
  id       = each.value
}

import {
  for_each = var.adopt_existing ? var.existing_public_subnet_ids : {}
  to       = aws_subnet.public[each.key]
  id       = each.value
}

import {
  for_each = var.adopt_existing && var.existing_private_route_table_id != null ? { current = var.existing_private_route_table_id } : {}
  to       = aws_route_table.private
  id       = each.value
}

import {
  for_each = var.adopt_existing && var.existing_public_route_table_id != null ? { current = var.existing_public_route_table_id } : {}
  to       = aws_route_table.public
  id       = each.value
}

import {
  for_each = var.adopt_existing ? var.existing_public_subnet_ids : {}
  to       = aws_route_table_association.public[each.key]
  id       = "${each.value}/${var.existing_public_route_table_id}"
}

import {
  for_each = var.adopt_existing && var.existing_nat_eip_allocation_id != null ? { current = var.existing_nat_eip_allocation_id } : {}
  to       = aws_eip.nat
  id       = each.value
}

import {
  for_each = var.adopt_existing && var.existing_nat_gateway_id != null ? { current = var.existing_nat_gateway_id } : {}
  to       = aws_nat_gateway.this
  id       = each.value
}

import {
  for_each = var.adopt_existing && contains(keys(var.existing_security_group_ids), "internal_alb") ? { current = var.existing_security_group_ids.internal_alb } : {}
  to       = aws_security_group.internal_alb
  id       = each.value
}

import {
  for_each = var.adopt_existing && contains(keys(var.existing_security_group_ids), "vpc_endpoints") ? { current = var.existing_security_group_ids.vpc_endpoints } : {}
  to       = aws_security_group.vpc_endpoints
  id       = each.value
}

import {
  for_each = var.adopt_existing && contains(keys(var.existing_vpc_endpoint_ids), "s3") ? { current = var.existing_vpc_endpoint_ids.s3 } : {}
  to       = aws_vpc_endpoint.s3
  id       = each.value
}

import {
  for_each = var.adopt_existing ? { for service, id in var.existing_vpc_endpoint_ids : service => id if service != "s3" } : {}
  to       = aws_vpc_endpoint.interface[each.key]
  id       = each.value
}

import {
  for_each = var.adopt_existing ? { current = var.cluster_name } : {}
  to       = aws_eks_cluster.this
  id       = each.value
}

import {
  for_each = var.adopt_existing ? { current = var.cluster_name } : {}
  to       = aws_eks_node_group.inference
  id       = "${each.value}:${var.node_group_name}"
}

import {
  for_each = var.adopt_existing ? var.managed_addon_versions : {}
  to       = aws_eks_addon.this[each.key]
  id       = "${var.cluster_name}:${each.key}"
}

import {
  for_each = var.adopt_existing ? { current = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.node_role_name}" } : {}
  to       = aws_eks_access_entry.node
  id       = "${var.cluster_name}:${each.value}"
}

import {
  for_each = var.adopt_existing && var.cluster_admin_principal_arn != null ? { current = var.cluster_admin_principal_arn } : {}
  to       = aws_eks_access_entry.admin[0]
  id       = "${var.cluster_name}:${each.value}"
}

import {
  for_each = var.adopt_existing && var.cluster_admin_principal_arn != null ? { current = var.cluster_admin_principal_arn } : {}
  to       = aws_eks_access_policy_association.admin[0]
  id       = "${var.cluster_name}#${each.value}#arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
}

import {
  for_each = var.adopt_existing ? { current = var.cluster_role_name } : {}
  to       = aws_iam_role.cluster
  id       = each.value
}

import {
  for_each = var.adopt_existing ? { current = var.node_role_name } : {}
  to       = aws_iam_role.node
  id       = each.value
}

import {
  for_each = var.adopt_existing ? { current = var.gateway_role_name } : {}
  to       = aws_iam_role.gateway
  id       = each.value
}

import {
  for_each = var.adopt_existing ? { current = var.ovms_role_name } : {}
  to       = aws_iam_role.ovms
  id       = each.value
}

import {
  for_each = var.adopt_existing ? { current = var.load_balancer_controller_role_name } : {}
  to       = aws_iam_role.load_balancer_controller
  id       = each.value
}

import {
  for_each = var.adopt_existing ? local.cluster_policy_arns : toset([])
  to       = aws_iam_role_policy_attachment.cluster[each.key]
  id       = "${var.cluster_role_name}/${each.key}"
}

import {
  for_each = var.adopt_existing ? local.node_policy_arns : toset([])
  to       = aws_iam_role_policy_attachment.node[each.key]
  id       = "${var.node_role_name}/${each.key}"
}

import {
  for_each = var.adopt_existing ? { current = var.gateway_role_name } : {}
  to       = aws_iam_policy.gateway_secret_read
  id       = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.cluster_name}-gateway-secret-read"
}

import {
  for_each = var.adopt_existing ? { current = var.ovms_role_name } : {}
  to       = aws_iam_policy.model_artifact_read
  id       = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.cluster_name}-model-read"
}

import {
  for_each = var.adopt_existing ? { current = var.gateway_role_name } : {}
  to       = aws_iam_role_policy_attachment.gateway
  id       = "${var.gateway_role_name}/arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.cluster_name}-gateway-secret-read"
}

import {
  for_each = var.adopt_existing ? { current = var.ovms_role_name } : {}
  to       = aws_iam_role_policy_attachment.ovms
  id       = "${var.ovms_role_name}/arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.cluster_name}-model-read"
}

import {
  for_each = var.adopt_existing ? { current = var.load_balancer_controller_role_name } : {}
  to       = aws_iam_role_policy_attachment.load_balancer_controller
  id       = "${var.load_balancer_controller_role_name}/arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/AWSLoadBalancerControllerIAMPolicy"
}

import {
  for_each = var.adopt_existing ? { current = var.cluster_name } : {}
  to       = aws_eks_pod_identity_association.gateway
  id       = "${each.value},${lookup(var.existing_pod_identity_association_ids, "gateway", "")}"
}

import {
  for_each = var.adopt_existing ? { current = var.cluster_name } : {}
  to       = aws_eks_pod_identity_association.ovms
  id       = "${each.value},${lookup(var.existing_pod_identity_association_ids, "ovms", "")}"
}

import {
  for_each = var.adopt_existing ? { current = var.cluster_name } : {}
  to       = aws_eks_pod_identity_association.load_balancer_controller
  id       = "${each.value},${lookup(var.existing_pod_identity_association_ids, "lbc", "")}"
}

import {
  for_each = var.adopt_existing ? { current = var.gateway_api_key_secret_name } : {}
  to       = aws_secretsmanager_secret.gateway_api_key
  id       = coalesce(var.existing_gateway_api_key_secret_arn, each.value)
}

import {
  for_each = var.adopt_existing ? { current = var.gateway_image_name } : {}
  to       = aws_ecr_repository.gateway
  id       = each.value
}

import {
  for_each = var.adopt_existing ? { current = var.model_bucket_name } : {}
  to       = aws_s3_bucket.models
  id       = each.value
}

import {
  for_each = var.adopt_existing ? { current = var.model_bucket_name } : {}
  to       = aws_s3_bucket_public_access_block.models
  id       = each.value
}

import {
  for_each = var.adopt_existing ? { current = var.model_bucket_name } : {}
  to       = aws_s3_bucket_server_side_encryption_configuration.models
  id       = each.value
}
