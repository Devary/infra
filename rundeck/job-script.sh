#!/usr/bin/env bash
set -euo pipefail

IMAGE="${RD_OPTION_IMAGE:-}"
TAG="${RD_OPTION_TAG:-}"
NAMESPACE="${RD_OPTION_NAMESPACE:-default}"
DEPLOYMENT="${RD_OPTION_DEPLOYMENT:-${RD_OPTION_IMAGE}}"
CONTAINER="${RD_OPTION_CONTAINER:-${RD_OPTION_IMAGE}}"
PORT="${RD_OPTION_PORT:-8080}"

: "${IMAGE:?image required}"

if [[ -z "${TAG}" ]]; then
  TAG="latest"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "REPO_ROOT=${REPO_ROOT}"
echo "IMAGE=${IMAGE}"
echo "TAG=${TAG}"
echo "NAMESPACE=${NAMESPACE}"
echo "DEPLOYMENT=${DEPLOYMENT}"
echo "CONTAINER=${CONTAINER}"
echo "PORT=${PORT}"

bash "${REPO_ROOT}/k8s/deploy.sh" "${IMAGE}" "${TAG}" "${NAMESPACE}" "${DEPLOYMENT}" "${CONTAINER}" "${PORT}"
