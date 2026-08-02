# Low-Cost Private DMZ Demo Design

## Goal

Make the AWS EKS OpenVINO LLM POC reliable enough for a first demo while
keeping the architecture private-only and cost-conscious.

The target deployment environment is an Intel DMZ VPN-connected laptop or
runner. That environment must be able to reach the private EKS API endpoint and
the internal ALB. The current learning cluster temporarily has public EKS API
access enabled; this must be disabled after a private administrative path is
available and before the POC is presented as private-only.

## Non-Goals

- Do not implement public EKS endpoint bootstrap.
- Do not make both blue and green OVMS stacks live by default.
- Do not claim GPU or NPU validation.
- Do not add GitHub Actions deployment in this phase.
- Do not add public internet access to the application gateway.

## Architecture

```text
Intel DMZ VPN-connected laptop or runner
        |
        | terraform, kubectl, smoke tests
        v
Private EKS API endpoint
        |
EKS cluster in private subnets
        |
Internal AWS ALB
        |
FastAPI gateway
        |
OVMS blue service -> OVMS blue StatefulSet -> EBS model cache
                                      |
                                      v
                              S3 model artifacts

OVMS green remains available as an optional standby manifest, scaled to zero
for the first low-cost demo.
```

## Capacity Sizing

The first demo uses blue as the only active inference stack.

- `ovms-blue` runs `1` replica by default.
- `ovms-green` runs `0` replicas by default.
- One `m7i.xlarge` node runs the Kubernetes system pods, one gateway replica,
  and the active OVMS pod.
- The gateway schedules on `nodepool=m7i-inference` for this single-node demo.
- OVMS requests `2` CPU and `6 GiB` memory, is limited to `3` CPU and `12 GiB`
  memory, and uses a `1 GiB` cache.
- The gateway HPA uses a minimum of `1` and maximum of `2` replicas.
- Blue-green promotion remains documented as a later operation: scale green up,
  verify it, update `OVMS_URL`, restart the gateway, then optionally scale blue
  down.

This removes the scheduling risk caused by the previous manifests requesting
more CPU and memory than the single `m7i.xlarge` can allocate.

## Model And Storage

- Use `OpenVINO/Phi-3.5-mini-instruct-int4-ov` as the standalone chat model.
- Do not use `Phi-3-mini-FastDraft-50M-int8-ov` as the served chat model; it is
  a draft model intended for speculative decoding with a target model.
- Store the approved model under
  `s3://openvino-llm-models-654158184275-ap-south-1/OpenVINO/Phi-3.5-mini-instruct-int4-ov/`.
- Use an encrypted `gp3` StorageClass backed by `ebs.csi.aws.com` and
  `WaitForFirstConsumer` for the OVMS model cache.
- Use EKS Pod Identity for the `llm-inference/ovms-model-reader` service account
  with read-only access to the exact S3 model prefix.

## Private Networking During Bootstrap

The live demo VPC uses private subnets and private AWS service endpoints. The
EC2 and EKS Auth interface endpoints are required for node bootstrap and Pod
Identity respectively. A public NAT Gateway is temporarily available for
pulling public container images during this learning deployment. The gateway
application remains private behind an internal ALB.

For the production-shaped follow-up, mirror every runtime image into private
ECR, verify all required VPC endpoints, remove the private-subnet default route
to the NAT Gateway, and then delete the NAT Gateway.

## Terraform And Bootstrap Flow

Terraform keeps:

- `cluster_endpoint_private_access = true`
- `cluster_endpoint_public_access = false`

The runbook must clearly state that Terraform and Helm provider operations must
run from an environment connected to the Intel DMZ VPN or another route that can
reach the private EKS endpoint.

This design does not split Terraform into separate foundation and in-cluster
stacks yet. The single Terraform stack remains acceptable because the expected
execution environment can reach the private endpoint.

## EKS Version

Move the EKS control plane version from `1.31` to `1.36`, which is currently in
AWS EKS standard support.

The README/runbook should mention that the version was selected because AWS
currently lists it in standard support.

## Readiness Endpoint

Keep `/health` as a shallow liveness endpoint.

Add `/ready` to the gateway:

- returns unhealthy if the gateway API key is not configured or the secret file
  cannot be read
- checks OVMS availability through a lightweight GET to `/v1/config` derived
  from the configured chat completion URL
- returns a small JSON status object for demo/debug visibility

Kubernetes readiness probe and the ALB health check should use `/ready`.
Liveness should continue to use `/health` so temporary OVMS issues do not cause
gateway restarts.

## HPA And Metrics

The gateway HPA is useful for the production-shaped story, but it needs metrics.
Install `metrics-server` through Terraform and keep the gateway HPA.

For the low-cost first demo, OVMS HPA should not be presented as active scaling.
Remove OVMS HPAs from the default demo manifests. A min/max of `2/2` is not
meaningful autoscaling and should not be sold as such.

## Test Command Hygiene

The repo root should support a normal test command.

Add lightweight project configuration so this passes from the repository root:

```powershell
python -m pytest gateway/tests
```

The existing gateway tests should continue to pass from the `gateway` directory.

## Documentation Updates

Update README and the AWS runbook to reflect:

- low-cost private DMZ demo as the default path
- private-only EKS API
- Intel DMZ VPN-connected execution environment
- active blue OVMS, green scaled to zero
- readiness behavior
- root-level test command
- metrics-server/HPA behavior

## Acceptance Criteria

- Terraform config keeps EKS private-only and uses a standard-support EKS
  version.
- Default Kubernetes manifests schedule only one active OVMS inference pod.
- Gateway has separate `/health` and `/ready` endpoints.
- Gateway readiness probe and ALB health check use `/ready`.
- `metrics-server` is installed through Terraform.
- Gateway HPA remains supported.
- OVMS HPA is removed from the default demo manifests.
- `python -m pytest gateway/tests` passes from the repo root.
- YAML parses locally.
- PowerShell scripts parse locally.
- README and runbook match the implemented low-cost demo path.
