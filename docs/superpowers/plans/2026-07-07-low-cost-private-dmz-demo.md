# Low-Cost Private DMZ Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the AWS EKS OpenVINO POC into a reliable low-cost private DMZ demo path.

**Architecture:** The EKS API remains private-only and deployment runs from an Intel DMZ VPN-connected laptop or runner. The default demo serves traffic through an internal ALB, FastAPI gateway, and one active blue OVMS pod; green remains present but scaled to zero.

**Tech Stack:** Terraform AWS provider, Helm provider, EKS, Kubernetes manifests, FastAPI, httpx, pytest, OpenVINO Model Server.

## Global Constraints

- EKS API remains private-only: `cluster_endpoint_private_access = true`, `cluster_endpoint_public_access = false`.
- EKS version is `1.36`.
- Default active inference capacity is `ovms-blue` `1` replica and `ovms-green` `0` replicas.
- Gateway exposes `/health` for liveness and `/ready` for readiness.
- Gateway readiness and ALB health check use `/ready`.
- Terraform installs `metrics-server`.
- Gateway HPA remains; OVMS HPA is removed from default manifests.
- `python -m pytest gateway/tests` must pass from the repository root.

---

### Task 1: Gateway Readiness And Test Hygiene

**Files:**
- Modify: `gateway/app/main.py`
- Modify: `gateway/tests/test_gateway.py`
- Create: `pyproject.toml`

**Interfaces:**
- Produces: `GET /ready` returns HTTP 200 when API key and OVMS config are available.
- Produces: `GET /ready` returns HTTP 503 when API key is missing or OVMS config check fails.
- Produces: `get_ovms_config_url() -> str` derives `/v1/config` from `OVMS_URL`.

- [ ] **Step 1: Add failing readiness tests**

Add tests for successful readiness, missing API key, and OVMS failure in `gateway/tests/test_gateway.py`.

- [ ] **Step 2: Run readiness tests and verify failure**

Run: `python -m pytest gateway/tests -q` from the repository root.
Expected before implementation: readiness tests fail because `/ready` does not exist.

- [ ] **Step 3: Implement readiness**

In `gateway/app/main.py`, add URL derivation, a `ReadinessResponse` model, and a `/ready` endpoint that checks API key availability and OVMS `/v1/config`.

- [ ] **Step 4: Add root pytest configuration**

Create `pyproject.toml` with pytest `pythonpath = ["gateway"]`.

- [ ] **Step 5: Verify tests**

Run: `python -m pytest gateway/tests -q` from the repository root.
Expected: all gateway tests pass.

### Task 2: Low-Cost Kubernetes Manifests

**Files:**
- Modify: `k8s/aws/gateway.yaml`
- Modify: `k8s/aws/gateway-ingress.yaml`
- Modify: `k8s/aws/ovms-blue.yaml`
- Modify: `k8s/aws/ovms-green.yaml`
- Modify: `k8s/aws/hpa.yaml`

**Interfaces:**
- Consumes: gateway `/ready` endpoint from Task 1.
- Produces: default manifests schedule one active blue OVMS pod and zero green pods.
- Produces: gateway readiness probe and ALB health check use `/ready`.

- [ ] **Step 1: Update readiness paths**

Set gateway readiness probe path and ALB healthcheck path to `/ready`.

- [ ] **Step 2: Resize OVMS**

Set `ovms-blue` replicas to `1` and `ovms-green` replicas to `0`.

- [ ] **Step 3: Remove OVMS HPA**

Keep only `llm-gateway-hpa` in `k8s/aws/hpa.yaml`.

- [ ] **Step 4: Validate YAML parse**

Run a Python YAML parse over `k8s/aws/*.yaml`.
Expected: all YAML files parse.

### Task 3: Terraform Demo Readiness

**Files:**
- Modify: `terraform/aws/main.tf`
- Modify: `terraform/aws/variables.tf`

**Interfaces:**
- Produces: EKS cluster version `1.36`.
- Produces: `metrics-server` Helm release installed into `kube-system`.

- [ ] **Step 1: Update EKS version**

Change `cluster_version` from `1.31` to `1.36`.

- [ ] **Step 2: Add metrics-server chart version variable**

Add `metrics_server_chart_version` with a pinned value.

- [ ] **Step 3: Add Helm release**

Add `helm_release.metrics_server` in `terraform/aws/main.tf`.

- [ ] **Step 4: Validate formatting if Terraform exists**

Run `terraform fmt -check -recursive` if the Terraform CLI is installed.
Expected: pass, or report that Terraform is unavailable.

### Task 4: README And Runbook Alignment

**Files:**
- Modify: `README.md`
- Modify: `docs/aws-eks-openvino-llm-poc.md`

**Interfaces:**
- Consumes: all implementation choices from Tasks 1-3.
- Produces: documentation that describes the low-cost private DMZ path.

- [ ] **Step 1: Update README**

Document private DMZ execution, low-cost blue-active/green-zero capacity, EKS `1.36`, `/ready`, metrics-server, and root test command.

- [ ] **Step 2: Update runbook**

Document that Terraform/kubectl must run from Intel DMZ VPN-connected environment and that green is scaled to zero by default.

- [ ] **Step 3: Check docs for stale claims**

Search for claims that both OVMS colors are live by default or that HPA applies to OVMS.

### Task 5: Final Verification And Commit

**Files:**
- All modified files.

**Interfaces:**
- Produces: verified branch ready for push.

- [ ] **Step 1: Run gateway tests**

Run: `python -m pytest gateway/tests -q`.

- [ ] **Step 2: Parse Kubernetes YAML**

Run YAML parse command over `k8s/aws/*.yaml`.

- [ ] **Step 3: Parse PowerShell scripts**

Run PowerShell parser over `scripts/*.ps1`.

- [ ] **Step 4: Run whitespace check**

Run: `git diff --check`.

- [ ] **Step 5: Commit**

Commit the implementation with message `Make AWS demo low-cost private DMZ ready`.
