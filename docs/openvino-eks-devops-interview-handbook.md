# OpenVINO on Kubernetes: DevOps Interview Handbook

## How To Use This Handbook

This handbook prepares you to explain the project as a DevOps and platform
engineering exercise. It covers the progression from a single Docker
container to local Kubernetes, a two-node k3s cluster, and a production-shaped
private Amazon Elastic Kubernetes Service (EKS) design.

Use it in three passes:

1. Learn the project summary and two-minute explanation.
2. Study the architecture, networking, identity, storage, and reliability
   sections.
3. Rehearse the troubleshooting cases, interview questions, and strict claim
   boundaries.

The current repository is the source of truth for the AWS design. Earlier
Docker, Minikube, and k3s experiments are recorded as project-history
validation because their old manifests are no longer kept on this branch.

## Interview-Ready Project Summary

### One-Sentence Summary

I designed a private Kubernetes platform for serving an open-source language
model through OpenVINO Model Server, starting with local validation and
evolving it into a production-shaped AWS EKS architecture with private
networking, workload identity, persistent model caching, health checks,
GitOps, and blue-green model rollout.

### Thirty-Second Pitch

The project serves an OpenVINO-optimized open-source language model behind a
small FastAPI gateway. I first validated OpenVINO Model Server in Docker, moved
it to Minikube, and then built a two-node k3s cluster on lightweight Ubuntu
VMs to learn scheduling, Services, storage, resource limits, and failure
diagnosis. The AWS target implementation uses a private EKS cluster, internal
Application Load Balancer, private subnets, EKS Pod Identity,
S3 model storage, EBS model caches, Secrets Manager, and Argo CD. Kubernetes
manages health, placement, restarts, gateway scaling, and blue-green model
deployment.

### Two-Minute Explanation

The system has two application layers. The FastAPI gateway is the policy and
API layer: it validates an `X-API-Key`, validates the request body, checks
whether OpenVINO Model Server is ready, forwards the request, and returns a
small stable response. OpenVINO Model Server, or OVMS, is the inference layer:
it loads an OpenVINO-optimized model and exposes an OpenAI-compatible chat
completion endpoint.

On AWS, private users enter through one internal Application Load Balancer
created from a Kubernetes Ingress. The load balancer sends traffic to the
gateway's ClusterIP Service, and the gateway forwards valid requests to the
active OVMS ClusterIP Service. Model artifacts are stored in S3. An init
container copies them into an EBS-backed persistent volume before OVMS starts.
The API key stays in AWS Secrets Manager and is mounted into the gateway pod by
the Secrets Store CSI Driver.

The target cluster is private-only. Worker nodes run in private subnets, the
EKS API is intended to be private, and AWS service traffic can use VPC
endpoints. During the AWS learning exercise, public and private EKS API access
were temporarily enabled to make laptop administration possible; the
application ALB remained internal. The Terraform implementation defines the
VPC, EKS, node group, IAM, ECR, S3, Secrets Manager metadata, controllers, and
add-ons. Argo CD is the planned application reconciler. Blue is active with
one OVMS replica; green is defined but scaled to zero until a controlled
promotion.

The strongest part of the project is the progression and troubleshooting. I
diagnosed invalid image tags, model initialization timing, memory pressure,
CPU instruction behavior under nested virtualization, empty Service
endpoints, and dynamic Minikube tunnel URLs by inspecting events, logs,
readiness, endpoint objects, and resource state rather than repeatedly changing
configuration.

### Resume-Ready Bullets

- Designed a private AWS EKS architecture for OpenVINO LLM inference using an
  internal ALB, private subnets, VPC endpoints, IAM roles for service accounts,
  S3 model storage, EBS caches, Secrets Manager, and Argo CD.
- Built and tested an inference path from Docker to Minikube and a two-node k3s
  VM cluster, diagnosing image, storage, memory, networking, and CPU
  compatibility failures.
- Implemented a FastAPI gateway with API-key authentication, input validation,
  separate liveness and readiness checks, OVMS request forwarding, and latency
  and token-usage logging.

### What The End User Does

The end user does not operate Kubernetes or OpenVINO. An internal application,
developer, or employee sends a prompt to the private gateway:

```text
POST /chat
X-API-Key: <approved key>

{
  "message": "Explain Kubernetes in simple terms",
  "max_tokens": 64
}
```

The user receives the generated answer, model name, latency, and token usage.
Kubernetes, OVMS, storage synchronization, health checks, and recovery remain
platform responsibilities.

## Problem And Engineering Goals

### Problem

Running a model in one container is enough for a demonstration, but it does not
answer platform questions:

- How is the model exposed safely?
- How are failed processes restarted?
- How are model files persisted and distributed?
- How are secrets kept outside images and YAML?
- How is traffic moved between model versions?
- How is the service deployed repeatedly?
- How can the design remain private inside a corporate network?

The project turns model inference into an operable service rather than a
single-machine experiment.

### Goals

- Serve an open-source model through a stable HTTP API.
- Use OpenVINO for optimized Intel CPU inference.
- Separate API policy from the inference server.
- Keep the EKS API and application endpoint private.
- Store model artifacts and secrets in managed AWS services.
- Use Kubernetes-native health, scheduling, storage, and disruption controls.
- Make infrastructure and application deployment reproducible.
- Preserve a path from a small POC to a larger production model.

### Non-Goals

- Training or fine-tuning a model.
- Building a consumer chat user interface.
- Claiming Intel GPU or NPU validation.
- Presenting gateway HPA as automatic inference scaling.
- Treating the POC as a completed multi-region production platform.

## Implementation Journey

### Stage 1: OVMS In Docker On Windows

The first goal was to prove the inference server independently of Kubernetes.
OpenVINO Model Server started in Docker and exposed its REST port on
`localhost:8000`.

At first, `GET /v1/config` returned:

```json
{}
```

That did not mean the HTTP server was broken. OVMS was still downloading and
initializing the model. The logs showed Git Large File Storage downloading a
multi-gigabyte `openvino_model.bin`. Calling the chat route too early produced
a MediaPipe graph-not-found error because the model graph was not ready.

The correct readiness evidence was:

```json
{
  "OpenVINO/Phi-3.5-mini-instruct-int4-ov": {
    "model_version_status": [
      {
        "version": "1",
        "state": "AVAILABLE",
        "status": {
          "error_code": "OK",
          "error_message": "OK"
        }
      }
    ]
  }
}
```

After the model became `AVAILABLE`, chat completion returned a valid response
with prompt, completion, and total token counts. This stage proved:

- The container image could run on the laptop CPU.
- OVMS could download and load an OpenVINO model.
- The REST configuration and chat endpoints worked.
- Readiness had to mean model availability, not merely an open TCP port.

### Stage 2: Minikube On The Laptop

The same serving workload was moved into Minikube to learn Kubernetes without
the cost and complexity of multiple machines.

The main resources were:

- A Deployment for OVMS.
- A Service for stable access.
- Resource requests and limits.
- Health probes against `/v1/config`.
- A local model cache.

Important lessons:

- An invalid image tag, `openvino/model_server:2025.4-py`, caused
  `ErrImagePull` and `ImagePullBackOff`. Kubernetes events showed that the
  image manifest did not exist.
- A running pod was not enough. The Service needed a ready endpoint before it
  could route traffic.
- With Minikube's Docker driver on Windows, `minikube service --url` created a
  temporary tunnel and returned a dynamic localhost port. The tunnel terminal
  had to stay open.
- Reusing an older tunnel URL caused connection failures even though the pod
  was healthy.

The successful local benchmark ran five requests:

| Run | Status | Latency | Completion tokens | Completion tokens/sec |
| --- | --- | ---: | ---: | ---: |
| 1 | OK | 5.023 s | 35 | 6.97 |
| 2 | OK | 1.826 s | 35 | 19.17 |
| 3 | OK | 1.817 s | 35 | 19.26 |
| 4 | OK | 1.848 s | 35 | 18.94 |
| 5 | OK | 1.832 s | 35 | 19.10 |
| **Average** |  | **2.469 s** |  | **16.69** |

These are local results, not AWS results. The slower first request indicates a
cold-start or runtime warm-up effect. Subsequent requests were consistently
around 1.8 seconds.

### Stage 3: Two-Node k3s Cluster On Ubuntu VMs

The next stage simulated separate bare-metal machines using two lightweight
Ubuntu Server VMs:

```text
k3s server/control-plane VM
            |
            | Kubernetes cluster network
            v
k3s worker VM -> OVMS pod
```

The VMs used private RFC 1918 addresses in the `192.168.88.0/24` range. SSH
access had to be installed and enabled before remote administration worked.
The worker joined the k3s server using the k3s token and server address.

The OVMS workload used:

- A node label to place inference on the worker.
- A PersistentVolumeClaim for the model cache.
- A NodePort Service exposing port `30080`.
- Startup and readiness probes.

The request path was:

```text
Client -> worker private IP:30080 -> NodePort Service
       -> ready OVMS pod:8000 -> OpenVINO model
```

This stage exposed hardware and capacity problems that Minikube hid:

- The larger model was killed by the Linux out-of-memory mechanism.
- Kubernetes removed the pod from Service endpoints while it was unready.
- Reducing a PersistentVolumeClaim request below its already-provisioned
  capacity was rejected; PVC storage requests cannot be shrunk that way.
- The smaller
  `OpenVINO/Phi-3-mini-FastDraft-50M-int8-ov` model reached `AVAILABLE`.
- Inference triggered a oneDNN BRGEMM initialization failure under the virtual
  CPU. Constraining oneDNN to the AVX2 instruction set made the virtualized CPU
  behavior explicit:

  ```text
  ONEDNN_MAX_CPU_ISA=AVX2
  DNNL_MAX_CPU_ISA=AVX2
  ```

The k3s experiment proved cluster creation, worker scheduling, NodePort
exposure, persistent storage, probes, and model availability. It also showed
that a benchmark is a capacity test: a service that is ready at idle may still
fail under generation load.

### Stage 4: Production-Shaped Private AWS EKS Design

The final design replaced the manually managed control plane with Amazon EKS
and mapped the lessons into managed AWS services:

| Earlier concern | AWS design response |
| --- | --- |
| VM-based control plane | Managed EKS control plane |
| Direct NodePort access | Internal ALB through Kubernetes Ingress |
| Local model download/cache | S3 source plus per-pod EBS cache |
| Plain environment secret | Secrets Manager plus Secrets Store CSI |
| Manual deployment | Terraform bootstrap plus Argo CD sync |
| One mixed node pool | Separate platform and inference node groups |
| Manual model replacement | Blue-green OVMS Services and StatefulSets |
| Ad hoc health checks | `/health`, `/ready`, startup, readiness, and liveness probes |

The repository and the console-learning deployment use `ap-south-1`. Region
names change resource endpoints and pricing, but not the architecture.

## Final AWS EKS Architecture

```mermaid
flowchart TB
    Client["Intel DMZ/VPN-connected client"]
    ALB["Internal AWS ALB<br/>private DNS endpoint"]
    Ingress["Kubernetes Ingress<br/>AWS Load Balancer Controller"]
    GatewayService["llm-gateway-service<br/>ClusterIP"]
    GatewayPods["FastAPI gateway Deployment<br/>1 demo replica"]
    GatewayConfig["ConfigMap<br/>active OVMS URL and model"]
    SecretCSI["Secrets Store CSI Driver<br/>AWS provider"]
    Secrets["AWS Secrets Manager<br/>gateway API key"]

    BlueService["ovms-blue-service<br/>ClusterIP"]
    BlueOVMS["OVMS blue StatefulSet<br/>1 active replica"]
    GreenService["ovms-green-service<br/>ClusterIP"]
    GreenOVMS["OVMS green StatefulSet<br/>0 standby replicas"]

    S3["Amazon S3<br/>versioned model artifacts"]
    EBS["Amazon EBS PVC<br/>20 GiB model cache per pod"]
    ECR["Amazon ECR<br/>gateway image"]

    EKS["Private Amazon EKS cluster<br/>private API endpoint"]
    SystemNodes["Optional platform node group<br/>production-shaped target"]
    InferenceNodes["m7i-inference node group<br/>one demo worker"]

    Git["Git repository<br/>k8s/aws manifests"]
    Argo["Argo CD<br/>GitOps reconciliation"]
    Metrics["Metrics Server<br/>gateway HPA metrics"]
    Health["Probes and PDBs<br/>availability controls"]

    Client --> ALB
    ALB --> Ingress
    Ingress --> GatewayService
    GatewayService --> GatewayPods
    GatewayPods --> GatewayConfig
    GatewayConfig --> BlueService
    GatewayConfig -. "promotion target" .-> GreenService
    BlueService --> BlueOVMS
    GreenService --> GreenOVMS

    GatewayPods --> SecretCSI
    SecretCSI --> Secrets
    GatewayPods -. "image pull" .-> ECR
    BlueOVMS --> EBS
    GreenOVMS --> EBS
    S3 --> BlueOVMS
    S3 --> GreenOVMS

    EKS --> SystemNodes
    EKS --> InferenceNodes
    GatewayPods -. "scheduled on" .-> SystemNodes
    BlueOVMS -. "scheduled on" .-> InferenceNodes
    GreenOVMS -. "scheduled on" .-> InferenceNodes

    Git --> Argo
    Argo --> EKS
    Metrics --> GatewayPods
    Health --> GatewayPods
    Health --> BlueOVMS
```

### Why This Is Production-Shaped

It includes common production platform boundaries:

- Private control-plane and application access.
- Separate compute pools for platform and inference workloads.
- Least-privilege workload identities.
- Managed artifact, secret, and block storage.
- Health-based traffic admission.
- Declarative infrastructure and application configuration.
- Horizontal scaling for the stateless API layer.
- Controlled model-version promotion.

It is still a POC because production readiness also requires sustained load
testing, explicit service-level objectives, complete telemetry, backup and
restore testing, certificate/TLS design, policy enforcement, image promotion,
and verified failure behavior in AWS.

## End-To-End System Flows

### User Request Flow

```text
1. Private client resolves the internal ALB DNS name.
2. Client sends POST /chat with X-API-Key.
3. ALB sends traffic to the Ingress target group.
4. Ingress routes to llm-gateway-service.
5. Service selects a ready gateway pod.
6. Gateway validates API key and request limits.
7. Gateway calls the active OVMS ClusterIP Service.
8. OVMS generates tokens using the OpenVINO CPU runtime.
9. Gateway returns answer, model, latency, and token usage.
```

The end user never addresses the OVMS Service directly.

### Model Loading Flow

```text
1. An approved OpenVINO model is uploaded to an S3 prefix.
2. Kubernetes creates the OVMS pod and its 20 GiB EBS-backed PVC.
3. The sync-model init container runs before the OVMS container.
4. The init container uses the ovms-model-reader service account.
5. EKS Pod Identity grants only S3 ListBucket and GetObject permissions.
6. aws s3 sync copies artifacts into /models on the PVC.
7. OVMS starts only after synchronization succeeds.
8. The startup probe waits for /v1/config.
9. The readiness probe admits traffic after the model is available.
```

S3 is the durable artifact source. EBS avoids downloading and reconstructing
the model cache on every container restart.

### Secret Flow

```text
1. The API key value is stored in AWS Secrets Manager.
2. The llm-gateway service account uses its EKS Pod Identity association.
3. The AWS provider for Secrets Store CSI calls Secrets Manager.
4. The driver mounts the value as /mnt/secrets-store/api-key.
5. The gateway reads the file and strips surrounding whitespace.
6. /ready fails if the key cannot be read.
7. /chat compares X-API-Key to the configured value.
```

The configuration disables synchronization to a normal Kubernetes Secret, so
the value is mounted directly instead of being copied into etcd as an ordinary
Secret.

### Deployment And GitOps Flow

```text
Terraform -> VPC, EKS, node groups, IAM, storage, endpoints, add-ons
Docker build -> gateway image -> ECR
Git commit -> k8s/aws manifests -> Argo CD
Argo CD -> reconcile desired resources into EKS
```

Terraform owns the AWS foundation and bootstrap add-ons. Argo CD owns the
application manifests after bootstrap. This keeps infrastructure lifecycle
separate from application reconciliation.

### Health And Recovery Flow

```text
Container process failure -> kubelet restarts container
Pod failure -> Deployment or StatefulSet creates replacement
Failed readiness -> Service and ALB stop sending new traffic
Node failure -> controller reschedules movable workloads
Voluntary disruption -> PDB limits simultaneous unavailability
High gateway CPU -> HPA increases gateway replicas
```

An EBS `ReadWriteOnce` volume and Availability Zone binding can affect where a
stateful OVMS replacement can run. Recovery claims must therefore be validated
with actual EBS and node-failure testing.

## Component Deep Dives

### OpenVINO And OVMS

OpenVINO is Intel's inference optimization and runtime toolkit. It converts or
loads optimized model representations and executes them on supported Intel
hardware.

OpenVINO Model Server is the serving layer around that runtime. OVMS adds:

- A long-running server process.
- REST and gRPC serving interfaces.
- OpenAI-compatible generation routes for supported model graphs.
- Model lifecycle and readiness reporting.
- Continuous batching and cache management.
- A deployable container image.

OpenVINO is the execution engine; OVMS is the network service that hosts it.

OVMS and Ollama overlap as local model-serving tools, but their goals differ.
Ollama optimizes developer convenience and local model use. OVMS is suited to
OpenVINO-specific optimization, standard serving protocols, Kubernetes
deployment, and Intel-oriented inference platform work.

### FastAPI Gateway

[The gateway implementation](../gateway/app/main.py) provides the client-facing
application contract while keeping OVMS internal.

Responsibilities:

- Validate `message` length from 1 to 2,000 characters.
- Restrict `max_tokens` to 1 through 256.
- Authenticate `X-API-Key`.
- Read the key from an environment variable or mounted file.
- Transform the request into an OVMS chat completion payload.
- Translate OVMS failures into HTTP `502`.
- Record latency and token usage.
- Expose separate `/health` and `/ready` endpoints.

The gateway does not implement model inference, model storage, or Kubernetes
orchestration. This narrow scope keeps it replaceable.

### Health Endpoints

`GET /health` is a shallow liveness check:

```json
{"status": "ok"}
```

It answers whether the gateway process can serve HTTP. It deliberately does
not depend on OVMS, so a temporary model outage does not cause Kubernetes to
restart a healthy gateway process.

`GET /ready` is a dependency-aware readiness check. It verifies:

- The API key is available.
- The configured OVMS URL can be converted to `/v1/config`.
- OVMS returns a successful response within the readiness timeout.

The Kubernetes readiness probe and ALB health check both use `/ready`.

### Gateway Deployment And Service

[The gateway manifest](../k8s/aws/gateway.yaml) defines:

- One initial replica in the low-cost demo. Two replicas are the production
  shaped target after a second worker is available.
- Placement on `nodepool=m7i-inference` in the current CPU-only demo.
- A mounted Secrets Store CSI volume.
- CPU request `250m` and memory request `256Mi`.
- CPU limit `1` and memory limit `1Gi`.
- `/ready` readiness and `/health` liveness probes.
- A ClusterIP Service on port `8080`.

The ClusterIP Service provides a stable in-cluster virtual IP and load
balances across ready gateway pod endpoints. It does not create an AWS load
balancer.

### OVMS StatefulSets

[Blue OVMS](../k8s/aws/ovms-blue.yaml) is active with one replica.
[Green OVMS](../k8s/aws/ovms-green.yaml) is standby with zero replicas.

Each template defines:

- The `ovms-model-reader` service account.
- Placement on `nodepool=m7i-inference` and
  `inference=openvino-cpu`.
- An S3 synchronization init container.
- OpenVINO Model Server targeting `CPU`.
- A `1` GiB cache setting.
- CPU request `2`, memory request `6Gi`.
- CPU limit `3`, memory limit `12Gi`.
- A `20Gi` `ReadWriteOnce` volume claim.
- Startup, readiness, and liveness probes on `/v1/config`.

StatefulSet is appropriate because each replica has stable storage identity.
It does not automatically make the model highly available; replicas, topology,
storage binding, and capacity still determine availability.

### Ingress And Internal ALB

[The Ingress](../k8s/aws/gateway-ingress.yaml) specifies:

```text
Ingress class: alb
Scheme: internal
Target type: ip
Listener: HTTP 80
Health check: /ready
```

The AWS Load Balancer Controller watches the Ingress and creates one internal
Application Load Balancer. IP target mode routes directly to pod IPs rather
than using NodePort as the ALB target.

Ingress is the desired routing object. The controller is the software that
translates it into AWS resources. Without the controller, the Ingress object
does not create an ALB by itself.

### S3 And EBS

S3 and EBS solve different storage problems:

| Storage | Purpose |
| --- | --- |
| S3 | Durable, versioned source of approved model artifacts |
| EBS | Low-latency, writable model cache attached to one OVMS pod |

Terraform enables S3 versioning, blocks public access, and enables AES-256
server-side encryption. The OVMS identity receives read-only permissions.

EBS is provisioned through the Amazon EBS CSI Driver. Because EBS volumes are
zonal and `ReadWriteOnce`, scheduling and recovery must respect volume
topology.

### ECR

Amazon Elastic Container Registry stores the custom FastAPI gateway image.
Terraform enables image scanning on push. Worker nodes pull the image using
their node role and private ECR endpoints.

For stronger production promotion, immutable tags or image digests should
replace the current mutable gateway tags. The OVMS image in the manifests is
already digest-pinned.

### Argo CD

Argo CD watches the Git repository and the `k8s/aws` path. Automated sync,
pruning, and self-healing make Git the desired-state source after bootstrap.

This provides:

- Auditable configuration changes.
- Repeatable application deployment.
- Drift correction.
- A natural blue-green promotion workflow through Git.

Argo CD does not create the EKS cluster; Terraform must bootstrap the cluster
and Argo CD first.

### Repository Map

| Path | Responsibility |
| --- | --- |
| [`terraform/aws`](../terraform/aws) | AWS foundation and bootstrap add-ons |
| [`k8s/aws`](../k8s/aws) | Kubernetes application desired state |
| [`gateway/app/main.py`](../gateway/app/main.py) | Gateway runtime |
| [`gateway/tests/test_gateway.py`](../gateway/tests/test_gateway.py) | Gateway behavior tests |
| [`scripts/aws-smoke-test.ps1`](../scripts/aws-smoke-test.ps1) | Basic health and chat validation |
| [`scripts/aws-benchmark.ps1`](../scripts/aws-benchmark.ps1) | Repeated request measurement |
| [`scripts/aws-failure-demo.sh`](../scripts/aws-failure-demo.sh) | OVMS pod replacement demonstration |
| [`docs/aws-eks-openvino-llm-poc.md`](aws-eks-openvino-llm-poc.md) | AWS deployment runbook |

## AWS Networking Deep Dive

### VPC And Availability Zones

The Terraform VPC uses:

- One `/16` VPC CIDR, defaulting to `10.80.0.0/16`.
- Two Availability Zones.
- Two private subnets.
- Two public subnets.
- DNS support and DNS hostnames.
- One NAT Gateway for the low-cost POC.

Worker nodes and the internal ALB use private subnets. Public subnets provide
the NAT Gateway path; they do not make private worker nodes publicly
addressable.

For corporate connectivity, the VPC CIDR must not overlap Intel DMZ, VPN, or
on-premises routes.

### Route Tables

A route table is associated with a subnet, not directly with a pod, instance,
or endpoint ENI. Every resource in the subnet uses the subnet's effective
route table.

Typical private-subnet routes are:

```text
10.80.0.0/16 -> local
0.0.0.0/0    -> NAT Gateway
S3 prefix    -> S3 gateway endpoint
```

The `local` route handles communication between private IP addresses inside
the VPC.

### Gateway VPC Endpoint

The S3 gateway endpoint:

- Adds an S3 service-prefix route to selected route tables.
- Does not create an endpoint ENI.
- Does not require a security group.
- Does not require selecting endpoint subnets.
- Has no endpoint hourly charge.

The OVMS init container can reach S3 without sending S3 traffic through the
NAT Gateway.

### Interface VPC Endpoints

The design creates interface endpoints for:

```text
ecr.api
ecr.dkr
secretsmanager
sts
logs
monitoring
```

An interface endpoint creates an Elastic Network Interface (ENI) with a
private IP in every selected subnet. Private DNS maps the normal regional AWS
service name to those private IPs.

```text
Pod -> private DNS -> endpoint ENI:443 -> AWS service
```

Because the ENI receives traffic, it needs a security group. The Terraform
endpoint security group permits TCP `443` from the VPC CIDR. Interface
endpoints do not need custom route-table entries; normal VPC local routing
reaches their private IPs.

Placing an endpoint in both private subnets provides an endpoint ENI in each
Availability Zone. That improves zonal resilience but incurs endpoint charges
for each service in each zone.

### NAT Versus VPC Endpoints

| NAT Gateway | VPC endpoint |
| --- | --- |
| General outbound path | Private path to a specific supported AWS service |
| Uses a public service endpoint | Uses AWS private networking |
| Hourly and data-processing cost | Interface endpoints have hourly/AZ and data cost |
| Supports external registries and package sites | Does not provide general internet access |
| One route can serve many destinations | One endpoint service per AWS API family |

The POC uses both. Endpoints privatize core AWS-service traffic, while NAT
supports bootstrap or destinations that do not have endpoints. A stricter
environment can mirror every required image into ECR and reduce NAT
dependence.

### Private EKS Endpoint

Terraform configures:

```text
cluster_endpoint_private_access = true
cluster_endpoint_public_access  = false
```

`kubectl`, Terraform's Kubernetes/Helm providers, and operational scripts must
run from a system that can route to the VPC, such as:

- An Intel DMZ VPN-connected laptop.
- A Direct Connect-connected network.
- A bastion or managed workstation inside the VPC.
- A private runner.
- An EKS Console CloudShell VPC environment.

The EKS API endpoint administers Kubernetes. The internal ALB serves
application requests. They are distinct endpoints with different security
boundaries.

### Subnet Tags

Private subnets use:

```text
kubernetes.io/role/internal-elb = 1
kubernetes.io/cluster/openvino-llm-poc = shared
```

The first tag tells the AWS Load Balancer Controller where internal load
balancers may be created. The cluster tag records intended sharing/ownership.

## IAM And Security Model

### Why Separate Roles

One broad IAM role would be easy to create but difficult to defend. The design
separates identities by responsibility:

| Identity | Trusted principal | Main purpose |
| --- | --- | --- |
| EKS cluster role | `eks.amazonaws.com` | Allow the managed control plane to manage required AWS resources |
| Node role | `ec2.amazonaws.com` | Allow kubelet/node bootstrap and ECR image pulls |
| EBS CSI role | EKS Pod Identity | Provision and attach EBS volumes |
| ALB controller role | EKS Pod Identity | Manage ALB-related AWS resources |
| Gateway role | `llm-inference:llm-gateway` | Read one Secrets Manager secret |
| OVMS model-reader role | `llm-inference:ovms-model-reader` | List and read model objects from one S3 bucket |

Compromise of the gateway pod should not grant model-bucket administration or
load-balancer permissions. Compromise of an OVMS pod should not reveal the
gateway API key.

### EKS Pod Identity And IRSA

The deployed AWS design used EKS Pod Identity. The equivalent identity flow is:

```text
Kubernetes service account
        -> EKS Pod Identity association
        -> pods.eks.amazonaws.com trust policy
        -> short-lived STS credentials
        -> permitted AWS API
```

The association limits the namespace and service account. The IAM permission
policy limits the AWS operations and resources. The EBS CSI add-on,
`llm-gateway`, `ovms-model-reader`, and AWS Load Balancer Controller each use a
separate role association in the AWS design.

IRSA is the older OIDC-based alternative and is still worth understanding for
interviews. Both approaches are preferable to placing S3 and Secrets Manager
permissions on the node role. A node role is shared by every pod that can use
node credentials; a workload role follows the specific service account.

### Secret Handling

The API key:

- Is not built into the image.
- Is not committed to Git.
- Is not embedded in a ConfigMap.
- Is not synchronized into a normal Kubernetes Secret by this configuration.
- Is mounted read-only into the gateway pod.

Production improvements would include secret rotation testing, TLS, stronger
client identity such as corporate OIDC or mutual TLS, and audited access
policies.

### Security Groups

Security groups are stateful firewalls:

- The internal ALB security group allows HTTP from trusted private CIDRs.
- The endpoint security group allows HTTPS from the VPC CIDR.
- EKS-managed cluster and node security groups protect control-plane and node
  communication.

For production, replace broad VPC-CIDR rules with approved corporate ranges or
source security groups where practical.

## Kubernetes Concepts Demonstrated

| Concept | Use in this project |
| --- | --- |
| Namespace | Isolates application resources in `llm-inference` |
| Pod | Smallest execution unit for gateway, OVMS, init containers, and add-ons |
| Deployment | Runs interchangeable stateless gateway replicas |
| StatefulSet | Gives OVMS replicas stable storage identity |
| ClusterIP Service | Provides stable internal discovery and balances across ready pods |
| Headless Service | Supplies StatefulSet network identity without a virtual ClusterIP |
| Ingress | Declares private HTTP routing to the gateway |
| Ingress controller | Translates Ingress into an AWS ALB |
| ConfigMap | Selects active OVMS URL and model name |
| ServiceAccount | Gives each workload a Kubernetes and AWS identity |
| SecretProviderClass | Defines which Secrets Manager object to mount |
| PersistentVolumeClaim | Requests a 20 GiB EBS model-cache volume |
| Init container | Synchronizes S3 model files before OVMS starts |
| Startup probe | Gives slow model initialization time to complete |
| Readiness probe | Removes unready pods from traffic |
| Liveness probe | Restarts a stuck process |
| Requests | Reserve schedulable CPU and memory |
| Limits | Cap container CPU/memory consumption |
| Labels | Identify workloads and select Services/pods |
| Node selector | Places gateway and inference workloads on separate node pools |
| HPA | Scales gateway replicas from CPU metrics |
| PDB | Limits voluntary concurrent disruption |
| Argo CD Application | Reconciles Git state into the cluster |

### NodePort Versus ClusterIP Versus LoadBalancer

- NodePort exposes the same fixed port on every node and was useful for the
  k3s POC.
- ClusterIP exposes a service only inside the cluster and is used between the
  gateway and OVMS.
- In the AWS design, the internal ALB is created from Ingress. The gateway
  Service remains ClusterIP.

NodePort does not provide a stable external entry address by itself. The
Service load-balances across ready pod endpoints, while an external or
internal load balancer provides one client-facing endpoint.

## Reliability, Scaling, And Deployment Strategy

### Probes

OVMS startup can take minutes because it may synchronize artifacts, initialize
the graph, allocate cache, and compile runtime operations. A startup probe
prevents liveness from killing it during legitimate initialization.

Readiness and liveness answer different questions:

```text
Liveness: should Kubernetes restart this process?
Readiness: should this pod receive new traffic?
```

The gateway liveness check is shallow. Its readiness check includes the API
key and OVMS dependency. That prevents restart loops during a downstream
outage while still removing the gateway from traffic.

### Resource Management

The current POC OVMS pod requests 2 CPU and 6 GiB memory and limits at 3 CPU
and 12 GiB. The request determines scheduling. A nominal 4-vCPU node is tight
because Kubernetes reserves CPU and memory for the operating system and node
services. The low-cost demo used one `m7i.xlarge`; a larger production-shaped
profile should use a larger worker and spare capacity.

Resource sizing must include:

- Model weights and runtime graph.
- KV cache.
- Request concurrency.
- Temporary initialization memory.
- Kubernetes and operating-system reservation.
- Desired headroom for failure and rolling operations.

### Gateway HPA

[The HPA](../k8s/aws/hpa.yaml) targets the gateway Deployment:

```text
Minimum replicas: 1
Maximum replicas: 2
CPU target: 70 percent average utilization
```

Metrics Server supplies resource metrics. This scales the stateless API layer,
not OVMS. Inference autoscaling needs model-aware capacity, startup time, queue
depth, concurrency, and cost controls; it is intentionally not presented as
implemented here. A `minReplicas: 0`, `maxReplicas: 1` setting was discussed as
a theoretical cost-saving option, but it was not applied or load-tested.

### PodDisruptionBudgets

[The PDB definitions](../k8s/aws/pdb.yaml) require at least one gateway and
active blue OVMS pod to remain available during voluntary disruptions such as
node draining.

A PDB does not protect against:

- Process crashes.
- Node power loss.
- Availability Zone failure.
- Insufficient replacement capacity.

It constrains voluntary eviction, not every failure mode.

### Blue-Green Model Promotion

Default state:

```text
Blue StatefulSet:  1 replica, active target
Green StatefulSet: 0 replicas, standby definition
```

Promotion sequence:

1. Update green to the candidate model configuration.
2. Scale green to one replica.
3. Wait for model synchronization and readiness.
4. Run direct or controlled validation.
5. Change the gateway `OVMS_URL` ConfigMap from blue Service to green Service.
6. Reconcile through Git/Argo CD.
7. Restart gateway pods because the ConfigMap is consumed as an environment
   variable.
8. Run smoke and benchmark checks.
9. Scale blue down after the rollback window.

This minimizes simultaneous inference cost while retaining an explicit
rollback target.

## Troubleshooting Case Studies

### Case 1: OVMS Returned An Empty Configuration

**Symptom**

`GET /v1/config` returned `{}`, and chat returned a graph-not-found error.

**Evidence**

OVMS logs showed the server listening but Git LFS was still downloading and
checking out model artifacts.

**Root cause**

The process was alive, but the model graph was not yet initialized.

**Correction**

Wait for `/v1/config` to report the model as `AVAILABLE`. Use model readiness,
not an open port, as the traffic gate.

**Lesson**

Health is layered: process health, application readiness, and model readiness
are not the same state.

### Case 2: `ImagePullBackOff`

**Symptom**

The Minikube pod cycled between `ErrImagePull` and `ImagePullBackOff`.

**Evidence**

`kubectl describe pod` reported:

```text
manifest for openvino/model_server:2025.4-py not found
```

**Root cause**

The requested image tag did not exist in the registry.

**Correction**

Use a verified image reference. The AWS manifests later improved this by
pinning OVMS to an image digest.

**Lesson**

Read the event message before changing credentials, DNS, or Kubernetes
configuration. The registry answered successfully and stated the exact
problem.

### Case 3: Service Had No Endpoints

**Symptom**

The NodePort Service existed, but the client could not connect and the
Endpoints object was empty.

**Evidence**

The OVMS pod was in `CrashLoopBackOff` or not ready.

**Root cause**

Services route only to selected ready pod endpoints. Creating a Service does
not make an unhealthy backend reachable.

**Correction**

Debug the pod state and readiness first, then verify EndpointSlice membership.

**Lesson**

Trace traffic in order:

```text
client -> load balancer/NodePort -> Service -> EndpointSlice -> pod -> process
```

### Case 4: Model Pod Was `OOMKilled`

**Symptom**

The pod started, consumed memory during model initialization, and was killed.

**Evidence**

`kubectl describe pod` showed `Last State: Terminated`, `Reason: OOMKilled`.

**Root cause**

The model, runtime, cache, and initialization peak exceeded the VM/container
memory available.

**Correction**

Use a smaller model for the constrained VM proof of concept and size requests,
limits, and node memory from measured peak usage.

**Lesson**

Quantization reduces model memory but does not remove runtime, cache, and
temporary allocation requirements.

### Case 5: BRGEMM CPU Compatibility Failure

**Symptom**

The smaller model became available, but generation crashed with an invalid
BRGEMM parameter error from the Intel CPU plugin.

**Evidence**

The stack trace identified `PagedAttentionExtension`, the CPU plugin, and a
oneDNN BRGEMM kernel initialization failure. The issue appeared when an actual
generation request exercised the kernel.

**Root cause**

The virtual CPU exposed an instruction/capability combination that the runtime
path did not handle reliably under nested virtualization.

**Correction**

Constrain oneDNN to AVX2 for the VM experiment and validate the workload on the
intended physical or cloud CPU before claiming performance.

**Lesson**

Readiness proves initialization, not every inference execution path. A smoke
request and benchmark are necessary after readiness.

### Case 6: Minikube URL Changed

**Symptom**

The benchmark could not connect even though the pod was healthy.

**Evidence**

`minikube service --url` returned a new localhost port, while the benchmark
still used an older port.

**Root cause**

The Docker-driver tunnel is temporary and bound to the terminal that created
it.

**Correction**

Keep the tunnel terminal open and pass its current URL to the benchmark.

**Lesson**

Separate backend health from client-path health. Dynamic local tunnels are not
stable production endpoints.

### Debugging Method Used

The repeatable investigation order was:

1. `kubectl get pods -o wide` for state and placement.
2. `kubectl describe pod` for events, termination reason, probes, and
   scheduling.
3. `kubectl logs` and `kubectl logs --previous` for current and crashed
   containers.
4. Service and EndpointSlice inspection for routing eligibility.
5. Node capacity, requests, limits, and PVC state.
6. A single smoke request before a repeated benchmark.

This prevents random edits across image, network, storage, and application
layers.

## Validation And Current Scope

| Capability | Local Docker | Minikube | k3s VMs | Repository implementation | Requires live AWS validation |
| --- | :---: | :---: | :---: | :---: | :---: |
| OVMS model availability | Yes | Yes | Yes | Yes | Yes |
| Chat completion | Yes | Yes | Yes, constrained | Yes | Yes |
| Local benchmark behavior | Yes | Yes | Partially stress-tested | Scripts exist | Yes |
| Kubernetes scheduling | No | Yes | Yes | Manifests exist | Yes |
| NodePort access | No | Local tunnel | Yes | Not used in AWS design | No |
| Internal ALB | No | No | No | Terraform/Ingress exist | Yes |
| S3 model sync | No | No | No | Init container/IAM exist | Yes |
| EBS model cache | No | Local storage | PVC tested locally | CSI/PVC definitions exist | Yes |
| Secrets Manager CSI mount | No | No | No | Terraform/manifests exist | Yes |
| EKS Pod Identity | No | No | No | Roles and service accounts exist | Yes |
| Argo CD reconciliation | No | No | No | Helm/Application definitions exist | Yes |
| Gateway HPA | No | No | No | HPA/Metrics Server definitions exist | Yes |
| Blue-green promotion | No | No | No | Blue/green definitions exist | Yes |
| Intel GPU or NPU path | No | No | No | Not in current AWS scope | Outside current scope |

The table is the interview truth boundary. "Implemented" means the repository
contains the required code and declarative resources; it does not substitute
for live environment validation.

## Interview Questions And Answers

Use the first paragraph of each answer for a short response. Use the remaining
detail only when the interviewer asks a follow-up.

### What Is The Main DevOps Value?

The value is not merely running a model. It is turning model inference into a
private, deployable, observable, recoverable service with controlled identity,
storage, routing, and rollout behavior.

### Why Use Kubernetes?

Kubernetes provides a consistent control plane for scheduling, networking,
health checks, resource allocation, configuration, storage, recovery, and
rollouts. Those capabilities matter when a model server must become a shared
service rather than a process started manually on one machine.

In this project, Kubernetes:

- Schedules gateway and inference workloads onto separate node groups.
- Restarts failed containers and removes unready pods from Service endpoints.
- Gives the gateway and OVMS stable internal DNS names through Services.
- Mounts model-cache storage and the gateway API key declaratively.
- Supports gateway scaling, disruption protection, and blue-green promotion.

Kubernetes does not make an oversized model fit into memory, fix incompatible
CPU instructions, or determine safe inference concurrency automatically.
Those remain application and capacity-engineering responsibilities.

### Why Use OpenVINO Instead Of Ollama?

OpenVINO is an inference optimization runtime, while Ollama is primarily a
developer-friendly model runner and local model-management experience. This
project focuses on Intel CPU optimization, explicit model-serving
infrastructure, Kubernetes scheduling, and production-shaped APIs, so
OpenVINO is the more relevant foundation.

The strict comparison is not "OpenVINO is always better." Ollama is convenient
for quickly running models on a workstation. OpenVINO is useful when the
engineering objective is to optimize and serve models on Intel hardware with
control over the runtime and deployment architecture.

### Why Use OpenVINO Model Server?

OpenVINO Model Server (OVMS) packages OpenVINO inference behind network APIs
and adds serving behavior such as model lifecycle management and continuous
batching. It lets application clients call an HTTP endpoint instead of loading
the model runtime inside every application.

That separation gives the platform a clear boundary: OVMS owns model execution;
the gateway owns authentication and request policy; Kubernetes owns placement,
health, storage, and recovery.

### Why Put A Gateway In Front Of OVMS?

OVMS should not be the direct trust boundary for end users. The FastAPI gateway
provides API-key validation, a stable application endpoint, readiness checks,
request forwarding, and a single place for future rate limiting, audit
metadata, or corporate identity integration.

It also decouples clients from blue and green backends. Changing the
`OVMS_URL` configuration can promote another model-server Service without
changing the client-facing URL.

### Why Is OVMS A StatefulSet?

The model server uses per-pod persistent model-cache storage. A StatefulSet
provides stable pod identity and a predictable relationship between each pod
and its PersistentVolumeClaim (PVC), which is useful for expensive model
downloads and local cache reuse.

A Deployment could be sufficient if models were small, downloaded on every
start, or stored on a shared read-only filesystem. Here the StatefulSet makes
the storage lifecycle explicit.

### Why Use ClusterIP Services Internally?

ClusterIP exposes a stable virtual IP and DNS name only inside the cluster.
That is appropriate for the gateway and OVMS because neither component should
be opened directly through a public node port.

The internal Application Load Balancer (ALB) reaches the gateway pods through
the Ingress configuration, and the gateway reaches OVMS through its ClusterIP
Service. This keeps the model server off the external request boundary.

### Why Use Ingress And An Internal ALB?

Ingress expresses HTTP routing in Kubernetes, while the AWS Load Balancer
Controller translates that resource into an AWS ALB. The ALB is internal, so
it receives private addresses and is reachable only through approved private
network paths such as the Intel DMZ/VPN-connected environment.

This is one application load balancer for the POC. The EKS API endpoint is a
separate private control-plane endpoint and is not an application load
balancer.

### Why Use Both S3 And EBS?

Amazon S3 is the durable source of truth for versioned model artifacts.
Amazon Elastic Block Store (EBS) is the pod's local persistent cache. The OVMS
init container copies the selected model from S3 to the EBS-backed volume
before the server starts.

This separates durable artifact distribution from runtime access. S3 is
durable and centrally managed; EBS gives the pod filesystem semantics and
local block access expected by the model server. The trade-off is that an EBS
volume is Availability Zone-specific and is not a multi-writer shared model
store.

### Why Use Gateway And Interface VPC Endpoints?

Both endpoint types keep supported AWS-service traffic on private AWS
networking, but they work differently.

- The S3 gateway endpoint adds S3 routes to selected subnet route tables. It
  does not create endpoint network interfaces and has no endpoint security
  group.
- Interface endpoints create elastic network interfaces (ENIs) with private
  IP addresses in the selected subnets. Private DNS maps normal AWS service
  names to those addresses, and a security group controls HTTPS access.

The interface endpoints cover services such as ECR API, ECR Docker registry,
Secrets Manager, Security Token Service (STS), CloudWatch Logs, and
CloudWatch monitoring. NAT remains available for bootstrap traffic or
destinations that do not have an endpoint in this design.

### Why Place Interface Endpoints In Two Private Subnets?

Creating an endpoint ENI in each Availability Zone gives workloads a
same-zone private path and avoids making one zone's endpoint a single point of
dependency. Each endpoint ENI uses a private IP and incurs AWS PrivateLink
cost, so the availability benefit has a cost trade-off.

Interface endpoints use security groups because they accept network
connections. They do not need a special route-table entry: private DNS
resolves the service name to their private IP addresses, and the subnet's
normal local VPC route reaches those addresses.

### Why Use Separate IAM Roles?

Separate Identity and Access Management (IAM) roles reduce blast radius and
make the trust boundary reviewable.

- The EKS cluster role lets the managed control plane operate required AWS
  resources.
- The node role lets kubelet and node-level components join and operate.
- Controller roles give the ALB and EBS CSI controllers only the AWS
  permissions they need.
- Workload roles use EKS Pod Identity: OVMS can read the model prefix in S3,
  while the gateway can read only its Secrets Manager secret.

Node access is therefore not treated as permission for every workload on that
node.

### How Does Kubernetes Recover From Failure?

The Deployment or StatefulSet controller replaces a failed pod. Startup and
readiness probes prevent traffic from reaching a pod before it is usable, and
a liveness probe can restart a stuck container. Services route only to ready
endpoints.

Recovery is still bounded by capacity and storage. A replacement cannot start
if no node has enough CPU or memory, and an EBS volume must be attachable in
the target Availability Zone. A PodDisruptionBudget (PDB) limits voluntary
disruptions; it does not protect against every node, zone, or application
failure.

### What Does The HPA Scale?

The Horizontal Pod Autoscaler (HPA) scales the gateway from one to two
replicas based on CPU utilization reported by Metrics Server. It does not
scale OVMS. A theoretical zero-to-one configuration was discussed for cost
control but was not applied or load-tested.

Inference scaling needs model-aware signals such as queue depth, concurrent
requests, token throughput, latency, and memory or key-value cache pressure.
CPU alone can be a poor signal for model-serving capacity, so OVMS scaling is
left as an explicit production next step.

### How Does Blue-Green Promotion Work?

The blue StatefulSet starts as the active one-replica backend and green starts
at zero. A release operator scales green up, waits until its OVMS configuration
reports the model as available, runs direct smoke tests, changes the gateway's
active OVMS Service target, and then verifies the client path.

Rollback changes the gateway target back to blue. Only after a stable
observation period should the old backend be scaled down. The repository
contains the blue and green resources, but the promotion still requires live
operational validation and disciplined sequencing.

### How Would This Move To Intel GPU Hardware?

First create or reserve a GPU-capable node group and expose the Intel GPU
devices to Kubernetes using the supported Intel device plugin and host driver
stack. Label and taint those nodes, update OVMS scheduling and resource
requests to claim the GPU resource, select the GPU target device, and validate
the model format and runtime version on that hardware.

Then repeat functional, concurrency, memory, failover, and performance tests.
Changing `--target_device` alone is not enough; drivers, device discovery,
container permissions, scheduling, and model compatibility must all be
verified.

### What Are The Main Production Gaps?

The main gaps are live AWS validation, measured capacity, transport and user
identity security, deeper observability, model-aware scaling, failure testing,
and automated promotion controls.

Specifically, the ALB, Pod Identity sessions, Secrets Store CSI mount, S3 model sync,
EBS attachment behavior, Argo CD reconciliation, HPA response, node drains,
Availability Zone failure, and AWS performance require live environment
testing. Transport Layer Security (TLS), corporate authentication, rate
limits, audit logs, NetworkPolicies, immutable model promotion, dashboards,
alerts, and backup/restore exercises should be completed before a production
launch.

### What Was The Hardest Technical Lesson?

A Kubernetes object being present does not mean the request path works.
Troubleshooting had to trace image availability, pod state, model readiness,
Service endpoints, client routing, resource capacity, and CPU execution in
order.

## STAR Stories

### Story 1: Diagnosing An Image Pull Failure

**Situation:** The Minikube OVMS pod stayed in `ImagePullBackOff`, so the model
service never started.

**Task:** Restore the deployment without changing unrelated Kubernetes
resources.

**Action:** I inspected the pod events with `kubectl describe pod`. The event
showed that `openvino/model_server:2025.4-py` had no registry manifest. I
replaced the invalid tag with an available OVMS image and watched the rollout,
pod logs, and `/v1/config` rather than assuming a running container meant the
model was ready. In the AWS design I then used a digest-pinned OVMS image to
remove tag ambiguity.

**Result:** The image pulled, OVMS initialized, and the model eventually
reported `AVAILABLE`. The lasting lesson was to read scheduler and kubelet
events first and to use immutable image references for controlled
environments.

### Story 2: Separating Memory And CPU Compatibility Failures

**Situation:** On the two-node k3s VM cluster, the original model pod was
`OOMKilled`. After moving to a smaller model, inference still crashed with a
PagedAttention/BRGEMM error under nested virtualization.

**Task:** Determine whether Kubernetes networking, memory, or CPU execution was
responsible and get a stable small-model path.

**Action:** I used pod termination reasons and resource limits to identify the
memory failure, then selected the smaller
`Phi-3-mini-FastDraft-50M-int8-ov` model. When the model became `AVAILABLE` but
the request still crashed, I read the OVMS logs and separated readiness from
inference execution. The BRGEMM stack trace pointed to CPU instruction
compatibility, so I constrained oneDNN to AVX2 with
`ONEDNN_MAX_CPU_ISA=AVX2` and `DNNL_MAX_CPU_ISA=AVX2`. I resumed with a smoke
request before applying benchmark load.

**Result:** The pod reached ready state with zero restarts and the endpoint
became reachable. Repeated load could still destabilize the constrained VM,
which produced the stronger capacity lesson: health checks prove service
eligibility, not safe throughput.

### Story 3: Evolving A Local Demo Into A Private Platform Design

**Situation:** Docker and Minikube proved that OVMS could serve a model, but
they did not address private enterprise access, least-privilege identity,
durable model distribution, controlled rollout, or multi-node operations.

**Task:** Design a production-shaped POC that could be operated from an Intel
DMZ/VPN-connected environment without exposing the application or EKS API
publicly.

**Action:** I separated platform and inference node groups, placed them in two
private subnets, selected an internal ALB, and retained NAT only for bootstrap
or uncovered destinations. I added an S3 gateway endpoint and interface
endpoints for core AWS APIs, with private DNS and endpoint security groups. I
used EKS Pod Identity to separate S3 and Secrets Manager permissions, Secrets
Store CSI to mount the gateway key as a file, EBS for per-pod model cache, and Argo CD plus
blue-green manifests for controlled deployment.

**Result:** The repository now contains a coherent private EKS implementation
that can be deployed and validated stage by stage. I present the result
accurately: the architecture and automation exist, while AWS integration,
failure, scaling, and performance behavior remain live-validation work.

## Trade-Offs And Production Next Steps

The architecture deliberately favors clarity and managed services over the
smallest possible AWS bill. PrivateLink endpoints, EKS, NAT, ALB, and multiple
node groups all carry fixed costs. A learning deployment can temporarily use
one node per group, while the production-shaped Terraform defaults preserve
two nodes in each group.

Production work should prioritize:

1. Measured capacity and concurrency tests on the selected CPU.
2. TLS and corporate identity integration.
3. Full metrics, logs, traces, dashboards, and alerts.
4. Image and model promotion with immutable identifiers.
5. NetworkPolicy and admission-policy enforcement.
6. Backup, restore, node-drain, and Availability Zone failure tests.
7. Model-aware inference scaling or queue-based load shedding.
8. Multi-AZ storage and rollout behavior validation.
9. Cost budgets, ownership tags, and automated teardown for POC environments.

## Strict Claim Boundaries

Say:

- "I validated OVMS serving locally, then moved it through Minikube and k3s."
- "I implemented the private AWS EKS architecture and deployment definitions."
- "The AWS path uses Intel M7i CPU instances and OpenVINO CPU inference."
- "The local benchmark averaged 2.469 seconds and 16.69 completion tokens per
  second."
- "Gateway autoscaling is defined; model-server autoscaling is a separate
  production concern."

Do not say:

- "This is already a production deployment."
- "The local benchmark represents AWS or bare-metal performance."
- "The project validated Intel GPU or NPU inference."
- "A PodDisruptionBudget guarantees availability."
- "NodePort is a production load balancer."
- "Kubernetes automatically solves model capacity and KV-cache sizing."
- "Blue-green deployment is complete merely because two YAML files exist."

## Final Revision Checklist

- Can I explain the end-user request path without mentioning implementation
  details first?
- Can I distinguish OpenVINO from OVMS and Ollama?
- Can I explain why the gateway exists?
- Can I trace traffic from ALB to pod?
- Can I explain why a Service can have no endpoints?
- Can I compare ClusterIP, NodePort, Ingress, and an ALB?
- Can I explain route tables, NAT, gateway endpoints, and interface endpoints?
- Can I explain why interface endpoints need security groups but no special
  route-table entry?
- Can I explain cluster, node, controller, and workload IAM roles separately?
- Can I explain EKS Pod Identity and contrast it with IRSA without saying
  long-lived credentials are stored in the pod?
- Can I explain why S3 and EBS are both used?
- Can I explain startup, readiness, and liveness probes?
- Can I explain why gateway HPA does not scale inference?
- Can I explain the blue-green promotion and rollback sequence?
- Can I describe the benchmark environment accurately?
- Can I state what still needs live AWS validation?

## Appendix: Complete Project Execution Record

This appendix is the chronological record of the work, the failures that were
encountered, what each failure meant, and how to describe it in an interview.
It is deliberately more concrete than the architecture summary.

### Current Truth

The project has three validated layers and one implemented-but-rebuildable AWS
layer:

1. Docker and OVMS serving were validated locally on Windows.
2. Minikube was used to learn single-node Kubernetes and Service exposure.
3. A two-node k3s cluster on lightweight Ubuntu VMs was used to learn worker
   scheduling, storage, capacity, and CPU compatibility.
4. The AWS EKS design, manifests, Terraform roots, and deployment scripts are
   present locally. The AWS learning environment was created and exercised,
   then deleted. The current AWS environment is not running.

The AWS environment was initially created mainly through the AWS console and
CLI. Terraform adoption plans were generated and reviewed, but the adoption
plan was not applied. Therefore the accurate statement is:

> I implemented and validated Terraform plans for the AWS architecture; the
> next clean run will create the environment from Terraform.

Do not say that Terraform already provisioned the deleted AWS environment.
That would overstate the work.

### Phase 0: Requirements And Design Decisions

The initial problem was to serve an open-source LLM on Intel-oriented
infrastructure and make it an operable service rather than a process started
manually on one machine.

The design separated responsibilities:

| Component | Responsibility |
| --- | --- |
| OpenVINO | Optimized Intel inference runtime |
| OVMS | Network-serving layer around OpenVINO |
| FastAPI gateway | Authentication, validation, stable client API, routing |
| Kubernetes | Scheduling, probes, Services, storage, restarts, rollout |
| S3 | Durable model artifact source |
| EBS | Per-pod writable model cache |
| Secrets Manager | API key storage |
| Secrets Store CSI | Mounts the key into the gateway as a file |
| Internal ALB | Private client entry point |
| EKS Pod Identity | Per-workload AWS permissions |

The end user sends a prompt to the gateway. The end user does not contact
OVMS, Kubernetes, S3, EBS, or the AWS control plane directly.

The first target was Intel CPU inference because it was available locally and
on AWS M7i instances. Intel GPU and NPU execution were kept as a future node
pool and device-plugin path; they were not validated in this project.

### Phase 1: Running OVMS In Docker On Windows

The first milestone was to prove that the model and serving runtime worked
without Kubernetes.

The container exposed REST on `localhost:8000`. The useful first check was:

```powershell
curl.exe http://localhost:8000/v1/config
```

PowerShell detail: `curl` can resolve to the `Invoke-WebRequest` alias. That
produces a PowerShell object and can display a script-parsing warning. Use
`curl.exe` for real curl behavior or use `Invoke-RestMethod` when a parsed JSON
object is desired.

#### First Docker issue: empty model configuration

`/v1/config` initially returned `{}`. The REST server was healthy, but the
model was not ready. Container logs showed Git LFS downloading a multi-gigabyte
`openvino_model.bin` and the detokenizer files.

The lesson was to distinguish:

- Process readiness: port 8000 is listening.
- Model readiness: the requested model reports `AVAILABLE`.

#### Second Docker issue: MediaPipe graph not found

Calling `/v3/chat/completions` before model initialization produced:

```text
Mediapipe graph definition with requested name is not found
```

This was a timing and readiness problem, not an invalid chat request. The
correct gate was the model status in `/v1/config`:

```json
{
  "OpenVINO/Phi-3.5-mini-instruct-int4-ov": {
    "model_version_status": [
      {
        "version": "1",
        "state": "AVAILABLE",
        "status": {"error_code": "OK", "error_message": "OK"}
      }
    ]
  }
}
```

Only after this state was reached did chat completion return a valid answer,
model name, and token usage. This led to the readiness design used later in
Kubernetes.

#### Docker result

The local container proved that:

- The OVMS image could run on the laptop CPU.
- The OpenVINO model could download and initialize.
- REST chat serving worked.
- A listening port was not sufficient evidence of inference readiness.

### Phase 2: Minikube On The Laptop

Minikube was the first Kubernetes step. It provided a single-node cluster
inside the laptop so that Kubernetes concepts could be learned without cloud
cost.

The workload used a Deployment, a Service, resource requests and limits, and
HTTP probes against `/v1/config`.

#### Minikube API server failure

One startup attempt failed with messages such as:

```text
K8S_APISERVER_MISSING
apiserver process never appeared
connect: connection refused to localhost:8443
```

The storage-class and storage-provisioner add-ons also failed because the API
server was not available. This was a cluster bootstrap problem, not an OVMS
problem. The correct debugging order was `minikube status`, cluster logs,
driver state, and a clean restart before debugging application manifests.

#### Invalid image tag

The pod entered `ErrImagePull` and `ImagePullBackOff` because the manifest used:

```text
openvino/model_server:2025.4-py
```

The registry returned `manifest unknown`. Kubernetes events showed the exact
reason. The fix was to use an image tag that actually existed, and the AWS
manifests later moved toward digest-pinned images to avoid mutable-tag
ambiguity.

#### Dynamic Minikube service URL

With the Docker driver on Windows, this command returned a temporary URL:

```powershell
minikube service ovms-llm-service --url
```

The URL changed when the tunnel was recreated. The terminal running the
Minikube tunnel had to remain open. Reusing an older port caused:

```text
Unable to connect to the remote server
```

The Kubernetes Service and pod could be healthy while the client was still
using a dead tunnel URL.

#### Local benchmark result

After using the current tunnel URL, five requests succeeded:

| Measurement | Result |
| --- | ---: |
| Average latency | 2.469 seconds |
| Average completion throughput | 16.69 tokens/second |
| First request | 5.023 seconds |
| Later requests | Approximately 1.8 seconds |

The first request was slower because of runtime warm-up. These numbers are
local laptop measurements, not AWS or bare-metal performance numbers.

### Phase 3: Two-Node k3s Cluster On Ubuntu VMs

The next goal was to simulate separate bare-metal machines without buying
multiple physical systems.

The architecture was:

```text
Ubuntu VM 1: k3s server/control plane
        |
        +-- private VM network -- Ubuntu VM 2: k3s worker
                                      |
                                      +-- OVMS inference pod
```

The two VMs used private addresses in the `192.168.88.0/24` range.

#### Why two VMs?

One VM taught Kubernetes syntax. Two VMs taught scheduling and node failure
boundaries. It was still only a simulation of bare metal: the VMs shared the
laptop's physical CPU and memory, and they did not provide a real Intel GPU or
NPU device path.

#### SSH connection refused

An attempt to connect to the worker returned:

```text
ssh: connect to host 192.168.88.13 port 22: Connection refused
```

`192.168.x.x` is a private RFC 1918 address. The error meant the VM was
reachable but no SSH service was accepting connections, or the VM firewall was
rejecting the port. The fix path was to verify the VM was running, install or
start `sshd`, allow TCP 22, and confirm the VM network adapter was on the
expected private network.

#### NodePort and empty endpoints

The k3s version used a NodePort such as `worker-ip:30080`. NodePort is a stable
port on nodes; it is not the same as a production cloud load balancer. A
Service with no ready endpoints still cannot route traffic.

The useful checks were:

```text
kubectl get pods -o wide
kubectl describe pod <pod>
kubectl get service <service>
kubectl get endpoints <service>
kubectl get events --sort-by=.lastTimestamp
```

An empty Endpoint object meant that the Service selector did not currently
have a ready pod. The application could be listening inside a container while
the Service correctly refused to route to it.

#### PVC capacity could not be reduced

Kubernetes rejected an attempt to reduce a PVC request below its existing
capacity:

```text
spec.resources.requests.storage: Forbidden: field can not be less than status.capacity
```

A bound volume cannot be shrunk by editing the claim. The choices are to keep
the existing size, create a new larger claim, or delete and recreate the
volume when data can safely be discarded.

#### Model memory failure

The larger Phi-3 model caused the pod to enter `OOMKilled`. This was a real
capacity failure, not a Kubernetes networking failure. The model, runtime,
KV-cache behavior, and request concurrency all consume memory.

The POC moved to the smaller:

```text
OpenVINO/Phi-3-mini-FastDraft-50M-int8-ov
```

It reached `AVAILABLE` and was a better fit for the VM.

#### CPU instruction failure under virtualization

The smaller model still produced an inference-time failure in the
PagedAttention/BRGEMM path:

```text
cannot be executed due to invalid brgemm params
```

The pod could report ready while a real generation request still crashed. The
logs showed that this was CPU execution compatibility under the virtualized
CPU, not a Service problem.

The workaround made the oneDNN instruction ceiling explicit:

```text
ONEDNN_MAX_CPU_ISA=AVX2
DNNL_MAX_CPU_ISA=AVX2
```

This is useful for a constrained VM lab, but it is not proof of optimal
hardware performance. On real Intel hardware, the supported driver, CPU
features, OpenVINO version, model format, and target device still need to be
benchmarked.

#### Benchmark destabilized the pod

The k3s benchmark could make the inference container fail even after a single
smoke request worked. The corrected sequence was:

1. Check model availability.
2. Run one request.
3. Watch restarts and logs.
4. Run a small benchmark.
5. Increase load only after the capacity limit is understood.

The lesson was that readiness proves traffic eligibility, not safe throughput.

### Phase 4: AWS Network Foundation

The AWS design used one VPC in `ap-south-1` with two Availability Zones.

The learning VPC values were:

| Resource | Learning value |
| --- | --- |
| VPC | `10.0.0.0/16` |
| Private subnet A | `10.0.128.0/20` in `ap-south-1a` |
| Private subnet B | `10.0.144.0/20` in `ap-south-1b` |
| Public subnet A | `10.0.0.0/20` in `ap-south-1a` |
| Public subnet B | `10.0.16.0/20` in `ap-south-1b` |
| Kubernetes Service CIDR | `172.20.0.0/16` |

The private subnets hosted worker nodes. Public subnets hosted the Internet
Gateway path and the single NAT Gateway used during bootstrap. A route table
is associated with a subnet; a VPC itself is not directly attached to a route
table in the way a subnet is.

#### NAT Gateway versus VPC endpoints

The design used both because they solve different problems:

- NAT Gateway provides outbound access for destinations without a private VPC
  endpoint. It is useful but carries hourly and data-processing cost.
- The S3 gateway endpoint adds private S3 routes to a route table and does not
  create an ENI or require an endpoint security group.
- Interface endpoints create ENIs with private IPs in selected subnets. Private
  DNS resolves normal AWS service hostnames to those private IPs.
- Interface endpoints require a security group because they accept HTTPS
  connections. They do not require a special endpoint route table because the
  normal VPC local route reaches their private ENIs.

The interface endpoints used for the POC included ECR API, ECR Docker, EC2,
Secrets Manager, STS, CloudWatch Logs, CloudWatch Monitoring, and EKS Auth.
They were placed in both private subnets for Availability Zone locality and
survivability, at the cost of additional PrivateLink ENIs.

#### AWS console concepts that caused confusion

An EKS control plane is managed by AWS. It is not a pair of EC2 control-plane
instances that the user creates and SSHs into. The user still creates or
selects worker capacity through managed node groups, self-managed nodes, or
EKS Auto Mode.

Auto Mode is an AWS-managed way to provision and manage node capacity. It is
not the same as the EKS control plane. Standard EKS with a managed node group
was easier to reason about for this learning project because node type,
labels, disk size, and scaling were explicit.

The initial production-shaped design discussed separate platform and inference
node groups. The low-cost AWS demo reduced this to one `m7i.xlarge` inference
node because the account had a tight EC2 vCPU quota.

### Phase 5: AWS Quota And Node-Group Problems

#### Free Tier eligibility versus credits

The console rejected an instance with:

```text
The specified instance type is not eligible for Free Tier
```

Account credits can offset eligible charges, but credits do not make an
instance Free Tier eligible. A separate EC2 service quota can still block the
launch.

#### Eight-vCPU quota

The node group also failed with:

```text
VcpuLimitExceeded
current vCPU limit of 8
```

Two running `t3.medium` instances already consumed 4 vCPUs. An `m7i.xlarge`
uses 4 vCPUs, so one inference node fits exactly under an 8-vCPU quota. Two
`m7i.xlarge` workers would need 8 vCPUs by themselves and would exceed the
quota once the existing instances were counted.

The important interview distinction is:

- EKS control-plane management does not mean EC2 control-plane instances are
  consuming this node quota.
- Worker instances and Auto Mode capacity do consume EC2 capacity and quotas.
- Billing credits do not remove service-quota limits.

#### Node group stuck in CREATING or DELETING

The console showed a node group stuck in `CREATING` with no Auto Scaling Group
listed yet. Manually deleting the Auto Scaling Group made the situation worse:
EKS still owned the node-group operation and could become stuck trying to
reconcile a resource that had been removed behind its back.

The safe operational rule is to delete managed node groups through EKS, wait
for the EKS operation to finish, and only then delete the cluster. Do not
delete the backing Auto Scaling Group directly while EKS owns it.

#### NodeCreationFailure: instance did not join

One instance was running but EKS reported:

```text
NodeCreationFailure
Instances failed to join the Kubernetes cluster
```

The node console output identified the root cause:

```text
EC2: DescribeInstances ... context deadline exceeded
SSM Agent unable to acquire credentials ... ssm.ap-south-1.amazonaws.com ... i/o timeout
```

The instance had a private address and could not reach required AWS APIs. The
fix was to verify private-subnet egress, NAT routes, interface endpoints,
endpoint private DNS, endpoint security-group rules, and the node role. The
EC2 and EKS Auth endpoints were especially important for the bootstrap path.

The useful evidence chain was:

```text
aws eks describe-nodegroup
aws ec2 describe-instances
aws ec2 get-console-output
kubectl get nodes
kubectl get events -n kube-system
```

Once the network path was corrected, the node joined and became `Ready`.

#### CoreDNS and Metrics Server showed Degraded

The add-ons reported `InsufficientNumberOfReplicas` and `no nodes available to
schedule pods`. This was expected while the node group had no joined worker.
CoreDNS and Metrics Server pods were `Pending` with no node assigned.

After the worker became `Ready`, both add-ons scheduled and reported `Running`.
The lesson was to distinguish an add-on health symptom from the scheduling
root cause.

#### EBS CSI controller initially crashed

The EBS CSI controller briefly showed `1/6`, `Error`, and `CrashLoopBackOff`.
The node-side CSI pod was running. After the managed add-on and its Pod
Identity association settled, the controller reached `6/6 Running`.

The final storage checks were:

```powershell
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
kubectl get storageclass
```

The StorageClass needed to use `ebs.csi.aws.com` for EBS dynamic provisioning.

### Phase 6: AWS Add-ons, Secrets, And Workload Identity

The first Secrets Store CSI attempt used the upstream Helm chart. It created
resources that later conflicted with the AWS-managed add-on:

```text
ConfigurationConflict
ClusterRole ... metadata.labels.app.kubernetes.io/instance
CSIDriver ... metadata.labels.app.kubernetes.io/instance
```

The clean ownership rule became: use one owner. For EKS, the AWS-managed
`aws-secrets-store-csi-driver-provider` add-on is the preferred owner for the
driver/provider components. Do not install the same components through Helm
at the same time.

The workload identities were separated:

| Service account | AWS permission |
| --- | --- |
| `llm-gateway` | Read the one Secrets Manager API-key secret |
| `ovms-model-reader` | List and read only the model prefix in S3 |
| `aws-load-balancer-controller` | Manage the internal ALB resources |
| `ebs-csi-controller-sa` | Provision and attach EBS volumes |

An EKS Pod Identity association connects a namespace and service account to a
role. The API key is not stored in Git, an image, or a normal ConfigMap. It is
mounted by Secrets Store CSI at `/mnt/secrets-store/api-key`.

### Phase 7: Artifact And Application Deployment

The deployment order was intentionally dependency-driven.

#### Model artifact

The model was stored under:

```text
s3://<model-bucket>/OpenVINO/Phi-3.5-mini-instruct-int4-ov/
```

The OVMS StatefulSet uses an init container with the `ovms-model-reader`
identity. The init container synchronizes the model from S3 into an EBS-backed
PVC. OVMS then serves the local filesystem path.

This avoids making every request dependent on S3 and gives OVMS the filesystem
layout it expects. S3 is the durable source; EBS is the per-pod cache.

#### Gateway image

The gateway image was built locally and pushed to private ECR. The final
deployment should use an immutable digest, not a mutable `latest` tag:

```powershell
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$REGISTRY = "$ACCOUNT_ID.dkr.ecr.ap-south-1.amazonaws.com"

aws ecr get-login-password --region ap-south-1 |
  docker login --username AWS --password-stdin $REGISTRY

docker build -t "$REGISTRY/openvino-llm-gateway:0.1.0" .\gateway
docker push "$REGISTRY/openvino-llm-gateway:0.1.0"
```

After the push, query the digest and place that digest in the Terraform input
or rendered manifest. This prevents a tag from silently changing the runtime.

#### Kubernetes application order

The reliable order was:

1. Create the cluster and wait for the worker to be `Ready`.
2. Confirm CoreDNS, VPC CNI, Pod Identity, Metrics Server, EBS CSI, and
   Secrets Store CSI are healthy.
3. Apply the `gp3` StorageClass and namespace.
4. Apply gateway configuration.
5. Apply blue and green OVMS StatefulSets.
6. Apply the SecretProviderClass and gateway Deployment/Service.
7. Apply HPA, PDB, and finally the Ingress after the controller and ALB
   security group are ready.
8. Wait for OVMS `/v1/config` to report `AVAILABLE`.
9. Run one direct smoke request before benchmarking.
10. Test the internal ALB from the private network.

The renderer at `scripts/render-aws-manifests.ps1` fills account-specific
Terraform outputs such as the ECR image reference, S3 bucket, model prefix,
secret name, AWS region, and ALB security-group ID. It writes to an ignored
directory and leaves source manifests unchanged.

### Phase 8: AWS Request Path And Validation

The final request path is:

```text
Private client
  -> internal AWS ALB
  -> Kubernetes Ingress
  -> gateway ClusterIP Service
  -> FastAPI gateway pod
  -> active OVMS ClusterIP Service
  -> OVMS model on CPU
```

The ALB is the application load balancer. The EKS API endpoint is a separate
control-plane endpoint and is not an application load balancer. The Kubernetes
Service provides stable internal discovery; it does not replace the ALB.

The validation sequence was:

```powershell
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide
kubectl get pods,pvc -n llm-inference
kubectl get endpoints -n llm-inference
kubectl logs -n llm-inference statefulset/ovms-blue -c sync-model
kubectl logs -n llm-inference statefulset/ovms-blue -c ovms
```

Then:

1. Check `/v1/config` inside the cluster.
2. Port-forward the gateway for a direct smoke request.
3. Run a small benchmark with a bounded run count.
4. Check latency, token counts, restarts, and memory.
5. Test the internal ALB only from a private path.

The HPA was defined and discussed as a Kubernetes capability. A serious
model-serving HPA test was not performed. For a reliable demo, `minReplicas: 1`
is safer. A scale-to-zero HPA with `maxReplicas: 1` can produce cold starts and
cannot reliably use ordinary CPU metrics when there are zero pods; true
scale-to-zero normally needs an external metric or event-driven scaler.

### Terraform: Adoption And Clean Rebuild

The repository now has two Terraform roots:

| Root | Owns |
| --- | --- |
| `terraform/aws` | VPC, subnets, routes, NAT, endpoints, EKS, node group, IAM, add-ons, ECR, S3, and secret metadata |
| `terraform/platform` | AWS Load Balancer Controller Helm release |

The adoption design was created because the first AWS environment was built
manually. Its read-only plan showed:

```text
65 to import, 0 to add, 0 to change, 0 to destroy
```

The platform adoption plan showed:

```text
1 to import, 0 to add, 0 to change, 0 to destroy
```

Those plans were reviewed but not applied. After the AWS resources were
deleted, the correct path is a clean build:

```powershell
adopt_existing = false
```

Do not reuse `adoption.tfvars.example`; it contains old resource IDs and
`adopt_existing = true`.

The clean-build workflow is:

```powershell
terraform -chdir=terraform/aws init -backend=false
terraform -chdir=terraform/aws validate
terraform -chdir=terraform/aws plan -var-file=clean.tfvars -out=clean.tfplan
terraform -chdir=terraform/aws apply clean.tfplan
```

The plan should contain creates, zero imports, and zero destroys. Then obtain
the new VPC ID, configure the platform Terraform root with
`adopt_existing = false`, install the AWS Load Balancer Controller, push the
new gateway image, recreate the secret value, upload the model, render the
manifests, and deploy the Kubernetes application.

Important clean-build boundaries:

- Terraform creates the Secrets Manager secret container, not the secret value.
  Keep the value out of Terraform state and create it separately.
- Terraform creates the S3 bucket, not the model files.
- Terraform creates the ECR repository, not the image. Build and push the
  gateway after the repository exists.
- The current AWS root reads the AWS Load Balancer Controller IAM policy as a
  data source. Verify that policy exists or add it to the clean-build
  bootstrap before applying.
- EBS CSI requires a Pod Identity role with the EBS CSI policy. Supply or
  create that role before relying on EBS PVC provisioning.
- If the EKS API is public during laptop bootstrap, restrict the public CIDR
  to the administrator's `/32` rather than `0.0.0.0/0`. Disable public access
  after a VPN, Direct Connect path, or VPC-connected runner can reach the
  private endpoint.

Terraform uses local state in this POC. A future production version should use
an encrypted remote backend with locking and a controlled state-access policy.

### Cleanup And Cost Control

The cost-heavy resources were EKS, EC2 worker nodes, NAT Gateway, interface
endpoints, and the internal ALB. The cleanup order matters:

1. Delete Kubernetes Ingress and workloads so the ALB controller can remove the
   ALB.
2. Delete managed node groups through EKS.
3. Delete the EKS cluster.
4. Delete the NAT Gateway and release its Elastic IP.
5. Delete interface and gateway endpoints.
6. Empty and delete the S3 bucket.
7. Delete ECR images and repository.
8. Delete the secret, using immediate deletion only when the name must be
   reused right away.
9. Delete the VPC only after dependent ENIs, subnets, route tables, and
   security groups are gone.

Do not delete a managed node group's backing Auto Scaling Group directly. Do
not run `terraform destroy` against a manually created environment that has
not been imported into the Terraform state. Once Terraform owns a clean-build
environment, destroy the platform root first and the AWS root second, after
emptying S3 and handling ECR images.

### Troubleshooting Playbook Used Throughout

The same diagnostic order worked across Docker, Minikube, k3s, and EKS:

1. **Is the process or pod running?** Check container/pod state and restarts.
2. **Why did it stop?** Check termination reason and previous logs.
3. **Can it be scheduled?** Check node readiness, taints, selectors, requests,
   limits, and events.
4. **Can the Service route?** Check selectors, ready conditions, Endpoints, and
   EndpointSlices.
5. **Is the model ready?** Check `/v1/config` and OVMS initialization logs.
6. **Can the client reach it?** Check port-forward, NodePort tunnel, ALB DNS,
   security groups, routes, and private-network access.
7. **Does one request work?** Run a smoke request before a benchmark.
8. **Does load remain safe?** Watch memory, CPU, cache usage, latency, and
   restart count while increasing load gradually.

The following is the quick error map. The detailed interview-ready resolution
strategy follows it. In every case, the useful structure is:

```text
symptom -> evidence collected -> root cause -> smallest safe fix -> validation
```

| Symptom | Meaning | Correct next check |
| --- | --- | --- |
| `Mediapipe graph ... not found` | Model graph not loaded yet | `/v1/config` and model logs |
| `ErrImagePull` | Image tag or registry access problem | Pod events and image reference |
| `ImagePullBackOff` | Kubelet is backing off repeated pulls | Original pull error |
| `CrashLoopBackOff` | Process starts and exits repeatedly | Current and previous logs |
| `Pending` | Scheduler cannot place the pod | Events, nodes, requests, selectors |
| Empty Service endpoints | No ready pod matches the selector | Labels and readiness probe |
| `OOMKilled` | Memory capacity was exceeded | Limits, model size, concurrency |
| BRGEMM/PagedAttention error | CPU/runtime compatibility or execution issue | OVMS logs and CPU features |
| CoreDNS degraded | Usually no schedulable worker | Add-on health plus node state |
| NodeCreationFailure | Instance booted but did not join | nodeadm output, IAM, network |
| PVC shrink forbidden | Bound volume cannot be reduced | Keep, replace, or recreate PVC |
| Endpoint `ConfigurationConflict` | Two managers own one resource | Select one owner: Helm or add-on |

### Resolution Strategies In Interview Language

#### `Mediapipe graph definition ... not found`

**What I checked:** I checked the OVMS container logs and queried
`/v1/config`. The REST process was listening, but the model was still being
downloaded and initialized. The logs showed Git LFS retrieving the large model
files, while `/v1/config` was still `{}` or did not contain an `AVAILABLE`
model.

**Resolution strategy:** I did not treat an open port as model readiness. I
waited for the model version to report `AVAILABLE`, then made the Kubernetes
startup and readiness probes depend on `/v1/config`. The chat request was only
tested after that condition was true.

**Interview version:**

> The graph-not-found response was caused by sending traffic before OVMS had
> completed model initialization. I verified that from the logs and
> `/v1/config`, then used model availability as the readiness gate instead of
> merely checking whether port 8000 was open.

#### `ErrImagePull` and `ImagePullBackOff`

**What I checked:** I used `kubectl describe pod` and read the Events section
instead of starting with application logs. The event identified the exact
image reference and returned `manifest unknown` for
`openvino/model_server:2025.4-py`.

**Resolution strategy:** I replaced the invalid image reference with an
available OVMS image. I then watched the pod transition from pulling to
running and verified model availability. `ImagePullBackOff` was treated as a
retry symptom; the original pull error was the useful diagnosis. For the AWS
path I moved toward digest-pinned images so a tag could not silently change.

**Interview version:**

> I diagnosed the image pull failure from kubelet events. The image tag did not
> exist in the registry, so changing application configuration would not have
> helped. I corrected the image reference, verified the rollout, and used an
> immutable digest in the AWS design.

#### `CrashLoopBackOff`

**What I checked:** I inspected the current and previous container logs,
`kubectl describe pod`, the termination reason, restart count, resource limits,
and the last cluster events. I separated an application crash, an OOM kill, a
CPU/runtime failure, and a failed model initialization instead of treating all
CrashLoopBackOff events as the same problem.

**Resolution strategy:** I fixed the cause indicated by the evidence. That
could mean correcting the model path, selecting a valid image, increasing
available capacity, using a smaller model, or constraining CPU instructions in
the VM lab. I then deleted or rolled the pod only after the configuration was
correct and validated with one request.

**Interview version:**

> CrashLoopBackOff was only the controller's summary. I looked at the previous
> container termination and logs to identify the real cause, fixed that cause,
> and then used a single smoke request before applying benchmark load.

#### `Pending`

**What I checked:** I read the scheduling Events and compared the pod's
`nodeSelector`, taints, CPU and memory requests, PVC state, and available node
capacity. In the AWS cluster, CoreDNS and Metrics Server were Pending because
there was no joined worker node.

**Resolution strategy:** I fixed the scheduling prerequisite rather than
editing the pod blindly. That meant making a worker `Ready`, correcting labels,
choosing an instance with enough headroom, or resolving a PVC/storage
dependency. After the worker joined, the system add-ons scheduled normally.

**Interview version:**

> I used the scheduler events to identify why the pod had no placement. The
> root cause was missing usable node capacity, not a CoreDNS configuration
> problem. Once the worker became Ready, the Pending system pods scheduled and
> recovered without changing their manifests.

#### Empty Service endpoints

**What I checked:** I compared the Service selector with the pod labels and
checked readiness state, Endpoints, and EndpointSlices. A pod can be running
and listening while still be excluded from a Service because its readiness
probe has not passed.

**Resolution strategy:** I corrected label/selector mismatches and waited for
the readiness check to pass. If the pod was not ready, I debugged the pod
itself. I did not blame the Service or expose a new NodePort before proving
that a ready endpoint existed.

**Interview version:**

> The Service had no endpoints because Kubernetes had no ready pod matching its
> selector. I verified labels and readiness, fixed the underlying pod problem,
> and confirmed the endpoint list before testing client connectivity.

#### `OOMKilled`

**What I checked:** I used the pod's last termination reason and compared the
model size, runtime initialization, KV-cache behavior, request concurrency,
memory request, memory limit, and node allocatable memory.

**Resolution strategy:** I selected the smaller quantized FastDraft model for
the constrained VM and kept explicit requests and limits. I treated simply
raising a container limit as insufficient if the node did not have the
capacity. On a real deployment I would size the node and concurrency from
measured model memory and throughput, not from the model file size alone.

**Interview version:**

> OOMKilled showed that the model workload exceeded available memory. I
> separated model weights from runtime and cache overhead, selected a smaller
> model for the lab, and would use measured concurrency and KV-cache behavior
> to size production nodes.

#### BRGEMM or PagedAttention execution failure

**What I checked:** The model reached `AVAILABLE`, so I separated model
loading from request execution. The OVMS logs pointed to an Intel CPU
BRGEMM/PagedAttention initialization failure under the virtual CPU.

**Resolution strategy:** I constrained oneDNN to AVX2 in the VM lab using
`ONEDNN_MAX_CPU_ISA=AVX2` and `DNNL_MAX_CPU_ISA=AVX2`. That made the lab
environment stable enough for the small model. I treated it as a virtualization
and CPU-runtime compatibility workaround, not as proof that the same setting
is optimal on physical Intel hardware.

**Interview version:**

> The server was ready but inference still failed, so I did not continue
> debugging Kubernetes networking. The stack trace identified a CPU kernel
> compatibility issue under virtualization. I constrained oneDNN to AVX2 for
> the lab and would validate the native instruction set and OpenVINO runtime on
> production Intel hardware.

#### CoreDNS or Metrics Server `DEGRADED`

**What I checked:** I queried the add-on health, listed the pods in
`kube-system`, and read events. The add-on message said all replicas were
unscheduled because no nodes were available.

**Resolution strategy:** I fixed the worker node group and network bootstrap
first. Once a node joined and became `Ready`, CoreDNS and Metrics Server
scheduled and became healthy. The add-on status was a symptom of missing
capacity, not evidence that both add-ons needed to be reinstalled.

**Interview version:**

> CoreDNS and Metrics Server were degraded because their pods had nowhere to
> schedule. I traced the condition back to the failed worker join, repaired
> node bootstrap, and confirmed the add-ons recovered after the node became
> Ready.

#### `NodeCreationFailure`

**What I checked:** I compared the EKS node-group health, EC2 instance state,
instance security group, private IP, node console output, and the EKS access
entry. The node console showed `nodeadm` timing out on EC2 `DescribeInstances`
and the SSM agent timing out to the regional SSM endpoint.

**Resolution strategy:** I repaired the private-subnet network path: route
tables, NAT or required interface endpoints, private DNS, endpoint security
groups, node IAM permissions, and EKS Auth reachability. I did not recreate
Kubernetes objects because the failure occurred before the node could join.
After the network path was available, the same node bootstrap completed and
`kubectl get nodes` showed `Ready`.

**Interview version:**

> The EC2 instance was running, but the node had not joined Kubernetes. The
> nodeadm console output showed AWS API timeouts, so I traced the issue through
> private-subnet routing, endpoints, security groups, and node IAM. The fix was
> network/bootstrap access, not a Kubernetes Deployment change.

#### PVC shrink forbidden

**What I checked:** I compared the requested PVC size with the bound volume's
`status.capacity` and checked whether the data could be discarded.

**Resolution strategy:** Kubernetes does not shrink a bound volume by lowering
the request. I kept the existing claim, increased it when necessary, or
created a replacement claim when the cache was disposable. For a model cache,
recreation is often acceptable; for persistent application data it requires a
backup and migration plan.

**Interview version:**

> The PVC error was a storage lifecycle constraint: the claim was already
> bound at a larger capacity. I did not force-edit it downward. I either kept
> the capacity or recreated the disposable model cache with the intended size.

#### `ConfigurationConflict` between Helm and an EKS add-on

**What I checked:** I identified which resources already had Helm ownership
labels and compared them with the AWS-managed add-on resources. The conflict
was caused by two deployment managers trying to own the same ClusterRoles,
bindings, CSIDriver, and CRDs.

**Resolution strategy:** I selected one owner. For the AWS deployment I used
the EKS-managed Secrets Store CSI provider add-on and removed the self-managed
Helm ownership rather than applying both. I then verified the add-on status,
CSI driver, CRD, and running pods.

**Interview version:**

> The conflict was an ownership problem, not a permissions problem. Helm and
> the AWS-managed add-on were managing the same Kubernetes objects. I chose one
> owner, removed the competing installation, and verified the resulting
> driver and provider pods.

### Additional Incidents Worth Mentioning

#### `K8S_APISERVER_MISSING` in Minikube

The Minikube storage add-ons failed with connection refused to `localhost:8443`
because the API server process never appeared. I treated this as a cluster
bootstrap failure, checked Minikube status and driver logs, and restarted or
recreated the local cluster before applying workloads. The interview lesson
is to verify the control plane before debugging application YAML.

#### `Unable to connect to the remote server` from Minikube

The pod was healthy, but the client used an old dynamic tunnel port returned by
`minikube service --url`. I regenerated the URL and kept the tunnel terminal
open. The interview lesson is to separate the Kubernetes Service from the
local exposure mechanism.

#### `VcpuLimitExceeded` and Free Tier errors

The EC2 launch failed first because the selected instance was not Free Tier
eligible and later because the Standard instance bucket had an 8-vCPU limit.
I checked existing EC2 usage, counted the vCPUs required by the node group, and
reduced the demo to one `m7i.xlarge`. Credits could offset cost but could not
override the quota. The interview lesson is to check both pricing eligibility
and service quotas before choosing a node type.

#### Node group stuck after manual Auto Scaling Group deletion

The backing Auto Scaling Group was deleted directly while EKS still believed it
owned the node group. I learned to use EKS for managed node-group lifecycle and
to wait for the EKS operation rather than deleting a dependent AWS resource
behind its back. This is a useful example of respecting the control plane's
ownership boundary.

#### Benchmark caused a healthy inference pod to fail

I first proved the request path with one smoke request, then watched logs,
memory, restarts, and OVMS cache usage while increasing the run count. The
benchmark exposed capacity and runtime limits that readiness did not. The
interview lesson is that functional validation and performance validation are
different test classes.

### Interview Answers To Rehearse

#### What did you actually build?

I built a layered inference platform. OVMS executes an OpenVINO-optimized
model, a FastAPI gateway provides the client contract and authentication, and
Kubernetes manages placement, health, storage, and recovery. I validated the
serving path locally through Docker, Minikube, and k3s, then implemented the
private AWS EKS architecture with Terraform, managed add-ons, EKS Pod Identity,
S3, EBS, Secrets Manager, ECR, and an internal ALB. The AWS environment was
later deleted, so the next run is a Terraform clean build rather than a claim
of an always-running production service.

#### Why did you not expose OVMS directly?

The gateway is the trust and policy boundary. It validates the API key and
request shape, hides the blue/green backend choice, translates upstream
failures, and gives clients a stable API. OVMS remains an internal model
server, not the public application boundary.

#### What did the hardest failure teach you?

A pod being `Running` or a port being open does not prove inference works. The
project had to distinguish image availability, model availability, Service
readiness, node capacity, and actual request execution. The most useful
diagnosis came from combining events, logs, endpoint state, resource status,
and a single smoke request.

#### Why are S3 and EBS both present?

S3 is the durable, centrally managed source of model artifacts. EBS provides a
writable, low-latency local cache for the OVMS pod. The init container copies
from S3 to EBS before OVMS starts. This improves runtime behavior but introduces
Availability Zone and ReadWriteOnce recovery considerations.

#### Why did you choose Pod Identity?

It maps a Kubernetes service account to a dedicated IAM role without putting
long-lived credentials in the pod or granting every workload the node role.
Gateway, OVMS, the ALB controller, and EBS CSI each receive separate AWS
permissions. IRSA is the OIDC-based alternative and is also important to know,
but the current AWS design uses Pod Identity.

#### Did you validate GPU or NPU inference?

No. The project validates Intel CPU inference. A GPU/NPU version would require
the host driver stack, a supported Intel device plugin, node labels/taints,
resource requests, container device access, the correct OVMS target device,
and hardware-specific performance tests.

#### Did you solve KV-cache sizing?

No. The POC set conservative resource limits and observed OVMS cache logs, but
production capacity still requires model-specific measurements of context
length, concurrency, batch size, KV-cache usage, memory, latency, and
throughput. Kubernetes cannot infer a safe model-serving capacity from a CPU
request alone.

#### Why is the HPA not enough for OVMS?

The HPA is useful for the stateless gateway, where CPU utilization is a rough
signal. Inference capacity is better described by queue depth, concurrent
requests, token throughput, latency, and model memory. Scaling OVMS also has
startup, model-download, EBS, and hardware-capacity costs. The POC keeps OVMS
replica changes explicit through blue-green promotion.

#### What remains before production?

The next work is a real Terraform clean build, private-only EKS API access
from the Intel DMZ/VPN, TLS and corporate identity, complete metrics/logs/
traces, model-aware scaling, image and model promotion, NetworkPolicies,
backup/restore, node-drain and Availability Zone failure testing, and measured
capacity on the target Intel hardware.
