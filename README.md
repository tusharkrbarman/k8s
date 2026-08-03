# AWS EKS OpenVINO LLM Inference POC

This repository serves an OpenVINO-optimized open-source LLM on Amazon EKS.
The current low-cost demo uses one Intel `m7i.xlarge` worker and keeps the
production shape visible without pretending that a single node is highly
available.

## Current Demo Profile

- Cluster: Amazon EKS `1.36` in two private subnets in `ap-south-1`.
- Worker: one `m7i.xlarge` managed node labelled `nodepool=m7i-inference`.
- Model: `OpenVINO/Phi-3.5-mini-instruct-int4-ov`.
- Inference: one active OVMS blue StatefulSet; green remains at zero replicas.
- Storage: encrypted `gp3` EBS cache provisioned by `ebs.csi.aws.com`.
- Model source: private S3 bucket, read through EKS Pod Identity.
- Gateway: one FastAPI pod using a digest-pinned image in private ECR.
- Secret: AWS Secrets Manager mounted through the AWS-managed Secrets Store CSI add-on.
- Bootstrap egress: a temporary NAT Gateway permits public image pulls.
- Target ingress: an internal AWS ALB, reachable only through the private network.

The live learning cluster currently has both private and public EKS API access
enabled. The application ALB remains internal. Disable public EKS API access
after a VPN, Direct Connect path, or VPC-hosted runner can reach the private API.

Strict scope: this AWS version demonstrates Intel CPU inference. It does not
claim Intel GPU or NPU validation.

## Architecture

```mermaid
flowchart TB
    Client["Private client<br/>Intel DMZ VPN or VPC"]
    ALB["Internal AWS ALB<br/>private entry point"]
    Gateway["FastAPI gateway<br/>1 pod"]
    Secret["Secrets Store CSI<br/>API key from Secrets Manager"]
    Blue["OVMS blue<br/>1 active pod"]
    Green["OVMS green<br/>0 standby pods"]
    PVC["Encrypted gp3 PVC<br/>model cache"]
    S3["Private S3 bucket<br/>Phi-3.5 OpenVINO model"]
    Identity["EKS Pod Identity<br/>scoped S3 and secret access"]
    Worker["One m7i.xlarge worker<br/>private subnet"]

    Client --> ALB --> Gateway --> Blue
    Gateway --> Secret
    Gateway -. "later promotion" .-> Green
    Blue --> PVC
    Green --> PVC
    S3 --> PVC
    Identity --> Gateway
    Identity --> Blue
    Worker --- Gateway
    Worker --- Blue
```

## Request Flow

1. A private client sends an authenticated request to the internal ALB.
2. The ALB routes it to the gateway ClusterIP service.
3. The gateway checks the API key mounted from Secrets Manager.
4. The gateway forwards the request to the active OVMS blue service.
5. OVMS runs the Phi-3.5 INT4 model from its local EBS cache.
6. On first start, an init container copies the model from S3 into that cache.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `k8s/aws` | EKS application, storage, secret-mount, scaling, and ingress manifests. |
| `gateway` | FastAPI gateway, container definition, and tests. |
| `scripts` | Smoke, benchmark, recovery, and Terraform-output rendering commands. |
| `terraform/aws` | AWS resource ownership, adoption imports, and clean-build infrastructure. |
| `terraform/platform` | AWS Load Balancer Controller Helm ownership. |
| `docs/aws-eks-openvino-llm-poc.md` | Manual deployment runbook matching the current console-built cluster. |

## Adopt Or Build With Terraform

Terraform uses local state in both roots. The adoption profile is a reference file;
copy it to an ignored local file before running Terraform:

```powershell
Copy-Item terraform/aws/adoption.tfvars.example terraform/aws/adoption.tfvars
terraform -chdir=terraform/aws init -backend=false
terraform -chdir=terraform/aws validate
terraform -chdir=terraform/aws plan '-var-file=adoption.tfvars' -out=adoption.tfplan
```

Review the plan. The current adoption plan should show imports only, with no
replacement or destroy action. Apply only after that review, then run a second
plan to confirm a clean state:

```powershell
terraform -chdir=terraform/aws apply adoption.tfplan
terraform -chdir=terraform/aws plan '-var-file=adoption.tfvars'
```

Adopt the existing AWS Load Balancer Controller separately:

```powershell
Copy-Item terraform/platform/platform.tfvars.example terraform/platform/platform.tfvars
terraform -chdir=terraform/platform init -backend=false
terraform -chdir=terraform/platform validate
terraform -chdir=terraform/platform plan '-var-file=platform.tfvars'
```

The platform adoption plan should import only
`aws-load-balancer-controller`. Argo CD and external-dns are intentionally
outside Terraform ownership. For a new environment, omit the adoption files
and set `adopt_existing = false` in normal local variables.

Use the detailed manual runbook for the Kubernetes deployment sequence:

[AWS EKS deployment runbook](docs/aws-eks-openvino-llm-poc.md)

## Render Kubernetes Manifests

After the AWS root has state, render current Terraform outputs into ignored
local files. The source manifests remain unchanged and no secret value is
printed or copied into YAML:

```powershell
.\scripts\render-aws-manifests.ps1 `
  -TerraformDir .\terraform\aws `
  -OutputDir .\tmp\rendered-aws
kubectl apply --dry-run=client -f .\tmp\rendered-aws
```

The renderer fills the model S3 location, gateway image digest, AWS region,
Secrets Manager name, and internal ALB security group. It skips the Argo CD
application manifest because that file still requires a repository-specific
value.

## Remaining Placeholders

- `REPLACE_WITH_GIT_REPOSITORY_URL`

The Git repository placeholder is needed only when Argo CD is enabled. Do not
apply that Argo CD manifest until its repository value is configured.

## Capacity And Reliability

OVMS requests 2 vCPU and 6 GiB and is limited to 3 vCPU and 12 GiB. The gateway
requests 250 millicores and 256 MiB. This fits one `m7i.xlarge`, but one worker,
one active OVMS replica, and one gateway replica provide no node-level high
availability. Add workers before raising replica counts or testing failover.

## Validation

```powershell
python -m pytest gateway/tests
terraform -chdir=terraform/aws fmt -check
terraform -chdir=terraform/aws validate
terraform -chdir=terraform/platform fmt -check
terraform -chdir=terraform/platform validate
git diff --check
```

Live validation requires access to the EKS API and is documented in the
runbook. Keep model artifacts under `models/` local-only; the directory is
ignored by Git.
