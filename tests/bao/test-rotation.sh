#!/bin/bash
set -uo pipefail

# Teste Zero-Trust: encurta o TTL da role (revogação observável em ~1min, não em 1h),
# simula um incidente e prova que a credencial comprometida é apagada do banco.
# Restaura o TTL canônico (1h/24h) na saída, aconteça o que acontecer.

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib.sh"
trap 'echo; echo "Restaurando TTL canônico (1h/24h)..."; restore_role_ttl >/dev/null' EXIT

echo "================================================="
echo "Iniciando Teste Zero-Trust: Revogação do OpenBao"
echo "================================================="

# Espera após o incidente: precisa passar do max_ttl curto para o lease expirar.
ESPERA="${ESPERA:-75}"

echo "[1/5] Encurtando a role para default_ttl=30s / max_ttl=1m..."
set_role_ttl "30s" "1m" >/dev/null

echo "[2/5] Reiniciando a API para os Pods pegarem o lease curto (estado servidor≠cliente)..."
kubectl rollout restart deployment/api-podinfo -n prod-apps
kubectl rollout status deployment/api-podinfo -n prod-apps --timeout=120s

# Descobre o Pod e a credencial EXATA que o cofre gerou para ele
API_POD=$(kubectl get pods -n prod-apps -l app=podinfo -o jsonpath="{.items[0].metadata.name}")
DB_USER=$(kubectl exec "$API_POD" -c backend -n prod-apps -- cat /vault/secrets/db-creds.env | grep DB_USER | cut -d '"' -f 2)
if [ -z "$DB_USER" ]; then
  echo "❌ Não consegui extrair DB_USER. O Database Engine do OpenBao está configurado?"
  exit 1
fi

echo "[3/5] Confirmando que '$DB_USER' existe no PostgreSQL (com validade)..."
kubectl exec postgres-0 -n database -- psql -U postgres -d meubanco -c \
  "SELECT rolname, rolvaliduntil FROM pg_roles WHERE rolname = '$DB_USER';"

echo "[4/5] Simulando incidente de segurança (deletando o Pod $API_POD)..."
kubectl delete pod "$API_POD" -n prod-apps

echo "Aguardando ${ESPERA}s para o lease expirar e o OpenBao revogar..."
sleep "$ESPERA"

# Assertion correta: checamos o usuário EXATO comprometido (não um LIKE, que
# pegaria a credencial nova que o Pod recriado acabou de receber).
echo "[5/5] O usuário comprometido '$DB_USER' ainda existe no banco?"
SOBROU=$(kubectl exec postgres-0 -n database -- psql -U postgres -d meubanco -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER';")

echo "================================================="
if [ -z "$SOBROU" ]; then
  echo "✅ PASSOU: '$DB_USER' foi revogado (DROP ROLE). A senha vazada virou inútil."
else
  echo "❌ FALHOU: '$DB_USER' ainda existe — a revogação não ocorreu na janela esperada."
  exit 1
fi
