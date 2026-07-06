# AWS EKS OpenVINO LLM POC Runbook

This runbook deploys the production-shaped AWS proof of concept for OpenVINO LLM inference on EKS. It is private-only, CPU-based, and GitOps-managed after bootstrap.

## Architecture Summary

- Terraform lives in `terraform/aws` and creates the AWS foundation: VPC, private EKS cluster, Intel M7i managed node groups, ECR, S3, IAM roles for service accounts, Secrets Manager, EBS CSI, AWS Load Balancer Controller, Secrets Store CSI, and Argo CD.
- Application manifests live in `k8s/aws` and are intended to be synced by Argo CD.
- The gateway is a FastAPI service running behind an internal ALB. It reads the API key from AWS Secrets Manager through the Secrets Store CSI driver.
- OpenVINO Model Server runs as blue and green StatefulSets on Intel M7i CPU inference nodes. The OVMS image is digest-pinned in the manifests.
- Model artifacts are copied from S3 into each OVMS pod's EBS-backed model cache by an init container.
- Active traffic target is controlled by `k8s/aws/gateway-config.yaml` through `OVMS_URL`.
- Access is private-only through an internal ALB; there is no public EKS endpoint and no public gateway.

Strict scope note: this AWS design validates Intel CPU inference with OpenVINO on M7i instances. It does not claim Intel GPU or NPU validation.

## Prerequisites

- AWS account access with permissions to create VPC, EKS, IAM, ECR, S3, Secrets Manager, KMS, EBS, ALB, and related resources.
- AWS CLI authenticated to the target account.
- Terraform CLI installed.
- Docker installed and able to build Linux images.
- `kubectl` installed.
- Git remote for this repository reachable by Argo CD.
- Network path to the private EKS API endpoint after cluster creation, such as VPN, Direct Connect, bastion, or a runner inside the VPC.

Important: Terraform sets `cluster_endpoint_private_access = true` and `cluster_endpoint_public_access = false`. After the EKS cluster exists, Terraform and Helm operations that talk to Kubernetes must run from a network path that can reach the private endpoint.

## Bootstrap AWS Infrastructure

Run Terraform from `terraform/aws`.

```powershell
cd terraform/aws

$AWS_REGION = "us-east-1"
$MODEL_BUCKET = "openvino-llm-models-tusha-dev"

terraform init
terraform plan `
  -var "region=$AWS_REGION" `
  -var "model_bucket_name=$MODEL_BUCKET"

terraform apply `
  -var "region=$AWS_REGION" `
  -var "model_bucket_name=$MODEL_BUCKET"
```

Capture the outputs used by later steps.

```powershell
$CLUSTER_NAME = terraform output -raw cluster_name
$GATEWAY_ECR_REPOSITORY_URL = terraform output -raw gateway_ecr_repository_url
$MODEL_BUCKET = terraform output -raw model_bucket_name
$GATEWAY_API_KEY_SECRET_ARN = terraform output -raw gateway_api_key_secret_arn
$GATEWAY_SERVICE_ACCOUNT_ROLE_ARN = terraform output -raw gateway_service_account_role_arn
$OVMS_MODEL_READER_SERVICE_ACCOUNT_ROLE_ARN = terraform output -raw ovms_model_reader_service_account_role_arn
```

Configure `kubectl` from a host that can reach the private EKS endpoint.

```powershell
aws eks update-kubeconfig `
  --region $AWS_REGION `
  --name $CLUSTER_NAME

kubectl get nodes
```

## Build And Push The Gateway Image

Build from the repository root so the gateway Dockerfile can use the `gateway` directory as its build context.

```powershell
cd ..\..

$IMAGE_TAG = "0.1.0"
$GATEWAY_IMAGE = "$($GATEWAY_ECR_REPOSITORY_URL):$IMAGE_TAG"
$ECR_REGISTRY = ($GATEWAY_ECR_REPOSITORY_URL -split "/")[0]

aws ecr get-login-password --region $AWS_REGION |
  docker login --username AWS --password-stdin $ECR_REGISTRY

docker build -t $GATEWAY_IMAGE .\gateway
docker push $GATEWAY_IMAGE
```

## Replace Manifest Placeholders

The AWS manifests intentionally contain placeholders until Terraform has created the real AWS resources and the gateway image is pushed.

Set the Git repository URL that Argo CD should sync.

```powershell
$GIT_REPOSITORY_URL = "https://github.com/YOUR_ORG/YOUR_REPO.git"
```

Replace the placeholders in place.

```powershell
$gatewayManifest = Get-Content -Raw k8s/aws/gateway.yaml
$gatewayManifest = $gatewayManifest.Replace("REPLACE_WITH_GATEWAY_SERVICE_ACCOUNT_ROLE_ARN", $GATEWAY_SERVICE_ACCOUNT_ROLE_ARN)
$gatewayManifest = $gatewayManifest.Replace("REPLACE_WITH_GATEWAY_ECR_IMAGE", $GATEWAY_IMAGE)
Set-Content -NoNewline k8s/aws/gateway.yaml $gatewayManifest

$blueManifest = Get-Content -Raw k8s/aws/ovms-blue.yaml
$blueManifest = $blueManifest.Replace("REPLACE_WITH_OVMS_MODEL_READER_SERVICE_ACCOUNT_ROLE_ARN", $OVMS_MODEL_READER_SERVICE_ACCOUNT_ROLE_ARN)
$blueManifest = $blueManifest.Replace("REPLACE_WITH_MODEL_BUCKET_NAME", $MODEL_BUCKET)
Set-Content -NoNewline k8s/aws/ovms-blue.yaml $blueManifest

$greenManifest = Get-Content -Raw k8s/aws/ovms-green.yaml
$greenManifest = $greenManifest.Replace("REPLACE_WITH_MODEL_BUCKET_NAME", $MODEL_BUCKET)
Set-Content -NoNewline k8s/aws/ovms-green.yaml $greenManifest

$argoApplication = Get-Content -Raw k8s/aws/argocd-application.yaml
$argoApplication = $argoApplication.Replace("REPLACE_WITH_GIT_REPOSITORY_URL", $GIT_REPOSITORY_URL)
Set-Content -NoNewline k8s/aws/argocd-application.yaml $argoApplication
```

Commit and push those manifest changes to the branch Argo CD tracks:

```powershell
git add k8s/aws
git commit -m "Configure AWS EKS OpenVINO manifests"
git push origin codex/aws-eks-openvino-poc
```

The Argo CD Application uses `targetRevision: codex/aws-eks-openvino-poc` and path `k8s/aws`.

## Populate The Gateway API Key Secret

Terraform creates the Secrets Manager secret, but it does not create the secret value. Add the value before starting gateway pods.

```powershell
$GATEWAY_API_KEY = Read-Host "Gateway API key"

aws secretsmanager put-secret-value `
  --region $AWS_REGION `
  --secret-id $GATEWAY_API_KEY_SECRET_ARN `
  --secret-string $GATEWAY_API_KEY
```

The manifest `k8s/aws/gateway-secret-provider.yaml` mounts this secret as `/mnt/secrets-store/api-key`.

## Upload Model Artifacts

Upload approved OpenVINO model artifacts to the S3 path expected by both blue and green OVMS StatefulSets.

```powershell
$LOCAL_MODEL_DIR = "C:\models\OpenVINO\Phi-3-mini-FastDraft-50M-int8-ov"
$S3_MODEL_PREFIX = "s3://$MODEL_BUCKET/OpenVINO/Phi-3-mini-FastDraft-50M-int8-ov"

aws s3 sync $LOCAL_MODEL_DIR $S3_MODEL_PREFIX --region $AWS_REGION
```

Use only approved model artifacts for the POC. The manifests expect the model path `OpenVINO/Phi-3-mini-FastDraft-50M-int8-ov`.

## Apply The Argo CD Application

Apply the Application after replacing `repoURL` and pushing the manifest changes.

```powershell
kubectl apply -f k8s/aws/argocd-application.yaml

kubectl get application -n argocd openvino-llm-poc
kubectl get pods -n llm-inference -o wide
kubectl get ingress -n llm-inference llm-gateway-internal
```

Wait for the ALB address to appear:

```powershell
$ALB_HOSTNAME = kubectl get ingress -n llm-inference llm-gateway-internal -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
$ALB_URL = "http://$ALB_HOSTNAME"
```

Run smoke and benchmark tests from a host that can reach the internal ALB.

```powershell
.\scripts\aws-smoke-test.ps1 -Url $ALB_URL -ApiKey $GATEWAY_API_KEY
.\scripts\aws-benchmark.ps1 -Url $ALB_URL -ApiKey $GATEWAY_API_KEY -Runs 5
```

Run the failure demo from an environment with `kubectl` access to the private EKS endpoint.

```bash
NAMESPACE=llm-inference LABEL_SELECTOR='app=ovms-llm,color=blue' ./scripts/aws-failure-demo.sh
```

The failure demo deletes one blue OVMS pod and waits for the StatefulSet to recover.

## Blue-Green Promotion

The active OVMS target is controlled in `k8s/aws/gateway-config.yaml`.

Blue target:

```yaml
OVMS_URL: http://ovms-blue-service.llm-inference.svc.cluster.local:8000/v3/chat/completions
```

Green target:

```yaml
OVMS_URL: http://ovms-green-service.llm-inference.svc.cluster.local:8000/v3/chat/completions
```

To promote green:

```powershell
$gatewayConfig = Get-Content -Raw k8s/aws/gateway-config.yaml
$gatewayConfig = $gatewayConfig.Replace("http://ovms-blue-service.llm-inference.svc.cluster.local:8000/v3/chat/completions", "http://ovms-green-service.llm-inference.svc.cluster.local:8000/v3/chat/completions")
Set-Content -NoNewline k8s/aws/gateway-config.yaml $gatewayConfig

git add k8s/aws/gateway-config.yaml
git commit -m "Promote OpenVINO green target"
git push origin codex/aws-eks-openvino-poc
```

Then sync or wait for Argo CD automated sync:

```powershell
kubectl get application -n argocd openvino-llm-poc
kubectl rollout restart deployment/llm-gateway -n llm-inference
kubectl rollout status deployment/llm-gateway -n llm-inference --timeout=5m
.\scripts\aws-smoke-test.ps1 -Url $ALB_URL -ApiKey $GATEWAY_API_KEY
```

The gateway reads `OVMS_URL` from a ConfigMap as an environment variable, so restart the gateway deployment after changing the ConfigMap.

## Known Local Validation Gaps

- A real AWS account, Terraform CLI, and EKS cluster are required to validate infrastructure creation.
- The local environment cannot prove the private EKS endpoint, Helm releases, IRSA, CSI mounts, ALB provisioning, S3 model sync, EBS volumes, HPA behavior, or OVMS readiness.
- `kubectl --dry-run` is not meaningful for this stack without a live cluster and installed CRDs such as Argo CD `Application` and Secrets Store CSI `SecretProviderClass`.
- Local documentation validation is limited to static checks such as `git diff --check`.
