# CLAUDE.md

Este arquivo orienta o Claude Code (claude.ai/code) ao trabalhar com o código deste repositório.

## Visão geral

Manifestos Kubernetes + values do Helm para um cluster local `kind`, orquestrados pelo `Makefile` (provisionamento) + `tests/Makefile` (execução dos testes; o raiz só encaminha os alvos test-*/k6-*). Sobe a app de demonstração `stefanprodan/podinfo` atrás de um HPA, busca segredos do OpenBao (fork open-source do Vault) via Vault Agent injector, e faz teste de carga com k6 transmitindo métricas para InfluxDB + Grafana. Não há código de aplicação aqui — apenas infraestrutura declarativa. As **aplicações** (`podinfo` e a API FastAPI `argocd-app`) não vivem mais neste repo: migraram para o repo `gitops-manifests` (kustomize) e são gerenciadas pelo **ArgoCD** (GitOps pull-based). Este repo guarda a infra + os `Application` (ponteiros de controle) em `argocd/`. Ver `docs/gitops-argocd.md`. Comentários e saídas dos alvos estão em português (`prod-apps` = namespace de teste; `NOVIDADE` = adição nova).

## Workflow (a ordem de subida importa)

As peças têm dependências de ordem rígidas; suba nesta sequência:

```sh
make cluster-up            # kind create cluster
make metrics-server-up     # OBRIGATÓRIO antes do HPA calcular utilização de CPU
make bao-up                # helm install do OpenBao (modo dev) no namespace `security`
make argocd-install        # instala o ArgoCD no namespace `argocd` (apps sobem pela UI — ver docs/gitops-argocd.md)
make db-up                 # PostgreSQL (StatefulSet + PVC) no namespace `database` — o cofre precisa dele vivo
make bao-setup             # bootstrap do OpenBao: semeia segredos KV, configura o Database Engine, auth k8s, policy/role
make monitoring-up         # InfluxDB v2 + Grafana (provisiona o dashboard do k6) no `monitoring`
make monitoring-setup      # cria o usuário v1 do InfluxDB que o output do k6 precisa (senha lida do OpenBao)
make k6-config             # cria o ConfigMap k6-script a partir de tests/k6/spike.js (antes dos testes)
make run-k6-tests          # cria o Job de carga do k6 (generateName: cada run é um Job novo)
```

Derrubar: `make cluster-down` (as apps são gerenciadas pelo ArgoCD, não por `make`).
Observar: `make watch-all` (pods/hpa/jobs), `make hpa-pods`, `make monitoring-forward-grafana` (localhost:3000, admin/admin).
Documentação humana por tópicos em `README.md` e `docs/` (roadmap, troubleshooting, conceitos).

`make bao-up` e `make monitoring-up` instalam os charts do Helm diretamente (sem alvo idempotente de upgrade) — re-rodar sobre um release existente falha; use `helm upgrade` manualmente ou desinstale antes.

**Provisionamento × testes.** Os alvos de provisionamento (cluster, helm installs, setups) vivem no `Makefile` raiz; os de teste vivem em `tests/Makefile` e o raiz apenas os encaminha. Ao adicionar um alvo novo, coloque-o no arquivo certo e, se for de teste, inclua o nome na linha `.PHONY` de encaminhamento do raiz (senão `make <alvo>` da raiz não o acha). Variáveis de linha de comando (ex.: `NAMESPACE=`, `ESPERA=`) propagam ao sub-make automaticamente.

## Arquitetura & acoplamentos não-óbvios

**Fluxo de segredos (OpenBao → pods).** O `openbao/setup.sh` é a fonte da verdade: semeia `secret/podinfo` (`DATABASE_PASS`) e `secret/monitoramento` (`INFLUX_TOKEN`), habilita o auth do Kubernetes e amarra a role `app-role` à ServiceAccount `podinfo-sa` no namespace `prod-apps`. Tudo que precisa de segredo deve (a) rodar como `podinfo-sa` e (b) carregar anotações `vault.hashicorp.com/...` para o sidecar injetor buscar. Tanto `gitops-manifests/podinfo/deployment.yaml` quanto `tests/k6/01-job.yaml` fazem exatamente isso.

**Credenciais dinâmicas do banco (Database Engine).** Além do motor `kv`, o `setup.sh` liga o motor `database`: dá ao OpenBao o `root` do PostgreSQL (`postgres`/`root123`) e cria a role `app-role` que **gera usuários efêmeros sob demanda** (`v-root-app-role-…`, `default_ttl=1h`/`max_ttl=24h`). O `gitops-manifests/podinfo/deployment.yaml` **não usa mais** o KV `secret/podinfo`: suas anotações apontam para `database/creds/app-role` e o template injeta `DB_USER`/`DB_PASS` em `/vault/secrets/db-creds.env` (a `app-policy` precisa de `read` nessa rota). **Ordem importa:** `db-up` antes de `bao-setup` — a config `database/config/meubanco` valida a `connection_url` contra um banco vivo. O `secret/podinfo` (`DATABASE_PASS`) segue semeado, mas hoje é legado/PoC (a app migrou para credenciais dinâmicas). `root123` ainda em texto plano no manifesto do Postgres é dívida conhecida (candidato a *root rotation* pelo OpenBao).

**Caminho de escrita k6 → InfluxDB (o não-óbvio).** O `--out influxdb=` embutido no k6 fala o **protocolo InfluxDB v1** e autentica por basic-auth `k6:<senha>` da URL. O InfluxDB 2.x resolve esse basic-auth contra um **mapeamento "v1 auth" usuário/senha** (`influx v1 auth ...`), *não* contra API tokens — então, sem esse mapeamento, toda escrita é rejeitada com `401 Unauthorized` (o roteamento DBRP `k6`→bucket já é virtual/automático). O `monitoring/setup.sh` (rodado por `make monitoring-setup`) cria/sincroniza esse usuário v1; a senha é **lida do OpenBao** (`secret/monitoramento` → `INFLUX_TOKEN`) — o mesmo segredo que o Job do k6 injeta — então o OpenBao continua sendo a fonte única da credencial de escrita. Re-rodar re-sincroniza a senha se ela rotacionar.

**O token do InfluxDB ainda vive hardcoded em dois pontos de leitura/bootstrap:** `monitoring/influxdb-values.yaml` (`adminUser.token`, onboarding do InfluxDB) e `monitoring/grafana-values.yaml` (`secureJsonData.token`, token de leitura do Grafana). São consumidos pelo Helm no momento do install e precisam bater com o `INFLUX_TOKEN` semeado no `openbao/setup.sh`. O caminho de *escrita* do k6 não duplica mais o segredo (deriva do OpenBao); esses dois continuam sendo um acoplamento conhecido (candidato a External Secrets Operator).

**Provisionamento do dashboard do Grafana.** O `monitoring/grafana-k6-dashboard.json` é provisionado, não importado à mão. `make grafana-dashboard-config` empacota ele no ConfigMap `k6-dashboard`, que o `grafana-values.yaml` monta via `dashboardsConfigMaps` no caminho do file provider (`monitoring-up` cria o ConfigMap *antes* de instalar o Grafana, pois é um volume). Cada painel fixa o datasource no `uid: influxdb` (sem variável de template de datasource). **Cada query mira um measurement literal** com `_field == "value"` — o output v1 do k6 grava toda métrica sob o field `value`. *Não* reintroduza uma variável `$Measurement` multi-valor em `r._measurement == "${var}"`: o multi-select quebra o match exato e todo painel desses vira "No Data" (o bug do dashboard original). Os painéis só cobrem métricas que o k6 realmente emite; o `tests/k6/spike.js` não tem `check()`, então não há painel de checks, e erros são mostrados via `http_req_failed` (taxa), não via um measurement `errors` inexistente. Após editar o JSON, rode de novo `make grafana-dashboard-config` e `kubectl rollout restart deployment/grafana -n monitoring` para recarregar.

**`pod-info/06-secret.yaml.bkp` é o Secret em texto plano pré-OpenBao** (a extensão `.bkp` o tornava inerte), mantido só como referência. A pasta `pod-info/` é **legado em remoção** — migrou para `gitops-manifests/podinfo/` (sem o `.bkp`). Os segredos vêm da injeção do OpenBao, não deste arquivo.

**O HPA depende das declarações de CPU do injector.** O `api-podinfo-hpa` mira 50% de utilização de CPU, mas o Pod também roda um sidecar do Vault Agent. O deployment declara os requests/limits de CPU do sidecar via anotações `vault.hashicorp.com/agent-*-cpu` para a conta de porcentagem do HPA fechar. Sem o metrics-server, o HPA lê `<unknown>` e nunca escala.

**Reload na rotação de credencial.** O deployment define `shareProcessNamespace: true` mais `agent-inject-command-db-creds.env: "killall podinfo"` e `agent-run-as-same-user: "true"`, de modo que, quando a credencial **rotaciona** (o lease bate no `max_ttl`), o sidecar mata o processo da app (mesmo UID 1000) para forçar o reload. Enquanto o lease só **renova** (abaixo do `max_ttl`), o arquivo não muda e não há restart. Mudar a config da role no OpenBao **não** afeta Pods vivos — eles só conhecem o lease que já têm; use `kubectl rollout restart deployment/api-podinfo -n prod-apps` para forçar a política nova (estado servidor × cliente; ver `docs/conceitos-e-padroes.md`).

**O OpenBao roda em modo dev** (`server.dev.enabled: true`) — em memória, auto-unseal, auth por root-token. O estado se perde no restart do pod, e por isso o `bao-setup` re-semeia tudo e precisa ser re-rodado após qualquer recriação do pod do OpenBao.

**GitOps com ArgoCD (apps fora deste repo).** As aplicações são gerenciadas pelo ArgoCD a partir do repo `gitops-manifests` (kustomize, overlays `argocd-app/` e `podinfo/`). Este repo só guarda os `Application` em `argocd/` — **espelhos saneados** do que é criado pela UI; **NÃO** aplique-os via `kubectl` (o bootstrap é pela UI; a credencial do repo privado vem do Connect Repo da UI, virando Secret no namespace `argocd`, nunca embutida na `repoURL`). O `Application` é governança/infra: por isso mora aqui, não no repo do app (senão o CI do app mudaria o próprio destino/política). Passo a passo em `docs/gitops-argocd.md`; tratativa de bug (revert/rollback/roll-forward) em `docs/estrategia-cd-rollback.md`.

**Infra preservada por construção.** Cada `Application` tem `path` escopado e `prune` só apaga recursos com o label de tracking do ArgoCD (`app.kubernetes.io/instance`). OpenBao/monitoring/database/Traefik sobem pelo Makefile, sem esse label → o ArgoCD nunca os toca.

**HPA × `selfHeal` (e acoplamento do podinfo).** O Deployment do podinfo (`gitops-manifests/podinfo/deployment.yaml`) **não declara `replicas`** (o HPA é o dono) e o `argocd/podinfo-app.yaml` tem `ignoreDifferences` em `/spec/replicas` — sem isso o `selfHeal` brigaria com o HPA num loop. O overlay `podinfo/` **precisa** manter `namespace: prod-apps` + SA `podinfo-sa` (a role do OpenBao está amarrada a esse par). Nenhum overlay declara o recurso `Namespace`: o `CreateNamespace=true` cria (evita dois Apps disputando o mesmo objeto).

**CI do `argocd-app` (repo de source).** Um **workflow único** (`release→build→bump` por `needs`): semantic-release cria `vX.Y.Z`, builda `vlimanu/argocd-app:X.Y.Z` no Docker Hub, e dá `kustomize edit set image` no `gitops-manifests`. Sem `SEMANTIC_RELEASE_TOKEN` (o build é job downstream, não workflow disparado por push de tag — só o `GITHUB_TOKEN` basta). A versão flui por `--build-arg APP_VERSION` → `ENV` → pydantic-settings → rota `/version`; o `.env` fica fora da imagem (`.dockerignore`).

## Layout

- `Makefile` — o orquestrador de **provisionamento**; comece por aqui.
- `tests/Makefile` — a **execução dos testes** (test-db-pvc, test/watch-bao-rotation, k6-config, run/clean-k6-tests). O Makefile raiz só encaminha esses alvos (`$(MAKE) -C tests $@`), então `make run-k6-tests` etc. seguem funcionando da raiz; rodar `make -C tests <alvo>` também funciona.
- `argocd/` — os `Application` do ArgoCD (`argocd-app.yaml`, `podinfo-app.yaml`): espelhos saneados, **NÃO** aplicados via kubectl.
- `pod-info/` — **legado em remoção**: migrou para `gitops-manifests/podinfo/` (gerenciado pelo ArgoCD).
- `database/` — PostgreSQL (StatefulSet + PVC) no namespace `database`; primeira peça stateful.
- `openbao/` — `values.yaml` do Helm + script `setup.sh` de bootstrap (KV + Database Engine).
- `monitoring/` — values do Helm para InfluxDB v2 e Grafana + JSON do dashboard do k6.
- `tests/k6/` — script de carga `spike.js` (rampa 0→200 VUs em 3 min, bate no Service `servico-podinfo` interno) e runner `01-job.yaml`.
- `tests/db/` — `test-pvc.sh`: teste de caos da persistência do PVC (`make test-db-pvc`).
- `tests/bao/` — `test-rotation.sh`/`watch-rotation.sh` (revogação/rotação; encurtam o TTL e restauram via `trap`) + `lib.sh` compartilhado (`make test-bao-rotation`, `make watch-bao-rotation`).
- `docs/` — documentação humana por tópicos (roadmap, troubleshooting, conceitos-e-padroes).
