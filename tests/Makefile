NAMESPACE ?= prod-apps

# =============================================================================
# Execução dos testes do laboratório. Pode ser chamado direto (make -C tests …)
# ou pelos alvos encaminhados do Makefile raiz. Os caminhos são relativos a
# tests/ — os scripts resolvem suas próprias dependências (lib.sh) via $0.
# =============================================================================

# Suíte determinística: persistência do PVC + revogação de credencial do OpenBao
test: test-db-pvc test-bao-rotation

# -----------------------------------------------------------------------------
# Persistência do banco (caos no PVC do StatefulSet)
# -----------------------------------------------------------------------------
test-db-pvc:
	bash db/test-pvc.sh

# -----------------------------------------------------------------------------
# Credenciais dinâmicas do OpenBao (rotação / revogação)
# Ambos encurtam o TTL (30s/1m) e restauram o canônico (1h/24h) ao sair.
# -----------------------------------------------------------------------------
test-bao-rotation:
	bash bao/test-rotation.sh

watch-bao-rotation:
	bash bao/watch-rotation.sh

# -----------------------------------------------------------------------------
# Carga (k6 → InfluxDB)
# -----------------------------------------------------------------------------
# Cria o ConfigMap k6-script a partir do spike.js (rode antes de run-k6-tests)
k6-config:
	kubectl create configmap k6-script --from-file=k6/spike.js -n $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

# O Job usa generateName, então cada run cria um Job novo (k6-load-test-xxxxx).
# Por isso usamos 'create' (não 'apply', que exige nome fixo).
run-k6-tests:
	kubectl create -f k6/01-job.yaml

# Remove todas as execuções de carga (Jobs e pods) do k6
clean-k6-tests:
	kubectl delete jobs -l app=k6-load-test -n $(NAMESPACE)

.PHONY: test test-db-pvc test-bao-rotation watch-bao-rotation k6-config run-k6-tests clean-k6-tests
