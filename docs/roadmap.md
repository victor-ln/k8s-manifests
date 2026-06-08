# Roadmap — a jornada de aprendizado

Documentação reconstruída do passo a passo que originou este repositório. Cada etapa traz o **conceito**, o **porquê** e as **peças** (arquivos/comandos) envolvidas.

## 1. Hello-world imperativo

Primeiro contato com o cluster usando comandos diretos (modo imperativo):

```sh
kubectl create deployment hello-nginx --image=nginx
kubectl expose deployment hello-nginx --type=NodePort --port=80
kubectl port-forward deployment/hello-nginx 8080:80   # kind não tem o atalho `minikube service`
```

- **kind vs minikube:** o kind roda os nós do Kubernetes como contêineres dentro do Docker — leve e rápido de subir/destruir, padrão de CI. O minikube é mais "VM completa", com add-ons e dashboard.
- **Como o `kubectl` se conecta:** ele é só um cliente REST. Lê o `~/.kube/config` (kubeconfig), que o `kind`/`minikube` editam ao criar o cluster, definindo o `current-context`.

## 2. Estado declarativo e reconciliação

Saímos do imperativo para **manifestos YAML** (Infraestrutura como Código). Você declara o estado desejado; o cluster reconcilia a realidade até bater.

Fluxo interno de um `kubectl apply`:
1. `kubectl` envia o YAML (como JSON) para o **API Server**.
2. O API Server valida e grava a intenção no **etcd** (banco chave-valor, fonte da verdade).
3. O **Controller Manager** percebe o diff (desejado vs. real) e aciona o **Scheduler**, que escolhe o nó.
4. O **kubelet** do nó baixa a imagem e sobe o contêiner.

> Mudar `replicas: 2` → `5` e re-aplicar: o K8s calcula o diff e sobe 3 cópias. Namespace e Service inalterados ficam `unchanged`.

**Ordem alfabética importa:** `kubectl apply -f .` lê a pasta em ordem alfabética. Por isso os manifestos são numerados (`01-namespace` antes de `03-deployment`), senão o Deployment tenta nascer num namespace que ainda não existe.

## 3. ConfigMap & Secret nativos

- **ConfigMap** (`05-configmap.yaml`): variáveis de ambiente abertas (ex.: `APP_LOG_LEVEL`).
- **Secret** nativo: senha em `stringData`; o K8s só **codifica em base64** (não é criptografia — qualquer um reverte). Por isso evoluímos para o OpenBao.

## 4. OpenBao (cofre de segredos)

Trocamos o Secret nativo por um cofre real. Conceitos:

- **Padrão Sidecar Injector:** o OpenBao instala um **Mutating Webhook** que intercepta a criação de Pods. Lendo as anotações `vault.hashicorp.com/...`, ele injeta um sidecar que busca o segredo e grava em arquivo (`/vault/secrets/...`) na memória do Pod.
- **ServiceAccount = identidade:** a `podinfo-sa` é o "RG" da app. A role `app-role` no OpenBao só entrega o segredo para essa SA, neste namespace.
- **Namespace `security` isolado:** ferramentas de infra não rodam junto da app. O injector escuta o cluster inteiro, mesmo morando em `security`.
- **Helm:** o OpenBao tem ~50 manifestos; o Helm empacota isso. A config fica declarativa no `openbao/values.yaml`, e o bootstrap manual (segredos, policy, role) vira o `openbao/setup.sh` (GitOps).
- **Init vs sidecar:** o `vault-agent-init` busca o segredo no boot e morre; o `vault-agent` fica renovando o token/segredo em paralelo.
- **Segurança:** o segredo vai para um **arquivo**, não para `env` — variáveis de ambiente vazam fácil em logs de crash.

## 5. Rotação de segredo

Para a app recarregar quando a senha muda no cofre:

- `shareProcessNamespace: true` — contêineres do Pod enxergam os processos uns dos outros.
- anotação `agent-inject-command-...: "killall podinfo"` — ao atualizar o arquivo, o sidecar mata o processo; o K8s reinicia o contêiner, que lê a nova senha no boot.
- `agent-run-as-same-user: "true"` — o sidecar precisa rodar com o **mesmo UID** da app, senão o Linux barra o `killall` (um usuário não mata processo de outro).
- **Cache de 5 min:** com *static secret*, o sidecar faz polling a cada ~5 min. Em *dynamic secrets* (o cofre gera credencial efêmera no banco, com TTL), a renovação é no segundo exato da expiração.

## 6. Probes (health checks)

- **Liveness** (`/healthz`): "a app travou?" Se falhar, o K8s **mata e recria** o contêiner (self-healing).
- **Readiness** (`/readyz`): "já pode receber tráfego?" Se falhar, o K8s **tira do Service** sem matar (isola até ficar pronta).

## 7. Requests & Limits

- **Requests:** reserva garantida, usada pelo Scheduler para escolher o nó. Sem CPU livre suficiente → Pod fica `Pending`.
- **Limits:** teto. Estourar CPU → *throttling* (fica lento); estourar memória → **OOMKilled**.
- Unidades: CPU em millicores (`1000m` = 1 vCPU); memória em `Mi`/`Gi`.
- **Metrics Server:** o `kubectl top` e o HPA dependem dele. O kind não traz de fábrica → instalado via Helm (`--kubelet-insecure-tls`).

## 8. HPA (autoscaling horizontal)

`07-hpa.yaml`: escala de 2 a 10 réplicas mirando 50% de CPU.

- **Pegadinha do sidecar:** o HPA soma a CPU de **todos** os contêineres do Pod. Como o OpenBao injeta um sidecar, foi preciso declarar a CPU dele via `agent-requests-cpu` / `agent-init-requests-cpu`, senão o HPA fica `<unknown>` e não escala.
- **securityContext:** o webhook do OpenBao exige um `runAsUser` no contêiner para copiá-lo no sidecar (`No SecurityContext found` se faltar).
- **Cooldown:** após a carga cair, o K8s espera ~5 min de estabilidade antes de remover réplicas (evita *thrashing*).

## 9. Teste de carga com k6

- **k6** (Grafana Labs, escrito em Go, scripts em JS) com `stages` para rampas de carga.
- **Job, não Deployment:** teste de carga nasce, executa e morre. O Job usa `restartPolicy: Never` e termina como `Completed`. Com `generateName`, cada execução cria um Job novo (`make run-k6-tests`); `make clean-k6-tests` remove os antigos.
- **Script via ConfigMap:** `make k6-config` empacota o `spike.js` num ConfigMap montado no Pod.
- **DNS interno:** dentro do cluster, o alvo é `http://servico-podinfo.prod-apps.svc.cluster.local:9898` (não `localhost`).
- **Onde rodam testes de carga:** dev/local (validar script), **CI/staging** (padrão ouro — quebra o pipeline se degradar), produção (só com cautela, geralmente rotas GET).

## 10. Observabilidade (InfluxDB v2 + Grafana)

- `make monitoring-up` instala InfluxDB v2 e Grafana no namespace `monitoring`, com datasource e dashboard **provisionados** (sem clicar na UI).
- **Job zumbi:** o sidecar contínuo do OpenBao impede o Job de terminar. Correção: `agent-pre-populate-only: "true"` (injeta e morre, como um init).
- **Alpine/POSIX:** a imagem do k6 é Alpine; usa `.` em vez de `source`.
- **Gatilho mestre:** sem `agent-inject: "true"` o webhook ignora o Pod e a pasta `/vault/secrets/` nem existe.

## 11. Correção do caminho de escrita do k6 → InfluxDB

O output nativo `--out influxdb=` do k6 fala **protocolo v1** e autentica por basic-auth `k6:<senha>`. O InfluxDB **2.x** resolve isso contra um **"v1 auth"** (usuário/senha), não contra API tokens — sem ele, toda escrita volta `401 Unauthorized`. Solução: `monitoring/setup.sh` (`make monitoring-setup`) cria/sincroniza o usuário v1 `k6` com a senha **lida do OpenBao**, mantendo a fonte única. Ver [troubleshooting](./troubleshooting.md) e [`CLAUDE.md`](../CLAUDE.md).

## 12. Versionamento e automação (GitOps)

- **Determinismo de versão:** `helm install --version 0.28.3` (chart version, distinta da app version). Sem travar, o `latest` pode quebrar rotas no futuro (como aconteceu no InfluxDB v1 → v2).
- **Race conditions na automação:** o que funciona na "velocidade humana" quebra na "velocidade de máquina". Daí o `sleep`/`kubectl wait`/`rollout status` no `setup.sh` e a **ordem** no `Makefile` (cofre antes da app).
- **Nuvem:** em EKS/GKE/AKS o Control Plane é gerenciado e oculto; os Worker Nodes são VMs na sua conta, provisionadas via Terraform. O `kubectl` ganha acesso via CLI do provedor (ex.: `aws eks update-kubeconfig`), que edita o kubeconfig. Os mesmos manifestos rodam sem alteração.

## 13. Estado persistente: banco de dados com StatefulSet

Subimos um PostgreSQL no namespace `database` (`make db-up` → `kubectl apply -f database/`; também entrou primeiro no `setup-up-all`). É a primeira peça **stateful** do lab — até aqui tudo era efêmero (app web, Jobs de carga, observabilidade). Agora o dado precisa **sobreviver à morte do Pod**.

- **StatefulSet, não Deployment:** um Deployment daria ao Pod um nome aleatório (`postgres-8f7b9v`) e um disco descartável — ao recriar, nasceria uma máquina nova e **vazia**. O **StatefulSet** dá **identidade estável**: o Pod é sempre `postgres-0` e o K8s repluga **o mesmo disco** (PVC) nele a cada recriação. Identidade fixa é essencial para bancos (hostname previsível, storage colado à identidade, ordem de boot em réplicas).
- **PVC (`02-pvc.yaml`):** o Pod *pede* 1Gi (`ReadWriteOnce`); o provisionador padrão do kind cria o volume real (uma pasta no HD do host) e o casa com o claim. O `mountPath: /var/lib/postgresql/data` pluga esse disco onde o Postgres grava — o ciclo de vida do **dado** fica desacoplado do ciclo de vida do **Pod**.
- **`serviceName` + Service (`04-service.yaml`):** o StatefulSet exige um Service governante (ClusterIP na 5432). Outros Pods alcançam o banco por DNS interno (`postgres-svc.database.svc.cluster.local`), isolado na camada de dados.
- **Self-healing comprovado na prática:** observando com `make watch-all NAMESPACE=database`, deletei o `postgres-0` à mão (`kubectl delete pod`). O **Control Loop** — a mesma reconciliação já descrita no [passo 2](#2-estado-declarativo-e-reconciliação) — notou `estado real (0) ≠ desejado (1)` e **ressuscitou o Pod sozinho**, com o **mesmo nome e o mesmo PVC**; o registro `INSERT 0 1` ("Sobrevivi à queda do Pod!") continuou lá. A novidade sobre o passo 2 não é a reconciliação em si, mas **a persistência do estado através dela**: o Pod é descartável, mas o disco é sagrado.
- **`POSTGRES_PASSWORD` ainda em texto plano** no manifesto (`root123`) — provisório e assumidamente frágil. Próximo passo natural: o OpenBao gerando **credenciais dinâmicas** (usuários temporários com TTL no banco) em vez de senha estática (ver [passo 5](#5-rotação-de-segredo), *dynamic secrets*) — fechando o ciclo segredo → app → banco.

## 14. Credenciais dinâmicas do banco (OpenBao Database Engine)

Matamos a senha estática: em vez do motor `kv` (string fixa), ligamos o **Database Engine**. O OpenBao recebe o `root` do Postgres e passa a **gerar usuários "fantasma" sob demanda** (`v-root-app-role-…`), cada um com validade própria. Ninguém mais usa o `root` direto — ele vira só a credencial de administração que o cofre usa para criar/derrubar os efêmeros.

- **As 3 peças no `setup.sh`** (agora automatizadas, antes eram comandos manuais):
  - `bao secrets enable database` — liga o motor.
  - `database/config/meubanco` — a conexão: `connection_url` apontando para o DNS interno (`postgres-svc.database…`), `username/password` = admin (`postgres`/`root123`).
  - `database/roles/app-role` — o **molde** do usuário efêmero: `creation_statements` (SQL com `{{name}}`/`{{password}}`/`{{expiration}}`) + `default_ttl=1h` / `max_ttl=24h`.
- **Policy + Deployment:** a `app-policy` ganhou a rota `database/creds/app-role`; o `pod-info/03-deployment.yaml` trocou as anotações do `secret/data/podinfo` por essa rota, com template que exporta `DB_USER`/`DB_PASS` em `/vault/secrets/db-creds.env`. Uma API real abriria o pool com essas variáveis (o `podinfo` é só a cobaia — não usa banco; é PoC da injeção).
- **Renovação × Rotação × Revogação** (o coração do capítulo — o `vault-agent` é o "advogado" da app, renovando aos **2/3 do TTL**):
  - **Renovação** (TTL longo): contrato abaixo do `max_ttl` → o agente estende o `VALID UNTIL` do **mesmo** usuário. Arquivo não muda, sem restart, **sem downtime**.
  - **Rotação** (atingiu o `max_ttl`): o cofre recusa renovar → o agente pega um usuário **novo**, reescreve o arquivo e dispara `killall podinfo`; o Pod reinicia lendo a credencial virgem e o Postgres dropa a antiga.
  - **Revogação (Zero-Trust):** Pod morre/incidente → o lease deixa de ser renovado → ao expirar, o OpenBao faz `DROP ROLE`. Senha vazada vira inútil em minutos.
- **Por que precisei de `rollout restart` ao encurtar o TTL?** Estado do **servidor** ≠ estado do **cliente**. Mudar a role no OpenBao não re-emite contratos já vivos — o agente só conhece o lease "no bolso" e não faz polling da config. Pods novos nascem **sem contrato** e pegam a regra nova na hora; os antigos só a adotariam ao bater o `max_ttl`. O `killall` automatiza o **ciclo de vida da credencial**; o `rollout restart` é a operação manual para **aplicar nova política** já.
- **Reprodutibilidade & testes** (IaC = destruir e reconstruir com um comando): a ordem no `Makefile` garante `db-up` (com `rollout status`) **antes** do `bao-setup` — o cofre valida a `connection_url` contra um banco vivo. Dois testes de caos automatizados:
  - `make test-db-pvc` → `tests/db/test-pvc.sh`: insere uma sentinela, deleta o `postgres-0`, espera o self-healing e **falha se o dado não voltar** (assertion real).
  - `make test-bao-rotation` → `tests/bao/test-rotation.sh`: **encurta o TTL** (30s/1m), reinicia a API, mata o Pod e checa que **aquele usuário exato** sumiu do `pg_roles`. `make watch-bao-rotation` faz o mesmo encurtamento e espia o arquivo em loop para ver a rotação ao vivo em ~1min. Ambos **restauram o TTL canônico (1h/24h) na saída** (via `trap`) — com o padrão você esperaria 1h/24h para ver o efeito. A definição da role mora num único lugar (`tests/bao/lib.sh`, espelhando o `setup.sh`).
- **Pendência de segurança:** `root123` ainda existe (texto plano), agora só como admin do cofre. Evoluções: rotacionar a própria senha root via OpenBao (*root rotation*) e fechar a **camada de rede** (ver `NetworkPolicy` em [conceitos](./conceitos-e-padroes.md) — hoje a rede é plana e qualquer Pod alcança o banco pelo DNS).

## 15. GitOps com ArgoCD (pull-based, 3 repos)

Saímos do deploy **push** (`make`/`kubectl apply`) para **pull**: o ArgoCD roda no cluster,
observa um repo Git e reconcilia o cluster com ele — o Git vira a fonte da verdade. Detalhe
e passo a passo em [gitops-argocd.md](./gitops-argocd.md).

- **3 repos, 2 planos:** `argocd-app` (source: código + Dockerfile + CI) → `gitops-manifests`
  (kustomize, o que o ArgoCD lê) ← `k8s-manifests` (infra + os `Application`). Os
  **manifestos** são o workload; o **`Application`** é o ponteiro de controle (governança) —
  por isso ele mora no repo de infra, não no do app (senão o CI do app mudaria a própria política).
- **Pipeline:** commit convencional → semantic-release cria `vX.Y.Z` → build/push
  `vlimanu/argocd-app:X.Y.Z` → CI dá `kustomize edit set image` no `gitops-manifests` → ArgoCD
  sincroniza. **Workflow único** (jobs por `needs`) evita o PAT que serviria só para "uma
  action disparar a outra".
- **Infra preservada por construção:** `prune` só apaga o que o ArgoCD criou (label de
  tracking); a infra do Makefile não tem esse label → intocada.
- **HPA × `selfHeal`:** o Deployment não declara `replicas` (HPA é o dono) + `ignoreDifferences`
  no Application — senão o `selfHeal` brigaria com o HPA num loop.
- **Versão pela tag:** `--build-arg APP_VERSION` → `ENV` → pydantic-settings → rota `/version`.
  O `.env` fica fora da imagem (`.dockerignore`); a versão vem 100% do build-arg.

## 16. Estratégia de CD: roll-forward × revert × rollback

Como reagir a um bug em produção sob GitOps. Doc dedicado:
[estrategia-cd-rollback.md](./estrategia-cd-rollback.md).

- **Roll-forward** (padrão): commit do fix → novo release → sync. História linear.
- **`git revert`** (rollback GitOps-correto): novo commit que inverte o ruim; Git segue
  fonte da verdade. Reverter a *tag de imagem* volta a versão na hora (imagem já no registry).
- **ArgoCD Rollback** (UI/CLI): volta o cluster a uma revisão anterior **sem mexer no Git** →
  **desabilita o auto-sync** (senão re-sincronizaria pro HEAD ruim). Alavanca de emergência;
  depois reconciliar via `git revert` + reabilitar o auto-sync.
- **Tags imutáveis** (`:X.Y.Z`, não `:latest`) são o que torna revert/rollback instantâneos.
