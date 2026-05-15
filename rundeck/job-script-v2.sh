  #!/usr/bin/env bash
  set -euo pipefail

  IMAGE="${RD_OPTION_IMAGE:-}"
  TAG="${RD_OPTION_TAG:-latest}"
  NAMESPACE="${RD_OPTION_NAMESPACE:-default}"
  DEPLOYMENT="${RD_OPTION_DEPLOYMENT:-${RD_OPTION_IMAGE##*/}}"
  CONTAINER="${RD_OPTION_CONTAINER:-${RD_OPTION_IMAGE##*/}}"
  PORT="${RD_OPTION_PORT:-8080}"
  REPLICAS="${RD_OPTION_REPLICAS:-1}"
  REPO_URL="${RD_OPTION_REPO_URL:-git@github.com:Devary/infra.git}"
  REPO_REF="${RD_OPTION_REPO_REF:-main}"

  : "${IMAGE:?image required}"

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

  echo "REPO_URL=${REPO_URL}"
  echo "REPO_REF=${REPO_REF}"
  echo "IMAGE=${IMAGE}"
  echo "TAG=${TAG}"
  echo "FULL_IMAGE=${FULL_IMAGE}"
  echo "NAMESPACE=${NAMESPACE}"
  echo "DEPLOYMENT=${DEPLOYMENT}"
  echo "CONTAINER=${CONTAINER}"
  echo "PORT=${PORT}"
  echo "REPLICAS=${REPLICAS}"

  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "${WORKDIR}"' EXIT

  git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${WORKDIR}/infra"

  cd "${WORKDIR}/infra"

  kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

  if kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Updating existing deployment ${DEPLOYMENT} in namespace ${NAMESPACE} to ${FULL_IMAGE}"
    kubectl -n "${NAMESPACE}" set image "deployment/${DEPLOYMENT}" "${CONTAINER}=${FULL_IMAGE}"
    echo "Scaling deployment ${DEPLOYMENT} in namespace ${NAMESPACE} to ${REPLICAS} replicas"
    kubectl -n "${NAMESPACE}" scale "deployment/${DEPLOYMENT}" --replicas="${REPLICAS}"
  else
    echo "Creating deployment ${DEPLOYMENT} in namespace ${NAMESPACE} with image ${FULL_IMAGE}"

    sed \
      -e "s|__NAMESPACE__|${NAMESPACE}|g" \
      -e "s|__DEPLOYMENT__|${DEPLOYMENT}|g" \
      -e "s|__CONTAINER__|${CONTAINER}|g" \
      -e "s|__IMAGE__|${FULL_IMAGE}|g" \
      -e "s|__PORT__|${PORT}|g" \
      -e "s|__REPLICAS__|${REPLICAS}|g" \
      k8s/deployment.yaml | kubectl apply -f -

    sed \
      -e "s|__NAMESPACE__|${NAMESPACE}|g" \
      -e "s|__DEPLOYMENT__|${DEPLOYMENT}|g" \
      -e "s|__PORT__|${PORT}|g" \
      k8s/service.yaml | kubectl apply -f -
  fi

  kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=300s
  kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o wide
  kubectl -n "${NAMESPACE}" get pods -l app="${DEPLOYMENT}" -o wide