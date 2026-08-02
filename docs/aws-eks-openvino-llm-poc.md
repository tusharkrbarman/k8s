# AWS EKS OpenVINO LLM POC Runbook

This runbook continues from the console-built AWS environment and deploys the
first working demo directly with `kubectl`. It does not push local changes or
enable Argo CD yet.

## 1. Known Deployment Profile

| Item | Current value |
| --- | --- |
| Region | `ap-south-1` |
| Cluster | `openvino-llm-poc` |
| Kubernetes | EKS `1.36` |
| Worker | one `m7i.xlarge` managed node |
| Node labels | `nodepool=m7i-inference`, `inference=openvino-cpu`, `hardware=intel-cpu` |
| Namespace | `llm-inference` |
| Model | `OpenVINO/Phi-3.5-mini-instruct-int4-ov` |
| Model bucket | `openvino-llm-models-654158184275-ap-south-1` |
| Storage | encrypted `gp3`, provisioner `ebs.csi.aws.com` |
| Identity | EKS Pod Identity |
| Egress | temporary public NAT Gateway |
| Target ingress | internal ALB |

Blue OVMS has one replica. Green has zero. The gateway has one replica. This is
a low-cost functional demo, not a highly available deployment.

The current learning cluster temporarily exposes the EKS API publicly as well
as privately. The target state is private API access from the Intel DMZ VPN or
another VPC-connected environment, plus an internal ALB for application traffic.

## 2. Verify The Cluster Foundation

Run these commands from the Windows terminal that already has AWS and
Kubernetes access:

```powershell
$REGION = "ap-south-1"
$CLUSTER = "openvino-llm-poc"

aws eks update-kubeconfig --name $CLUSTER --region $REGION
kubectl get nodes -L nodepool,inference,hardware
kubectl get pods -n kube-system -o wide
kubectl get storageclass
```

Do not deploy the application unless:

- the worker reports `Ready`;
- CoreDNS, Metrics Server, VPC CNI, EKS Pod Identity agent, and EBS CSI pods are
  `Running`;
- the Secrets Store CSI driver and AWS provider pods are `Running`;
- `gp3` exists and uses `ebs.csi.aws.com`;
- the node has `nodepool=m7i-inference` and `inference=openvino-cpu`.

The private subnets currently use NAT for bootstrap. They also use VPC endpoints
for core AWS APIs. The two endpoints that were required during node and EBS CSI
bootstrap were `com.amazonaws.ap-south-1.ec2` and
`com.amazonaws.ap-south-1.eks-auth`.

Use the AWS-managed add-on as the single owner of the Secrets Store CSI driver
and AWS provider. For the existing learning cluster, first remove the
self-managed Helm release if it is present:

```cmd
helm uninstall csi-secrets-store --namespace kube-system
```

Delete any failed copy of the managed add-on, then create it with one-time
conflict adoption:

```cmd
aws eks delete-addon --cluster-name openvino-llm-poc --addon-name aws-secrets-store-csi-driver-provider --region ap-south-1
aws eks create-addon --cluster-name openvino-llm-poc --addon-name aws-secrets-store-csi-driver-provider --region ap-south-1 --resolve-conflicts OVERWRITE
aws eks wait addon-active --cluster-name openvino-llm-poc --addon-name aws-secrets-store-csi-driver-provider --region ap-south-1
```

If deletion reports `ResourceNotFoundException`, continue with creation. Verify
the managed add-on, pods, driver, and CRD:

```cmd
aws eks describe-addon --cluster-name openvino-llm-poc --addon-name aws-secrets-store-csi-driver-provider --region ap-south-1 --query "addon.status" --output text
kubectl get pods -n kube-system | findstr /i "secrets provider"
kubectl get csidriver secrets-store.csi.k8s.io
kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io
```

`terraform/aws/main.tf` declares the same managed add-on. In a new
Terraform-created environment, Terraform creates it directly. Do not run a
blanket `terraform apply` against this manually created cluster: its VPC, EKS
cluster, IAM, and node groups are not represented in this Terraform state. If
the existing environment is later adopted into Terraform, import and reconcile
the full infrastructure first; the add-on import identifier is:

```cmd
terraform import aws_eks_addon.secrets_store_csi_driver_provider openvino-llm-poc:aws-secrets-store-csi-driver-provider
```

## 3. Verify Storage And Model Access

The storage class is already represented in the repository:

```powershell
kubectl apply -f k8s/aws/storage-class.yaml
kubectl get storageclass gp3
```

The expected S3 prefix is:

```text
s3://openvino-llm-models-654158184275-ap-south-1/OpenVINO/Phi-3.5-mini-instruct-int4-ov/
```

Verify that it contains the OpenVINO model, tokenizer, and configuration files:

```powershell
aws s3 ls s3://openvino-llm-models-654158184275-ap-south-1/OpenVINO/Phi-3.5-mini-instruct-int4-ov/ --recursive --region $REGION
```

The `ovms-model-reader` service account uses the existing EKS Pod Identity
association and the role `openvino-llm-poc-ovms-model-reader`. Its IAM policy
must allow `s3:ListBucket` on the bucket and `s3:GetObject` on only this prefix.
No IAM role annotation belongs in the service-account YAML.

## 4. Build And Push The Gateway

Create a private ECR repository named `openvino-llm-gateway`, then run from the
repository root:

```powershell
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$ECR_REGISTRY = "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
$GATEWAY_IMAGE = "$ECR_REGISTRY/openvino-llm-gateway:0.1.0"

aws ecr get-login-password --region $REGION |
  docker login --username AWS --password-stdin $ECR_REGISTRY

docker build -t $GATEWAY_IMAGE .\gateway
docker push $GATEWAY_IMAGE
```

Replace `REPLACE_WITH_GATEWAY_ECR_IMAGE` in `k8s/aws/gateway.yaml` with the
resulting image URI. Do not change the OVMS image digest during this demo.

## 5. Create The Gateway Secret Identity

Create the Secrets Manager value expected by
`k8s/aws/gateway-secret-provider.yaml`:

```powershell
$GATEWAY_API_KEY = Read-Host "Gateway API key"

aws secretsmanager create-secret `
  --name /openvino-llm-poc/gateway/api-key `
  --secret-string $GATEWAY_API_KEY `
  --region $REGION
```

If the secret already exists, update it instead:

```powershell
aws secretsmanager put-secret-value `
  --secret-id /openvino-llm-poc/gateway/api-key `
  --secret-string $GATEWAY_API_KEY `
  --region $REGION
```

Create an IAM role with EKS Pod Identity trust and permission to read only this
secret. Associate it with namespace `llm-inference` and service account
`llm-gateway`. Confirm the association before deploying:

```powershell
aws eks list-pod-identity-associations `
  --cluster-name $CLUSTER `
  --namespace llm-inference `
  --service-account llm-gateway `
  --region $REGION `
  --output table
```

## 6. Validate The Ready Manifests

The model bucket, model name, resources, storage class, and OVMS identity are
already concrete. Only these placeholders remain:

```text
REPLACE_WITH_GATEWAY_ECR_IMAGE
REPLACE_WITH_INTERNAL_ALB_SECURITY_GROUP_ID
REPLACE_WITH_GIT_REPOSITORY_URL
```

The last two belong to the later ingress and Argo CD steps. After replacing the
gateway image, validate the manifests against the live API:

```powershell
kubectl apply --dry-run=server -f k8s/aws/storage-class.yaml
kubectl apply --dry-run=server -f k8s/aws/namespace.yaml
kubectl apply --dry-run=server -f k8s/aws/gateway-config.yaml
kubectl apply --dry-run=server -f k8s/aws/ovms-blue.yaml
kubectl apply --dry-run=server -f k8s/aws/ovms-green.yaml
kubectl apply --dry-run=server -f k8s/aws/gateway-secret-provider.yaml
kubectl apply --dry-run=server -f k8s/aws/gateway.yaml
kubectl apply --dry-run=server -f k8s/aws/hpa.yaml
kubectl apply --dry-run=server -f k8s/aws/pdb.yaml
```

Do not validate or apply `gateway-ingress.yaml` or `argocd-application.yaml`
until their placeholders are replaced and their controllers are installed.

## 7. Deploy The Demo Directly

Apply resources in dependency order:

```powershell
kubectl apply -f k8s/aws/storage-class.yaml
kubectl apply -f k8s/aws/namespace.yaml
kubectl apply -f k8s/aws/gateway-config.yaml
kubectl apply -f k8s/aws/ovms-blue.yaml
kubectl apply -f k8s/aws/ovms-green.yaml
kubectl apply -f k8s/aws/gateway-secret-provider.yaml
kubectl apply -f k8s/aws/gateway.yaml
kubectl apply -f k8s/aws/hpa.yaml
kubectl apply -f k8s/aws/pdb.yaml
```

Watch the model copy and startup rather than repeatedly restarting it:

```powershell
kubectl get pods,pvc -n llm-inference -w
kubectl logs -n llm-inference statefulset/ovms-blue -c sync-model -f
kubectl logs -n llm-inference statefulset/ovms-blue -c ovms -f
```

Expected steady state:

```text
ovms-blue:  1 ready
ovms-green: 0 replicas
llm-gateway: 1 ready
model-cache-ovms-blue-0: Bound
```

Check the OVMS model status from inside the cluster:

```powershell
kubectl run ovms-check --rm -i --restart=Never `
  --image=curlimages/curl:8.12.1 `
  -n llm-inference -- `
  curl -fsS http://ovms-blue-service:8000/v1/config
```

## 8. Smoke-Test Before Adding Ingress

Keep this terminal open:

```powershell
kubectl port-forward -n llm-inference service/llm-gateway-service 8080:8080
```

In a second terminal:

```powershell
.\scripts\aws-smoke-test.ps1 -Url http://127.0.0.1:8080 -ApiKey $GATEWAY_API_KEY
```

Run one smoke request first. Do not start a benchmark until the pod remains
stable and the response is correct. Then use a small run count:

```powershell
.\scripts\aws-benchmark.ps1 -Url http://127.0.0.1:8080 -ApiKey $GATEWAY_API_KEY -Runs 3
```

## 9. Add The Internal ALB

After the direct smoke test succeeds:

1. Install the AWS Load Balancer Controller with EKS Pod Identity.
2. Create or select the internal ALB security group.
3. Replace `REPLACE_WITH_INTERNAL_ALB_SECURITY_GROUP_ID` in
   `k8s/aws/gateway-ingress.yaml`.
4. Apply the ingress and wait for its internal hostname.

```powershell
kubectl apply -f k8s/aws/gateway-ingress.yaml
kubectl get ingress -n llm-inference llm-gateway-internal -w
```

The ALB is internal, so test it only from the Intel DMZ VPN or another private
path into the VPC.

## 10. Production-Shaped Follow-Up

Do these only after the one-node demo works:

- add workers across two Availability Zones before increasing replicas;
- mirror public AWS CLI and OVMS images into private ECR;
- add any missing VPC endpoints, including Elastic Load Balancing when NAT is
  removed;
- remove private-subnet default routes to the NAT Gateway, then delete the NAT;
- disable public EKS API access after verifying private administration;
- enable Argo CD and replace `REPLACE_WITH_GIT_REPOSITORY_URL`;
- test blue-green promotion and node failure only after spare capacity exists.

The HPA allows up to two gateway replicas, but the current single node is the
capacity ceiling. This demo proves deployment and request flow, not multi-AZ
resilience.
