# Conceitos & padrões

Referência rápida dos conceitos-chave exercitados no lab.

## Estado declarativo & reconciliação
Você declara o **estado desejado** (YAML); o cluster trabalha em loop para que a realidade bata. Não se dá ordens passo a passo. `kubectl apply` calcula o diff.

## Control Plane vs. Worker Nodes
- **Control Plane (cérebro):** API Server (porta de entrada), etcd (fonte da verdade), Controller Manager (reconcilia), Scheduler (escolhe o nó). Na nuvem (EKS/GKE/AKS) é gerenciado e oculto.
- **Worker Nodes:** VMs/máquinas onde os Pods rodam. Na nuvem, são instâncias na sua conta (provisionadas via Terraform).

## Pod, Deployment, ReplicaSet, Job
- **Pod:** menor unidade; um ou mais contêineres compartilhando rede e memória.
- **Deployment → ReplicaSet → Pod:** o Deployment não cria Pods diretamente; gerencia um ReplicaSet, que cria os Pods. Processo **contínuo**.
- **Job:** roda uma tarefa até o fim e morre (`Completed`). Usado para testes de carga, migrações, etc. `restartPolicy: Never`.

## Namespaces
"Cercadinhos" lógicos para isolar domínios: `prod-apps` (app), `security` (OpenBao), `monitoring` (observabilidade). Ferramentas de infra nunca dividem namespace com a aplicação.

## IaC & GitOps
Infraestrutura versionada como código. O `values.yaml` (Helm) e o `setup.sh` (bootstrap) tornam o ambiente reprodutível: um `git clone` + `make` recria tudo igual.

## Helm
Gerenciador de pacotes do K8s (o "apt/npm" da infra). Empacota dezenas de manifestos; a config declarativa fica no `values.yaml`. **Trave a versão** do chart (`--version`) para determinismo. Distinção: *chart version* (empacotamento) vs. *app version* (software).

## Sidecar & Mutating Webhook (OpenBao)
- **Webhook de admissão:** intercepta a criação de Pods e pode mutá-los.
- **Sidecar:** contêiner extra injetado ao lado da app. O OpenBao injeta um `vault-agent-init` (busca o segredo no boot e morre) e um `vault-agent` (renova em paralelo).
- **Fonte única da verdade:** todo segredo deriva do OpenBao; nada hardcoded duplicado.

## Identidade: ServiceAccount + Role
A `ServiceAccount` é o "RG" do Pod. A role do OpenBao amarra a entrega do segredo a uma SA específica num namespace específico.

## Probes
- **Liveness:** travou? → mata e recria.
- **Readiness:** pronto para tráfego? → isola do Service sem matar.

## Requests & Limits
- **Requests:** reserva (scheduling). Falta de recurso → `Pending`.
- **Limits:** teto. CPU → throttling; memória → `OOMKilled`.
- CPU em millicores (`1000m` = 1 vCPU); memória em `Mi`/`Gi`.

## HPA (Horizontal Pod Autoscaler)
Escala réplicas com base em métricas (CPU/memória/customizadas). Depende do **metrics-server**. Soma a CPU de **todos** os contêineres do Pod — por isso o sidecar precisa declarar CPU. Tem cooldown de scale-down (~5 min) contra thrashing.

## Infra vs. software (quando escalar resolve?)
- **Infra:** carga linear e previsível — mais réplicas resolvem.
- **Software:** memory leak, query lenta, deadlock — escalar só adia ou piora (ex.: 20 réplicas atacando o mesmo banco lento).

## kubeconfig
`~/.kube/config` guarda endereço da API, certificados e o `current-context`. `kind`/`minikube`/`aws eks update-kubeconfig` editam esse arquivo. O `kubectl` é só um cliente REST que lê esse contexto.

## Race conditions na automação
O que funciona digitando à mão quebra em milissegundos no `Makefile`. Mitiga-se com `sleep`, `kubectl wait`, `rollout status` e **ordem de dependência** explícita.

## InfluxDB v1 vs v2
- **v1:** um nome de banco (ex.: `k6`), aberto por padrão.
- **v2:** Organization + Bucket + Token. O output nativo do k6 fala v1; o InfluxDB 2.x aceita escrita v1 via "v1 auth" (usuário/senha), não via API token. Ver [troubleshooting](./troubleshooting.md).
