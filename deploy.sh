#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${RD_OPTION_WORKSPACE:-${WORKSPACE_DIR:-}}"

if [[ -n "${WORKSPACE_DIR}" ]]; then
  ROOT_DIR="${WORKSPACE_DIR}"
elif [[ -d "${SCRIPT_DIR}/k8s" ]]; then
  ROOT_DIR="${SCRIPT_DIR}"
elif [[ -d "$(pwd)/k8s" ]]; then
  ROOT_DIR="$(pwd)"
else
  ROOT_DIR="${SCRIPT_DIR}"
fi

K8S_DIR="${ROOT_DIR}/k8s"
DEPLOYMENT_TEMPLATE="${K8S_DIR}/deployment.yaml"
SERVICE_TEMPLATE="${K8S_DIR}/service.yaml"
INGRESS_TEMPLATE="${K8S_DIR}/ingress.yaml"
SERVICE_MONITOR_TEMPLATE="${K8S_DIR}/serviceMonitors/service-monitor.yaml"

if [[ -n "${RD_OPTION_IMAGE:-}" ]]; then
  IMAGE="${RD_OPTION_IMAGE:-}"
  TAG="${RD_OPTION_TAG:-latest}"
  NAMESPACE="${RD_OPTION_NAMESPACE:-default}"
  DEPLOYMENT="${RD_OPTION_DEPLOYMENT:-${RD_OPTION_IMAGE##*/}}"
  CONTAINER="${RD_OPTION_CONTAINER:-${RD_OPTION_IMAGE##*/}}"
  PORT="${RD_OPTION_PORT:-8080}"
  REPLICAS="${RD_OPTION_REPLICAS:-1}"
  VAULT_URL="${RD_OPTION_VAULTURL:-${VAULT_URL:-http://192.168.178.41:8200}}"
  SERVICE_ACCOUNT="${RD_OPTION_SERVICEACCOUNT:-${DEPLOYMENT}}"
  INGRESS_HOST="${RD_OPTION_INGRESSHOST:-${INGRESS_HOST:-${DEPLOYMENT}.192.168.178.41.nip.io}}"
  GRPC_INGRESS_HOST="${RD_OPTION_GRPCINGRESSHOST:-${GRPC_INGRESS_HOST:-grpc-${DEPLOYMENT}.192.168.178.41.nip.io}}"
  VAULT_KV_MOUNT="${RD_OPTION_VAULTKVMOUNT:-${VAULT_KV_MOUNT:-anipoll}}"
  VAULT_SECRET_PATH="${RD_OPTION_VAULTSECRETPATH:-${VAULT_SECRET_PATH:-${DEPLOYMENT}}}"
  VAULT_BOOTSTRAP_ENABLED="${RD_OPTION_VAULTBOOTSTRAP:-${VAULT_BOOTSTRAP_ENABLED:-true}}"
  SERVICE_MONITOR_ENABLED="${RD_OPTION_SERVICEMONITORENABLED:-${SERVICE_MONITOR_ENABLED:-true}}"
  MONITORING_NAMESPACE="${RD_OPTION_MONITORINGNAMESPACE:-${MONITORING_NAMESPACE:-monitoring}}"
  PROMETHEUS_RELEASE_LABEL="${RD_OPTION_PROMETHEUSRELEASELABEL:-${PROMETHEUS_RELEASE_LABEL:-prometheus}}"
  METRICS_PATH="${RD_OPTION_METRICSPATH:-${METRICS_PATH:-/${DEPLOYMENT}/q/metrics}}"
  PROJECT_VERSION="${RD_OPTION_PROJECTVERSION:-${PROJECT_VERSION:-${TAG}}}"
else
  IMAGE="${1:?image required}"
  TAG="${2:?tag required}"
  NAMESPACE="${3:-default}"
  DEPLOYMENT="${4:-service}"
  CONTAINER="${5:-service}"
  PORT="${6:-8080}"
  REPLICAS="${7:-1}"
  VAULT_URL="${8:-${VAULT_URL:-http://192.168.178.41:8200}}"
  SERVICE_ACCOUNT="${9:-${DEPLOYMENT}}"
  INGRESS_HOST="${10:-${INGRESS_HOST:-${DEPLOYMENT}.192.168.178.41.nip.io}}"
  GRPC_INGRESS_HOST="${11:-${GRPC_INGRESS_HOST:-grpc-${DEPLOYMENT}.192.168.178.41.nip.io}}"
  VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-anipoll}"
  VAULT_SECRET_PATH="${VAULT_SECRET_PATH:-${DEPLOYMENT}}"
  VAULT_BOOTSTRAP_ENABLED="${VAULT_BOOTSTRAP_ENABLED:-true}"
  SERVICE_MONITOR_ENABLED="${SERVICE_MONITOR_ENABLED:-true}"
  MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
  PROMETHEUS_RELEASE_LABEL="${PROMETHEUS_RELEASE_LABEL:-prometheus}"
  METRICS_PATH="${METRICS_PATH:-/${DEPLOYMENT}/q/metrics}"
  PROJECT_VERSION="${PROJECT_VERSION:-${TAG}}"
fi

FULL_IMAGE="${IMAGE}:${TAG}"
ROLLOUT_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 is required"; exit 127; }
}

render_apply() {
  local template="$1"
  shift
  sed "$@" "${template}" | kubectl apply -f -
}

apply_service_monitor() {
  [[ "${SERVICE_MONITOR_ENABLED}" == "true" ]] || {
    echo "Skipping ServiceMonitor apply (SERVICE_MONITOR_ENABLED=${SERVICE_MONITOR_ENABLED})"
    return
  }

  [[ -f "${SERVICE_MONITOR_TEMPLATE}" ]] || {
    echo "ERROR: ServiceMonitor template not found at ${SERVICE_MONITOR_TEMPLATE}"
    exit 1
  }

  render_apply "${SERVICE_MONITOR_TEMPLATE}" \
    -e "s|__DEPLOYMENT__|${DEPLOYMENT}|g" \
    -e "s|__NAMESPACE__|${NAMESPACE}|g" \
    -e "s|__METRICS_PATH__|${METRICS_PATH}|g" \
    -e "s|namespace: monitoring|namespace: ${MONITORING_NAMESPACE}|" \
    -e "s|release: prometheus|release: ${PROMETHEUS_RELEASE_LABEL}|"

  echo "ServiceMonitor applied: ${DEPLOYMENT}"
}

bootstrap_vault_k8s_auth() {
  local role="${DEPLOYMENT}"
  local policy_name="${DEPLOYMENT}"
  local reviewer_sa="vault-auth-reviewer"
  local reviewer_binding="vault-auth-reviewer-${NAMESPACE}"
  local kube_host kube_ca_data kube_ca_file kube_ca_cert reviewer_jwt

  [[ "${VAULT_BOOTSTRAP_ENABLED}" == "true" ]] || {
    echo "Skipping Vault auth bootstrap (VAULT_BOOTSTRAP_ENABLED=${VAULT_BOOTSTRAP_ENABLED})"
    return
  }

  if ! command -v vault >/dev/null 2>&1; then
    echo "WARNING: vault CLI not found; skipping Vault Kubernetes auth bootstrap"
    return
  fi

  export VAULT_ADDR="${VAULT_URL}"

  set +e
  mount_check_output="$(vault read -format=json "${VAULT_KV_MOUNT}/config" 2>&1)"
  mount_check_status=$?
  set -e

  if [ "${mount_check_status}" -eq 0 ]; then
    echo "Vault KV mount ${VAULT_KV_MOUNT} is reachable"
  else
    case "${mount_check_output}" in
      *"permission denied"*|*"403"*)
        echo "Vault token cannot inspect mount ${VAULT_KV_MOUNT}; continuing without mount bootstrap"
        ;;
      *"No value found at"*|*"404"*|*"No handler for route"*|*"unsupported path"*)
        echo "Vault mount ${VAULT_KV_MOUNT} is missing or unavailable; attempting to create it"
        vault secrets enable -path="${VAULT_KV_MOUNT}" -version=2 kv >/dev/null
        echo "Vault KV mount ${VAULT_KV_MOUNT} created"
        ;;
      *)
        echo "ERROR: Unexpected Vault response while checking mount ${VAULT_KV_MOUNT}"
        echo "${mount_check_output}"
        exit 1
        ;;
    esac
  fi

  kube_host="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  kube_ca_data="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  kube_ca_file="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')"

  if [[ -n "${kube_ca_data}" ]]; then
    kube_ca_cert="$(printf '%s' "${kube_ca_data}" | base64 -d)"
  elif [[ -n "${kube_ca_file}" && -f "${kube_ca_file}" ]]; then
    kube_ca_cert="$(cat "${kube_ca_file}")"
  else
    kube_ca_cert=""
  fi

  [[ -n "${kube_host}" && -n "${kube_ca_cert}" ]] || {
    echo "ERROR: unable to resolve Kubernetes API host or CA from kubectl config"
    exit 1
  }

  kubectl -n "${NAMESPACE}" get serviceaccount "${reviewer_sa}" >/dev/null 2>&1 || kubectl -n "${NAMESPACE}" create serviceaccount "${reviewer_sa}" >/dev/null
  kubectl get clusterrolebinding "${reviewer_binding}" >/dev/null 2>&1 || kubectl create clusterrolebinding "${reviewer_binding}" --clusterrole=system:auth-delegator --serviceaccount="${NAMESPACE}:${reviewer_sa}" >/dev/null

  reviewer_jwt="$(kubectl -n "${NAMESPACE}" create token "${reviewer_sa}")"

  vault auth enable kubernetes >/dev/null 2>&1 || true
  vault write -address="${VAULT_ADDR}" auth/kubernetes/config kubernetes_host="${kube_host}" token_reviewer_jwt="${reviewer_jwt}" kubernetes_ca_cert="${kube_ca_cert}" >/dev/null

  cat <<EOF | vault policy write "${policy_name}" - >/dev/null
path "${VAULT_KV_MOUNT}/data/${VAULT_SECRET_PATH}" {
  capabilities = ["read"]
}

path "${VAULT_KV_MOUNT}/metadata/${VAULT_SECRET_PATH}" {
  capabilities = ["read", "list"]
}
EOF
  echo "Vault policy ${policy_name} ensured"

  vault write -address="${VAULT_ADDR}" "auth/kubernetes/role/${role}" bound_service_account_names="${SERVICE_ACCOUNT}" bound_service_account_namespaces="${NAMESPACE}" token_policies="${policy_name}" ttl="24h" >/dev/null
  echo "Vault Kubernetes auth configured for role ${role} (service account ${SERVICE_ACCOUNT})"
}

validate_vault_k8s_auth() {
  if ! command -v vault >/dev/null 2>&1; then
    echo "WARNING: vault CLI not found; skipping Vault Kubernetes login check"
    return
  fi

  export VAULT_ADDR="${VAULT_URL}"
  local role="${DEPLOYMENT}"
  echo "Validating Vault Kubernetes login for role ${role} using service account ${SERVICE_ACCOUNT}"
  local jwt
  jwt="$(kubectl -n "${NAMESPACE}" create token "${SERVICE_ACCOUNT}")"
  vault write -address="${VAULT_ADDR}" -field=token auth/kubernetes/login role="${role}" jwt="${jwt}" >/dev/null
  echo "Vault Kubernetes login check passed for role ${role}"
}

[[ "${FULL_IMAGE}" == :* || "${FULL_IMAGE}" == *: ]] && { echo "ERROR: Invalid image reference: ${FULL_IMAGE}"; exit 1; }
[[ "${REPLICAS}" =~ ^[0-9]+$ ]] || { echo "ERROR: replicas must be a non-negative integer, got: ${REPLICAS}"; exit 1; }

require_cmd kubectl

[[ -f "${DEPLOYMENT_TEMPLATE}" && -f "${SERVICE_TEMPLATE}" && -f "${INGRESS_TEMPLATE}" ]] || {
  echo "ERROR: deployment/service/ingress templates not found under ${K8S_DIR}"
  exit 1
}

echo "IMAGE=${IMAGE}"
echo "TAG=${TAG}"
echo "FULL_IMAGE=${FULL_IMAGE}"
echo "NAMESPACE=${NAMESPACE}"
echo "DEPLOYMENT=${DEPLOYMENT}"
echo "CONTAINER=${CONTAINER}"
echo "PORT=${PORT}"
echo "REPLICAS=${REPLICAS}"
echo "VAULT_URL=${VAULT_URL}"
echo "SERVICE_ACCOUNT=${SERVICE_ACCOUNT}"
echo "INGRESS_HOST=${INGRESS_HOST}"
echo "GRPC_INGRESS_HOST=${GRPC_INGRESS_HOST}"
echo "VAULT_KV_MOUNT=${VAULT_KV_MOUNT}"
echo "VAULT_SECRET_PATH=${VAULT_SECRET_PATH}"
echo "VAULT_BOOTSTRAP_ENABLED=${VAULT_BOOTSTRAP_ENABLED}"
echo "SERVICE_MONITOR_ENABLED=${SERVICE_MONITOR_ENABLED}"
echo "MONITORING_NAMESPACE=${MONITORING_NAMESPACE}"
echo "PROMETHEUS_RELEASE_LABEL=${PROMETHEUS_RELEASE_LABEL}"
echo "METRICS_PATH=${METRICS_PATH}"
echo "PROJECT_VERSION=${PROJECT_VERSION}"
echo "WORKSPACE_DIR=${WORKSPACE_DIR}"
echo "ROOT_DIR=${ROOT_DIR}"
echo "K8S_DIR=${K8S_DIR}"

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
kubectl -n "${NAMESPACE}" get serviceaccount "${SERVICE_ACCOUNT}" >/dev/null 2>&1 || kubectl -n "${NAMESPACE}" create serviceaccount "${SERVICE_ACCOUNT}"

if kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Updating existing deployment ${DEPLOYMENT} in namespace ${NAMESPACE} to ${FULL_IMAGE}"
  kubectl -n "${NAMESPACE}" set image "deployment/${DEPLOYMENT}" "${CONTAINER}=${FULL_IMAGE}"
  kubectl -n "${NAMESPACE}" set env "deployment/${DEPLOYMENT}" VAULT_URL="${VAULT_URL}"
  kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT}" --type=merge -p "{\"metadata\":{\"labels\":{\"app.kubernetes.io/version\":\"${PROJECT_VERSION}\"}},\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"app.kubernetes.io/version\":\"${PROJECT_VERSION}\"},\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"${ROLLOUT_TS}\"}},\"spec\":{\"serviceAccountName\":\"${SERVICE_ACCOUNT}\"}}}}"
  kubectl -n "${NAMESPACE}" scale "deployment/${DEPLOYMENT}" --replicas="${REPLICAS}"
else
  echo "Creating deployment ${DEPLOYMENT} in namespace ${NAMESPACE} with image ${FULL_IMAGE}"
  render_apply "${DEPLOYMENT_TEMPLATE}" \
    -e "s|__NAMESPACE__|${NAMESPACE}|g" \
    -e "s|__DEPLOYMENT__|${DEPLOYMENT}|g" \
    -e "s|__CONTAINER__|${CONTAINER}|g" \
    -e "s|__IMAGE__|${FULL_IMAGE}|g" \
    -e "s|__PORT__|${PORT}|g" \
    -e "s|__REPLICAS__|${REPLICAS}|g" \
    -e "s|__VAULT_URL__|${VAULT_URL}|g" \
    -e "s|__SERVICE_ACCOUNT__|${SERVICE_ACCOUNT}|g" \
    -e "s|__PROJECT_VERSION__|${PROJECT_VERSION}|g"

  render_apply "${SERVICE_TEMPLATE}" \
    -e "s|__NAMESPACE__|${NAMESPACE}|g" \
    -e "s|__DEPLOYMENT__|${DEPLOYMENT}|g" \
    -e "s|__PORT__|${PORT}|g"
fi

render_apply "${INGRESS_TEMPLATE}" \
  -e "s|__NAMESPACE__|${NAMESPACE}|g" \
  -e "s|__DEPLOYMENT__|${DEPLOYMENT}|g" \
  -e "s|__INGRESS_HOST__|${INGRESS_HOST}|g" \
  -e "s|__GRPC_INGRESS_HOST__|${GRPC_INGRESS_HOST}|g"

apply_service_monitor
bootstrap_vault_k8s_auth

kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=300s
kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o wide
kubectl -n "${NAMESPACE}" get pods -l app="${DEPLOYMENT}" -o wide

validate_vault_k8s_auth
