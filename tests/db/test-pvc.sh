#!/bin/bash
set -euo pipefail

echo "================================================="
echo "Iniciando Teste de Caos: Persistência do PVC"
echo "================================================="

SENTINELA="Sobrevivi ao apocalipse do Pod!"

# 1. Cria a tabela e insere um dado de teste
echo "[1/4] Inserindo dados no PostgreSQL..."
kubectl exec postgres-0 -n database -- psql -U postgres -d meubanco -c \
  "CREATE TABLE IF NOT EXISTS teste_caos (id serial, nome varchar); INSERT INTO teste_caos (nome) VALUES ('$SENTINELA');"

# 2. Deleta o Pod brutalmente
echo "[2/4] Executando o caos (Deletando o Pod postgres-0)..."
kubectl delete pod postgres-0 -n database

# 3. Aguarda a reconciliação do Kubernetes (Self-Healing)
echo "[3/4] Aguardando o StatefulSet recriar o Pod e plugar o disco..."
kubectl rollout status statefulset/postgres -n database --timeout=120s

# 4. Verifica se o dado sobreviveu — assertion real: o teste FALHA se a sentinela sumiu
echo "[4/4] Lendo os dados do disco recriado:"
RESULTADO=$(kubectl exec postgres-0 -n database -- psql -U postgres -d meubanco -tAc \
  "SELECT nome FROM teste_caos;")
echo "$RESULTADO"

echo "================================================="
if echo "$RESULTADO" | grep -qF "$SENTINELA"; then
  echo "✅ PASSOU: o dado sobreviveu à morte do Pod — o PVC persiste."
else
  echo "❌ FALHOU: o dado sumiu — a persistência do PVC não funcionou."
  exit 1
fi
