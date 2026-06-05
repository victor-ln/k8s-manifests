# Troubleshooting — erros reais e correções

Catálogo dos problemas que apareceram durante a construção deste lab. Cada um traz o **sintoma**, a **causa raiz** e a **correção**.

## Ordem & manifestos

**`namespaces "prod-apps" not found`**
- Causa: `kubectl apply -f .` lê em ordem alfabética; o Deployment foi antes do Namespace.
- Correção: numerar os manifestos (`01-namespace.yaml` primeiro).

**`empty selector is invalid for deployment`**
- Causa: indentação quebrada no `spec.selector.matchLabels` (YAML é sensível a espaços).
- Correção: `matchLabels` precisa ser idêntico aos `labels` do template do Pod.

## Helm

**`cannot re-use a name that is still in use`**
- Causa: o release já existe (a primeira instalação funcionou); reinstalar falha.
- Correção: `helm upgrade`, ou `helm uninstall` antes. Estes alvos do Makefile não são idempotentes.

**`helm status bao` → `release: not found`**
- Causa: o Helm assume o namespace `default`; o release está em `security`.
- Correção: sempre passar `-n security`.

## OpenBao

**`pods "bao-server-0"`/`"bao-0"` not found**
- Causa: o chart nomeia o pod a partir do release (`bao-openbao-0`), não `bao-0`/`bao-server-0`.
- Correção: `kubectl get pods -n security` antes de `exec` ("olhe antes de entrar").

**`env` não mostra `DATABASE_PASS`**
- Não é erro: o OpenBao grava o segredo em **arquivo** (`/vault/secrets/senha.txt`), não em `env` — proposital (env vaza em logs).

**Variáveis do ConfigMap sumiram após `apply`**
- Causa: o estado é declarativo; um YAML sem o bloco `env` faz o K8s **apagar** as variáveis.
- Correção: manter `env` (ConfigMap) e anotações (OpenBao) juntos no manifesto.

**Pod não nasce após `apply` (Deployment `created`, 0 pods)**
- `error looking up service account podinfo-sa: not found` — ordem: a SA nasce depois (consistência eventual resolve, ou renomeie a SA para `02-`).
- `admission webhook "vault.hashicorp.com" denied: No SecurityContext found for Container 0` — com `agent-run-as-same-user`, o webhook precisa do `securityContext.runAsUser` no contêiner para copiá-lo. Correção: declarar `runAsUser: 1000`.

**Rotação de senha não reinicia a app**
- Causas: (1) *static secret* só é verificado a cada ~5 min; (2) sem `agent-run-as-same-user`, o `killall` falha por permissão do Linux.
- Correção: as duas anotações + `shareProcessNamespace: true`.

## HPA

**`TARGETS: <unknown>/50%`**
- `missing request for cpu in container backend` — o contêiner (ou um pod fantasma antigo) está sem `resources.requests`. Correção: declarar requests e **recriar** os pods (`down`/`up`; o `rollout restart` às vezes não basta).
- Sidecar do OpenBao sem CPU declarada — adicionar `agent-requests-cpu` e `agent-init-requests-cpu`.
- `Metrics API not available` / `no metrics returned` — falta o **metrics-server** (kind não traz). Instalar via Helm com `--kubelet-insecure-tls`.

## k6 / Job

**Job preso em `1/2 NotReady`, nunca `Completed`**
- Causa: o sidecar contínuo do OpenBao mantém o Pod "vivo".
- Correção: `agent-pre-populate-only: "true"` (injeta e morre).

**`can't open '/vault/secrets/influx-token'`**
- Causas: (1) `source` não existe no shell POSIX do Alpine — usar `.`; (2) faltou o gatilho `agent-inject: "true"`, então o sidecar nem foi injetado (Pod `0/1` em vez de `0/2`).
- Correção: `. /vault/secrets/...` + garantir `agent-inject: "true"`.

**k6 roda mas não grava no InfluxDB (`output=InfluxDBv1`, `401 Unauthorized`)**
- Causa: o output v1 do k6 autentica por basic-auth contra um **"v1 auth"** que não existia no InfluxDB 2.x (token de API não serve para essa rota).
- Correção: `make monitoring-setup` cria o usuário v1 `k6` com senha do OpenBao. Ver [`CLAUDE.md`](../CLAUDE.md).

**Job não recria com `apply` (`unchanged`)**
- Causa: o template de um Job é imutável; o `apply` vira no-op.
- Correção: o Job usa `generateName` + `make run-k6-tests` faz `kubectl create` (cada run = Job novo). `make clean-k6-tests` limpa.

## Grafana

**Dashboard com "No Data" / não dá para selecionar o datasource**
- Causas: (1) datasource não provisionado/sem `uid` fixo; (2) painéis usando uma variável `$Measurement` multi-valor em `_measurement == "${var}"` (o multi-select quebra o match exato).
- Correção: datasource provisionado com `uid: influxdb` e queries com **measurement literal** + `_field == "value"`.

**`/readyz/disable` e `/healthz/disable` não derrubam a app**
- Não é erro de infra: a imagem `podinfo` mudou/depreciou essas rotas (`/healthz/disable` retorna 404). Para testar liveness de verdade, use `kubectl exec ... -- killall podinfo`.
