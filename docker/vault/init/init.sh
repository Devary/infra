#!/bin/sh
set -eu

echo "Waiting for Vault..."
# vault dev is already unsealed/initialized; just wait for HTTP up
until wget -qO- "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do
  sleep 1
done

echo "Vault is up. Provisioning..."

# 1) KV secret for config source (KV v2 is already enabled at secret/ in dev mode)
vault kv put secret/myapps/vault-quickstart/config a-private-key=123456

# 2) Policy for KV v2 path (note the /data/ part for v2 policies)
cat <<'EOF' | vault policy write vault-quickstart-policy -
path "secret/data/myapps/vault-quickstart/*" {
  capabilities = ["read", "create", "update", "list"]
}
EOF

# 3) Enable userpass + create bob
vault auth enable userpass >/dev/null 2>&1 || true
vault write auth/userpass/users/bob password=sinclair policies=vault-quickstart-policy >/dev/null

echo "KV + userpass ready (bob/sinclair)."

# 4) OPTIONAL: Database secrets engine for Postgres (dynamic credentials)
# Enable engine (idempotent)
vault secrets enable database >/dev/null 2>&1 || true

# Configure DB connection using admin user (here: appuser/apppass)
vault write database/config/appdb \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-readwrite" \
  connection_url="postgresql://{{username}}:{{password}}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=disable" \
  username="${POSTGRES_ADMIN_USER}" \
  password="${POSTGRES_ADMIN_PASSWORD}" >/dev/null

# Role that creates users in Postgres with a TTL
vault write database/roles/app-readwrite \
  db_name=appdb \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO \"{{name}}\"; GRANT USAGE ON SCHEMA public TO \"{{name}}\"; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h" >/dev/null

# Policy for DB creds endpoint (so Quarkus or a user can request creds)
cat <<'EOF' | vault policy write app-db-creds-policy -
path "database/creds/app-readwrite" {
  capabilities = ["read"]
}
EOF

# Give bob that policy too (optional)
vault write auth/userpass/users/bob password=sinclair policies="vault-quickstart-policy,app-db-creds-policy" >/dev/null

echo "Database engine ready (role: app-readwrite)."
echo "Done."
