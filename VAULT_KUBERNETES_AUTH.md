# Vault Kubernetes Auth for `service-template`

This document captures the exact working steps used to fix and validate Vault Kubernetes authentication for the deployed `service-template` app.

## Context

- Vault URL: `http://192.168.178.41:8200`
- Kubernetes auth role: `service-template`
- Kubernetes namespace: `default`
- Kubernetes service account: `service-template`
- Kubernetes API host: `https://192.168.178.41:6443`

## 1. Set Vault environment

```bash
export VAULT_ADDR=http://192.168.178.41:8200
export VAULT_TOKEN=<your-vault-token>
```

If `VAULT_ADDR` is not set, the Vault CLI defaults to `https://127.0.0.1:8200`, which causes this error:

```text
http: server gave HTTP response to HTTPS client
```

## 2. Create or verify the reviewer service account

```bash
kubectl -n default create serviceaccount vault-auth-reviewer
```

If it already exists, Kubernetes returns:

```text
error: failed to create serviceaccount: serviceaccounts "vault-auth-reviewer" already exists
```

## 3. Create the ClusterRoleBinding for token review

```bash
kubectl create clusterrolebinding vault-auth-reviewer \
  --clusterrole=system:auth-delegator \
  --serviceaccount=default:vault-auth-reviewer
```

Expected result:

```text
clusterrolebinding.rbac.authorization.k8s.io/vault-auth-reviewer created
```

## 4. Create a token secret for the reviewer service account

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-reviewer-token
  namespace: default
  annotations:
    kubernetes.io/service-account.name: vault-auth-reviewer
type: kubernetes.io/service-account-token
EOF
```

Expected result:

```text
secret/vault-auth-reviewer-token created
```

## 5. Read the reviewer JWT

```bash
REVIEWER_JWT=$(kubectl -n default get secret vault-auth-reviewer-token -o jsonpath='{.data.token}' | base64 -d)
```

## 6. Write the Vault Kubernetes auth config

```bash
vault write auth/kubernetes/config \
  kubernetes_host="https://192.168.178.41:6443" \
  kubernetes_ca_cert="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)" \
  token_reviewer_jwt="$REVIEWER_JWT" \
  disable_iss_validation=true \
  disable_local_ca_jwt=true
```

Expected result:

```text
Success! Data written to: auth/kubernetes/config
```

## 7. Test login with the app service account

```bash
JWT=$(kubectl -n default create token service-template)
vault write auth/kubernetes/login role=service-template jwt="$JWT"
```

Expected successful result:

```text
Key Value
--- -----
token hvs....
token_accessor ...
token_duration 24h
token_renewable true
token_policies ["default" "service-template"]
identity_policies []
policies ["default" "service-template"]
token_meta_service_account_uid 0e4213e9-06d1-43f9-aba3-42931c5492f0
token_meta_role service-template
token_meta_service_account_name service-template
token_meta_service_account_namespace default
token_meta_service_account_secret_name n/a
```

## 8. Restart the deployment

```bash
kubectl -n default rollout restart deploy/service-template
```

Expected result:

```text
deployment.apps/service-template restarted
```

## Notes

- This is normally a **one-time Vault/Kubernetes auth setup**, not something to repeat on every deploy.
- You only need to do it again if Vault config is reset, the cluster changes, or the service account / namespace / role changes.
- Normal app deploys should not automatically rewrite `auth/kubernetes/config` unless you explicitly want deploy-time Vault administration.
