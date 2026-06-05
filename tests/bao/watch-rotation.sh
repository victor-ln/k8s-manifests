#!/bin/bash
set -uo pipefail

# Encurta o TTL da role e reinicia a API para que a ROTAÇÃO aconteça em ~1min
# (com o padrão 24h você esperaria um dia). Restaura 1h/24h ao sair (Ctrl+C).

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib.sh"
trap 'echo; echo "Restaurando TTL canônico (1h/24h)..."; restore_role_ttl >/dev/null; exit 0' EXIT

echo "Encurtando a role para default_ttl=30s / max_ttl=1m..."
set_role_ttl "30s" "1m" >/dev/null

echo "Reiniciando a API para os Pods pegarem o lease curto..."
kubectl rollout restart deployment/api-podinfo -n prod-apps
kubectl rollout status deployment/api-podinfo -n prod-apps --timeout=120s

echo "Espiando as credenciais — em ~1min o DB_USER deve mudar sozinho (rotação)."
echo "Ctrl+C para sair (o TTL é restaurado automaticamente)."
echo "====================================================="

# Loop infinito a ler o ficheiro de senhas de 5 em 5 segundos
while true; do
  # Re-resolve o Pod a cada ciclo: após um rollout/recriação o nome pode mudar
  POD=$(kubectl get pods -n prod-apps -l app=podinfo -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
  echo "[$(date +%H:%M:%S)] Pod $POD — /vault/secrets/db-creds.env:"
  kubectl exec "$POD" -c backend -n prod-apps -- cat /vault/secrets/db-creds.env 2>/dev/null \
    || echo "O contentor está a reiniciar (killall acionado!)..."
  echo "-----------------------------------------------------"
  sleep 5
done
