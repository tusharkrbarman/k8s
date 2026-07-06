# AWS EKS OpenVINO LLM POC Design

Date: 2026-07-06

## Objective

Design a production-shaped proof of concept for serving an open-source LLM with Kubernetes on AWS while keeping the project aligned with Intel-style optimization work.

The POC uses AWS as the managed Kubernetes substrate and Intel M7i CPU instances as the inference hardware. It does not claim Intel GPU or NPU validation on AWS. Intel GPU validation remains a separate bare-metal or Intel-hosted hardware phase.

## Approved Direction

Use a private-only, production-shaped EKS platform:

```text
Private user/service
  -> VPN / Direct Connect / SSM access path
  -> internal AWS Application Load Balancer
  -> FastAPI gateway on EKS
  -> active OVMS service
  -> OpenVINO Model Server StatefulSet
  -> Intel M7i CPU inference nodes
```

This is the selected approach because it is credible enough for a production architecture discussion while still being buildable as a POC.

## Architecture Summary

Terraform owns AWS infrastructure and platform add-ons:

- VPC and private subnets across two Availability Zones
- EKS cluster with private worker nodes
- Two EKS managed node groups
- ECR repository for the gateway image
- S3 bucket for approved model artifacts
- IAM roles and policies for service accounts
- EBS CSI driver
- AWS Load Balancer Controller
- Secrets Store CSI Driver and AWS provider
- Argo CD
- CloudWatch logging/metrics integration
- VPC endpoints for core AWS services
- Limited NAT Gateway only when bootstrap requires it

Argo CD owns application deployment:

- FastAPI gateway Deployment and Service
- Internal ALB Ingress
- OVMS blue and green StatefulSets
- OVMS blue and green Services
- Gateway config pointing to the active OVMS service
- HPA resources
- PVC templates for model caches
- SecretProviderClass resources
- ConfigMaps for model and routing configuration

## Network Boundary

The POC is private-only. There is no public LLM endpoint.

```text
Trusted private access
  -> internal AWS ALB
  -> FastAPI gateway
  -> OVMS internal ClusterIP service
```

The internal ALB is created from a Kubernetes Ingress by the AWS Load Balancer Controller. It is deployed into private subnets and should only allow trusted private CIDRs/security groups.

OVMS is never exposed outside the cluster. The gateway is the only caller-facing API surface.

## Security

The first POC uses one gateway API key, while leaving room for multiple team keys later.

Secrets are handled through AWS Secrets Manager:

- The API key is stored in AWS Secrets Manager.
- The gateway reads it through Secrets Store CSI Driver with the AWS provider.
- The gateway service account gets least-privilege permission to read only the required secret.
- The secret is mounted into the gateway pod as a file.
- The secret value is not committed to Git and does not need to be stored as a normal Kubernetes Secret.

AWS permissions are scoped through service-account identity:

- Gateway service account can read the gateway API key.
- OVMS/init-container service account can read approved model artifacts from S3.
- Platform controllers get only the permissions required for their controllers.

Private networking is not treated as the entire security model. The gateway still authenticates callers, and backend model serving remains isolated behind ClusterIP services.

## Compute

Use two EKS managed node groups:

```text
system-gateway node group
  -> Argo CD
  -> AWS Load Balancer Controller
  -> Secrets Store CSI components
  -> FastAPI gateway replicas

m7i-inference node group
  -> OVMS StatefulSet
  -> OpenVINO CPU inference
  -> EBS-backed model cache PVCs
```

The inference node group uses M7i instances because they provide a balanced CPU/memory profile and are based on Intel Xeon processors. This is a safer first choice than compute-optimized or memory-optimized families before benchmark data exists.

The initial OVMS deployment runs two replicas, spread across two Availability Zones.

## Model Artifacts And Storage

S3 is the source of truth for approved model artifacts. EBS-backed PVCs provide runtime model cache storage.

```text
Approved OpenVINO model artifacts in S3
  -> init container syncs model to EBS PVC if missing or stale
  -> OVMS starts from local /models cache
  -> gateway calls OVMS through ClusterIP service
```

OVMS runs as a StatefulSet so each replica has stable cache identity. Each replica receives its own EBS-backed PVC mounted at `/models`.

The first model should be a small reliable OpenVINO-compatible LLM. Larger production-like models are a later phase after memory, startup, latency, and throughput are measured.

## Application Gateway

The FastAPI gateway remains the external contract for clients. It should:

- Validate the API key from the request.
- Hide raw OVMS endpoints from callers.
- Route requests to the active OVMS service.
- Return model response, latency, and usage data.
- Log request metadata needed for debugging and benchmarking.

For AWS mode, the gateway should be able to read the API key from a mounted file supplied by Secrets Store CSI Driver. The existing environment-variable path can remain useful for local and bare-metal POCs.

## Deployment And GitOps

Terraform provisions infrastructure and installs platform add-ons. Argo CD reconciles the application layer from Git.

The desired state for app workloads should live in Git and be reconciled by Argo CD. Direct `kubectl` access can still be used for debugging, but normal changes should flow through Git.

This gives the POC a clear operating model:

```text
Terraform
  -> AWS infrastructure and platform add-ons

Argo CD
  -> Kubernetes app manifests

Git history
  -> audit trail for application changes
```

## Scaling

Initial scaling strategy:

- Gateway runs with at least two replicas.
- OVMS runs with two replicas, one per AZ.
- HPA is enabled for gateway and OVMS.
- Node count is fixed for the first POC.

Karpenter or Cluster Autoscaler is documented as a later phase. The first POC should avoid node autoscaling until there is load-test data to justify replica and node sizing.

## Blue-Green Model Rollout

Model rollout uses blue-green serving:

```text
ovms-blue
  -> current active model version

ovms-green
  -> next model version
  -> smoke tested privately
  -> gateway config changes OVMS_URL to green
  -> Argo CD syncs promotion
```

The gateway owns the active service switch by changing which internal OVMS service it calls. This is simpler than canary routing and easier to roll back during the POC.

## Failure Demo

The POC should include a controlled failure demo:

- Delete one OVMS pod and show traffic continues through the remaining replica.
- Optionally drain one inference node and observe recovery.
- Use readiness probes, liveness probes, ALB health checks, and PodDisruptionBudgets.
- Capture before/after request success, latency, pod restarts, and HPA state.

This proves the endpoint survives a realistic failure instead of only proving that manifests apply successfully.

## Observability

The POC should measure inference behavior, not just Kubernetes health.

Minimum metrics/logs:

- Gateway request count
- Gateway status code counts
- Gateway latency per request
- OVMS response latency
- Prompt tokens, completion tokens, total tokens
- Completion tokens per second from benchmark scripts
- Pod CPU and memory
- Pod restarts
- HPA decisions/events
- Model cache sync status
- Cold-start versus warm-cache startup time
- ALB target health

CloudWatch is the default AWS logging/metrics destination for the POC. A richer dashboard stack can be added later.

## Success Criteria

The POC is successful when:

1. The private endpoint responds through the internal ALB.
2. The gateway rejects missing or invalid API keys.
3. The gateway successfully calls the active OVMS service.
4. OVMS loads approved model artifacts from the S3/EBS cache path.
5. Two OVMS replicas run across two AZs.
6. Repeated smoke tests succeed.
7. Benchmark output reports latency and tokens/sec.
8. Deleting one OVMS pod does not take the endpoint fully down.
9. Blue-green promotion can switch the gateway from blue to green.
10. Logs and metrics explain latency, failures, and pod behavior.

## Out Of Scope For Initial AWS POC

- Intel GPU/NPU inference on AWS
- Public internet exposure of the LLM endpoint
- Full OIDC/SSO caller identity
- Service mesh traffic splitting
- Canary rollout percentages
- Karpenter or Cluster Autoscaler
- Full SLO/alerting/incident-management stack
- Large model production capacity claims before benchmarking

## Research References

- Amazon EKS managed node groups: https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html
- Amazon EKS private endpoint access: https://docs.aws.amazon.com/eks/latest/userguide/config-cluster-endpoint.html
- AWS Load Balancer Controller: https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html
- Amazon EKS pricing: https://aws.amazon.com/eks/pricing/
- AWS Secrets Manager CSI integration: https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html
- EKS IAM roles for service accounts: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- Amazon EC2 M7i instances: https://aws.amazon.com/ec2/instance-types/m7i/
- Amazon EC2 C7i instances: https://aws.amazon.com/ec2/instance-types/c7i/
- Amazon EC2 R7i instances: https://aws.amazon.com/ec2/instance-types/r7i/
