# Conceitos & padrões

Referência rápida dos conceitos-chave exercitados no lab.

## Estado declarativo & reconciliação
Você declara o **estado desejado** (YAML); o cluster trabalha em loop para que a realidade bata. Não se dá ordens passo a passo. `kubectl apply` calcula o diff.

## Control Loop & Self-healing (auto-cura)
Consequência prática da reconciliação acima. O **Controller Manager** roda um loop infinito comparando, a cada instante, o **estado real** com o **estado desejado** gravado no etcd. Ao detectar divergência, dispara um evento de reconciliação — e **não se importa com a causa** (você deletou? o nó pegou fogo? faltou memória?). A única missão é fazer o real voltar a bater com o desejado.
- **Demonstração no lab:** deletando o `postgres-0` à mão, o cluster vê `réplicas: 0 ≠ 1 desejada` e **ressuscita o Pod automaticamente**, sem ninguém de plantão. É o que torna a infra resiliente a falhas.
- **A diferença do estado:** num Deployment, o Pod renasce com nome aleatório e **disco vazio**. Num StatefulSet, renasce com **a mesma identidade e o mesmo disco** — por isso os dados sobrevivem (ver abaixo).

## StatefulSet (workloads com estado)
Para apps **stateful** (bancos, filas, sistemas de consenso) onde identidade e disco importam. Contraste com o Deployment:
- **Deployment:** Pods são *gado descartável* — nome aleatório (`api-8f7b9v`), intercambiáveis, disco efêmero. Recriou → nasce vazio. Bom para apps **stateless** (a API web do lab).
- **StatefulSet:** Pods têm **identidade estável e ordenada** (`postgres-0`, `postgres-1`, …). O K8s recria o Pod com **o mesmo nome** e repluga **o mesmo PVC**. Exige um `serviceName` (Service governante) para ancorar o DNS da camada de dados.
- **Regra mental:** o Pod continua descartável e auto-curável, mas o **disco é sagrado** — o dado é desacoplado do contêiner e sobrevive à sua morte. No lab: o `postgres-0` ressuscitou após `kubectl delete pod` com a tabela e o registro intactos.

## Volumes: PV, PVC & StorageClass
Desacopla o ciclo de vida do **dado** do ciclo de vida do **Pod**.
- **PVC (PersistentVolumeClaim):** o *pedido* de disco que o Pod faz ("quero 1Gi, `ReadWriteOnce`"). É o que vive no manifesto (`database/02-pvc.yaml`).
- **PV (PersistentVolume):** o disco *real* que satisfaz o claim. No kind, o **provisionador padrão** cria sob demanda (uma pasta no HD do host); na nuvem seria um EBS/Persistent Disk.
- **`accessModes: ReadWriteOnce`:** o volume só monta num nó por vez (típico de armazenamento de bloco).
- **`mountPath`:** onde o disco aparece dentro do contêiner (ex.: `/var/lib/postgresql/data`). Pod morre, PV fica; o próximo Pod remonta o mesmo PV — a base da persistência.

## Control Plane vs. Worker Nodes
- **Control Plane (cérebro):** API Server (porta de entrada), etcd (fonte da verdade), Controller Manager (reconcilia), Scheduler (escolhe o nó). Na nuvem (EKS/GKE/AKS) é gerenciado e oculto.
- **Worker Nodes:** VMs/máquinas onde os Pods rodam. Na nuvem, são instâncias na sua conta (provisionadas via Terraform).

## Pod, Deployment, ReplicaSet, Job
- **Pod:** menor unidade; um ou mais contêineres compartilhando rede e memória.
- **Deployment → ReplicaSet → Pod:** o Deployment não cria Pods diretamente; gerencia um ReplicaSet, que cria os Pods. Processo **contínuo**.
- **Job:** roda uma tarefa até o fim e morre (`Completed`). Usado para testes de carga, migrações, etc. `restartPolicy: Never`.

## Namespaces
"Cercadinhos" lógicos para isolar domínios: `prod-apps` (app), `security` (OpenBao), `monitoring` (observabilidade). Ferramentas de infra nunca dividem namespace com a aplicação.

## Ingress & borda da rede (Ingress Controller)
- **Service vs Ingress:** o Service expõe a app **dentro** do cluster (ClusterIP) ou numa porta de nó (NodePort). O **Ingress** é a porta de entrada **HTTP(S)** da borda: roteia por host/path (`podinfo.local` → `servico-podinfo`) e centraliza TLS.
- **Ingress (regra) vs Ingress Controller (motor):** o objeto `Ingress` é só a *regra declarativa*; quem a executa é um **controller** (Traefik, NGINX) rodando como Pod. Sem controller instalado, a regra não faz nada. O `ingressClassName: traefik` amarra a regra ao controller.
- **kind não tem LoadBalancer real:** o Service do Traefik fica `EXTERNAL-IP <pending>` para sempre. Contorna-se com `extraPortMappings` no `kind-config.yaml` (mapeia `host:80` → `nó:80`, **só vale na criação do cluster**) + `hostPort` no Traefik (o pod escuta a porta 80 do nó). Cadeia: `host:80 → nó-kind:80 → Traefik → Ingress → Service`. Mexeu no `kind-config.yaml`? Recriar o cluster é obrigatório.

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
Escala réplicas **horizontalmente** (mais cópias, não cópias maiores) reagindo a métricas — não adivinha, lê números via **metrics-server** e compara com um alvo declarativo.
- **Métricas de recurso:** "se a média de CPU/memória passar de 50%, sobe réplica; se cair muito, remove." É o que o `07-hpa.yaml` faz.
- **Métricas customizadas / externas:** via adapter/Prometheus, o HPA lê métrica de **negócio**. Ex.: "se a fila do RabbitMQ passar de 1000 mensagens, sobe +3 workers." Desacopla a escala da CPU e a amarra ao trabalho real pendente.
- **Pegadinha do sidecar:** soma a CPU de **todos** os contêineres do Pod — por isso o sidecar do OpenBao precisa declarar CPU, senão o HPA lê `<unknown>` e nunca escala.
- **Cooldown:** ~5 min de estabilidade antes do scale-down (evita thrashing).

## Quem opera o Kubernetes?
No dia a dia é o "pessoal de infra/cloud", mas no mercado os cargos são:
- **DevOps Engineer:** automatiza a entrega (CI/CD) e mantém a infra rodando.
- **SRE (Site Reliability Engineer):** cargo criado no Google — aplica engenharia de software à operação para garantir disponibilidade e escala (SLOs, error budgets).
- **Platform Engineer:** em empresas grandes, monta um "Time de Plataforma" que entrega o K8s pronto, para os devs só subirem código sem operar o cluster.
- **Dev Backend Sênior / Tech Lead:** em startups, costuma assumir essa bucha e configurar o ambiente.

## Infra vs. software (quando escalar resolve?)
Escalar infra **custa dinheiro** (mais máquinas); escalar para esconder código ruim é jogar dinheiro fora. O K8s escala a **capacidade de processamento** — não conserta dependência lenta nem algoritmo ineficiente.
- **É infra (escala resolve):** carga linear e previsível — dobrou o tráfego, dobrou CPU/RAM; adiciona réplicas e o tempo de resposta volta ao normal. Só faltava "músculo".
- **É software (escala só adia ou piora):**
  - **Memory leak:** memória cresce sem aumento de tráfego até `OOMKilled`/restart. Mais réplicas só adiam o estouro.
  - **Gargalo de banco / query lenta (sem índice):** escalar de 2 → 20 réplicas = 20 instâncias martelando o **mesmo banco** com queries pesadas → derruba o banco mais rápido.
  - **Deadlock / contenção:** duas partes do código se esperam; a CPU **despenca** (travado esperando) e nada anda. Nenhuma escala resolve lógica travada.
- **Regra de ouro:** o K8s escala a app, não o banco lento nem o algoritmo ruim.

## kubeconfig
`~/.kube/config` guarda endereço da API, certificados e o `current-context`. `kind`/`minikube`/`aws eks update-kubeconfig` editam esse arquivo. O `kubectl` é só um cliente REST que lê esse contexto.

## Race conditions na automação
O que funciona digitando à mão quebra em milissegundos no `Makefile`. Mitiga-se com `sleep`, `kubectl wait`, `rollout status` e **ordem de dependência** explícita.

## InfluxDB v1 vs v2
- **v1:** um nome de banco (ex.: `k6`), aberto por padrão.
- **v2:** Organization + Bucket + Token. O output nativo do k6 fala v1; o InfluxDB 2.x aceita escrita v1 via "v1 auth" (usuário/senha), não via API token. Ver [troubleshooting](./troubleshooting.md).
