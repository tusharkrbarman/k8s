output "controller_release_name" {
  description = "Managed AWS Load Balancer Controller Helm release name."
  value       = var.adopt_existing ? helm_release.aws_load_balancer_controller_adopted[0].name : helm_release.aws_load_balancer_controller_managed[0].name
}

output "controller_release_namespace" {
  description = "Namespace containing the controller release."
  value       = var.adopt_existing ? helm_release.aws_load_balancer_controller_adopted[0].namespace : helm_release.aws_load_balancer_controller_managed[0].namespace
}

output "controller_chart_version" {
  description = "Installed controller chart version."
  value       = var.adopt_existing ? helm_release.aws_load_balancer_controller_adopted[0].version : helm_release.aws_load_balancer_controller_managed[0].version
}
