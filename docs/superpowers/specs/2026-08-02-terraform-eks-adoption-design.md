# Terraform Adoption for the AWS EKS OpenVINO POC

**Status:** Approved design
**Date:** 2026-08-02

## Problem

The running AWS demo was created manually, while the existing Terraform configuration describes a different environment. The current configuration uses different networking defaults, multiple node pools, older add-on versions, and broader ownership than the live cluster. Applying it directly could replace or disrupt the working demo.

Terraform should first adopt the existing environment safely, then become the authoritative owner so the same repository can create a fresh environment later.

## Goals

- Import the current AWS EKS environment into local Terraform state.
- Make the first adoption plan non-destructive and reviewable.
- Keep the existing OpenVINO inference demo working.
- Allow a future clean deployment by changing variables and disabling adoption imports.
- Keep the API key value out of Terraform configuration and state.
- Preserve the private-only production direction while allowing temporary laptop access during bootstrap.

## Non-goals

- GPU, NPU, or Intel device scheduling. The current AWS POC remains CPU-based.
- Terraform ownership of Kubernetes application objects such as OVMS, the gateway, Services, Ingress, PVCs, HPA, or SecretProviderClass.
- Terraform ownership of Argo CD or external-dns. Existing external-dns resources remain untouched.
- Importing or directly managing the ALB. The AWS Load Balancer Controller owns it through the Kubernetes Ingress.
- Secret rotation implementation.

## Ownership Model

The repository will use two Terraform roots:

```text
terraform/
|-- aws/       # AWS infrastructure and EKS resources
`-- platform/  # AWS Load Balancer Controller Helm release
```

### `terraform/aws`

Owns or adopts:

- VPC, subnets, route tables, route associations, NAT gateway, and EIPs.
- S3 gateway and AWS service interface endpoints.
- Custom security groups, including the internal ALB and VPC endpoint groups.
- EKS cluster configuration and the existing managed node group.
- EKS managed add-ons: VPC CNI, CoreDNS, kube-proxy, EBS CSI, Secrets Store CSI provider, Metrics Server, Pod Identity Agent, and node monitoring.
- ECR repository, S3 bucket configuration, and Secrets Manager secret metadata.
- IAM roles, policies, and EKS Pod Identity associations for the node, gateway, OVMS, EBS CSI, and Load Balancer Controller paths.

The EKS-generated cluster security group will be discovered and validated rather than broadly modified. Custom security groups are the resources Terraform should control.

### `terraform/platform`

Owns the Helm release for the AWS Load Balancer Controller. It will use the existing cluster and the Terraform-managed Pod Identity role. It will not manage the application ALB directly.

### `k8s/aws`

Remains the application layer. It owns OVMS blue/green StatefulSets, model services, the FastAPI gateway, the internal Ingress, PVCs, readiness probes, SecretProviderClass, PDB, and HPA.

## Live Adoption Baseline

The first adoption profile must match the current environment:

- Region: `ap-south-1`
- Cluster: `openvino-llm-poc`
- EKS version: `1.36`
- VPC: `vpc-09f5d3038235fc21d`
- VPC CIDR: `10.0.0.0/16`
- Cluster role: `openvino-llm-poc-cluster-role`
- Private subnets:
  - `subnet-002bad3d9e2407605`
  - `subnet-0aefcc64a75b1dab2`
- Current node group: `m7i-inference`
- Current instance type: `m7i.xlarge`
- Current node count: minimum, desired, and maximum of `1`
- Current node disk: `100 GiB`
- Current node labels:
  - `nodepool=m7i-inference`
  - `inference=openvino-cpu`
  - `hardware=intel-cpu`
- Model bucket: `openvino-llm-models-654158184275-ap-south-1`
- Model prefix: `OpenVINO/Phi-3.5-mini-instruct-int4-ov`
- Existing internal ALB security group: `sg-0b68c332fe030f72c`
- Existing private/main route table: `rtb-04fbbaf40f4c576d3`
- Existing public route table: `rtb-04eda5e02cfcc8b82`

The EKS API currently has both private and public access. Adoption must preserve that setting initially so Terraform does not make an unplanned connectivity change. Public access will be restricted or disabled in a separate hardening change after a VPN or other private route to the API is available.

## Target Capacity and Networking

The low-cost default remains one `m7i.xlarge` inference node. A separate system node group is not required for this POC because EKS control-plane components are AWS-managed and the current cluster fits on one worker node.

The target networking shape is:

- Two private subnets in separate Availability Zones.
- One NAT gateway for bootstrap and any services without private endpoints.
- S3 gateway endpoint.
- Interface endpoints for ECR API, ECR Docker, EC2, STS, Secrets Manager, CloudWatch Logs, CloudWatch Monitoring, and EKS Auth when required by the private-only profile.
- Internal ALB security group restricted to the approved private client CIDRs.

The public API endpoint variable remains available for temporary laptop bootstrap. The secure profile sets public access to disabled once the DMZ VPN/private route is operational.

## Identity and Secret Boundaries

- EKS Pod Identity is the default workload-to-AWS mechanism; new IRSA resources are not introduced.
- The gateway role can read only the configured Secrets Manager secret.
- The OVMS role can read only the configured model prefix in S3.
- The Load Balancer Controller role has only the permissions required by its AWS integration.
- The secret value is created or edited in Secrets Manager, never placed in `.tfvars`, Kubernetes YAML, or Terraform state.
- Local state and adoption variable files are ignored by Git.

## Import and Rebuild Workflow

Adoption will use Terraform import blocks and explicit AWS provider resources rather than relying on module-specific import addresses for critical resources.

### Existing environment

1. Populate a local adoption variables file with the live IDs and names.
2. Initialize and validate both Terraform roots.
3. Run a plan containing only imports and configuration that matches the live environment.
4. Confirm that the plan contains no replacement or destructive action.
5. Apply the import plan.
6. Run a second plan and require a clean result before changing any infrastructure.
7. Deploy or verify the Kubernetes application using Terraform outputs.

The import profile must not silently create a second VPC, node group, NAT gateway, or load balancer.

### Future clean environment

The same resource definitions can create a new environment when adoption is disabled and no existing resource IDs are supplied. The new environment receives the same default architecture, with names, CIDRs, capacity, and endpoint mode supplied through variables.

## Terraform Outputs and Application Handoff

The AWS root will expose:

- Cluster name and region.
- ECR repository URI and immutable gateway image reference.
- Model bucket and prefix.
- Internal ALB security-group ID.
- IAM role names or ARNs used by Pod Identity.
- S3 bucket and Secrets Manager ARNs.

The deployment helper or documented handoff will consume these outputs so application manifests do not depend on stale account-specific values. The image should be pinned by digest for repeatable deployment.

## Verification and Safety Checks

Required checks before calling adoption complete:

- `terraform fmt -check`.
- `terraform validate` for both roots.
- First adoption plan contains imports and no destructive actions.
- Second plan is clean after import.
- All expected EKS add-ons are active.
- Node is Ready and has the expected labels.
- OVMS and gateway rollouts are Ready.
- Gateway readiness reports OVMS readiness and secret configuration.
- Authenticated inference succeeds through the internal ALB from a VPC-connected client.
- PVC remains bound after an OVMS restart.
- HPA configuration is present and valid; scaling tests remain a Kubernetes application concern.

No live `terraform apply` is part of repository implementation. The first AWS apply remains an operator-reviewed step because it changes ownership of production-shaped resources.
