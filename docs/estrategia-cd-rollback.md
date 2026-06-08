# Estratégia de CD — tratativa de bug (roll-forward, revert, rollback)

Quando uma versão entra com bug, há **três** formas de reagir sob GitOps com ArgoCD. A
escolha não é gosto: depende de **urgência**, **confiança no fix** e de **manter o Git como
fonte da verdade**. Conhecimento transferível — vale para qualquer stack GitOps, não só
este lab.

> **Princípio:** no GitOps, o estado desejado é o que está no Git. Qualquer correção que
> **não** passe pelo Git é, por definição, *drift* — tolerável só como medida de emergência,
> e sempre reconciliada de volta ao Git depois.

## Os três caminhos

### 1. Roll-forward (fix forward) — o padrão
Corrigir para frente: novo commit com o conserto → CI gera nova versão → ArgoCD sincroniza.

- **Quando:** o bug tem fix rápido e de baixo risco; você entende a causa.
- **Como:** `fix: ...` no `argocd-app` → sai `vX.Y.(Z+1)` → bump → ArgoCD aplica.
- **Prós:** história linear, auditável; o Git nunca mente. **Contras:** leva o tempo de um
  ciclo de CI (build + push + sync).

### 2. `git revert` — o "rollback GitOps-correto"
Desfazer um commit ruim criando **um novo commit** que o inverte. O Git continua a fonte da
verdade; o ArgoCD aplica o estado revertido.

- **Quando:** precisa voltar atrás, mas sem abrir mão do GitOps; o ciclo de CI cabe na
  janela de impacto.
- **Como (no `gitops-manifests`):**
  ```sh
  git revert <sha-do-bump-ruim>   # cria commit que volta a tag de imagem anterior
  git push                        # ArgoCD detecta e re-sincroniza
  ```
  Reverter a *tag de imagem* (no `gitops-manifests`) volta a versão **na hora** (a imagem
  antiga já existe no registry) — não espera rebuild. Reverter no **`argocd-app`** (código)
  dispara um novo ciclo de CI.
- **Prós:** auditável (o erro e o revert ficam registrados), Git = verdade. **Contras:**
  ainda passa pelo polling/sync do ArgoCD (segundos a ~3 min).

### 3. ArgoCD Rollback (UI/CLI) — a alavanca de emergência
Pela UI (`History and Rollback` → escolher uma revisão Synced anterior → `Rollback`) ou
`argocd app rollback <app> <id>`. O ArgoCD aplica **uma revisão de Git anterior** ao
cluster — **sem mexer no Git**.

- ⚠️ **Efeito colateral crítico:** o Rollback **desabilita o auto-sync**. Tem que ser: se o
  auto-sync continuasse ligado, o ArgoCD veria "cluster (revisão antiga) ≠ HEAD (revisão
  ruim)" e **re-sincronizaria para o HEAD ruim na hora**, desfazendo seu rollback. Por isso
  ele se protege desligando o automático.
- **Quando:** incidente em andamento, "estancar o sangramento" mais rápido que um round-trip
  no Git. É **temporário por natureza**.
- **Depois, obrigatório reconciliar:** `git revert` (ou fix) no `gitops-manifests` para que
  o HEAD volte a refletir o estado bom, e **reabilite o auto-sync**. Enquanto não fizer
  isso, o cluster está em *drift* e o Git está mentindo.

## Matriz de decisão

| Situação                                              | Caminho            |
| ----------------------------------------------------- | ------------------ |
| Bug pequeno, causa clara, fix rápido                  | **Roll-forward**   |
| Precisa voltar a versão, dá pra esperar o sync        | **`git revert`**   |
| Incidente quente, cada segundo conta                  | **ArgoCD Rollback** → depois `git revert` + reabilitar auto-sync |
| Mudança de config (não de imagem) entrou errada       | `git revert` do commit de config |

Regra de bolso: **prefira `git revert`**; use o Rollback da UI só quando o tempo do ciclo de
Git for inaceitável — e sempre reconcilie em seguida.

## Por que tags de imagem imutáveis importam
O `revert`/rollback só é instantâneo porque cada versão é uma **tag fixa** (`vlimanu/argocd-app:1.2.3`)
que continua no registry. Por isso o CI também publica `:X.Y.Z` além de `:latest`, e o
`gitops-manifests` referencia a tag exata (via `kustomize edit set image`). Apontar para
`:latest` quebraria o rollback: "latest" muda embaixo de você e o ArgoCD nem perceberia o
drift (mesma string de imagem, conteúdo diferente).

## Conexão com "estado servidor × cliente"
O mesmo princípio do [roadmap (passo 14)](./roadmap.md#14-credenciais-dinâmicas-do-banco-openbao-database-engine)
e de [conceitos](./conceitos-e-padroes.md): mudar a regra no servidor (Git/HEAD) não muda o
que já está aplicado até haver reconciliação. O `selfHeal` reconcilia continuamente; o
Rollback **pausa** essa reconciliação de propósito — entender isso é entender por que o
auto-sync cai.

## Checklist de incidente
1. **Estancar:** Rollback pela UI (se urgente) **ou** `git revert` (se couber no tempo).
2. **Confirmar:** App `Healthy`/`Synced`; `/version` mostra a versão boa.
3. **Reconciliar:** garantir que o HEAD do `gitops-manifests` reflete o estado bom.
4. **Reabilitar** o auto-sync (se usou Rollback da UI).
5. **Post-mortem:** o `git revert` e o release ruim ficam na história — use-os.
