#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:?namespace required}"
SERVICE_ACCOUNT="${2:?service account required}"
ROLE="${3:-${SERVICE_ACCOUNT}}"
VAULT_ADDR_INPUT="${4:-${VAULT_ADDR:-http://192.168.178.41:8200}}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is required for Vault Kubernetes auth validation"
  exit 127
fi

if ! command -v vault >/dev/null 2>&1; then
  echo "WARNING: vault CLI not found; skipping Vault Kubernetes login check"
  exit 0
fi

export VAULT_ADDR="${VAULT_ADDR_INPUT}"

echo "Validating Vault Kubernetes login for service account ${SERVICE_ACCOUNT} with role ${ROLE} via ${VAULT_ADDR}"
JWT="$(kubectl -n "${NAMESPACE}" create token "${SERVICE_ACCOUNT}")"
vault write -address="${VAULT_ADDR}" -field=token auth/kubernetes/login role="${ROLE}" jwt="${JWT}" >/dev/null
echo "Vault Kubernetes login check passed for role ${ROLE}"
