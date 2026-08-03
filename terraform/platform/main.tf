import {
  for_each = var.adopt_existing ? { current = var.controller_release_name } : {}
  to       = helm_release.aws_load_balancer_controller_adopted[0]
  id       = "kube-system/${each.value}"
}

resource "helm_release" "aws_load_balancer_controller_adopted" {
  count = var.adopt_existing ? 1 : 0

  name      = var.controller_release_name
  namespace = "kube-system"
  chart     = "aws-load-balancer-controller"
  version   = var.controller_chart_version
}

resource "helm_release" "aws_load_balancer_controller_managed" {
  count = var.adopt_existing ? 0 : 1

  name       = var.controller_release_name
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.controller_chart_version

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  set {
    name  = "replicaCount"
    value = "2"
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
}
