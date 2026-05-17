#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_TEMPLATE="${SCRIPT_DIR}/deployment.yaml"
SERVICE_TEMPLATE="${SCRIPT_DIR}/service.yaml"

echo "ARG1_IMAGE=${1:-}"
echo "ARG2_TAG=${2:-}"
echo "ARG3_NAMESPACE=${3:-}"
echo "ARG4_DEPLOYMENT=${4:-}"
echo "ARG5_CONTAINER=${5:-}"
echo "ARG6_PORT=${6:-}"
echo "ARG7_REPLICAS=${7:-}"
echo "ARG8_VAULT_URL=${8:-}"
echo "ARG9_SERVICE_ACCOUNT=${9:-}"

IMAGE="${1:?image required}"
TAG="${2:?tag required}"
NAMESPACE="${3:-default}"
DEPLOYMENT="${4:-service}"
CONTAINER="${5:-service}"
PORT="${6:-8080}"
REPLICAS="${7:-1}"
VAULT_URL="${8:-${VAULT_URL:-http://192.168.178.41:8200}}"
SERVICE_ACCOUNT="${9:-default}"

FULL_IMAGE="${IMAGE}:${TAG}"

if [[ "${FULL_IMAGE}" == :* || "${FULL_IMAGE}" == *: ]]; then
  echo "ERROR: Invalid image reference: ${FULL_IMAGE}"
  exit 1
fi

if [[ ! "${REPLICAS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: replicas must be a non-negative integer, got: ${REPLICAS}"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is not installed in the Rundeck execution environment"
  exit 127
fi

if [[ ! -f "${DEPLOYMENT_TEMPLATE}" || ! -f "${SERVICE_TEMPLATE}" ]]; then
  echo "ERROR: deployment templates not found beside deploy.sh"
  exit 1
fi

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

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

if kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Updating existing deployment ${DEPLOYMENT} in namespace ${NAMESPACE} to ${FULL_IMAGE}"
  kubectl -n "${NAMESPACE}" set image "deployment/${DEPLOYMENT}" "${CONTAINER}=${FULL_IMAGE}"
  kubectl -n "${NAMESPACE}" set env "deployment/${DEPLOYMENT}" VAULT_URL="${VAULT_URL}"
  kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT}" --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"serviceAccountName\":\"${SERVICE_ACCOUNT}\"}}}}"
  echo "Scaling deployment ${DEPLOYMENT} in namespace ${NAMESPACE} to ${REPLICAS} replicas"
  kubectl -n "${NAMESPACE}" scale "deployment/${DEPLOYMENT}" --replicas="${REPLICAS}"
else
  echo "Creating deployment ${DEPLOYMENT} in namespace ${NAMESPACE} with image ${FULL_IMAGE}"

  sed -e "s|__NAMESPACE__|${NAMESPACE}|g" \
      -e "s|__DEPLOYMENT__|${DEPLOYMENT}|g" \
      -e "s|__CONTAINER__|${CONTAINER}|g" \
      -e "s|__IMAGE__|${FULL_IMAGE}|g" \
      -e "s|__PORT__|${PORT}|g" \
      -e "s|__REPLICAS__|${REPLICAS}|g" \
      -e "s|__VAULT_URL__|${VAULT_URL}|g" \
      -e "s|__SERVICE_ACCOUNT__|${SERVICE_ACCOUNT}|g" \
      "${DEPLOYMENT_TEMPLATE}" | kubectl apply -f -

  sed -e "s|__NAMESPACE__|${NAMESPACE}|g" \
      -e "s|__DEPLOYMENT__|${DEPLOYMENT}|g" \
      -e "s|__PORT__|${PORT}|g" \
      "${SERVICE_TEMPLATE}" | kubectl apply -f -
fi

kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=300s
kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o wide
kubectl -n "${NAMESPACE}" get pods -l app="${DEPLOYMENT}" -o wide
