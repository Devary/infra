#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/service-monitor.yaml"

DEPLOYMENT="${1:?deployment required}"
NAMESPACE="${2:?namespace required}"
MONITORING_NAMESPACE="${3:-monitoring}"
PROM_RELEASE_LABEL="${4:-prometheus}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is required to apply the ServiceMonitor"
  exit 127
fi

if [[ ! -f "${TEMPLATE}" ]]; then
  echo "ERROR: ServiceMonitor template not found at ${TEMPLATE}"
  exit 1
fi

sed \
  -e "s|__DEPLOYMENT__|${DEPLOYMENT}|g" \
  -e "s|__NAMESPACE__|${NAMESPACE}|g" \
  -e "s|namespace: monitoring|namespace: ${MONITORING_NAMESPACE}|" \
  -e "s|release: prometheus|release: ${PROM_RELEASE_LABEL}|" \
  "${TEMPLATE}" | kubectl apply -f -

echo "ServiceMonitor applied: ${DEPLOYMENT} (service namespace: ${NAMESPACE}, monitoring namespace: ${MONITORING_NAMESPACE}, release label: ${PROM_RELEASE_LABEL})"
