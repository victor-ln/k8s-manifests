#!/bin/bash

echo "Aguardando o Kubernetes registrar os Pods (Anti-Race Condition)..."
sleep 10

# Aguarda o pod do servidor ficar pronto
kubectl wait --for=condition=Ready pod/bao-openbao-0 -n security --timeout=120s

# 1. Cria a senha e o token do monitoramento
kubectl exec bao-openbao-0 -n security -- bao kv put secret/podinfo DATABASE_PASS="senha-automatizada-2026"
kubectl exec bao-openbao-0 -n security -- bao kv put secret/monitoramento INFLUX_TOKEN="token-secreto-v2-xyz"

# 2. Habilita o auth do K8s
kubectl exec bao-openbao-0 -n security -- bao auth enable kubernetes
kubectl exec bao-openbao-0 -n security -- /bin/sh -c 'bao write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"'

# 3. Cria policy e role
kubectl exec bao-openbao-0 -n security -- /bin/sh -c 'bao policy write app-policy - <<EOF
path "secret/data/podinfo" { capabilities = ["read"] }
path "secret/data/monitoramento" { capabilities = ["read"] }
EOF'

kubectl exec bao-openbao-0 -n security -- bao write auth/kubernetes/role/app-role \
    bound_service_account_names=podinfo-sa \
    bound_service_account_namespaces=prod-apps \
    policies=app-policy \
    ttl=1h

echo "OpenBao configurado com sucesso!"
