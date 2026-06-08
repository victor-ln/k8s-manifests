# GitOps com ArgoCD — o passo a passo

Como o lab saiu do `kubectl apply`/`make` (push) para **GitOps pull-based** com o ArgoCD,
e o passo a passo para você reproduzir. Continua o [passo 2 do roadmap](./roadmap.md#2-estado-declarativo-e-reconciliação)
(estado declarativo e reconciliação): o ArgoCD é um **Control Loop** que vive no cluster e
reconcilia o estado real com o Git — em vez de você empurrar o estado, ele **puxa**.

## Conceitos

### Push × Pull
- **Push (antes):** `make pod-info-app-up` rodava `kubectl apply` da sua máquina/CI. Quem
  tem o `kubeconfig` manda no cluster; o Git é só um arquivo morto que pode divergir do real.
- **Pull (ArgoCD):** o ArgoCD roda **dentro** do cluster, observa um repo Git e aplica o
  que está lá. O Git vira a **fonte da verdade**; o cluster persegue o Git. Ninguém precisa
  de `kubeconfig` para fazer deploy — basta um commit.

### Os dois planos (a distinção que organiza tudo)
1. **Manifestos da aplicação** (Deployment, Service, HPA…) — o *workload*. Vivem no repo
   **`gitops-manifests`** (kustomize). É o que o ArgoCD lê e o que o CI do app atualiza.
2. **O objeto `Application`** do ArgoCD — o *ponteiro de controle*: diz qual repo/path
   observar, em que namespace, com que política. **Isso é governança/infra, não app.** Mora
   no repo de infra (`k8s-manifests/argocd/`). Se ficasse junto do app, o CI do app poderia
   mudar o próprio destino/política — quebrando a separação de responsabilidades.

### Topologia (3 repos)
```
argocd-app (source) ──build+push──▶ Docker Hub (vlimanu/argocd-app:vX)
      │ CI: kustomize edit set image
      ▼
gitops-manifests (kustomize) ◀──observa── ArgoCD ◀── argocd/*.yaml (k8s-manifests)
```
- **`argocd-app`** — código FastAPI + Dockerfile + CI (um workflow só).
- **`gitops-manifests`** — overlays `argocd-app/` e `podinfo/`. Fonte da verdade do ArgoCD.
- **`k8s-manifests`** (este) — cluster + cofre + monitoring + os `Application` (em `argocd/`).

## Passo a passo

### 1. Subir o ArgoCD
```sh
make argocd-install          # instala no namespace argocd e espera o server
make argocd-pass             # imprime a senha inicial do usuário admin
make argocd-forward          # UI em https://localhost:8080 (admin / <senha>)
```

### 2. Preparar os repositórios
- O **`argocd-app`** já existe (source). Confirme os secrets/vars do CI (ver
  [README do argocd-app](https://github.com/victor-ln/argocd-app)).
- Crie o **`gitops-manifests`** (privado) e suba os overlays (`argocd-app/` e `podinfo/`).

### 3. Credenciais
- **Revogue** qualquer PAT que tenha sido versionado e gere um novo (escopo mínimo).
- O token do repo **não** vai em arquivo nem na `repoURL` do Application — vai no Connect
  Repo (passo 4), que o ArgoCD guarda como Secret no namespace `argocd`.

### 4. Connect Repo (pela UI)
`Settings → Repositories → + Connect Repo` → **VIA HTTPS** → URL do `gitops-manifests`,
`username` + `password` (o PAT). Status deve ficar **Successful**. Isso cria um Secret
`repository` no namespace `argocd` — a credencial fica no cluster, fora do Git.

### 5. Criar os dois Applications (pela UI)
`+ NEW APP`, duas vezes:

| Campo            | argocd-app                  | podinfo-gitops             |
| ---------------- | --------------------------- | -------------------------- |
| Project          | `default`                   | `default`                  |
| Repo URL         | `gitops-manifests`          | `gitops-manifests`         |
| Path             | `argocd-app`                | `podinfo`                  |
| Revision         | `HEAD`                      | `HEAD`                     |
| Cluster          | `https://kubernetes.default.svc` | idem                  |
| Namespace        | `argocd-app`                | `prod-apps`                |
| Sync Policy      | Automatic + Prune + Self Heal | idem                     |
| Sync Options     | `Auto-Create Namespace`     | idem                       |

Depois, **espelhe** o que você preencheu em `argocd/argocd-app.yaml` e
`argocd/podinfo-app.yaml` (já estão prontos como referência saneada) e commite no repo de
infra. Eles documentam a governança, mas **não** são aplicados via kubectl.

### 6. Rodar o ciclo (o teste-mestre)
No `argocd-app`: `git commit -m "feat: nova rota"` → push na `main`. Acompanhe:
1. **Actions:** `release` cria `vX.Y.Z`; `build` publica `vlimanu/argocd-app:X.Y.Z`; `bump`
   commita a nova tag no `gitops-manifests`.
2. **ArgoCD UI:** o App `argocd-app` fica **OutOfSync** e re-sincroniza sozinho.
3. `curl` na rota `/version` → mostra a versão nova. **Você acabou de ver o GitOps.**

## Acoplamentos & pegadinhas (não-óbvios)

- **Infra preservada por construção.** Cada Application tem `path` escopado a uma pasta, e
  `prune` só apaga recursos que o **próprio ArgoCD** criou (rastreados por label
  `app.kubernetes.io/instance`). OpenBao, monitoring, database e Traefik subiram pelo
  Makefile, **sem** esse label → o ArgoCD nunca os toca.
- **HPA × `selfHeal`.** O Deployment do podinfo **não declara `replicas`** (o HPA é o dono);
  e o `Application` tem `ignoreDifferences` em `/spec/replicas`. Sem isso, o `selfHeal`
  resetaria as réplicas e brigaria com o HPA num loop.
- **Sidecar do OpenBao não gera drift.** O webhook injeta o sidecar no **Pod** (admission),
  não no Deployment. O objeto que o ArgoCD compara (Deployment) não muda → fica Synced.
- **Acoplamento com o cofre.** O overlay `podinfo/` **precisa** manter `namespace: prod-apps`
  e a SA `podinfo-sa` — a role do OpenBao (`openbao/setup.sh`) está amarrada a esse par.
- **Namespace.** Nenhum overlay declara o recurso `Namespace`; o `CreateNamespace=true` cria
  (evita dois Apps disputando o mesmo objeto).
- **`make pod-info-app-up` morreu.** Quem aplica os manifestos agora é o ArgoCD. Aplicar à
  mão criaria recursos sem o tracking label e confundiria o estado.

## Tratativa de bug

Rollback, revert e roll-forward sob esta estratégia de CD: ver
[estrategia-cd-rollback.md](./estrategia-cd-rollback.md).
