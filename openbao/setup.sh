#!/bin/bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-kind-poc-prod}"
KUBECTL=(kubectl --context "$KUBE_CONTEXT")

echo "Aguardando o Kubernetes registrar os Pods (Anti-Race Condition)..."
sleep 10

# Aguarda o pod do servidor ficar pronto
"${KUBECTL[@]}" wait --for=condition=Ready pod/bao-openbao-0 -n security --timeout=120s

# 1. Cria a senha e o token do monitoramento
"${KUBECTL[@]}" exec bao-openbao-0 -n security -- bao kv put secret/podinfo DATABASE_PASS="senha-automatizada-2026"
"${KUBECTL[@]}" exec bao-openbao-0 -n security -- bao kv put secret/monitoramento INFLUX_TOKEN="token-secreto-v2-xyz"
"${KUBECTL[@]}" exec bao-openbao-0 -n security -- bao kv put secret/poc/argo-app/dev \
    message="segredo vindo do OpenBao de prod para o cluster dev"
"${KUBECTL[@]}" exec bao-openbao-0 -n security -- bao kv put secret/poc/argo-app/prod \
    message="segredo vindo do OpenBao de prod para o cluster prod"

# 2. Configura o motor de Banco de Dados
echo "Configurando OpenBao Database Engine..."
"${KUBECTL[@]}" exec bao-openbao-0 -n security -- bao secrets enable database || true
"${KUBECTL[@]}" exec bao-openbao-0 -n security -- bao write database/config/meubanco \
    plugin_name=postgresql-database-plugin \
    allowed_roles="app-role" \
    connection_url="postgresql://{{username}}:{{password}}@postgres-svc.database.svc.cluster.local:5432/meubanco?sslmode=disable" \
    username="postgres" \
    password="root123"

"${KUBECTL[@]}" exec bao-openbao-0 -n security -- bao write database/roles/app-role \
    db_name=meubanco \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

# 3. Habilita o auth do K8s
"${KUBECTL[@]}" exec bao-openbao-0 -n security -- bao auth enable kubernetes || true
"${KUBECTL[@]}" exec bao-openbao-0 -n security -- /bin/sh -c 'bao write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"'

# 4. Cria policy (agora com permissão para a rota database/creds) e role
"${KUBECTL[@]}" exec bao-openbao-0 -n security -- /bin/sh -c 'bao policy write app-policy - <<EOF
path "secret/data/podinfo" { capabilities = ["read"] }
path "secret/data/monitoramento" { capabilities = ["read"] }
path "database/creds/app-role" { capabilities = ["read"] }
EOF'

"${KUBECTL[@]}" exec bao-openbao-0 -n security -- bao write auth/kubernetes/role/app-role \
    bound_service_account_names=podinfo-sa \
    bound_service_account_namespaces=prod-apps \
    policies=app-policy \
    ttl=1h

echo "OpenBao configurado com sucesso!"
