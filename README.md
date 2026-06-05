# k8s-manifests — Laboratório de Kubernetes

Repositório de **estudo** de Kubernetes em um cluster local [`kind`](https://kind.sigs.k8s.io/), orquestrado por um `Makefile`. Sobe a aplicação de demonstração `stefanprodan/podinfo` atrás de um HPA, injeta segredos do **OpenBao** (fork open-source do HashiCorp Vault) via Vault Agent, e faz teste de carga com **k6** transmitindo métricas para **InfluxDB v2 + Grafana**. Não há código de aplicação aqui — apenas infraestrutura declarativa.

> ⚠️ **Não é produção.** Todas as credenciais versionadas (`token-secreto-v2-xyz`, senhas `admin`, etc.) são **valores descartáveis** de um cluster local, com o OpenBao em modo dev (em memória). Nenhuma é um segredo real.

## Arquitetura

Três namespaces isolam os domínios:

| Namespace        | O que roda |
| ---------------- | ---------- |
| `prod-apps` | app `podinfo` (Deployment + Service + HPA), ConfigMap e o Job do k6 |
| `security`       | OpenBao (cofre) + agent injector |
| `monitoring`     | InfluxDB v2 + Grafana |

O fluxo de segredos tem o `openbao/setup.sh` como **fonte única da verdade**: semeia os segredos, habilita o auth do Kubernetes e amarra a role `app-role` à ServiceAccount `podinfo-sa`. Quem precisa de segredo roda como essa SA e carrega anotações `vault.hashicorp.com/...` para o sidecar injetar.

Detalhes de acoplamentos não-óbvios: [`CLAUDE.md`](./CLAUDE.md).

## Pré-requisitos

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/) — cluster Kubernetes local
- [kubectl](https://kubernetes.io/docs/tasks/tools/) — cliente do cluster
- [Helm](https://helm.sh/) — gerenciador de pacotes do K8s
- [k6](https://k6.io/) — opcional, só para testes fora do cluster

## Subir o ambiente (a ordem importa)

```sh
make cluster-up            # cria o cluster kind
make metrics-server-up     # necessário ANTES do HPA medir CPU
make bao-up                # instala o OpenBao (modo dev) no namespace security
make bao-setup             # configura o cofre: segredos, auth k8s, policy/role
make pod-info-app-up       # sobe a app (depende do injector + role do OpenBao)
make monitoring-up         # InfluxDB v2 + Grafana (provisiona o dashboard do k6)
make monitoring-setup      # cria o usuário v1 do InfluxDB que o k6 usa (senha vem do OpenBao)
make k6-config             # cria o ConfigMap com o script do k6
make run-k6-tests          # dispara o Job de teste de carga
```

Observar: `make watch-all` (pods/hpa/jobs) · `make monitoring-forward-grafana` (localhost:3000, admin/admin).
Derrubar: `make pod-info-app-down` · `make cluster-down`.

## Documentação

Este repo nasceu de um roteiro de estudo passo a passo. O histórico de evolução (commits) se perdeu por falta de `git init` no início, então foi **reconstruído como documentação por tópicos**:

- 📍 [`docs/roadmap.md`](./docs/roadmap.md) — a jornada de aprendizado, etapa por etapa, com o "porquê" de cada peça.
- 🔧 [`docs/troubleshooting.md`](./docs/troubleshooting.md) — catálogo dos erros reais que apareceram, causa raiz e correção.
- 📚 [`docs/conceitos-e-padroes.md`](./docs/conceitos-e-padroes.md) — conceitos e padrões aprendidos (estado declarativo, sidecar, webhook, HPA, etc.).
- 🤖 [`CLAUDE.md`](./CLAUDE.md) — arquitetura e acoplamentos não-óbvios (guia para o Claude Code).

## Layout

```
.
├── Makefile              # orquestrador — comece por aqui
├── pod-info/             # app de demo (manifestos 01–07)
├── openbao/              # values.yaml + setup.sh (bootstrap do cofre)
├── monitoring/           # values do InfluxDB v2 e Grafana + dashboard do k6
├── tests/k6/             # spike.js (carga) + 01-job.yaml (runner)
└── docs/                 # documentação por tópicos
```

## Backlog (próximos passos)

- [ ] External Secrets Operator (ESO) para tirar os tokens hardcoded de `influxdb-values.yaml` e `grafana-values.yaml`, derivando do OpenBao.
- [ ] `check()` e thresholds no `spike.js` para popular os painéis de Errors/Checks.
- [ ] Travar as versões dos charts do Grafana/InfluxDB/metrics-server (como já feito no OpenBao).
