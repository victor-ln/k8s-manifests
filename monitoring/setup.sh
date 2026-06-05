#!/bin/bash
# Projeta no InfluxDB v2 o usuário/senha "v1" que o k6 usa para gravar métricas.
#
# Por que isso existe:
#   O output InfluxDBv1 do k6 autentica via basic-auth (k6:<senha>) no endpoint
#   /write de compatibilidade 1.x. O InfluxDB v2 resolve esse basic-auth contra
#   "v1 auth" (usuário/senha), NÃO contra API tokens. Sem esse mapeamento toda
#   gravação volta 401 Unauthorized.
#
# Fonte da verdade = OpenBao (sem segredo hardcoded aqui):
#   A senha é LIDA do OpenBao (secret/monitoramento -> INFLUX_TOKEN), o mesmo
#   segredo que o Job do k6 consome via Vault Agent injection. Assim o k6 e o
#   InfluxDB compartilham exatamente a mesma credencial, vinda de um lugar só.
#   Rodar de novo re-sincroniza a senha (idempotente) caso ela rotacione no OpenBao.

set -euo pipefail

BAO_NS="security"
BAO_POD="bao-openbao-0"
INFLUX_NS="monitoring"
INFLUX_POD="influxdb-influxdb2-0"
ORG="minha-empresa"
BUCKET="k6"
V1_USER="k6"

echo "Lendo a credencial do k6 a partir do OpenBao (fonte da verdade)..."
V1_PASSWORD=$(kubectl exec "$BAO_POD" -n "$BAO_NS" -- bao kv get -field=INFLUX_TOKEN secret/monitoramento)

if [ -z "$V1_PASSWORD" ]; then
  echo "ERRO: INFLUX_TOKEN vazio no OpenBao. Rode 'make bao-setup' antes."
  exit 1
fi

echo "Aguardando o InfluxDB ficar pronto..."
kubectl wait --for=condition=Ready "pod/$INFLUX_POD" -n "$INFLUX_NS" --timeout=120s

echo "Descobrindo o ID do bucket '$BUCKET'..."
BUCKET_ID=$(kubectl exec "$INFLUX_POD" -n "$INFLUX_NS" -- \
  influx bucket list --name "$BUCKET" --org "$ORG" --hide-headers | awk '{print $1}')

if [ -z "$BUCKET_ID" ]; then
  echo "ERRO: bucket '$BUCKET' não encontrado. O InfluxDB foi provisionado?"
  exit 1
fi

# Já existe o usuário v1 'k6'? Se sim apenas re-sincroniza a senha com o OpenBao.
if kubectl exec "$INFLUX_POD" -n "$INFLUX_NS" -- \
     influx v1 auth list --org "$ORG" --hide-headers | grep -qw "$V1_USER"; then
  echo "Usuário v1 '$V1_USER' já existe; sincronizando a senha com o OpenBao..."
  kubectl exec "$INFLUX_POD" -n "$INFLUX_NS" -- \
    influx v1 auth set-password --username "$V1_USER" --password "$V1_PASSWORD"
else
  echo "Criando usuário v1 '$V1_USER' (read/write no bucket '$BUCKET')..."
  kubectl exec "$INFLUX_POD" -n "$INFLUX_NS" -- \
    influx v1 auth create \
      --username "$V1_USER" \
      --password "$V1_PASSWORD" \
      --read-bucket "$BUCKET_ID" \
      --write-bucket "$BUCKET_ID" \
      --org "$ORG"
fi

echo "InfluxDB pronto para receber as métricas do k6!"
