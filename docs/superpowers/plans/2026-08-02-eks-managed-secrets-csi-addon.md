# EKS-Managed Secrets CSI Add-on Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the self-managed Secrets Store CSI Helm releases with the AWS-managed EKS add-on.

**Architecture:** EKS owns the Secrets Store CSI driver and AWS provider through `aws-secrets-store-csi-driver-provider`. Terraform overwrites self-managed fields only during migration and preserves supported configuration during later updates.

**Tech Stack:** Terraform, AWS provider, Amazon EKS managed add-ons.

## Global Constraints

- Keep the Helm provider because other cluster components still use Helm.
- Do not run `terraform apply` against the manually created live cluster.
- Keep all changes local.

### Task 1: Replace Terraform Resource Ownership

**Files:**
- Modify: `terraform/aws/main.tf`
- Modify: `terraform/aws/variables.tf`

- [ ] Replace both Secrets Store Helm releases with one `aws_eks_addon` resource.
- [ ] Remove the unused Helm chart version variables.
- [ ] Run `terraform fmt -check` and `terraform validate` when Terraform is available.

### Task 2: Align The Deployment Guide

**Files:**
- Modify: `README.md`
- Modify: `docs/aws-eks-openvino-llm-poc.md`

- [ ] Replace Helm installation instructions with EKS managed add-on instructions.
- [ ] Document the one-time Helm-to-managed migration and live-resource import requirement.
- [ ] Verify that no Secrets Store Helm installation references remain.
