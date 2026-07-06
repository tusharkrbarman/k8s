#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-inference}"
LABEL_SELECTOR="${LABEL_SELECTOR:-app=ovms-llm,color=blue}"

echo "Current pods:"
kubectl get pods -n "${NAMESPACE}" -l "${LABEL_SELECTOR}" -o wide

pod="$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_SELECTOR}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${pod}" ]]; then
  echo "No pod found for selector ${LABEL_SELECTOR} in namespace ${NAMESPACE}." >&2
  exit 1
fi

echo "Deleting pod ${pod}..."
kubectl delete pod -n "${NAMESPACE}" "${pod}"

echo "Waiting for statefulset/ovms-blue to recover..."
kubectl rollout status statefulset/ovms-blue -n "${NAMESPACE}" --timeout=10m

echo "Recovered pods:"
kubectl get pods -n "${NAMESPACE}" -l "${LABEL_SELECTOR}" -o wide
