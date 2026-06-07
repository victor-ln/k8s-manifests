NAMESPACE ?= prod-apps

# =============================================================================
# Orquestrador do laboratório. O PROVISIONAMENTO mora aqui; a EXECUÇÃO dos
# testes foi separada para tests/Makefile (encaminhada pelos alvos test-* /
# k6-* no fim deste arquivo). Ordem de subida: ver CLAUDE.md / README.md.
# =============================================================================

all: cluster-up

# Sobe a stack inteira na ordem de dependência.
setup-up-all: ingress-up db-up bao-up bao-setup pod-info-app-up monitoring-up metrics-server-up monitoring-setup

# -----------------------------------------------------------------------------
# Cluster (kind)
# -----------------------------------------------------------------------------
cluster-up:
	kind create cluster --config kind-config.yaml

cluster-down:
	kind delete cluster

# -----------------------------------------------------------------------------
# Banco de dados (PostgreSQL — StatefulSet + PVC no namespace database)
# -----------------------------------------------------------------------------
db-up:
	kubectl apply -f database/
	# Aguarda o banco nascer para evitar falhas no script do OpenBao
	kubectl rollout status statefulset/postgres -n database --timeout=120s

# -----------------------------------------------------------------------------
# Ingress (Traefik)
# -----------------------------------------------------------------------------
ingress-up:
	helm repo add traefik https://traefik.github.io/charts
	helm repo update
	# Usamos hostPort=80 para que o Traefik se conecte diretamente à porta mapeada pelo Kind
	helm install traefik traefik/traefik \
	  --namespace traefik-system --create-namespace \
	  --set ports.web.hostPort=80 \
	  --set ports.websecure.hostPort=443

# -----------------------------------------------------------------------------
# OpenBao (cofre — modo dev no namespace security)
# -----------------------------------------------------------------------------
bao-install:
	helm repo add openbao https://openbao.github.io/openbao-helm
	helm repo update

bao-up: bao-install
	helm install bao openbao/openbao \
	  --version 0.28.3 \
	  -f openbao/values.yaml \
	  --namespace security --create-namespace

bao-setup:
	bash openbao/setup.sh
	# Rollout status aguarda a criação real do recurso sem falhar prematuramente
	kubectl rollout status deployment/bao-openbao-agent-injector -n security --timeout=120s

# -----------------------------------------------------------------------------
# Aplicação de demonstração (podinfo)
# -----------------------------------------------------------------------------
pod-info-app-up:
	kubectl apply -f pod-info/

pod-info-app-down:
	kubectl delete -f pod-info/

# -----------------------------------------------------------------------------
# Monitoramento (InfluxDB v2 + Grafana no namespace monitoring)
# -----------------------------------------------------------------------------
monitoring-install:
	helm repo add influxdata https://helm.influxdata.com/
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo update

monitoring-up: monitoring-install
	# Instala o InfluxDB v2 (cria o namespace monitoring)
	helm install influxdb influxdata/influxdb2 \
	  --namespace monitoring --create-namespace \
	  -f monitoring/influxdb-values.yaml

	# Provisiona o dashboard do k6 ANTES do Grafana (é montado como volume no install)
	$(MAKE) grafana-dashboard-config

	# Instala o Grafana
	helm install grafana grafana/grafana \
	  --namespace monitoring \
	  -f monitoring/grafana-values.yaml

# Cria no InfluxDB o usuário v1 que o k6 usa para gravar; a senha vem do OpenBao.
# Rode depois de 'monitoring-up' e 'bao-setup' (depende do segredo no OpenBao).
monitoring-setup: grafana-dashboard-config
	bash monitoring/setup.sh

# (Re)cria o ConfigMap com o JSON do dashboard que o Grafana provisiona via volume
grafana-dashboard-config:
	kubectl create configmap k6-dashboard \
	  --from-file=grafana-k6-dashboard.json=monitoring/grafana-k6-dashboard.json \
	  -n monitoring --dry-run=client -o yaml | kubectl apply -f -

monitoring-forward-grafana:
	# Abre a porta do Grafana para você acessar no navegador (localhost:3000)
	kubectl port-forward svc/grafana 3000:80 -n monitoring

# -----------------------------------------------------------------------------
# Metrics Server (OBRIGATÓRIO antes do HPA calcular utilização de CPU)
# -----------------------------------------------------------------------------
metrics-server-install:
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
	helm repo update

metrics-server-up: metrics-server-install
	helm install metrics-server metrics-server/metrics-server \
	  -n kube-system \
	  --set args={--kubelet-insecure-tls}

# -----------------------------------------------------------------------------
# Observação / atalhos de inspeção
# -----------------------------------------------------------------------------
watch-pod-info:
	watch kubectl get pods -n prod-apps

list-pods:
	kubectl get pods -n $(NAMESPACE)

top-pods:
	kubectl get pods -n $(NAMESPACE)

hpa-pods:
	kubectl get hpa -n $(NAMESPACE)

top-hpa-pods:
	kubectl get pods,hpa -n $(NAMESPACE)

watch-all:
	watch kubectl get pods,hpa,jobs -n $(NAMESPACE)

# -----------------------------------------------------------------------------
# Testes — encaminhados para tests/Makefile (mantém os comandos documentados).
# Variáveis de linha de comando (ex.: NAMESPACE=foo, ESPERA=90) propagam ao
# sub-make automaticamente.
# -----------------------------------------------------------------------------
.PHONY: test test-db-pvc test-bao-rotation watch-bao-rotation k6-config run-k6-tests clean-k6-tests
test test-db-pvc test-bao-rotation watch-bao-rotation k6-config run-k6-tests clean-k6-tests:
	$(MAKE) -C tests $@
