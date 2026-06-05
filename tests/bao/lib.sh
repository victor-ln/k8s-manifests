#!/bin/bash
# Helper compartilhado dos testes do OpenBao.
# Reescreve a role app-role com os TTLs informados. O "molde" do usuário
# (db_name + creation_statements) ESPELHA openbao/setup.sh — mantenha em sincronia.
# Os testes encurtam o TTL para observar rotação/revogação rapidamente e restauram
# os valores canônicos (1h/24h) na saída via trap.

BAO_POD="bao-openbao-0"
BAO_NS="security"

set_role_ttl() {
  local default_ttl="$1" max_ttl="$2"
  kubectl exec "$BAO_POD" -n "$BAO_NS" -- bao write database/roles/app-role \
    db_name=meubanco \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    default_ttl="$default_ttl" \
    max_ttl="$max_ttl"
}

# Valores canônicos (iguais ao setup.sh), usados para restaurar após um teste.
restore_role_ttl() {
  set_role_ttl "1h" "24h"
}
