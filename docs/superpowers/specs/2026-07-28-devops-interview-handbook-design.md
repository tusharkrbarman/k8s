# DevOps Interview Handbook Design

## Purpose

Create one detailed Markdown handbook that helps explain and defend the
OpenVINO LLM inference project in a DevOps or platform-engineering interview.
The handbook must teach the implementation, provide concise interview answers,
and distinguish validated work from architecture that is implemented but not
yet performance-tested on AWS.

## Audience

The primary audience is the project author preparing for DevOps and platform
engineering interviews. The expected interviewer may ask about Kubernetes,
AWS networking, IAM, availability, deployment automation, troubleshooting,
observability, cost, or model-serving infrastructure.

## Output

Write the final handbook to:

`docs/openvino-eks-devops-interview-handbook.md`

The handbook will be self-contained but will link to relevant repository files
for deeper inspection.

## Scope

The handbook covers the complete project journey:

1. OpenVINO Model Server validation in Docker on Windows.
2. Local Kubernetes deployment with Minikube.
3. A lightweight two-node k3s cluster on Ubuntu VMs as a bare-metal simulation.
4. Evolution into a private, AWS-based EKS architecture.
5. The Terraform, Kubernetes, FastAPI gateway, GitOps, security, storage,
   networking, health-check, scaling, and blue-green implementation currently
   present in the repository.
6. Troubleshooting lessons from the local and k3s phases.
7. Interview pitches, technical questions, trade-offs, STAR stories, and
   explicit claim boundaries.

## Factual Boundaries

The handbook must:

- State that Docker, Minikube, and k3s experiments were hands-on validation.
- State that the AWS architecture and deployment code are implemented.
- Avoid claiming live AWS inference performance or completed production
  validation.
- Omit the account-specific AWS Free Plan node-launch incident.
- Avoid claiming Intel GPU or NPU validation; the current AWS implementation
  uses Intel M7i CPU instances and OpenVINO CPU inference.
- Identify benchmark results as local results rather than AWS results.
- Avoid inventing resource identifiers, account details, IP addresses, costs,
  or test results that are not supported by the project history.

## Structure

### 1. Interview-Ready Summary

- One-sentence project description.
- A 30-second pitch.
- A two-minute explanation.
- Resume-ready bullets.
- A concise explanation of the end user's role.

### 2. Problem And Design Goals

- Why Kubernetes is useful for model serving.
- Why OpenVINO and OVMS are used.
- Why a gateway is placed in front of OVMS.
- Requirements for private access, repeatability, resilience, security, and
  controlled cost.

### 3. Implementation Journey

- Docker model-serving baseline.
- Minikube Kubernetes baseline.
- Two-node k3s VM cluster.
- Production-shaped AWS EKS design.
- What each stage proved and why the next stage was necessary.

### 4. Final Architecture

- A Mermaid architecture diagram with non-overlapping labels.
- Request flow.
- Model artifact and cache flow.
- Deployment and GitOps flow.
- Secret retrieval flow.
- Health and recovery flow.

### 5. Component Deep Dives

- VPC and EKS.
- Managed node groups and scheduling labels.
- FastAPI gateway.
- OpenVINO Model Server and OpenVINO runtime.
- Internal ALB, Ingress, and ClusterIP Services.
- S3 model storage and EBS pod cache.
- ECR.
- Secrets Manager and Secrets Store CSI.
- Terraform and Argo CD.
- Metrics Server, HPA, PDB, probes, and StatefulSets.

### 6. AWS Networking And Security

- Availability Zones and subnet layout.
- Public and private subnet roles.
- Route tables, NAT Gateway, and local routes.
- Gateway versus interface VPC endpoints.
- Endpoint ENIs, private DNS, and endpoint security groups.
- Private EKS API access from an Intel DMZ/VPN-connected environment.
- Cluster, node, controller, and workload IAM role boundaries.
- IRSA and least-privilege access for S3 and Secrets Manager.

### 7. Kubernetes Concepts Demonstrated

- Pods, Deployments, StatefulSets, Services, Ingress, ConfigMaps, service
  accounts, PVCs, probes, requests and limits, HPA, PDB, labels, scheduling,
  namespaces, and blue-green rollout.
- Explain what each concept does specifically in this project.

### 8. Troubleshooting Case Studies

- Empty OVMS configuration before model availability.
- Invalid OVMS image tag causing `ImagePullBackOff`.
- Model pod termination caused by memory pressure.
- CPU instruction and BRGEMM compatibility troubleshooting in nested
  virtualization.
- NodePort and Minikube tunnel URL mismatch.
- Benchmark-driven stability observations.
- Root-cause method: inspect status, events, logs, endpoints, and resource
  constraints before changing configuration.

The account-specific AWS Free Plan incident is intentionally excluded.

### 9. Current Implementation Status

Use a matrix with these categories:

- Validated locally.
- Validated on k3s.
- Implemented in repository.
- Requires live AWS validation.

This section must be factual and avoid presenting planned or unverified work as
completed production behavior.

### 10. Interview Preparation

- Short and deep answers to likely questions.
- Architecture trade-offs and alternatives.
- Strict claims that should not be made.
- STAR-format troubleshooting stories.
- Production-readiness gaps and next steps.
- A final revision checklist.

## Source Material

The handbook should use:

- `README.md`
- `docs/aws-eks-openvino-llm-poc.md`
- `docs/superpowers/specs/2026-07-06-aws-eks-openvino-llm-poc-design.md`
- `docs/superpowers/specs/2026-07-07-low-cost-private-dmz-demo-design.md`
- `terraform/aws`
- `k8s/aws`
- `gateway/app/main.py`
- `gateway/tests/test_gateway.py`
- `scripts`
- Confirmed experiment results and errors from the project history.

## Known Results To Include

- The local benchmark completed five successful requests.
- Average latency was `2.469` seconds.
- Average completion throughput was `16.69` completion tokens per second.
- The first request was slower than subsequent requests, demonstrating
  cold-start or warm-up behavior.
- The two-node k3s setup used one server/control-plane VM and one worker VM.
- The k3s service used NodePort `30080` during the VM proof of concept.

## Style

- Detailed but interview-oriented rather than a raw transcript.
- Explain every acronym on first use.
- Use tables where they improve comparison.
- Use concise diagrams and flows.
- Include commands only when they illustrate a concept or troubleshooting
  method.
- Prefer direct language and explicit trade-offs.
- Separate facts, design choices, and future work.

## Acceptance Criteria

- The full journey is covered without relying on deleted legacy files.
- The final AWS architecture matches the current repository.
- The benchmark numbers are attributed to the local environment.
- Account-specific Free Plan details are absent.
- AWS GPU or NPU validation is not claimed.
- The current CPU requests and node sizing are explained accurately.
- The difference between validated, implemented, and pending work is visible.
- The document contains interview pitches, questions, answers, STAR stories,
  and a strict claim-boundary section.
- Repository links and filenames are correct.
- There are no placeholders, contradictions, or unsupported claims.
