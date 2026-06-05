# CLAUDE.md

Este arquivo orienta o Claude Code (claude.ai/code) ao trabalhar com o código deste repositório.

## Visão geral

Manifestos Kubernetes + values do Helm para um cluster local `kind`, orquestrados inteiramente pelo `Makefile`. Sobe a app de demonstração `stefanprodan/podinfo` atrás de um HPA, busca segredos do OpenBao (fork open-source do Vault) via Vault Agent injector, e faz teste de carga com k6 transmitindo métricas para InfluxDB + Grafana. Não há código de aplicação aqui — apenas infraestrutura declarativa. Comentários e saídas dos alvos estão em português (`prod-apps` = namespace de teste; `NOVIDADE` = adição nova).

## Workflow (a ordem de subida importa)

As peças têm dependências de ordem rígidas; suba nesta sequência:

```sh
make cluster-up            # kind create cluster
make metrics-server-up     # OBRIGATÓRIO antes do HPA calcular utilização de CPU
make bao-up                # helm install do OpenBao (modo dev) no namespace `security`
make bao-setup             # bootstrap do OpenBao: semeia segredos, habilita auth k8s, escreve policy/role
make pod-info-app-up       # kubectl apply -f pod-info/ — a app depende do injector + role do OpenBao
make monitoring-up         # InfluxDB v2 + Grafana (provisiona o dashboard do k6) no `monitoring`
make monitoring-setup      # cria o usuário v1 do InfluxDB que o output do k6 precisa (senha lida do OpenBao)
make k6-config             # cria o ConfigMap k6-script a partir de tests/k6/spike.js (antes dos testes)
make run-k6-tests          # cria o Job de carga do k6 (generateName: cada run é um Job novo)
```

Derrubar: `make pod-info-app-down`, `make cluster-down`.
Observar: `make watch-all` (pods/hpa/jobs), `make hpa-pods`, `make monitoring-forward-grafana` (localhost:3000, admin/admin).
Documentação humana por tópicos em `README.md` e `docs/` (roadmap, troubleshooting, conceitos).

`make bao-up` e `make monitoring-up` instalam os charts do Helm diretamente (sem alvo idempotente de upgrade) — re-rodar sobre um release existente falha; use `helm upgrade` manualmente ou desinstale antes.

## Arquitetura & acoplamentos não-óbvios

**Fluxo de segredos (OpenBao → pods).** O `openbao/setup.sh` é a fonte da verdade: semeia `secret/podinfo` (`DATABASE_PASS`) e `secret/monitoramento` (`INFLUX_TOKEN`), habilita o auth do Kubernetes e amarra a role `app-role` à ServiceAccount `podinfo-sa` no namespace `prod-apps`. Tudo que precisa de segredo deve (a) rodar como `podinfo-sa` e (b) carregar anotações `vault.hashicorp.com/...` para o sidecar injetor buscar. Tanto `pod-info/03-deployment.yaml` quanto `tests/k6/01-job.yaml` fazem exatamente isso.

**Caminho de escrita k6 → InfluxDB (o não-óbvio).** O `--out influxdb=` embutido no k6 fala o **protocolo InfluxDB v1** e autentica por basic-auth `k6:<senha>` da URL. O InfluxDB 2.x resolve esse basic-auth contra um **mapeamento "v1 auth" usuário/senha** (`influx v1 auth ...`), *não* contra API tokens — então, sem esse mapeamento, toda escrita é rejeitada com `401 Unauthorized` (o roteamento DBRP `k6`→bucket já é virtual/automático). O `monitoring/setup.sh` (rodado por `make monitoring-setup`) cria/sincroniza esse usuário v1; a senha é **lida do OpenBao** (`secret/monitoramento` → `INFLUX_TOKEN`) — o mesmo segredo que o Job do k6 injeta — então o OpenBao continua sendo a fonte única da credencial de escrita. Re-rodar re-sincroniza a senha se ela rotacionar.

**O token do InfluxDB ainda vive hardcoded em dois pontos de leitura/bootstrap:** `monitoring/influxdb-values.yaml` (`adminUser.token`, onboarding do InfluxDB) e `monitoring/grafana-values.yaml` (`secureJsonData.token`, token de leitura do Grafana). São consumidos pelo Helm no momento do install e precisam bater com o `INFLUX_TOKEN` semeado no `openbao/setup.sh`. O caminho de *escrita* do k6 não duplica mais o segredo (deriva do OpenBao); esses dois continuam sendo um acoplamento conhecido (candidato a External Secrets Operator).

**Provisionamento do dashboard do Grafana.** O `monitoring/grafana-k6-dashboard.json` é provisionado, não importado à mão. `make grafana-dashboard-config` empacota ele no ConfigMap `k6-dashboard`, que o `grafana-values.yaml` monta via `dashboardsConfigMaps` no caminho do file provider (`monitoring-up` cria o ConfigMap *antes* de instalar o Grafana, pois é um volume). Cada painel fixa o datasource no `uid: influxdb` (sem variável de template de datasource). **Cada query mira um measurement literal** com `_field == "value"` — o output v1 do k6 grava toda métrica sob o field `value`. *Não* reintroduza uma variável `$Measurement` multi-valor em `r._measurement == "${var}"`: o multi-select quebra o match exato e todo painel desses vira "No Data" (o bug do dashboard original). Os painéis só cobrem métricas que o k6 realmente emite; o `tests/k6/spike.js` não tem `check()`, então não há painel de checks, e erros são mostrados via `http_req_failed` (taxa), não via um measurement `errors` inexistente. Após editar o JSON, rode de novo `make grafana-dashboard-config` e `kubectl rollout restart deployment/grafana -n monitoring` para recarregar.

**`pod-info/06-secret.yaml.bkp` é intencionalmente inerte** — a extensão `.bkp` impede que `kubectl apply -f pod-info/` o pegue. É o Secret em texto plano pré-OpenBao, mantido só como referência. Os segredos agora vêm da injeção do OpenBao, não deste arquivo.

**O HPA depende das declarações de CPU do injector.** O `api-podinfo-hpa` mira 50% de utilização de CPU, mas o Pod também roda um sidecar do Vault Agent. O deployment declara os requests/limits de CPU do sidecar via anotações `vault.hashicorp.com/agent-*-cpu` para a conta de porcentagem do HPA fechar. Sem o metrics-server, o HPA lê `<unknown>` e nunca escala.

**Reload na rotação de segredo.** O deployment define `shareProcessNamespace: true` mais `agent-inject-command-senha.txt: "killall podinfo"` e `agent-run-as-same-user: "true"`, de modo que, quando o segredo injetado muda, o sidecar mata o processo da app (mesmo UID 1000) para forçar um reload.

**O OpenBao roda em modo dev** (`server.dev.enabled: true`) — em memória, auto-unseal, auth por root-token. O estado se perde no restart do pod, e por isso o `bao-setup` re-semeia tudo e precisa ser re-rodado após qualquer recriação do pod do OpenBao.

## Layout

- `Makefile` — o orquestrador; comece por aqui.
- `pod-info/` — a app de demo (numerada `01`–`07`); aplicada como diretório.
- `openbao/` — `values.yaml` do Helm + script `setup.sh` de bootstrap.
- `monitoring/` — values do Helm para InfluxDB v2 e Grafana + JSON do dashboard do k6.
- `tests/k6/` — script de carga `spike.js` (rampa 0→200 VUs em 3 min, bate no Service `servico-podinfo` interno) e runner `01-job.yaml`.
- `docs/` — documentação humana por tópicos (roadmap, troubleshooting, conceitos-e-padroes).
