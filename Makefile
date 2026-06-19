NAMESPACE ?= poc
PROD_CLUSTER ?= poc-prod
DEV_CLUSTER ?= poc-dev
PROD_CONTEXT ?= kind-$(PROD_CLUSTER)
DEV_CONTEXT ?= kind-$(DEV_CLUSTER)
GITOPS_REPO ?= https://github.com/victor-ln/gitops-manifests.git

# =============================================================================
# Orquestrador do laboratório. O PROVISIONAMENTO mora aqui; a EXECUÇÃO dos
# testes foi separada para tests/Makefile (encaminhada pelos alvos test-* /
# k6-* no fim deste arquivo). Ordem de subida: ver CLAUDE.md / README.md.
# =============================================================================

all: setup-up-all

# Sobe a stack de INFRA na ordem de dependência. As APLICAÇÕES (argocd-app e
# podinfo) sobem pelo ArgoCD a partir do repo gitops-manifests — ver
# docs/gitops-argocd.md (bootstrap pela UI). Por isso não há mais pod-info-app-up aqui.
setup-up-all: clusters-up prod-infra-up dev-infra-up argocd-register-dev argocd-bootstrap

prod-infra-up: prod-ingress-up prod-eso-up prod-reflector-up argocd-install db-up bao-up bao-setup prod-eso-store-up metrics-server-up

dev-infra-up: dev-ingress-up dev-eso-up dev-reflector-up dev-eso-store-up dev-metrics-server-up

# -----------------------------------------------------------------------------
# Cluster (kind)
# -----------------------------------------------------------------------------
cluster-up: prod-cluster-up

clusters-up: prod-cluster-up dev-cluster-up

prod-cluster-up:
	kind create cluster --config kind-prod-config.yaml --name $(PROD_CLUSTER)

dev-cluster-up:
	kind create cluster --config kind-dev-config.yaml --name $(DEV_CLUSTER)

cluster-down:
	kind delete cluster --name $(PROD_CLUSTER)

clusters-down:
	kind delete cluster --name $(DEV_CLUSTER) || true
	kind delete cluster --name $(PROD_CLUSTER) || true

# -----------------------------------------------------------------------------
# Banco de dados (PostgreSQL — StatefulSet + PVC no namespace database)
# -----------------------------------------------------------------------------
db-up:
	kubectl --context $(PROD_CONTEXT) apply -f database/
	# Aguarda o banco nascer para evitar falhas no script do OpenBao
	kubectl --context $(PROD_CONTEXT) rollout status statefulset/postgres -n database --timeout=120s

# -----------------------------------------------------------------------------
# Ingress (Traefik)
# -----------------------------------------------------------------------------
ingress-up: prod-ingress-up

prod-ingress-up:
	helm repo add traefik https://traefik.github.io/charts
	helm repo update
	# Usamos hostPort=80 para que o Traefik se conecte diretamente à porta mapeada pelo Kind
	helm --kube-context $(PROD_CONTEXT) upgrade --install traefik traefik/traefik \
	  --namespace traefik-system --create-namespace \
	  --set ports.web.hostPort=80 \
	  --set ports.websecure.hostPort=443

dev-ingress-up:
	helm repo add traefik https://traefik.github.io/charts
	helm repo update
	helm --kube-context $(DEV_CONTEXT) upgrade --install traefik traefik/traefik \
	  --namespace traefik-system --create-namespace \
	  --set ports.web.hostPort=80 \
	  --set ports.websecure.hostPort=443

argocd-install:
	kubectl --context $(PROD_CONTEXT) create namespace argocd || true
	kubectl --context $(PROD_CONTEXT) apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	# Aguarda os pods principais do ArgoCD subirem
	kubectl --context $(PROD_CONTEXT) wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s

argocd-register-dev:
	kubectl --context $(DEV_CONTEXT) -n kube-system create serviceaccount argocd-manager --dry-run=client -o yaml | kubectl --context $(DEV_CONTEXT) apply -f -
	kubectl --context $(DEV_CONTEXT) create clusterrolebinding argocd-manager-cluster-admin \
	  --clusterrole=cluster-admin \
	  --serviceaccount=kube-system:argocd-manager \
	  --dry-run=client -o yaml | kubectl --context $(DEV_CONTEXT) apply -f -
	DEV_TOKEN=$$(kubectl --context $(DEV_CONTEXT) -n kube-system create token argocd-manager); \
	DEV_NODE_IP=$$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(DEV_CLUSTER)-control-plane); \
	kubectl --context $(PROD_CONTEXT) -n argocd create secret generic cluster-$(DEV_CLUSTER) \
	  --from-literal=name=$(DEV_CLUSTER) \
	  --from-literal=server=https://$${DEV_NODE_IP}:6443 \
	  --from-literal=config="{\"bearerToken\":\"$${DEV_TOKEN}\",\"tlsClientConfig\":{\"insecure\":true}}" \
	  --dry-run=client -o yaml | kubectl --context $(PROD_CONTEXT) apply -f -
	kubectl --context $(PROD_CONTEXT) -n argocd label secret cluster-$(DEV_CLUSTER) argocd.argoproj.io/secret-type=cluster --overwrite

argocd-bootstrap:
	kubectl --context $(PROD_CONTEXT) -n argocd apply -f bootstrap/argocd/argocd-cm-customizations.yaml
	kubectl --context $(PROD_CONTEXT) -n argocd apply -f bootstrap/argocd/poc-project.yaml
	kubectl --context $(PROD_CONTEXT) -n argocd apply -f bootstrap/argocd/app-root.yaml

argocd-pass:
	# O ArgoCD gera uma senha inicial aleatória. Este comando extrai essa senha do cofre interno do K8s
	@echo "A senha do usuário 'admin' é:"
	@kubectl --context $(PROD_CONTEXT) -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo ""

argocd-forward:
	# Libera o acesso à interface visual do ArgoCD
	kubectl --context $(PROD_CONTEXT) port-forward svc/argocd-server -n argocd 8080:443

eso-install:
	helm repo add external-secrets https://charts.external-secrets.io
	helm repo update

prod-eso-up: eso-install
	helm --kube-context $(PROD_CONTEXT) upgrade --install external-secrets external-secrets/external-secrets \
	  --namespace external-secrets --create-namespace \
	  --set installCRDs=true
	kubectl --context $(PROD_CONTEXT) -n external-secrets rollout status deployment/external-secrets --timeout=120s

dev-eso-up: eso-install
	helm --kube-context $(DEV_CONTEXT) upgrade --install external-secrets external-secrets/external-secrets \
	  --namespace external-secrets --create-namespace \
	  --set installCRDs=true
	kubectl --context $(DEV_CONTEXT) -n external-secrets rollout status deployment/external-secrets --timeout=120s

prod-eso-store-up:
	kubectl --context $(PROD_CONTEXT) apply -f bootstrap/external-secrets/openbao-token.yaml
	kubectl --context $(PROD_CONTEXT) apply -f bootstrap/external-secrets/store-prod.yaml

dev-eso-store-up:
	kubectl --context $(DEV_CONTEXT) apply -f bootstrap/external-secrets/openbao-token.yaml
	kubectl --context $(DEV_CONTEXT) apply -f bootstrap/external-secrets/openbao-prod-endpoint-dev.yaml
	PROD_NODE_IP=$$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(PROD_CLUSTER)-control-plane); \
	printf '%s\n' \
	  'apiVersion: v1' \
	  'kind: Endpoints' \
	  'metadata:' \
	  '  name: openbao-prod' \
	  '  namespace: external-secrets' \
	  'subsets:' \
	  '  - addresses:' \
	  "      - ip: $${PROD_NODE_IP}" \
	  '    ports:' \
	  '      - name: http' \
	  '        port: 30200' | kubectl --context $(DEV_CONTEXT) apply -f -
	kubectl --context $(DEV_CONTEXT) apply -f bootstrap/external-secrets/store-dev.yaml

reflector-install:
	helm repo add emberstack https://emberstack.github.io/helm-charts
	helm repo update

prod-reflector-up: reflector-install
	helm --kube-context $(PROD_CONTEXT) upgrade --install reflector emberstack/reflector \
	  --namespace reflector --create-namespace
	kubectl --context $(PROD_CONTEXT) apply -f bootstrap/reflector/shared-secrets.yaml

dev-reflector-up: reflector-install
	helm --kube-context $(DEV_CONTEXT) upgrade --install reflector emberstack/reflector \
	  --namespace reflector --create-namespace
	kubectl --context $(DEV_CONTEXT) apply -f bootstrap/reflector/shared-secrets.yaml

# -----------------------------------------------------------------------------
# OpenBao (cofre — modo dev no namespace security)
# -----------------------------------------------------------------------------
bao-install:
	helm repo add openbao https://openbao.github.io/openbao-helm
	helm repo update

bao-up: bao-install
	helm --kube-context $(PROD_CONTEXT) upgrade --install bao openbao/openbao \
	  --version 0.28.3 \
	  -f openbao/values.yaml \
	  --namespace security --create-namespace

bao-setup:
	KUBE_CONTEXT=$(PROD_CONTEXT) bash openbao/setup.sh
	# Rollout status aguarda a criação real do recurso sem falhar prematuramente
	kubectl --context $(PROD_CONTEXT) rollout status deployment/bao-openbao-agent-injector -n security --timeout=120s

# -----------------------------------------------------------------------------
# Aplicações (podinfo + argocd-app): NÃO sobem por make. Quem as gerencia é o
# ArgoCD, a partir do repo gitops-manifests (bootstrap pela UI). Ver
# docs/gitops-argocd.md. Os manifestos antigos de pod-info/ migraram para lá.
# -----------------------------------------------------------------------------

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
	helm --kube-context $(PROD_CONTEXT) upgrade --install metrics-server metrics-server/metrics-server \
	  -n kube-system \
	  --set args={--kubelet-insecure-tls}

dev-metrics-server-up: metrics-server-install
	helm --kube-context $(DEV_CONTEXT) upgrade --install metrics-server metrics-server/metrics-server \
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
