#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="${RD_OPTION_WORKSPACE:-}"

IMAGE="${RD_OPTION_IMAGE:-}"
TAG="${RD_OPTION_TAG:-latest}"
NAMESPACE="${RD_OPTION_NAMESPACE:-default}"
DEPLOYMENT="${RD_OPTION_DEPLOYMENT:-${RD_OPTION_IMAGE##*/}}"
CONTAINER="${RD_OPTION_CONTAINER:-${RD_OPTION_IMAGE##*/}}"
PORT="${RD_OPTION_PORT:-8080}"

if [[ -n "${WORKSPACE_DIR}" ]]; then
  DEPLOY_SCRIPT="${WORKSPACE_DIR}/k8s/deploy.sh"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  DEPLOY_SCRIPT="${SCRIPT_DIR}/../k8s/deploy.sh"
fi

: "${IMAGE:?image required}"

if [[ ! -f "${DEPLOY_SCRIPT}" ]]; then
  echo "ERROR: deploy script not found at ${DEPLOY_SCRIPT}"
  exit 1
fi

echo "IMAGE=${IMAGE}"
echo "TAG=${TAG}"
echo "NAMESPACE=${NAMESPACE}"
echo "DEPLOYMENT=${DEPLOYMENT}"
echo "CONTAINER=${CONTAINER}"
echo "PORT=${PORT}"
echo "WORKSPACE_DIR=${WORKSPACE_DIR}"
echo "DEPLOY_SCRIPT=${DEPLOY_SCRIPT}"

bash "${DEPLOY_SCRIPT}" "${IMAGE}" "${TAG}" "${NAMESPACE}" "${DEPLOYMENT}" "${CONTAINER}" "${PORT}"
