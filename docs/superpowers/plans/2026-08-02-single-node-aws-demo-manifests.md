# Single-Node AWS Demo Manifests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Kubernetes application manifests fit the live single-node `m7i.xlarge` cluster and serve the uploaded Phi-3.5 OpenVINO model from an EBS-backed cache populated from S3.

**Architecture:** One OVMS blue StatefulSet and one gateway replica share the `m7i-inference` node; green remains scaled to zero. OVMS uses EKS Pod Identity to read the exact S3 model prefix into an encrypted `gp3` PVC, while the temporary NAT Gateway permits the public OVMS and AWS CLI image pulls during this learning deployment.

**Tech Stack:** Kubernetes 1.36, Amazon EKS, EKS Pod Identity, Amazon EBS CSI, Amazon S3, OpenVINO Model Server, PowerShell validation.

## Global Constraints

- Keep `ovms-blue` at `1` replica and `ovms-green` at `0` replicas.
- Use `OpenVINO/Phi-3.5-mini-instruct-int4-ov`; never serve `Phi-3-mini-FastDraft-50M-int8-ov` as the standalone chat model.
- OVMS requests `2` CPU and `6 GiB`, is limited to `3` CPU and `12 GiB`, and uses a `1 GiB` cache.
- Use the existing `llm-inference/ovms-model-reader` Pod Identity association; do not add an IRSA annotation.
- Use the existing encrypted default `gp3` StorageClass.
- Keep all changes local; do not push them.

---

### Task 1: Align OVMS With The Uploaded Model And Node Capacity

**Files:**
- Modify: `k8s/aws/ovms-blue.yaml`
- Modify: `k8s/aws/ovms-green.yaml`
- Modify: `k8s/aws/gateway-config.yaml`

**Interfaces:**
- Consumes: S3 prefix `s3://openvino-llm-models-654158184275-ap-south-1/OpenVINO/Phi-3.5-mini-instruct-int4-ov/`, service account `llm-inference/ovms-model-reader`, StorageClass `gp3`.
- Produces: blue and green OVMS manifests that use the same model name, bucket path, resource envelope, and PVC class.

- [ ] **Step 1: Run the pre-change checks and observe the stale configuration**

```powershell
rg -n "FastDraft|REPLACE_WITH_MODEL_BUCKET_NAME|cpu: \"8\"|memory: 24Gi|REPLACE_WITH_OVMS_MODEL_READER_SERVICE_ACCOUNT_ROLE_ARN" k8s/aws/ovms-blue.yaml k8s/aws/ovms-green.yaml k8s/aws/gateway-config.yaml
```

Expected: matches are printed, proving the current manifests still contain the draft model, oversized resources, bucket placeholder, and IRSA placeholder.

- [ ] **Step 2: Update both OVMS manifests**

Apply these exact changes to blue and green:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ovms-model-reader
  namespace: llm-inference
```

Use this source and destination in `sync-model`:

```yaml
- s3://openvino-llm-models-654158184275-ap-south-1/OpenVINO/Phi-3.5-mini-instruct-int4-ov
- /models/OpenVINO/Phi-3.5-mini-instruct-int4-ov
```

Use these OVMS values:

```yaml
- --source_model
- OpenVINO/Phi-3.5-mini-instruct-int4-ov
- --cache_size
- "1"
```

Use this resource envelope:

```yaml
resources:
  requests:
    cpu: "2"
    memory: 6Gi
  limits:
    cpu: "3"
    memory: 12Gi
```

Add the explicit storage class beneath each PVC spec:

```yaml
storageClassName: gp3
```

- [ ] **Step 3: Update the gateway model name**

Set `MODEL_NAME` in `k8s/aws/gateway-config.yaml` to:

```yaml
MODEL_NAME: OpenVINO/Phi-3.5-mini-instruct-int4-ov
```

- [ ] **Step 4: Run post-change content checks**

```powershell
if (rg -n "FastDraft|REPLACE_WITH_MODEL_BUCKET_NAME|REPLACE_WITH_OVMS_MODEL_READER_SERVICE_ACCOUNT_ROLE_ARN" k8s/aws/ovms-blue.yaml k8s/aws/ovms-green.yaml k8s/aws/gateway-config.yaml) { throw "Stale OVMS configuration remains" }
rg -n "Phi-3.5-mini-instruct-int4-ov|storageClassName: gp3|cpu: \"2\"|cpu: \"3\"|memory: 6Gi|memory: 12Gi" k8s/aws/ovms-blue.yaml k8s/aws/ovms-green.yaml k8s/aws/gateway-config.yaml
```

Expected: the first command emits no matches; the second shows the expected values in both OVMS manifests and the gateway ConfigMap.

- [ ] **Step 5: Commit the OVMS manifest change locally**

```powershell
git add k8s/aws/ovms-blue.yaml k8s/aws/ovms-green.yaml k8s/aws/gateway-config.yaml
git commit -m "Fit OVMS manifests to single-node AWS demo"
```

### Task 2: Fit The Gateway To The Single Node

**Files:**
- Modify: `k8s/aws/gateway.yaml`
- Modify: `k8s/aws/hpa.yaml`

**Interfaces:**
- Consumes: node label `nodepool=m7i-inference` and the future `llm-inference/llm-gateway` Pod Identity association.
- Produces: one gateway replica on the inference node with optional scale-out to two replicas.

- [ ] **Step 1: Confirm the old scheduling values are present**

```powershell
rg -n "replicas: 2|nodepool: system-gateway|minReplicas: 2|maxReplicas: 4|REPLACE_WITH_GATEWAY_SERVICE_ACCOUNT_ROLE_ARN" k8s/aws/gateway.yaml k8s/aws/hpa.yaml
```

Expected: all old values are found.

- [ ] **Step 2: Update gateway scheduling and identity**

Remove the service-account IRSA annotation and use:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: llm-gateway
  namespace: llm-inference
```

Set the Deployment values to:

```yaml
replicas: 1
nodeSelector:
  nodepool: m7i-inference
```

- [ ] **Step 3: Update the gateway HPA**

```yaml
minReplicas: 1
maxReplicas: 2
```

- [ ] **Step 4: Verify the gateway profile**

```powershell
if (rg -n "nodepool: system-gateway|minReplicas: 2|maxReplicas: 4|REPLACE_WITH_GATEWAY_SERVICE_ACCOUNT_ROLE_ARN" k8s/aws/gateway.yaml k8s/aws/hpa.yaml) { throw "Stale gateway configuration remains" }
rg -n "replicas: 1|nodepool: m7i-inference|minReplicas: 1|maxReplicas: 2" k8s/aws/gateway.yaml k8s/aws/hpa.yaml
```

Expected: only the new single-node values are printed.

- [ ] **Step 5: Commit the gateway manifest change locally**

```powershell
git add k8s/aws/gateway.yaml k8s/aws/hpa.yaml
git commit -m "Fit gateway manifests to single-node AWS demo"
```

### Task 3: Synchronize Deployment Documentation And Validate

**Files:**
- Modify: `README.md`
- Modify: `docs/aws-eks-openvino-llm-poc.md`
- Include existing local file: `k8s/aws/storage-class.yaml`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: manifest behavior from Tasks 1 and 2.
- Produces: a manual deployment guide that matches the live console-built cluster and does not instruct users to replace removed IRSA/model placeholders.

- [ ] **Step 1: Update the documented deployment profile**

Document these exact facts:

```text
Live demo: one m7i.xlarge worker
Active inference: one OVMS blue replica
Standby: OVMS green replicas = 0
Model: OpenVINO/Phi-3.5-mini-instruct-int4-ov
Storage: encrypted gp3 through ebs.csi.aws.com
Identity: EKS Pod Identity for application service accounts
Bootstrap egress: temporary public NAT Gateway
Target application ingress: internal ALB
```

Remove the model bucket and service-account role placeholders from the documented replacement steps. Keep the gateway ECR image, internal ALB security group, and Git repository placeholders because those resources are configured later.

- [ ] **Step 2: Verify repository text consistency**

```powershell
if (rg -n "Phi-3-mini-FastDraft-50M-int8-ov|REPLACE_WITH_MODEL_BUCKET_NAME|REPLACE_WITH_OVMS_MODEL_READER_SERVICE_ACCOUNT_ROLE_ARN|REPLACE_WITH_GATEWAY_SERVICE_ACCOUNT_ROLE_ARN" README.md docs/aws-eks-openvino-llm-poc.md k8s/aws) { throw "Stale deployment configuration remains" }
rg -n "Phi-3.5-mini-instruct-int4-ov|m7i.xlarge|EKS Pod Identity|gp3" README.md docs/aws-eks-openvino-llm-poc.md k8s/aws
```

Expected: no stale model or role placeholders remain; the new deployment profile is present in code and documentation.

- [ ] **Step 3: Run repository checks**

```powershell
python -m pytest gateway/tests
git diff --check
kubectl apply --dry-run=server -f k8s/aws/storage-class.yaml
kubectl apply --dry-run=server -f k8s/aws/namespace.yaml
kubectl apply --dry-run=server -f k8s/aws/ovms-blue.yaml
kubectl apply --dry-run=server -f k8s/aws/ovms-green.yaml
kubectl apply --dry-run=server -f k8s/aws/gateway-config.yaml
kubectl apply --dry-run=server -f k8s/aws/hpa.yaml
```

Expected: gateway tests pass, Git reports no whitespace errors, and every non-placeholder manifest is accepted by the live Kubernetes API. Do not validate `gateway.yaml`, `gateway-ingress.yaml`, or `argocd-application.yaml` until their remaining deployment-specific placeholders are replaced.

- [ ] **Step 4: Commit the documentation and local support files**

```powershell
git add README.md docs/aws-eks-openvino-llm-poc.md k8s/aws/storage-class.yaml .gitignore
git commit -m "Document single-node AWS deployment path"
```

