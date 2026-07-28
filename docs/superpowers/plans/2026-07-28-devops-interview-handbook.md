# DevOps Interview Handbook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a detailed, evidence-backed DevOps interview handbook for the complete OpenVINO Kubernetes project journey.

**Architecture:** Create one self-contained Markdown handbook organized around the progression from local model serving to Kubernetes and private AWS EKS. Derive current architecture claims from repository files, identify historical local/k3s observations as project-history results, and add interview pitches, questions, trade-offs, and claim boundaries without presenting unverified AWS runtime behavior as validated.

**Tech Stack:** Markdown, Mermaid, Docker, Kubernetes, Minikube, k3s, Amazon EKS, Terraform, OpenVINO Model Server, FastAPI, AWS ALB, ECR, S3, EBS, Secrets Manager, Argo CD.

## Global Constraints

- Create exactly one final handbook at `docs/openvino-eks-devops-interview-handbook.md`.
- Optimize the handbook for DevOps and platform-engineering interviews.
- Cover Docker, Minikube, k3s, and AWS EKS stages.
- Attribute `2.469` seconds average latency and `16.69` completion tokens per second only to the local benchmark.
- State that the AWS implementation uses Intel M7i CPU instances and OpenVINO CPU inference.
- Do not claim Intel GPU or NPU validation.
- Do not include account-plan, promotional-credit, or account-specific EC2 launch details.
- Do not claim live AWS inference performance or completed production validation.
- Clearly distinguish validated experiments, repository implementation, and work requiring live AWS validation.
- Explain acronyms on first use and keep commands limited to useful examples.
- Do not modify application, Terraform, Kubernetes, gateway, or script files.

---

### Task 1: Build The Evidence-Backed Technical Handbook

**Files:**
- Create: `docs/openvino-eks-devops-interview-handbook.md`
- Read: `README.md`
- Read: `docs/aws-eks-openvino-llm-poc.md`
- Read: `docs/superpowers/specs/2026-07-06-aws-eks-openvino-llm-poc-design.md`
- Read: `docs/superpowers/specs/2026-07-07-low-cost-private-dmz-demo-design.md`
- Read: `terraform/aws/main.tf`
- Read: `terraform/aws/variables.tf`
- Read: `k8s/aws/*.yaml`
- Read: `gateway/app/main.py`
- Read: `gateway/tests/test_gateway.py`
- Read: `scripts/*`

**Interfaces:**
- Consumes: Repository configuration and confirmed project-history results.
- Produces: A factual technical narrative that the interview-preparation sections can summarize and reference.

- [ ] **Step 1: Create the handbook structure**

Create these exact top-level sections:

```markdown
# OpenVINO on Kubernetes: DevOps Interview Handbook

## How To Use This Handbook
## Interview-Ready Project Summary
## Problem And Engineering Goals
## Implementation Journey
## Final AWS EKS Architecture
## End-To-End System Flows
## Component Deep Dives
## AWS Networking Deep Dive
## IAM And Security Model
## Kubernetes Concepts Demonstrated
## Reliability, Scaling, And Deployment Strategy
## Troubleshooting Case Studies
## Validation And Current Scope
## Interview Questions And Answers
## STAR Stories
## Trade-Offs And Production Next Steps
## Strict Claim Boundaries
## Final Revision Checklist
```

- [ ] **Step 2: Write the implementation journey**

Document these stages and the evidence each produced:

```text
Windows Docker -> OVMS model available through /v1/config -> chat completion
Minikube -> Kubernetes Deployment/Service -> tunnel/NodePort access -> benchmark
Ubuntu VMs with k3s -> one server and one worker -> NodePort 30080
AWS design -> private EKS, managed nodes, internal ALB, S3/EBS, IAM, GitOps
```

Include the local benchmark table:

```text
Run 1: 5.023 seconds, 6.97 completion tokens/second
Runs 2-5: approximately 1.8 seconds, approximately 19 completion tokens/second
Average latency: 2.469 seconds
Average completion throughput: 16.69 completion tokens/second
```

Explain that the slower first request indicates model/runtime warm-up.

- [ ] **Step 3: Add the final architecture diagram and flows**

The Mermaid diagram must contain:

```text
Intel DMZ/VPN-connected client
Internal AWS ALB
Kubernetes Ingress
FastAPI gateway Deployment and ClusterIP Service
Secrets Store CSI Driver and AWS Secrets Manager
Blue and green OVMS StatefulSets and ClusterIP Services
S3 model artifacts
EBS model-cache PVCs
ECR gateway image
Private EKS cluster and managed M7i node groups
Argo CD and Git repository
Metrics Server, HPA, probes, and PDB
```

Write separate request, model-loading, secret, deployment, and recovery flows.

- [ ] **Step 4: Explain repository components and Kubernetes concepts**

Tie every explanation to a concrete file or resource:

```text
gateway/app/main.py -> authentication, /health, /ready, OVMS forwarding
k8s/aws/gateway.yaml -> Deployment, Service, probes, secret mount, node selector
k8s/aws/ovms-blue.yaml -> active StatefulSet, one replica, EBS cache
k8s/aws/ovms-green.yaml -> standby StatefulSet, zero replicas
k8s/aws/gateway-ingress.yaml -> internal ALB routing and /ready health check
k8s/aws/gateway-config.yaml -> active blue/green target
k8s/aws/hpa.yaml -> gateway horizontal scaling
k8s/aws/pdb.yaml -> voluntary-disruption protection
terraform/aws/main.tf -> VPC, EKS, IAM, AWS storage, endpoints, and controllers
```

Explain why gateway pods use `nodepool=system-gateway` and OVMS uses
`nodepool=m7i-inference`.

- [ ] **Step 5: Explain AWS networking and IAM**

Cover these exact distinctions:

```text
Route tables attach to subnets.
Gateway endpoints add service routes and are used for S3.
Interface endpoints create ENIs with private IPs, private DNS, and security groups.
NAT provides outbound access for destinations without private endpoints.
The EKS API and application ALB are separate private entry points.
The cluster IAM role, node IAM role, controller roles, and workload IRSA roles have separate trust boundaries.
```

- [ ] **Step 6: Check the technical sections**

Run:

```powershell
rg -n "^## " docs/openvino-eks-devops-interview-handbook.md
rg -n "2\\.469|16\\.69|m7i|target_device|NodePort|30080|interface endpoint|gateway endpoint|IRSA" docs/openvino-eks-devops-interview-handbook.md
```

Expected: all required headings and technical facts are present.

- [ ] **Step 7: Commit the technical handbook**

```powershell
git add docs/openvino-eks-devops-interview-handbook.md
git commit -m "Add OpenVINO EKS technical interview handbook"
```

### Task 2: Add Interview Packaging And Verify Claim Boundaries

**Files:**
- Modify: `docs/openvino-eks-devops-interview-handbook.md`
- Read: `docs/superpowers/specs/2026-07-28-devops-interview-handbook-design.md`

**Interfaces:**
- Consumes: The factual technical narrative from Task 1.
- Produces: A polished handbook suitable for interview revision and deep technical follow-up.

- [ ] **Step 1: Add concise interview pitches**

Include:

```text
One-sentence summary
30-second pitch
Two-minute explanation
Three resume bullets
End-user explanation
```

The pitch must describe a private Kubernetes inference platform, OpenVINO Model
Server, a FastAPI policy gateway, private AWS networking, GitOps, health
checks, persistent model caching, and blue-green rollout.

- [ ] **Step 2: Add likely questions and direct answers**

Answer at least these questions:

```text
Why Kubernetes?
Why OpenVINO instead of Ollama?
Why OVMS?
Why use a gateway?
Why StatefulSet for OVMS?
Why ClusterIP internally?
Why Ingress and an internal ALB?
Why S3 plus EBS?
Why gateway and interface VPC endpoints?
Why separate IAM roles?
How does Kubernetes recover from failure?
How would this move to Intel GPU hardware?
What are the main production gaps?
```

- [ ] **Step 3: Add troubleshooting and STAR stories**

For each incident, use:

```text
Symptom -> evidence -> root cause -> minimal correction -> lesson
```

Include `ImagePullBackOff`, `OOMKilled`, BRGEMM/CPU compatibility, empty Service
endpoints, and Minikube tunnel URL mismatch. Build three STAR stories around
container image troubleshooting, resource/CPU troubleshooting, and private
platform architecture evolution.

- [ ] **Step 4: Add trade-offs and strict claim boundaries**

State:

```text
Validated: local Docker, Minikube, k3s, local benchmark behavior.
Implemented: AWS Terraform, Kubernetes manifests, gateway, scripts, GitOps definitions.
Requires live validation: ALB provisioning, IRSA, CSI mounts, EBS behavior, S3 sync, HPA, and AWS performance.
Do not claim: production deployment, AWS benchmark results, Intel GPU/NPU validation, automatic OVMS autoscaling, or zero-cost operation.
```

- [ ] **Step 5: Run documentation verification**

Run:

```powershell
rg -ni "free plan|free tier|promotional credit|166|ec2 rejected|not yet running" docs/openvino-eks-devops-interview-handbook.md
rg -ni "gpu.*validated|npu.*validated|aws benchmark.*completed|production deployed" docs/openvino-eks-devops-interview-handbook.md
rg -n "REPLACE_WITH|T[B]D|T[O]DO" docs/openvino-eks-devops-interview-handbook.md
git diff --check
```

Expected:

```text
The first three searches return no matches.
git diff --check returns no output.
```

Manually verify that every local file link points to a path returned by
`rg --files`.

- [ ] **Step 6: Commit the completed handbook**

```powershell
git add docs/openvino-eks-devops-interview-handbook.md
git commit -m "Complete DevOps interview preparation guide"
```
