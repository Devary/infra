#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:?namespace required}"
SERVICE_ACCOUNT="${2:?service account required}"
ROLE="${3:-${SERVICE_ACCOUNT}}"
VAULT_ADDR_INPUT="${4:-${VAULT_ADDR:-http://192.168.178.41:8200}}"
SECRET_MOUNT="${5:-anipoll}"
SECRET_PATH="${6:-${ROLE}}"
POLICY_NAME="${7:-${ROLE}}"
REVIEWER_SA="${8:-vault-auth-reviewer}"
REVIEWER_BINDING="vault-auth-reviewer-${NAMESPACE}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is required for Vault Kubernetes auth bootstrap"
  exit 127
fi

if ! command -v vault >/dev/null 2>&1; then
  echo "WARNING: vault CLI not found; skipping Vault Kubernetes auth bootstrap"
  exit 0
fi

export VAULT_ADDR="${VAULT_ADDR_INPUT}"

KUBE_HOST="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
KUBE_CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
KUBE_CA_FILE="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')"

if [[ -n "${KUBE_CA_DATA}" ]]; then
  KUBE_CA_CERT="$(printf '%s' "${KUBE_CA_DATA}" | base64 -d)"
elif [[ -n "${KUBE_CA_FILE}" && -f "${KUBE_CA_FILE}" ]]; then
  KUBE_CA_CERT="$(cat "${KUBE_CA_FILE}")"
else
  KUBE_CA_CERT=""
fi

if [[ -z "${KUBE_HOST}" || -z "${KUBE_CA_CERT}" ]]; then
  echo "ERROR: unable to resolve Kubernetes API host or CA from kubectl config"
  exit 1
fi

kubectl -n "${NAMESPACE}" get serviceaccount "${REVIEWER_SA}" >/dev/null 2>&1 || \
  kubectl -n "${NAMESPACE}" create serviceaccount "${REVIEWER_SA}" >/dev/null

kubectl get clusterrolebinding "${REVIEWER_BINDING}" >/dev/null 2>&1 || \
  kubectl create clusterrolebinding "${REVIEWER_BINDING}" \
    --clusterrole=system:auth-delegator \
    --serviceaccount="${NAMESPACE}:${REVIEWER_SA}" >/dev/null

REVIEWER_JWT="$(kubectl -n "${NAMESPACE}" create token "${REVIEWER_SA}")"

vault auth enable kubernetes >/dev/null 2>&1 || true
vault write -address="${VAULT_ADDR}" auth/kubernetes/config \
  kubernetes_host="${KUBE_HOST}" \
  token_reviewer_jwt="${REVIEWER_JWT}" \
  kubernetes_ca_cert="${KUBE_CA_CERT}" >/dev/null

cat <<EOF | vault policy write "${POLICY_NAME}" - >/dev/null
path "${SECRET_MOUNT}/data/${SECRET_PATH}" {
  capabilities = ["read"]
}

path "${SECRET_MOUNT}/metadata/${SECRET_PATH}" {
  capabilities = ["read", "list"]
}
EOF

vault write -address="${VAULT_ADDR}" "auth/kubernetes/role/${ROLE}" \
  bound_service_account_names="${SERVICE_ACCOUNT}" \
  bound_service_account_namespaces="${NAMESPACE}" \
  token_policies="${POLICY_NAME}" \
  ttl="24h" >/dev/null

echo "Vault Kubernetes auth configured for role ${ROLE}, service account ${SERVICE_ACCOUNT}, namespace ${NAMESPACE}, secret ${SECRET_MOUNT}/${SECRET_PATH}"
