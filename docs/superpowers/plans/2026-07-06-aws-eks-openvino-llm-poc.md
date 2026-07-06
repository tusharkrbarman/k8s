# AWS EKS OpenVINO LLM POC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an AWS-specific, private-only EKS implementation path for the approved OpenVINO LLM POC without breaking the existing Intel bare-metal GPU POC.

**Architecture:** Terraform provisions AWS infrastructure and platform add-ons. Argo CD reconciles Kubernetes app manifests for a FastAPI gateway, internal ALB, Secrets Manager CSI integration, and blue/green OVMS CPU StatefulSets running on Intel M7i EKS nodes.

**Tech Stack:** AWS EKS, Terraform, Argo CD, AWS Load Balancer Controller, AWS Secrets Manager CSI provider, EBS CSI, S3, ECR, FastAPI, OpenVINO Model Server, Kubernetes YAML, PowerShell/Bash validation scripts.

---

## File Structure

Create AWS-specific files instead of mutating the bare-metal manifests:

- `terraform/aws/versions.tf`: Terraform provider and module version constraints.
- `terraform/aws/variables.tf`: Inputs for region, cluster name, CIDRs, model bucket, and node sizing.
- `terraform/aws/main.tf`: AWS infrastructure, EKS, node groups, ECR, S3, VPC endpoints, and add-on Helm releases.
- `terraform/aws/outputs.tf`: EKS, ECR, S3, and ALB-related outputs.
- `k8s/aws/namespace.yaml`: Application namespace.
- `k8s/aws/gateway.yaml`: Gateway Deployment/Service configured for internal ALB and file-mounted API key.
- `k8s/aws/gateway-ingress.yaml`: Internal ALB Ingress.
- `k8s/aws/gateway-secret-provider.yaml`: SecretProviderClass for AWS Secrets Manager.
- `k8s/aws/ovms-blue.yaml`: Blue OVMS CPU StatefulSet and Service.
- `k8s/aws/ovms-green.yaml`: Green OVMS CPU StatefulSet and Service.
- `k8s/aws/hpa.yaml`: Gateway and OVMS HPAs.
- `k8s/aws/pdb.yaml`: PodDisruptionBudgets.
- `k8s/aws/argocd-application.yaml`: Argo CD Application pointing at `k8s/aws`.
- `gateway/app/main.py`: Add API key file support and structured logs while preserving env-var support.
- `gateway/requirements-dev.txt`: Test dependencies.
- `gateway/tests/test_gateway.py`: Unit tests for API key file/env behavior and OVMS forwarding.
- `scripts/aws-smoke-test.ps1`: Private endpoint smoke test.
- `scripts/aws-benchmark.ps1`: Reusable benchmark script for latency and tokens/sec.
- `scripts/aws-failure-demo.sh`: Controlled OVMS pod failure demo.
- `docs/aws-eks-openvino-llm-poc.md`: Operator-facing runbook.
- `.gitignore`: Ignore local Terraform state and generated secrets.

## Task 1: Gateway API Key File Support

**Files:**
- Modify: `gateway/app/main.py`
- Create: `gateway/requirements-dev.txt`
- Create: `gateway/tests/test_gateway.py`

- [ ] **Step 1: Add dev test dependencies**

Create `gateway/requirements-dev.txt`:

```text
-r requirements.txt
pytest==8.4.1
respx==0.22.0
```

- [ ] **Step 2: Write tests for env key, file key, invalid key, and OVMS forwarding**

Create `gateway/tests/test_gateway.py`:

```python
import importlib

import pytest
import respx
from fastapi.testclient import TestClient
from httpx import Response


def load_app(monkeypatch, tmp_path, api_key=None, api_key_file=None):
    monkeypatch.setenv("OVMS_URL", "http://ovms.test/v3/chat/completions")
    monkeypatch.setenv("MODEL_NAME", "test-model")
    if api_key is not None:
        monkeypatch.setenv("API_KEY", api_key)
    else:
        monkeypatch.delenv("API_KEY", raising=False)

    if api_key_file is not None:
        secret_file = tmp_path / "api-key"
        secret_file.write_text(api_key_file, encoding="utf-8")
        monkeypatch.setenv("API_KEY_FILE", str(secret_file))
    else:
        monkeypatch.delenv("API_KEY_FILE", raising=False)

    import app.main

    importlib.reload(app.main)
    return TestClient(app.main.app)


@respx.mock
def test_chat_accepts_env_api_key(monkeypatch, tmp_path):
    client = load_app(monkeypatch, tmp_path, api_key="env-secret")
    respx.post("http://ovms.test/v3/chat/completions").mock(
        return_value=Response(
            200,
            json={
                "model": "test-model",
                "choices": [{"message": {"content": "hello"}}],
                "usage": {"prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4},
            },
        )
    )

    response = client.post(
        "/chat",
        headers={"X-API-Key": "env-secret"},
        json={"message": "hi", "max_tokens": 8},
    )

    assert response.status_code == 200
    assert response.json()["answer"] == "hello"
    assert response.json()["usage"]["total_tokens"] == 4


@respx.mock
def test_chat_accepts_file_api_key(monkeypatch, tmp_path):
    client = load_app(monkeypatch, tmp_path, api_key_file="file-secret\n")
    respx.post("http://ovms.test/v3/chat/completions").mock(
        return_value=Response(
            200,
            json={
                "model": "test-model",
                "choices": [{"message": {"content": "from file"}}],
                "usage": {"prompt_tokens": 2, "completion_tokens": 2, "total_tokens": 4},
            },
        )
    )

    response = client.post(
        "/chat",
        headers={"X-API-Key": "file-secret"},
        json={"message": "hi", "max_tokens": 8},
    )

    assert response.status_code == 200
    assert response.json()["answer"] == "from file"


def test_chat_rejects_invalid_key(monkeypatch, tmp_path):
    client = load_app(monkeypatch, tmp_path, api_key="correct")

    response = client.post(
        "/chat",
        headers={"X-API-Key": "wrong"},
        json={"message": "hi", "max_tokens": 8},
    )

    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid API key"


def test_chat_requires_configured_key(monkeypatch, tmp_path):
    client = load_app(monkeypatch, tmp_path)

    response = client.post(
        "/chat",
        headers={"X-API-Key": "anything"},
        json={"message": "hi", "max_tokens": 8},
    )

    assert response.status_code == 500
    assert response.json()["detail"] == "Gateway API key is not configured"
```

- [ ] **Step 3: Run tests and verify they fail before implementation**

Run:

```powershell
cd gateway
python -m pip install -r requirements-dev.txt
python -m pytest tests/test_gateway.py -v
```

Expected: tests that rely on `API_KEY_FILE` fail because `gateway/app/main.py` does not read file-mounted secrets yet.

- [ ] **Step 4: Implement API key file support and structured request logging**

Modify `gateway/app/main.py` so its top section and auth helper look like this:

```python
import logging
import os
import time
from typing import Any

import httpx
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field


logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("llm-gateway")

OVMS_URL = os.getenv(
    "OVMS_URL",
    "http://ovms-llm-gpu-service:8000/v3/chat/completions",
)
MODEL_NAME = os.getenv(
    "MODEL_NAME",
    "OpenVINO/Phi-3.5-mini-instruct-int4-ov",
)
API_KEY = os.getenv("API_KEY")
API_KEY_FILE = os.getenv("API_KEY_FILE")
REQUEST_TIMEOUT_SECONDS = float(os.getenv("REQUEST_TIMEOUT_SECONDS", "60"))
```

Add this helper below the `ChatResponse` class:

```python
def get_configured_api_key() -> str | None:
    if API_KEY:
        return API_KEY

    if API_KEY_FILE:
        try:
            with open(API_KEY_FILE, encoding="utf-8") as secret_file:
                return secret_file.read().strip()
        except OSError as exc:
            logger.error("failed_to_read_api_key_file path=%s error=%s", API_KEY_FILE, exc)
            return None

    return None
```

Replace the first auth block in `chat()` with:

```python
    configured_api_key = get_configured_api_key()
    if not configured_api_key:
        raise HTTPException(status_code=500, detail="Gateway API key is not configured")

    if x_api_key != configured_api_key:
        raise HTTPException(status_code=401, detail="Invalid API key")
```

Add logging before returning the response:

```python
    logger.info(
        "chat_completion model=%s latency_seconds=%s prompt_tokens=%s completion_tokens=%s total_tokens=%s",
        body.get("model", MODEL_NAME),
        elapsed,
        body.get("usage", {}).get("prompt_tokens"),
        body.get("usage", {}).get("completion_tokens"),
        body.get("usage", {}).get("total_tokens"),
    )
```

- [ ] **Step 5: Run tests and verify they pass**

Run:

```powershell
cd gateway
python -m pytest tests/test_gateway.py -v
```

Expected: all four tests pass.

- [ ] **Step 6: Commit gateway support**

```bash
git add gateway/app/main.py gateway/requirements-dev.txt gateway/tests/test_gateway.py
git commit -m "Add AWS secret file support to gateway"
```

## Task 2: AWS Terraform Infrastructure

**Files:**
- Create: `terraform/aws/versions.tf`
- Create: `terraform/aws/variables.tf`
- Create: `terraform/aws/main.tf`
- Create: `terraform/aws/outputs.tf`
- Modify: `.gitignore`

- [ ] **Step 1: Ignore local Terraform state**

Add these lines to `.gitignore`:

```text
.terraform/
*.tfstate
*.tfstate.*
terraform.tfvars
```

- [ ] **Step 2: Create Terraform provider constraints**

Create `terraform/aws/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.15.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.31.0"
    }
  }
}
```

- [ ] **Step 3: Create Terraform inputs**

Create `terraform/aws/variables.tf`:

```hcl
variable "region" {
  description = "AWS region for the POC."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "openvino-llm-poc"
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.80.0.0/16"
}

variable "trusted_private_cidrs" {
  description = "CIDRs allowed to reach the internal ALB."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "gateway_image_name" {
  description = "ECR repository name for the FastAPI gateway."
  type        = string
  default     = "openvino-llm-gateway"
}

variable "model_bucket_name" {
  description = "Globally unique S3 bucket name for approved OpenVINO model artifacts."
  type        = string
}

variable "system_instance_types" {
  description = "Instance types for system and gateway workloads."
  type        = list(string)
  default     = ["m7i-flex.xlarge"]
}

variable "inference_instance_types" {
  description = "Intel M7i instance types for OVMS CPU inference."
  type        = list(string)
  default     = ["m7i.2xlarge"]
}
```

- [ ] **Step 4: Create Terraform main module**

Create `terraform/aws/main.tf` with VPC, EKS, ECR, S3, VPC endpoints, and Helm add-ons. Use Terraform modules for VPC/EKS and keep controller IAM policies scoped by service account.

```hcl
provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = [for index, az in local.azs : cidrsubnet(var.vpc_cidr, 4, index)]
  public_subnets  = [for index, az in local.azs : cidrsubnet(var.vpc_cidr, 4, index + 8)]
  tags = {
    Project = var.cluster_name
    Owner   = "openvino-llm-poc"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">= 5.0.0"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = ">= 20.0.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  enable_irsa = true

  eks_managed_node_groups = {
    system_gateway = {
      name           = "system-gateway"
      instance_types = var.system_instance_types
      min_size       = 2
      max_size       = 2
      desired_size   = 2

      labels = {
        nodepool = "system-gateway"
        workload = "platform"
      }
    }

    m7i_inference = {
      name           = "m7i-inference"
      instance_types = var.inference_instance_types
      min_size       = 2
      max_size       = 2
      desired_size   = 2

      labels = {
        nodepool  = "m7i-inference"
        inference = "openvino-cpu"
        hardware  = "intel-cpu"
      }
    }
  }

  cluster_addons = {
    coredns = {}
    kube-proxy = {}
    vpc-cni = {}
    aws-ebs-csi-driver = {}
  }

  tags = local.tags
}

resource "aws_ecr_repository" "gateway" {
  name                 = var.gateway_image_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_s3_bucket" "models" {
  bucket = var.model_bucket_name
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_security_group" "internal_alb" {
  name        = "${var.cluster_name}-internal-alb"
  description = "Allow trusted private clients to reach the internal ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.trusted_private_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  tags              = local.tags
}

resource "aws_vpc_endpoint" "interface_endpoints" {
  for_each = toset([
    "ecr.api",
    "ecr.dkr",
    "secretsmanager",
    "sts",
    "logs",
    "monitoring",
  ])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  private_dns_enabled = true

  security_group_ids = [module.eks.node_security_group_id]
  tags               = local.tags
}
```

- [ ] **Step 5: Add Terraform outputs**

Create `terraform/aws/outputs.tf`:

```hcl
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "gateway_ecr_repository_url" {
  value = aws_ecr_repository.gateway.repository_url
}

output "model_bucket_name" {
  value = aws_s3_bucket.models.bucket
}

output "internal_alb_security_group_id" {
  value = aws_security_group.internal_alb.id
}
```

- [ ] **Step 6: Format and validate Terraform**

Run:

```powershell
terraform -chdir=terraform/aws fmt
terraform -chdir=terraform/aws init
terraform -chdir=terraform/aws validate
```

Expected: `terraform validate` reports `Success! The configuration is valid.`

- [ ] **Step 7: Commit Terraform baseline**

```bash
git add .gitignore terraform/aws
git commit -m "Add AWS EKS Terraform baseline"
```

## Task 3: AWS Kubernetes App Manifests

**Files:**
- Create: `k8s/aws/namespace.yaml`
- Create: `k8s/aws/gateway-secret-provider.yaml`
- Create: `k8s/aws/gateway.yaml`
- Create: `k8s/aws/gateway-ingress.yaml`
- Create: `k8s/aws/ovms-blue.yaml`
- Create: `k8s/aws/ovms-green.yaml`
- Create: `k8s/aws/hpa.yaml`
- Create: `k8s/aws/pdb.yaml`

- [ ] **Step 1: Create namespace**

Create `k8s/aws/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: llm-inference
```

- [ ] **Step 2: Create Secrets Manager SecretProviderClass**

Create `k8s/aws/gateway-secret-provider.yaml`:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: gateway-api-key
  namespace: llm-inference
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "/openvino-llm-poc/gateway/api-key"
        objectType: "secretsmanager"
        objectAlias: "api-key"
```

- [ ] **Step 3: Create gateway manifest**

Create `k8s/aws/gateway.yaml` with `API_KEY_FILE=/mnt/secrets-store/api-key` and the active OVMS service set to blue:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: llm-gateway
  namespace: llm-inference
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/openvino-llm-gateway-secrets
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-gateway
  namespace: llm-inference
spec:
  replicas: 2
  selector:
    matchLabels:
      app: llm-gateway
  template:
    metadata:
      labels:
        app: llm-gateway
    spec:
      serviceAccountName: llm-gateway
      nodeSelector:
        nodepool: system-gateway
      containers:
        - name: gateway
          image: 111122223333.dkr.ecr.us-east-1.amazonaws.com/openvino-llm-gateway:0.1.0
          imagePullPolicy: IfNotPresent
          env:
            - name: OVMS_URL
              value: "http://ovms-blue-service.llm-inference.svc.cluster.local:8000/v3/chat/completions"
            - name: MODEL_NAME
              value: "OpenVINO/Phi-3-mini-FastDraft-50M-int8-ov"
            - name: API_KEY_FILE
              value: "/mnt/secrets-store/api-key"
            - name: REQUEST_TIMEOUT_SECONDS
              value: "120"
          ports:
            - name: http
              containerPort: 8080
          volumeMounts:
            - name: secrets-store
              mountPath: /mnt/secrets-store
              readOnly: true
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 20
            periodSeconds: 20
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
      volumes:
        - name: secrets-store
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: gateway-api-key
---
apiVersion: v1
kind: Service
metadata:
  name: llm-gateway-service
  namespace: llm-inference
spec:
  selector:
    app: llm-gateway
  ports:
    - name: http
      port: 8080
      targetPort: 8080
  type: ClusterIP
```

- [ ] **Step 4: Create internal ALB Ingress**

Create `k8s/aws/gateway-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: llm-gateway-internal
  namespace: llm-inference
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /health
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: llm-gateway-service
                port:
                  number: 8080
```

- [ ] **Step 5: Create blue OVMS StatefulSet**

Create `k8s/aws/ovms-blue.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ovms-model-reader
  namespace: llm-inference
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/openvino-llm-model-reader
---
apiVersion: v1
kind: Service
metadata:
  name: ovms-blue-headless
  namespace: llm-inference
spec:
  clusterIP: None
  selector:
    app: ovms-llm
    color: blue
  ports:
    - name: http
      port: 8000
      targetPort: 8000
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ovms-blue
  namespace: llm-inference
spec:
  serviceName: ovms-blue-headless
  replicas: 2
  selector:
    matchLabels:
      app: ovms-llm
      color: blue
  template:
    metadata:
      labels:
        app: ovms-llm
        color: blue
    spec:
      serviceAccountName: ovms-model-reader
      nodeSelector:
        nodepool: m7i-inference
        inference: openvino-cpu
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: ovms-llm
              color: blue
      initContainers:
        - name: sync-model
          image: public.ecr.aws/aws-cli/aws-cli:2.17.0
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              aws s3 sync s3://openvino-llm-models/OpenVINO/Phi-3-mini-FastDraft-50M-int8-ov /models/OpenVINO/Phi-3-mini-FastDraft-50M-int8-ov
          volumeMounts:
            - name: model-cache
              mountPath: /models
      containers:
        - name: ovms
          image: openvino/model_server:latest
          args:
            - "--source_model=OpenVINO/Phi-3-mini-FastDraft-50M-int8-ov"
            - "--model_repository_path=models"
            - "--task=text_generation"
            - "--rest_port=8000"
            - "--target_device=CPU"
            - "--cache_size=2"
          ports:
            - name: http
              containerPort: 8000
          volumeMounts:
            - name: model-cache
              mountPath: /models
          startupProbe:
            httpGet:
              path: /v1/config
              port: 8000
            periodSeconds: 10
            failureThreshold: 90
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              path: /v1/config
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /v1/config
              port: 8000
            initialDelaySeconds: 180
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: "4"
              memory: "12Gi"
            limits:
              cpu: "8"
              memory: "24Gi"
  volumeClaimTemplates:
    - metadata:
        name: model-cache
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: ovms-blue-service
  namespace: llm-inference
spec:
  selector:
    app: ovms-llm
    color: blue
  ports:
    - name: http
      port: 8000
      targetPort: 8000
  type: ClusterIP
```

- [ ] **Step 6: Create green OVMS StatefulSet**

Copy `k8s/aws/ovms-blue.yaml` to `k8s/aws/ovms-green.yaml` and change:

```yaml
metadata:
  name: ovms-green-headless
```

```yaml
color: green
```

```yaml
metadata:
  name: ovms-green
```

```yaml
serviceName: ovms-green-headless
```

```yaml
metadata:
  name: ovms-green-service
```

Keep the same model for the first POC so blue-green promotion proves the mechanism before changing model artifacts.

- [ ] **Step 7: Create HPA manifest**

Create `k8s/aws/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: llm-gateway-hpa
  namespace: llm-inference
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: llm-gateway
  minReplicas: 2
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ovms-blue-hpa
  namespace: llm-inference
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: StatefulSet
    name: ovms-blue
  minReplicas: 2
  maxReplicas: 2
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 75
```

- [ ] **Step 8: Create PDB manifest**

Create `k8s/aws/pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: llm-gateway-pdb
  namespace: llm-inference
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: llm-gateway
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ovms-blue-pdb
  namespace: llm-inference
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: ovms-llm
      color: blue
```

- [ ] **Step 9: Validate YAML client-side**

Run:

```powershell
kubectl apply --dry-run=client -f k8s/aws
```

Expected: each object is accepted by the Kubernetes client.

- [ ] **Step 10: Commit AWS manifests**

```bash
git add k8s/aws
git commit -m "Add AWS EKS application manifests"
```

## Task 4: Argo CD Application

**Files:**
- Create: `k8s/aws/argocd-application.yaml`

- [ ] **Step 1: Create the Argo CD Application**

Create `k8s/aws/argocd-application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openvino-llm-poc
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/tusha/openvino-llm-poc.git
    targetRevision: HEAD
    path: k8s/aws
    directory:
      recurse: false
      exclude: argocd-application.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: llm-inference
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Make repository ownership explicit**

Use this concrete repository URL in the first implementation:

```yaml
    repoURL: https://github.com/tusha/openvino-llm-poc.git
```

If the project is later pushed to a different Git remote, change this exact URL in a follow-up commit together with the Argo CD bootstrap notes.

- [ ] **Step 3: Validate the manifest**

Run:

```powershell
kubectl apply --dry-run=client -f k8s/aws/argocd-application.yaml
```

Expected: the manifest is accepted if Argo CD CRDs are installed locally or in the target cluster. If the CRD is absent, expected failure is `no matches for kind "Application"`; this is acceptable before Argo CD is installed.

- [ ] **Step 4: Commit Argo CD application**

```bash
git add k8s/aws/argocd-application.yaml
git commit -m "Add Argo CD application for AWS POC"
```

## Task 5: AWS Validation Scripts

**Files:**
- Create: `scripts/aws-smoke-test.ps1`
- Create: `scripts/aws-benchmark.ps1`
- Create: `scripts/aws-failure-demo.sh`

- [ ] **Step 1: Create smoke test script**

Create `scripts/aws-smoke-test.ps1`:

```powershell
param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [string]$ApiKey
)

$body = @{
    message = "Say hello in one short sentence."
    max_tokens = 16
} | ConvertTo-Json

$headers = @{
    "Content-Type" = "application/json"
    "X-API-Key" = $ApiKey
}

$response = Invoke-RestMethod -Method Post -Uri "$Url/chat" -Headers $headers -Body $body
$response | Format-List
```

- [ ] **Step 2: Create benchmark script**

Create `scripts/aws-benchmark.ps1`:

```powershell
param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [int]$Runs = 5
)

$results = @()

for ($i = 1; $i -le $Runs; $i++) {
    $body = @{
        message = "Explain Kubernetes in one concise paragraph."
        max_tokens = 48
    } | ConvertTo-Json

    $headers = @{
        "Content-Type" = "application/json"
        "X-API-Key" = $ApiKey
    }

    $started = Get-Date
    try {
        $response = Invoke-RestMethod -Method Post -Uri "$Url/chat" -Headers $headers -Body $body
        $elapsed = ((Get-Date) - $started).TotalSeconds
        $completionTokens = [int]$response.usage.completion_tokens
        $tokensPerSecond = if ($elapsed -gt 0) { [math]::Round($completionTokens / $elapsed, 2) } else { 0 }
        $results += [pscustomobject]@{
            Run = $i
            Status = "OK"
            Seconds = [math]::Round($elapsed, 3)
            CompletionTokens = $completionTokens
            TotalTokens = [int]$response.usage.total_tokens
            CompletionTokensPerSecond = $tokensPerSecond
            Answer = ($response.answer.Substring(0, [Math]::Min(80, $response.answer.Length)))
        }
    } catch {
        $elapsed = ((Get-Date) - $started).TotalSeconds
        $results += [pscustomobject]@{
            Run = $i
            Status = "FAILED"
            Seconds = [math]::Round($elapsed, 3)
            CompletionTokens = 0
            TotalTokens = 0
            CompletionTokensPerSecond = 0
            Answer = $_.Exception.Message
        }
    }
}

$results | Format-Table -AutoSize
$ok = $results | Where-Object { $_.Status -eq "OK" }
if ($ok.Count -gt 0) {
    "Average latency seconds: {0}" -f ([math]::Round(($ok | Measure-Object Seconds -Average).Average, 3))
    "Average completion tokens/sec: {0}" -f ([math]::Round(($ok | Measure-Object CompletionTokensPerSecond -Average).Average, 2))
}
```

- [ ] **Step 3: Create failure demo script**

Create `scripts/aws-failure-demo.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-inference}"
LABEL_SELECTOR="${LABEL_SELECTOR:-app=ovms-llm,color=blue}"

echo "Current OVMS pods:"
kubectl -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" -o wide

POD_NAME="$(kubectl -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
echo "Deleting pod: $POD_NAME"
kubectl -n "$NAMESPACE" delete pod "$POD_NAME"

echo "Waiting for StatefulSet recovery:"
kubectl -n "$NAMESPACE" rollout status statefulset/ovms-blue --timeout=10m

echo "Recovered OVMS pods:"
kubectl -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" -o wide
```

- [ ] **Step 4: Run PowerShell syntax checks**

Run:

```powershell
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content scripts/aws-smoke-test.ps1 -Raw), [ref]$null)
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content scripts/aws-benchmark.ps1 -Raw), [ref]$null)
```

Expected: no parser errors are printed.

- [ ] **Step 5: Commit validation scripts**

```bash
git add scripts/aws-smoke-test.ps1 scripts/aws-benchmark.ps1 scripts/aws-failure-demo.sh
git commit -m "Add AWS POC validation scripts"
```

## Task 6: AWS Operator Runbook

**Files:**
- Create: `docs/aws-eks-openvino-llm-poc.md`
- Modify: `README.md`

- [ ] **Step 1: Create AWS runbook**

Create `docs/aws-eks-openvino-llm-poc.md`:

```markdown
# AWS EKS OpenVINO LLM POC

This runbook deploys the AWS version of the OpenVINO LLM inference POC.

## Architecture

Private user or service -> internal AWS ALB -> FastAPI gateway -> active OVMS service -> OpenVINO Model Server on Intel M7i EKS nodes.

Terraform owns AWS infrastructure. Argo CD owns Kubernetes application deployment.

## Prerequisites

- AWS account with permissions for EKS, EC2, IAM, ECR, S3, Secrets Manager, CloudWatch, and Elastic Load Balancing.
- AWS CLI configured.
- Terraform installed.
- kubectl installed.
- Docker installed for building the gateway image.
- A unique S3 bucket name for model artifacts.
- Private network path to the internal ALB through VPN, Direct Connect, SSM, or equivalent access.

## Deploy Infrastructure

```powershell
terraform -chdir=terraform/aws init
$MODEL_BUCKET = "openvino-llm-models-tusha-dev"
terraform -chdir=terraform/aws plan -var "model_bucket_name=$MODEL_BUCKET"
terraform -chdir=terraform/aws apply -var "model_bucket_name=$MODEL_BUCKET"
```

## Build And Push Gateway

Use the ECR repository URL from Terraform output:

```powershell
$AWS_REGION = "us-east-1"
$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)
$IMAGE = "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/openvino-llm-gateway:0.1.0"
docker build -t $IMAGE gateway
docker push $IMAGE
```

Update `k8s/aws/gateway.yaml` with the pushed image before Argo CD syncs it.

## Store Gateway API Key

Create the secret in AWS Secrets Manager:

```powershell
$GATEWAY_API_KEY = "dev-openvino-poc-key-change-before-shared-demo"
aws secretsmanager create-secret --name "/openvino-llm-poc/gateway/api-key" --secret-string $GATEWAY_API_KEY
```

## Upload Model Artifacts

Upload approved OpenVINO model artifacts to:

```text
s3://openvino-llm-models-tusha-dev/OpenVINO/Phi-3-mini-FastDraft-50M-int8-ov/
```

## Deploy Apps With Argo CD

Update `k8s/aws/argocd-application.yaml` with the real repository URL, then apply:

```powershell
kubectl apply -f k8s/aws/argocd-application.yaml
```

## Smoke Test

Use the internal ALB DNS name:

```powershell
$INTERNAL_ALB_URL = "http://internal-openvino-llm-poc.us-east-1.elb.amazonaws.com"
$GATEWAY_API_KEY = "dev-openvino-poc-key-change-before-shared-demo"
.\scripts\aws-smoke-test.ps1 -Url $INTERNAL_ALB_URL -ApiKey $GATEWAY_API_KEY
```

## Benchmark

```powershell
$INTERNAL_ALB_URL = "http://internal-openvino-llm-poc.us-east-1.elb.amazonaws.com"
$GATEWAY_API_KEY = "dev-openvino-poc-key-change-before-shared-demo"
.\scripts\aws-benchmark.ps1 -Url $INTERNAL_ALB_URL -ApiKey $GATEWAY_API_KEY -Runs 5
```

## Failure Demo

```bash
NAMESPACE=llm-inference LABEL_SELECTOR=app=ovms-llm,color=blue ./scripts/aws-failure-demo.sh
```
```

- [ ] **Step 2: Link AWS runbook from README**

Add this section to `README.md`:

```markdown
## AWS EKS Production-Shaped POC

The AWS version is documented in `docs/aws-eks-openvino-llm-poc.md`.

It uses EKS, Intel M7i CPU inference nodes, OpenVINO Model Server, an internal AWS ALB, Secrets Manager CSI integration, S3 model artifacts, EBS model caches, Argo CD, HPA, and blue-green OVMS rollout.
```

- [ ] **Step 3: Commit docs**

```bash
git add README.md docs/aws-eks-openvino-llm-poc.md
git commit -m "Document AWS EKS OpenVINO POC"
```

## Task 7: Final Verification

**Files:**
- Verify all files created above.

- [ ] **Step 1: Run gateway tests**

Run:

```powershell
cd gateway
python -m pytest tests/test_gateway.py -v
```

Expected: all gateway tests pass.

- [ ] **Step 2: Run Kubernetes manifest dry-run**

Run:

```powershell
kubectl apply --dry-run=client -f k8s/aws
```

Expected: Kubernetes client accepts core resources. If Argo CD CRDs are not installed locally, `argocd-application.yaml` may fail with `no matches for kind "Application"`; validate it in the target cluster after Argo CD is installed.

- [ ] **Step 3: Run Terraform formatting**

Run:

```powershell
terraform -chdir=terraform/aws fmt -check
```

Expected: no formatting changes required.

- [ ] **Step 4: Check git status**

Run:

```bash
git status --short
```

Expected: only unrelated pre-existing files remain unstaged.

- [ ] **Step 5: Final commit if verification changes files**

If verification changed tracked files, commit them:

```bash
git add gateway terraform/aws k8s/aws scripts docs README.md .gitignore
git commit -m "Verify AWS EKS OpenVINO POC implementation"
```
