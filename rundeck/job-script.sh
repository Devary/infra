#!/usr/bin/env bash
set -euo pipefail

IMAGE="${RD_OPTION_IMAGE:-}"
TAG="${RD_OPTION_TAG:-}"
NAMESPACE="${RD_OPTION_NAMESPACE:-default}"
DEPLOYMENT="${RD_OPTION_DEPLOYMENT:-${RD_OPTION_IMAGE}}"
CONTAINER="${RD_OPTION_CONTAINER:-${RD_OPTION_IMAGE}}"
PORT="${RD_OPTION_PORT:-8080}"
REPO_URL="${RD_OPTION_REPO_URL:-git@github.com:Devary/infra.git}"
REPO_REF="${RD_OPTION_REPO_REF:-main}"

: "${IMAGE:?image required}"

if [[ -z "${TAG}" ]]; then
  TAG="latest"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "REPO_URL=${REPO_URL}"
echo "REPO_REF=${REPO_REF}"
echo "IMAGE=${IMAGE}"
echo "TAG=${TAG}"
echo "NAMESPACE=${NAMESPACE}"
echo "DEPLOYMENT=${DEPLOYMENT}"
echo "CONTAINER=${CONTAINER}"
echo "PORT=${PORT}"

#git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${WORKDIR}/infra"

bash "https://raw.githubusercontent.com/Devary/infra/refs/heads/main/k8s/deploy.sh" "${IMAGE}" "${TAG}" "${NAMESPACE}" "${DEPLOYMENT}" "${CONTAINER}" "${PORT}"
