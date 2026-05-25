# Infra

Local infra and deployment helpers for the service template.
#Test

## Contents

- `k8s/` - Kubernetes deployment/service templates and deploy script
- `rundeck/` - Rundeck job scripts
- `docker/` - local containerized infrastructure pieces
- `env.sh` - local Vault env helper

## Vault Kubernetes auth setup

The app failed at startup with:

```text
VaultClientException{operationName='VAULT [AUTH (k8s)] Login', requestPath='http://192.168.178.41:8200/v1/auth/kubernetes/login', status=403, errors=[permission denied]}
```

That usually means the Kubernetes auth method is enabled, but Vault is not fully configured for the cluster/service account being used.

### 1) Set Vault access

```bash
export VAULT_ADDR=http://192.168.178.41:8200
export VAULT_TOKEN=<root-or-admin-token>
```

### 2) Verify auth method and role

```bash
vault auth list
vault read auth/kubernetes/config
vault list auth/kubernetes/role
vault read auth/kubernetes/role/<deployment-name>
```

Expected role details for an app:

- service account: `<deployment-name>`
- namespace: `default`
- role: `<deployment-name>`

### 3) Get reviewer JWT and Kubernetes CA cert

Example values:

```bash
REVIEWER_JWT="<token with permission to review service account tokens>"
KUBE_CA_CERT="$(cat /path/to/cluster-ca.crt)"
```

Important: `kubernetes_ca_cert` must contain the PEM certificate content. If this value is missing, Vault may try to read `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt` on the Vault server side and fail with:

```text
open /var/run/secrets/kubernetes.io/serviceaccount/ca.crt: no such file or directory
```

### 4) Configure Vault Kubernetes auth

```bash
vault write auth/kubernetes/config \
  kubernetes_host="https://192.168.178.41:6443" \
  token_reviewer_jwt="$REVIEWER_JWT" \
  kubernetes_ca_cert="$KUBE_CA_CERT"
```

### 5) Test login with the app service account JWT

```bash
JWT=$(kubectl create token <deployment-name> -n default)

vault write auth/kubernetes/login \
  role=<deployment-name> \
  jwt="$JWT"
```

Or get just the client token field:

```bash
vault write -field=token auth/kubernetes/login \
  role=<deployment-name> \
  jwt="$JWT"
```

### 6) If login still fails

Check these first:

- `bound_service_account_names` matches your deployment/service account name
- `bound_service_account_namespaces` matches `default`
- the pod actually runs with `serviceAccountName: <deployment-name>`
- the JWT used for testing belongs to that service account
- `token_reviewer_jwt` is valid for the current cluster
- `kubernetes_host` points to the correct API server
- `kubernetes_ca_cert` matches the cluster CA

## Deployment script

`deploy.sh` is the single deployment entrypoint for both direct CLI use and Rundeck.

Direct CLI usage:

```bash
./deploy.sh <image> <tag> <namespace> <deployment> <container> <port> <replicas> <vault_url> <service_account>
```

By default, the deployment script uses the deployment name as the service account name. You can still override it explicitly if needed.

Rundeck usage:

- point the Rundeck job script directly at `infra/deploy.sh`
- set `RD_OPTION_WORKSPACE` to the checked-out infra repo/workspace path when Rundeck copies the script to a temp location
- the same file understands `RD_OPTION_*` variables automatically

## Prometheus integration via ServiceMonitor

If your cluster already runs `kube-prometheus-stack`, the clean way to scrape a deployed service is with a `ServiceMonitor`, not by hand-editing Prometheus config.

This repo now includes:

- `k8s/serviceMonitors/service-monitor.yaml` - generic ServiceMonitor template

`deploy.sh` renders and applies the ServiceMonitor automatically by default after the Service/Ingress are applied.

Expected scrape target shape for each deployed service:

- service port name: `http`
- metrics path: `/<service-name>/q/metrics`

The generated ServiceMonitor:

- lives in namespace `monitoring`
- targets the deployed service namespace
- selects the Service by label `app: <deployment-name>`

### Toggle / customize

Optional environment variables for `deploy.sh`:

```bash
export SERVICE_MONITOR_ENABLED=true
export MONITORING_NAMESPACE=monitoring
export PROMETHEUS_RELEASE_LABEL=prometheus
export METRICS_PATH=/<deployment-name>/q/metrics
```

If your Prometheus Operator expects a different label than `release=prometheus`, set `PROMETHEUS_RELEASE_LABEL` before running the deploy script.
