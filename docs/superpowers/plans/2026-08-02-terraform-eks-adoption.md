# Terraform EKS Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Terraform safely adopt the existing AWS EKS OpenVINO POC and provide a repeatable path for future clean deployments.

**Architecture:** `terraform/aws` will use explicit AWS resources and local import blocks for VPC, EKS, IAM, add-ons, storage, and network controls. `terraform/platform` will own only the AWS Load Balancer Controller Helm release. Kubernetes application manifests remain separate, with a small PowerShell renderer consuming Terraform outputs.

**Tech Stack:** Terraform >=1.8, AWS provider ~>6.0, Helm provider ~>2.13, AWS EKS managed add-ons, AWS EKS Pod Identity, PowerShell, kubectl.

## Global Constraints

- Region is `ap-south-1` and the adopted cluster is `openvino-llm-poc`.
- The adopted VPC is `vpc-09f5d3038235fc21d` with CIDR `10.0.0.0/16`.
- The adopted private subnets are `subnet-002bad3d9e2407605` and `subnet-0aefcc64a75b1dab2`.
- The adopted worker group is `m7i-inference`, using one `m7i.xlarge` worker and a 100 GiB disk.
- The adopted private/main route table is `rtb-04fbbaf40f4c576d3`; the public route table is `rtb-04eda5e02cfcc8b82`.
- The first adoption plan must contain no replacement or destructive action.
- The EKS API public endpoint remains enabled during adoption and is disabled only after private VPN routing is available.
- Secret values never enter Terraform configuration, Terraform state, Kubernetes YAML, or Git.
- Terraform uses local state; state files and local variable files are ignored by Git.
- Argo CD and external-dns remain outside Terraform ownership.
- The existing user change in `k8s/aws/gateway-ingress.yaml` remains untouched.
- No live `terraform apply` is performed as part of code implementation without an operator reviewing the plan.

---

## File Map

Create or modify only these files during implementation:

- Modify: `.gitignore` to exclude local Terraform state and adoption variables.
- Modify: `terraform/aws/versions.tf` for the AWS-only root and provider versions.
- Modify: `terraform/aws/variables.tf` for adoption, live baseline, and clean-build inputs.
- Replace: `terraform/aws/main.tf` with the AWS resource graph split into focused files below.
- Create: `terraform/aws/providers.tf` for providers, data sources, and shared locals.
- Create: `terraform/aws/network.tf` for VPC, subnets, routes, NAT, endpoints, and custom security groups.
- Create: `terraform/aws/cluster.tf` for EKS, the managed node group, access entries, and managed add-ons.
- Create: `terraform/aws/identity.tf` for IAM policies, roles, and Pod Identity associations.
- Create: `terraform/aws/artifacts.tf` for ECR, S3, and Secrets Manager metadata.
- Create: `terraform/aws/adoption.tf` for conditional import blocks.
- Replace: `terraform/aws/outputs.tf` with outputs consumed by platform and application deployment.
- Create: `terraform/aws/adoption.tfvars.example` with the known non-secret live values.
- Create: `terraform/platform/versions.tf` for the Helm root provider constraints.
- Create: `terraform/platform/variables.tf` for cluster, region, VPC, and LBC inputs.
- Create: `terraform/platform/main.tf` for the imported AWS Load Balancer Controller release.
- Create: `terraform/platform/outputs.tf` for the platform release status.
- Create: `scripts/render-aws-manifests.ps1` for output-driven application manifest rendering.
- Modify: `README.md` with adoption, clean-build, rendering, and verification instructions.

Do not modify `k8s/aws/gateway-ingress.yaml` during this work; the renderer patches its rendered copy with the Terraform output security-group ID.

## Interfaces Between Tasks

`terraform/aws` exposes these stable outputs:

```text
cluster_name
cluster_region
cluster_endpoint
vpc_id
private_subnet_ids
gateway_ecr_repository_url
gateway_image_reference
model_bucket_name
model_prefix
gateway_api_key_secret_arn
gateway_api_key_secret_name
internal_alb_security_group_id
gateway_pod_identity_role_arn
ovms_pod_identity_role_arn
load_balancer_controller_pod_identity_role_arn
```

The platform root consumes `cluster_name`, `region`, `vpc_id`, and the Load Balancer Controller role ARN. The renderer consumes the cluster region, ECR image reference, model bucket and prefix, secret name, and ALB security-group ID.

### Task 1: Add the Adoption Profile and Local-State Guardrails

**Files:**
- Modify: `.gitignore`
- Modify: `terraform/aws/variables.tf`
- Create: `terraform/aws/adoption.tfvars.example`
- Create: `terraform/aws/adoption.tf`

**Interfaces:**
- Consumes: The live resource identifiers listed in `adoption.tfvars.example`.
- Produces: `var.adopt_existing` and import blocks that can be disabled for a clean build.

- [ ] **Step 1: Add local-state ignore rules**

Add rules that ignore Terraform state, lock backups, and local variable files under both roots while keeping `.example` files trackable:

```gitignore
terraform/**/*.tfstate
terraform/**/*.tfstate.*
terraform/**/*.tfvars
!terraform/**/*.tfvars.example
```

- [ ] **Step 2: Define adoption variables**

Add `adopt_existing` with default `false`, plus variables for the existing VPC, subnets, main/private route table, public route table, NAT gateway, EIPs, endpoints, security groups, cluster, node group, add-ons, ECR repository, S3 bucket, secret, IAM roles, and Pod Identity association IDs. Use typed maps keyed by stable names such as `ap-south-1a`, `ap-south-1b`, `ecr.api`, `ecr.dkr`, and `ec2`.

Keep clean-build inputs separate: `vpc_cidr`, `private_subnet_cidrs`, `availability_zones`, `node_instance_types`, `node_min_size`, `node_desired_size`, `node_max_size`, `cluster_endpoint_private_access`, `cluster_endpoint_public_access`, and `cluster_public_access_cidrs`.

- [ ] **Step 3: Record the known adoption values**

Create `adoption.tfvars.example` with the known live values:

```hcl
adopt_existing = true
region         = "ap-south-1"
cluster_name   = "openvino-llm-poc"
existing_vpc_id = "vpc-09f5d3038235fc21d"
existing_private_subnet_ids = {
  ap_south_1a = "subnet-002bad3d9e2407605"
  ap_south_1b = "subnet-0aefcc64a75b1dab2"
}
node_group_name       = "m7i-inference"
node_instance_types   = ["m7i.xlarge"]
node_disk_size        = 100
node_min_size         = 1
node_desired_size     = 1
node_max_size         = 1
model_bucket_name     = "openvino-llm-models-654158184275-ap-south-1"
model_prefix          = "OpenVINO/Phi-3.5-mini-instruct-int4-ov"
internal_alb_sg_id    = "sg-0b68c332fe030f72c"
existing_private_route_table_id = "rtb-04fbbaf40f4c576d3"
existing_public_route_table_id  = "rtb-04eda5e02cfcc8b82"
```

Do not add an API-key value or secret-version resource.

- [ ] **Step 4: Add conditional import blocks**

Use Terraform 1.8 import blocks with `for_each` so importing is explicit and disabled for a fresh build. Use these resource address patterns:

```hcl
import {
  for_each = var.adopt_existing ? { current = var.existing_vpc_id } : {}
  to       = aws_vpc.this
  id       = each.value
}

import {
  for_each = var.adopt_existing ? var.existing_private_subnet_ids : {}
  to       = aws_subnet.private[each.key]
  id       = each.value
}

import {
  for_each = var.adopt_existing ? var.existing_addon_ids : {}
  to       = aws_eks_addon.this[each.key]
  id       = each.value
}
```

Use the same pattern for the existing EKS cluster, node group, route-table associations, NAT gateway, EIPs, VPC endpoints, custom security groups, ECR repository, S3 bucket, secret metadata, IAM roles/policies, and Pod Identity associations. Keep the import IDs in local variables rather than hard-coding them in resource definitions.

- [ ] **Step 5: Check the profile syntax**

Run:

```powershell
terraform -chdir=terraform/aws fmt -check
terraform -chdir=terraform/aws fmt -check -diff
```

Expected: formatting checks pass. Terraform validation waits until the resource graph exists in Task 2.

- [ ] **Step 6: Commit the guardrails**

```powershell
git add .gitignore terraform/aws/variables.tf terraform/aws/adoption.tf terraform/aws/adoption.tfvars.example
git commit -m "Add Terraform adoption profile"
```

### Task 2: Replace the Mismatched AWS Root with Explicit Network Resources

**Files:**
- Modify: `terraform/aws/versions.tf`
- Replace: `terraform/aws/main.tf`
- Create: `terraform/aws/providers.tf`
- Create: `terraform/aws/network.tf`

**Interfaces:**
- Consumes: Adoption variables and clean-build network variables from Task 1.
- Produces: `aws_vpc.this`, `aws_subnet.private`, route resources, endpoint resources, and custom security groups used by later tasks.

- [ ] **Step 1: Remove module and Kubernetes ownership from the AWS root**

Delete the VPC module, EKS module, Kubernetes provider, Helm provider, Kubernetes service account, Argo CD release, metrics-server release, and AWS Load Balancer Controller release from `terraform/aws/main.tf`. The AWS root must contain only AWS resources.

- [ ] **Step 2: Set provider constraints**

Use Terraform >=1.8 and the AWS provider `~> 6.0` in `terraform/aws/versions.tf`. Configure the AWS provider in `providers.tf` with `region = var.region` and the existing project tags.

- [ ] **Step 3: Define the explicit VPC graph**

Create resources named `aws_vpc.this`, `aws_internet_gateway.this`, `aws_subnet.private`, `aws_route_table.private`, `aws_main_route_table_association.private`, `aws_subnet.public`, `aws_route_table.public`, and `aws_route_table_association.public`. In adoption mode, import the existing main/private route table and leave the private subnet associations implicit, matching the live VPC. In clean-build mode, use one private/main route table for both private subnets and one public route table for both public subnets.

- [ ] **Step 4: Define the low-cost egress path**

Create one `aws_eip.nat`, one `aws_nat_gateway.this`, and private default routes. Adoption mode imports the existing NAT and EIP; clean-build mode creates one NAT gateway only.

- [ ] **Step 5: Define custom security groups**

Create `aws_security_group.internal_alb` and `aws_security_group.vpc_endpoints`. The ALB group permits TCP 80 only from `var.trusted_private_cidrs`; the endpoint group permits TCP 443 from the VPC CIDR. Import `sg-0b68c332fe030f72c` for the existing internal ALB group instead of creating a second group.

- [ ] **Step 6: Define private service endpoints**

Create one S3 gateway endpoint and interface endpoints for `ecr.api`, `ecr.dkr`, `ec2`, `secretsmanager`, `sts`, `logs`, `monitoring`, and `eks-auth` when the private-only profile enables it. Use both private subnets, private DNS, and the endpoint security group.

- [ ] **Step 7: Validate the network graph**

Run:

```powershell
terraform -chdir=terraform/aws fmt -check
terraform -chdir=terraform/aws init -backend=false
terraform -chdir=terraform/aws validate
```

Expected: initialization and validation pass without Kubernetes or Helm provider requirements.

- [ ] **Step 8: Commit the network root**

```powershell
git add terraform/aws/versions.tf terraform/aws/main.tf terraform/aws/providers.tf terraform/aws/network.tf
git commit -m "Model adopted EKS networking explicitly"
```

### Task 3: Model the Existing EKS Cluster, Node Group, and Managed Add-ons

**Files:**
- Create: `terraform/aws/cluster.tf`
- Modify: `terraform/aws/variables.tf`

**Interfaces:**
- Consumes: `aws_vpc.this`, `aws_subnet.private`, network security groups, and adoption IDs from Tasks 1 and 2.
- Produces: `aws_eks_cluster.this`, `aws_eks_node_group.inference`, `aws_eks_access_entry`, `aws_eks_access_policy_association`, and `aws_eks_addon.this` resources.

- [ ] **Step 1: Define the cluster resource**

Create `aws_eks_cluster.this` for cluster `openvino-llm-poc`, version `1.36`, private endpoint access enabled, public endpoint access controlled by variables, and authentication mode `API_AND_CONFIG_MAP`. In adoption mode, preserve the current public CIDR `0.0.0.0/0` until a later private-connectivity hardening change.

- [ ] **Step 2: Define the single inference node group**

Create `aws_eks_node_group.inference` with name `m7i-inference`, AL2023 x86_64 standard AMI, `m7i.xlarge`, a 100 GiB disk, one desired node, both private subnets, no SSH remote access, and labels:

```hcl
labels = {
  nodepool  = "m7i-inference"
  inference = "openvino-cpu"
  hardware  = "intel-cpu"
}
```

Do not create a separate system node group for this low-cost POC.

- [ ] **Step 3: Model API access entries**

Import and manage the node-role access entry required for node registration. Import the existing cluster administrator access entry and its policy association only when the live inventory confirms it is present. Do not remove the current user access path during adoption.

- [ ] **Step 4: Model current managed add-ons**

Create `aws_eks_addon.this` for the active managed add-ons: VPC CNI, CoreDNS, kube-proxy, EBS CSI, Secrets Store CSI provider, Metrics Server, Pod Identity Agent, and node monitoring. Set each adopted add-on version to the live version returned by `aws eks describe-addon`.

Do not declare external-dns or Argo CD. Do not attach an IRSA role to EBS CSI when the live add-on uses Pod Identity.

- [ ] **Step 5: Import and compare the EKS layer**

Run:

```powershell
terraform -chdir=terraform/aws plan -var-file=adoption.tfvars -out=adoption.tfplan
terraform -chdir=terraform/aws show -no-color adoption.tfplan | Select-String -Pattern 'destroy|replace|must be replaced'
```

Expected: the plan contains imports and no destructive action. Stop and correct the configuration if replacement text appears.

- [ ] **Step 6: Commit the EKS layer**

```powershell
git add terraform/aws/cluster.tf terraform/aws/variables.tf
git commit -m "Adopt the existing EKS cluster and node group"
```

### Task 4: Adopt IAM, Pod Identity, Artifact Storage, and Secret Metadata

**Files:**
- Create: `terraform/aws/identity.tf`
- Create: `terraform/aws/artifacts.tf`
- Replace: `terraform/aws/outputs.tf`

**Interfaces:**
- Consumes: Cluster and add-on resources from Task 3 plus the model and image variables.
- Produces: IAM and Pod Identity outputs, ECR/S3/secret outputs, and the values required by the platform root and renderer.

- [ ] **Step 1: Define existing roles without IRSA modules**

Use explicit `aws_iam_role`, `aws_iam_policy`, `aws_iam_role_policy_attachment`, and `aws_eks_pod_identity_association` resources. Import the node role, gateway role, OVMS role, EBS CSI role, and Load Balancer Controller role instead of recreating them.

- [ ] **Step 2: Preserve secret boundaries**

Manage only `aws_secretsmanager_secret.gateway_api_key`. Import the existing secret metadata by ARN and do not create `aws_secretsmanager_secret_version`. Output its ARN and name for the SecretProviderClass renderer.

- [ ] **Step 3: Scope workload policies**

The gateway policy grants `secretsmanager:DescribeSecret` and `secretsmanager:GetSecretValue` only on the gateway secret ARN. The OVMS policy grants `s3:ListBucket` on the model bucket with a prefix condition and `s3:GetObject` only on `OpenVINO/Phi-3.5-mini-instruct-int4-ov/*`.

For adoption, first match the live policy document so the ownership plan is clean. Apply any narrowing of an overly broad existing policy as a separate reviewed hardening change after import.

- [ ] **Step 4: Adopt ECR, S3, and bucket controls**

Create/import the gateway ECR repository, model S3 bucket, public-access block, and server-side encryption. Preserve the current unversioned bucket during adoption; versioning is a separate hardening change. Export the repository URL and use an immutable gateway image digest output rather than a mutable tag.

- [ ] **Step 5: Add the stable outputs**

Replace module-based output references with the interfaces listed above. Mark secret ARN and IAM role ARN outputs as sensitive where Terraform supports it; do not output secret values.

- [ ] **Step 6: Validate IAM and artifacts**

Run:

```powershell
terraform -chdir=terraform/aws validate
terraform -chdir=terraform/aws plan -var-file=adoption.tfvars -out=adoption.tfplan
```

Expected: the plan shows imports or intentional metadata updates only; no secret value appears in the plan output.

- [ ] **Step 7: Commit IAM and artifact ownership**

```powershell
git add terraform/aws/identity.tf terraform/aws/artifacts.tf terraform/aws/outputs.tf
git commit -m "Adopt EKS workload identity and model storage"
```

### Task 5: Create the Separate Platform Terraform Root for the Load Balancer Controller

**Files:**
- Create: `terraform/platform/versions.tf`
- Create: `terraform/platform/variables.tf`
- Create: `terraform/platform/main.tf`
- Create: `terraform/platform/outputs.tf`

**Interfaces:**
- Consumes: Cluster name, region, VPC ID, and Load Balancer Controller role ARN from `terraform/aws` outputs.
- Produces: Helm release status and the controller release name.

- [ ] **Step 1: Configure the platform providers**

Use the AWS provider and Helm provider only. Read the cluster endpoint and certificate through `data.aws_eks_cluster` and obtain the token with `data.aws_eks_cluster_auth`. Do not add a Kubernetes service-account resource to the AWS root.

- [ ] **Step 2: Match the existing Helm release**

Before defining the resource, inspect the live release:

```powershell
helm list -n kube-system
helm get values aws-load-balancer-controller -n kube-system --all
```

Set `helm_release.aws_load_balancer_controller` to the existing release name, namespace, chart repository, chart version, cluster name, region, VPC ID, and Pod Identity-compatible service-account settings.

- [ ] **Step 3: Import the release**

Import the existing release into the platform state using the Helm provider's `kube-system/aws-load-balancer-controller` release address. The first platform plan must be a no-op after import.

- [ ] **Step 4: Validate platform ownership**

Run:

```powershell
terraform -chdir=terraform/platform init -backend=false
terraform -chdir=terraform/platform validate
terraform -chdir=terraform/platform plan -var-file=platform.tfvars
```

Expected: the controller release is imported without replacing it, and Argo CD/external-dns are absent from the plan.

- [ ] **Step 5: Commit the platform root**

```powershell
git add terraform/platform
git commit -m "Manage the AWS Load Balancer Controller separately"
```

### Task 6: Make Kubernetes Deployment Consume Terraform Outputs

**Files:**
- Create: `scripts/render-aws-manifests.ps1`
- Modify: `README.md`

**Interfaces:**
- Consumes: Terraform outputs from `terraform/aws` and the existing manifests under `k8s/aws`.
- Produces: A local rendered directory containing deployable manifests with current bucket, secret, image, region, and ALB security-group values.

- [ ] **Step 1: Define the renderer contract**

Implement a PowerShell script with these parameters:

```powershell
.\scripts\render-aws-manifests.ps1 `
  -TerraformDir .\terraform\aws `
  -OutputDir .\tmp\rendered-aws
```

The script must read `terraform output -raw` for `cluster_region`, `gateway_image_reference`, `model_bucket_name`, `model_prefix`, `gateway_api_key_secret_name`, and `internal_alb_security_group_id`.

- [ ] **Step 2: Render without changing source manifests**

Copy the required `k8s/aws` YAML files into the output directory and replace only these deployment-specific fields in the copies:

- S3 bucket and prefix in both OVMS init-container commands.
- Gateway ECR image reference in `gateway.yaml`.
- Region and secret name in `gateway-secret-provider.yaml`.
- ALB security-group annotation in the rendered Ingress.

Leave the source `k8s/aws/gateway-ingress.yaml` unchanged, including its current `sg-0b68c332fe030f72c` edit.

- [ ] **Step 3: Add guardrails to the renderer**

Fail before writing output if any required Terraform output is empty, if a rendered file still contains `REPLACE_WITH_`, or if the source files contain an API-key value. Print the output directory and the files rendered; never print secret contents.

- [ ] **Step 4: Verify rendered content**

Run:

```powershell
Remove-Item -Recurse -Force tmp/rendered-aws -ErrorAction SilentlyContinue
.\scripts\render-aws-manifests.ps1 -TerraformDir .\terraform\aws -OutputDir .\tmp\rendered-aws
kubectl apply --dry-run=client -f .\tmp\rendered-aws
Select-String -Path .\tmp\rendered-aws\*.yaml -Pattern 'REPLACE_WITH_|api-key-value'
```

Expected: rendering succeeds, client-side YAML validation succeeds, and the final search returns no matches.

- [ ] **Step 5: Update the README handoff**

Replace the `terraform/aws` description from optional automation to the adoption and clean-build roots. Document the exact sequence: copy the example variables, inventory IDs, run plan, review imports, apply imports, run the second clean plan, render manifests, and deploy from the rendered directory.

- [ ] **Step 6: Commit the application handoff**

```powershell
git add scripts/render-aws-manifests.ps1 README.md
git commit -m "Render Kubernetes deployment values from Terraform"
```

### Task 7: Run the Full Adoption Verification Without an Unreviewed Change

**Files:**
- Modify: `README.md` if command ordering or observed output needs correction.

**Interfaces:**
- Consumes: Both Terraform roots, rendered manifests, and the existing VPC-connected Kubernetes client.
- Produces: A clean adoption plan and a repeatable deployment checklist.

- [ ] **Step 1: Validate both roots**

```powershell
terraform -chdir=terraform/aws fmt -check
terraform -chdir=terraform/aws validate
terraform -chdir=terraform/platform fmt -check
terraform -chdir=terraform/platform validate
```

- [ ] **Step 2: Run the AWS adoption plan**

```powershell
terraform -chdir=terraform/aws plan -var-file=adoption.tfvars -out=adoption.tfplan
terraform -chdir=terraform/aws show -no-color adoption.tfplan | Select-String -Pattern 'destroy|replace|must be replaced'
```

The command must produce no destructive or replacement action. Do not apply if it does.

- [ ] **Step 3: Apply ownership only after review**

```powershell
terraform -chdir=terraform/aws apply adoption.tfplan
terraform -chdir=terraform/aws plan -var-file=adoption.tfvars
```

Expected: the second plan is clean or contains only explicitly approved metadata drift.

- [ ] **Step 4: Validate the cluster and platform**

```powershell
aws eks update-kubeconfig --name openvino-llm-poc --region ap-south-1
kubectl get nodes -o wide
kubectl get nodes -L nodepool,inference,hardware
kubectl get pods -n kube-system
terraform -chdir=terraform/platform plan -var-file=platform.tfvars
```

Expected: one Ready `m7i.xlarge` node has the three expected labels, managed add-ons are healthy, and the LBC plan is clean.

- [ ] **Step 5: Validate application handoff**

Render the manifests, perform a client-side validation, then verify OVMS and gateway readiness and authenticated inference from a VPC-connected client. Confirm the PVC remains bound and the existing internal ALB hostname remains unchanged.

- [ ] **Step 6: Commit documentation corrections**

```powershell
git add README.md
git commit -m "Document Terraform adoption verification"
```

## Final Review Checklist

- [ ] The first adoption plan imports current resources and contains no destroy or replace action.
- [ ] A second AWS plan is clean after import.
- [ ] The platform root owns only the AWS Load Balancer Controller release.
- [ ] Argo CD and external-dns are not declared or deleted.
- [ ] The gateway secret value is absent from code, plan output, and state.
- [ ] The OVMS policy is limited to the model prefix after the separate hardening review.
- [ ] The user-modified `k8s/aws/gateway-ingress.yaml` remains unchanged.
- [ ] The rendered manifests use Terraform outputs instead of stale account-specific values.
- [ ] The README describes both adoption and future clean-build paths.
