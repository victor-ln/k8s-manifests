# k8s-manifests — Laboratório de Kubernetes

Repositório de **estudo** de Kubernetes em clusters locais [`kind`](https://kind.sigs.k8s.io/), orquestrado por um `Makefile`. A POC principal simula o fluxo CI/CD produtivo com dois clusters: `poc-prod` e `poc-dev`. O ArgoCD e o OpenBao rodam apenas em `poc-prod`; ESO e Reflector rodam nos dois clusters; o ESO de `poc-dev` lê segredos do OpenBao de `poc-prod`.

> ⚠️ **Não é produção.** Todas as credenciais versionadas (`token-secreto-v2-xyz`, senhas `admin`, etc.) são **valores descartáveis** de um cluster local, com o OpenBao em modo dev (em memória). Nenhuma é um segredo real.

## Arquitetura

Clusters e namespaces isolam os domínios:

| Cluster | Namespace | O que roda |
| ------- | --------- | ---------- |
| `poc-prod` | `argocd` | ArgoCD + App-of-Apps |
| `poc-prod` | `security` | OpenBao único da POC |
| `poc-prod` e `poc-dev` | `external-secrets` | External Secrets Operator + `ClusterSecretStore openbao-cluster-store` |
| `poc-prod` e `poc-dev` | `reflector` | Reflector |
| `poc-prod` e `poc-dev` | `poc` | workload reconciliado pelo ArgoCD |

As **aplicações** não são aplicadas por `make`: o **ArgoCD** as gerencia a partir do repo
[`gitops-manifests`](https://github.com/victor-ln/gitops-manifests). Este repo cuida da
infra, registra o cluster dev no ArgoCD e sobe o App-of-Apps em
`bootstrap/argocd/app-root.yaml`.

O fluxo de segredos tem o `openbao/setup.sh` como **fonte única da verdade**: semeia os segredos, habilita o auth do Kubernetes e amarra a role `app-role` à ServiceAccount `podinfo-sa`. Quem precisa de segredo roda como essa SA e carrega anotações `vault.hashicorp.com/...` para o sidecar injetar.

Detalhes de acoplamentos não-óbvios: [`CLAUDE.md`](./CLAUDE.md).

## Pré-requisitos

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/) — cluster Kubernetes local
- [kubectl](https://kubernetes.io/docs/tasks/tools/) — cliente do cluster
- [Helm](https://helm.sh/) — gerenciador de pacotes do K8s
- [k6](https://k6.io/) — opcional, só para testes fora do cluster

## Subir o ambiente

```sh
make setup-up-all
```

O alvo cria os clusters `poc-prod` e `poc-dev`, instala a infra, registra o cluster
`poc-dev` no ArgoCD do `poc-prod`, e aplica o App-of-Apps. Se quiser executar por etapas:

```sh
make clusters-up
make prod-infra-up
make dev-infra-up
make argocd-register-dev
make argocd-bootstrap
```

Observar: `make argocd-forward` e acesse `https://localhost:8080`.
Derrubar: `make clusters-down`.

## Documentação

Este repo nasceu de um roteiro de estudo passo a passo. O histórico de evolução (commits) se perdeu por falta de `git init` no início, então foi **reconstruído como documentação por tópicos**:

- 📍 [`docs/roadmap.md`](./docs/roadmap.md) — a jornada de aprendizado, etapa por etapa, com o "porquê" de cada peça.
- 🔧 [`docs/troubleshooting.md`](./docs/troubleshooting.md) — catálogo dos erros reais que apareceram, causa raiz e correção.
- 📚 [`docs/conceitos-e-padroes.md`](./docs/conceitos-e-padroes.md) — conceitos e padrões aprendidos (estado declarativo, sidecar, webhook, HPA, etc.).
- 🚢 [`docs/gitops-argocd.md`](./docs/gitops-argocd.md) — GitOps com ArgoCD (3 repos, pull-based) e o passo a passo de bootstrap pela UI.
- ↩️ [`docs/estrategia-cd-rollback.md`](./docs/estrategia-cd-rollback.md) — tratativa de bug no CD: roll-forward × revert × rollback.
- 🤖 [`CLAUDE.md`](./CLAUDE.md) — arquitetura e acoplamentos não-óbvios (guia para o Claude Code).

## Layout

```
.
├── Makefile              # orquestrador de INFRA multi-cluster
├── bootstrap/            # ESO, Reflector e App-of-Apps
├── kind-prod-config.yaml # cluster prod: ArgoCD + OpenBao
├── kind-dev-config.yaml  # cluster dev: workloads
├── argocd/               # espelhos legados das Applications antigas
├── openbao/              # values.yaml + setup.sh (bootstrap do cofre)
├── monitoring/           # values do InfluxDB v2 e Grafana + dashboard do k6
├── database/             # PostgreSQL (StatefulSet + PVC)
├── tests/k6/             # spike.js (carga) + 01-job.yaml (runner)
└── docs/                 # documentação por tópicos
```

> Os manifestos da app (antigo `pod-info/`) migraram para o repo
> [`gitops-manifests`](https://github.com/victor-ln/gitops-manifests) (kustomize),
> gerenciado pelo ArgoCD.

## Observações da POC

- O OpenBao roda em modo dev com token `root`, intencionalmente descartável.
- O `ClusterSecretStore` de `poc-dev` aponta para um Service local que encaminha para o
  NodePort do OpenBao no container do cluster `poc-prod`.
- O Reflector está instalado nos dois clusters e replica os placeholders
  `poc-registry-secret` e `poc-wildcard-tls` do namespace `infra-shared` para `poc`.
