# taskflow-gitops — dépôt GitOps du cours CI/CD M2

Ce dépôt décrit **l'état voulu** de l'application TaskFlow dans Kubernetes.
Argo CD le surveille et aligne le cluster dessus : pour changer la production,
on ne tape pas de commande, on fait une **Pull Request**.

## Installation (à faire chez vous, avant le cours)

Prérequis : Docker Desktop démarré, 8 Go de RAM, 10 Go de disque libre.
Sous Windows : WSL2 (Ubuntu) + intégration WSL de Docker Desktop, et toutes les commandes dans WSL.

```bash
git clone https://github.com/9m7fjfpv9k-cyber/taskflow-gitops.git
cd taskflow-gitops
./scripts/install.sh
```

Le script crée un cluster local `kind`, installe Argo CD et Argo Rollouts,
puis télécharge les images des labs. Comptez 5 à 15 minutes.
Il peut être relancé sans risque.

## Structure

| Chemin | Rôle |
| --- | --- |
| `apps/taskflow/` | Les manifests surveillés par Argo CD |
| `argocd/application.yaml` | Déclare l'application dans Argo CD |
| `exemples/bluegreen/` | Manifests pour le déploiement Blue-Green |
| `exemples/canary/` | Manifests pour le déploiement Canary |
| `exemples/robustesse/` | Canary avec test de charge k6 automatique, modèle de postmortem |
| `exemples/ci/` | Pipelines de la mini-PSSI (GitHub Actions et GitLab CI) |
| `policies/` | Mini-PSSI et règles Rego vérifiées par conftest |
| `scripts/install.sh` | Installation de l'environnement |
| `scripts/argocd-ui.sh` | Ouvre l'interface d'Argo CD |
| `scripts/observe.sh` | Montre quelle version répond, et avec quel code HTTP |
| `scripts/charge.sh` | Lance à la main le test de charge k6 contre un service |

## Images disponibles

`ghcr.io/9m7fjfpv9k-cyber/taskflow` en versions `1.0.0`, `1.1.0`, `2.0.0`, `2.1.0` et `2.2.0`.

## Équipe

- Hmz92 (compte GitHub `Hmz92`)
- Ezzat Saoud (compte GitHub `ezzatsd`), relecteur des PR

## Journal des déploiements (J2, 14/10/2026)

Nous avons fait ce lab en binôme : Chaque PR était proposée par l'un de nous et relue puis approuvée par l'autre. Les heures ci-dessous sont en UTC (en France, ajoutez 2 h). Nous les avons relevées après coup dans l'historique GitHub et dans celui d'Argo CD, pour ne pas dépendre de notre mémoire.

### Comment ça s'est passé

On a commencé par installer le cluster kind avec Argo CD et Argo Rollouts, puis posé un ruleset sur `main` : plus de push direct, une PR et une approbation obligatoires. On a ensuite remplacé `VOTRE-PSEUDO` par `Hmz92` dans `argocd/application.yaml` (PR #1) et lancé le seul `kubectl apply` du lab pour déclarer l'application. Premier essai raté : nous l'avions fait avant le merge de la PR, Argo CD était donc resté sur `Unknown` en cherchant un dépôt qui n'existait pas. Après le merge et un second `apply`, tout est passé en `Synced` et `Healthy`, avec 4 pods en 1.0.0.

Ensuite, la PR #2 a passé l'image en 2.0.0. Ezzat l'a approuvée vers 09:06, nous l'avons mergée juste après, et Argo CD a déployé vers 09:09, soit **environ 2 minutes** plus tard. Ce n'est pas la minute annoncée dans le cours : Argo CD interroge Git à intervalle régulier, il n'est pas prévenu par un webhook. `observe.sh` a confirmé 40 réponses sur 40 en `version=2.0.0`.

Puis on a joué les apprentis saboteurs : `kubectl scale` pour descendre à 1 réplica, et `kubectl set image` pour remettre la 1.0.0 à la main. Dans les deux cas, Argo CD a tout remis comme Git le dit (4 pods, 2.0.0), sans que nous fassions quoi que ce soit. Nous n'avons pas noté l'heure de ces deux manipulations : nous savons donc que la correction est rapide, mais pas de combien de secondes.

Enfin, le retour arrière : le bouton Revert de GitHub sur la PR #2 a créé la PR #5, approuvée puis mergée vers 09:22. La production est repassée en 1.0.0 vers 09:24 (environ 2 minutes) et `observe.sh` a de nouveau répondu 40 fois en 1.0.0. Les pods d'origine sont revenus avec le même identifiant de ReplicaSet que le premier jour : Kubernetes avait gardé l'ancien et l'a simplement réactivé.

Pour le bonus, on a voulu voir `prune` en action : une PR (#10) a supprimé `apps/taskflow/service.yaml`, approuvée par Ezzat et mergée vers 10:19. Quelques minutes plus tard, le service avait bel et bien disparu du cluster (`No resources found`), alors que l'application restait `Synced` et `Healthy`. Pourtant, `observe.sh` ne recevait plus aucune réponse (`version=aucune http=000`) : les pods tournaient, mais plus rien ne permettait de les joindre. On a remis le service par un revert (PR #11, mergée vers 10:28). Il est revenu de lui-même en moins de deux minutes avec une nouvelle adresse interne (`10.96.231.164` au lieu de `10.96.21.92`), et `observe.sh` a de nouveau répondu 40 fois en 1.0.0.

### Le tableau

| Merge (UTC) | Ce qu'on a changé | Déployé (UTC) | Délai | Ce qu'on a constaté |
| --- | --- | --- | --- | --- |
| ~08:57 | PR #1 : `repoURL` du fork (+ `kubectl apply`) | ~08:57 | < 1 min | `Synced` + `Healthy`, 4 pods en 1.0.0 |
| ~09:07 | PR #2 : image 1.0.0 → 2.0.0 | ~09:09 | ~2 min | 40/40 en `version=2.0.0 http=200` |
| pas de merge | Dérives à la main : `scale` à 1, puis `set image` 1.0.0 | corrigé par Argo CD | non mesuré | retour automatique à 4 pods en 2.0.0 |
| ~09:22 | PR #5 : revert de la PR #2 | ~09:24 | ~2 min | 40/40 en `version=1.0.0 http=200` |
| ~09:24 | PR #6 : revert de la PR #1, **par erreur** | pas de déploiement | n/a | `application.yaml` de `main` est revenu à `VOTRE-PSEUDO` |
| ~09:43 | PR #8 : revert de la PR #6, pour réparer | pas de déploiement (seul `application.yaml` change) | n/a | `repoURL` de `main` de nouveau à `Hmz92`, Git et cluster d'accord |
| ~10:19 | PR #10 : suppression de `service.yaml` (test de `prune`) | quelques minutes après | n/a | service supprimé du cluster, application `Synced` + `Healthy`, mais `observe.sh` : `http=000` |
| ~10:28 | PR #11 : revert de la PR #10 | < 2 min | < 2 min | service recréé, 40/40 en `version=1.0.0 http=200` |

Quelques précisions : les PR #3 (premier essai de revert de la #2) et #7 (premier essai de revert de la #6) ont été fermées sans merge, remplacées par la #5 et la #8. La PR #9 est celle qui a publié ce journal et les captures.

### Preuves

- Cluster kind, Argo CD et Argo Rollouts installés : ![install](docs/preuve/00-install-cluster.png)
- Ruleset sur `main` (PR obligatoire, 1 approbation, pas de force push) : ![ruleset](docs/preuve/01-ruleset-main.png)
- PR #1, le `repoURL` : ![pr1](docs/preuve/02-pr1-repourl.png)
- `Synced` + `Healthy`, 4 pods, `observe.sh` en 1.0.0 : ![synced](docs/preuve/03-synced-healthy.png)
- PR #2, l'image 2.0.0 : ![pr2](docs/preuve/04-pr2-image-2.0.0.png)
- Nouveaux pods et `observe.sh` en 2.0.0 : ![pods](docs/preuve/05-pods-2.0.0.png)
- Après la dérive, l'image est revenue à 2.0.0 : ![derive](docs/preuve/06-derive-image.png)
- Après le revert, `observe.sh` en 1.0.0 : ![revert](docs/preuve/07-revert-1.0.0.png)
- Bonus `prune` : le service a disparu du cluster : ![prune](docs/preuve/08-prune-service-supprime.png)
- Bonus `prune` : `Synced` + `Healthy`, mais plus aucune réponse : ![prune observe](docs/preuve/09-prune-observe-echec.png)
- Bonus `prune` : service revenu après le revert, `observe.sh` en 1.0.0 : ![prune revert](docs/preuve/10-prune-service-retabli.png)

### Nos réponses aux 3 questions

**Push ou pull ?** C'est du pull. Argo CD vit dans le cluster, il va lire Git et applique l'écart. Notre pipeline n'a jamais eu besoin d'un accès au cluster. La seule commande `kubectl apply` du lab sert à déclarer l'application une fois, le reste est passé par des PR.

**Qui a corrigé quoi ?** Nous avons causé les deux dérives (le `scale` et le `set image`). C'est Argo CD qui les a détectées et défaites tout seul grâce à `selfHeal: true`. Il se fie à Git, pas à ce qui tourne dans le cluster : peu importe ce qu'on tape à la main, c'est l'état déclaré dans Git qui gagne.

**Pourquoi `git revert` ?** Parce que ça laisse une trace : un commit, une PR, un relecteur, une heure. Et on peut l'annuler à son tour, ce qui nous a d'ailleurs servi (voir ci-dessous). Un `kubectl rollout undo` ou un `set image` direct serait défait par Argo CD au prochain passage, puisque Git dirait toujours 2.0.0, et il n'y aurait aucune trace de qui a fait quoi.

### Ce que le bonus nous a appris sur `prune`

`prune: true` fait ce qu'il dit : ce qui disparaît de Git disparaît du cluster, même quand c'est un élément aussi important que le service. Argo CD n'a pas jugé que c'était dangereux, il a juste appliqué Git. L'application est restée `Healthy` alors que plus personne ne pouvait l'atteindre : l'état vu par Argo CD ne dit pas ce que vivent les utilisateurs, et il faut une vérification de l'extérieur (ici `observe.sh`) pour s'en apercevoir. Garde-fou utile : tout passe par une PR relue, donc la suppression d'un fichier aussi sensible se voit et se discute avant d'être appliquée.

### Ce qu'on retient (y compris notre erreur)

Le revert de la PR #6 avait visé la mauvaise PR : au lieu d'annuler le changement d'image, il avait annulé la correction du `repoURL`. Le cluster ne s'en est pas ressenti, car l'application avait déjà été déclarée avec le bon dépôt, mais `main` et le cluster ne disaient plus la même chose. Sans l'historique des PR et des commits, cet écart serait passé inaperçu. Nous l'avons corrigé comme le reste, par un revert du revert (PR #8), relu et approuvé par Ezzat vers 09:43.

## Lab de l'après-midi, partie A : Blue-Green (14/10/2026)

Même principe que le matin : tout changement passe par une PR, sauf la promotion, qui est une action sur le Rollout.

### Comment ça s'est passé

On a d'abord remplacé le `Deployment` par un `Rollout` Argo Rollouts en Blue-Green. La PR #13, proposée par Ezzat et approuvée par Hamza, a supprimé `deployment.yaml` et ajouté `rollout.yaml`, `service.yaml` (le service actif `taskflow`) et `service-preview.yaml` (`taskflow-preview`), avec `autoPromotionEnabled: false`. Elle a été mergée vers 11:50 et déployée par Argo CD vers 11:52. À ce stade, rien ne change pour les utilisateurs : l'image est toujours la 1.0.0, avec 4 pods.

Ensuite, la PR #14 (Hamza, approuvée par Ezzat, mergée vers 12:33) a passé l'image en 1.1.0. Argo CD l'a déployée vers 12:34, soit environ une minute et demie après le merge. Le Rollout s'est alors mis en pause (`Paused`, message `BlueGreenPause`) : la 1.1.0 tournait sur 4 nouveaux pods, mais la production n'était pas encore touchée. On avait **8 pods** pour une demande de 4, le prix du Blue-Green.

On a vérifié les deux côtés avec `observe.sh`. Le service `taskflow` répondait 40 fois sur 40 en `1.0.0`, et `taskflow-preview` 40 fois sur 40 en `1.1.0`. On pouvait donc tester la nouvelle version à côté, sans exposer personne.

Enfin, `kubectl argo rollouts promote taskflow -n taskflow` (vers 12:41, heure approximative) a fait pointer `taskflow` vers la 1.1.0. L'ancienne révision est restée 30 secondes en vie (`scaleDownDelaySeconds`, la fenêtre de retour instantané), puis est passée à `ScaledDown` : on est revenus à 4 pods, tous en 1.1.0. `observe.sh` a confirmé 40 réponses sur 40 en `1.1.0`.

| Merge (UTC) | Ce qu'on a fait | Déployé (UTC) | Constat |
| --- | --- | --- | --- |
| ~11:50 | PR #13 : `Deployment` → `Rollout` Blue-Green (+ `service-preview`) | ~11:52 | 4 pods en 1.0.0, rien ne change pour les utilisateurs |
| ~12:33 | PR #14 : image 1.0.0 → 1.1.0 | ~12:34 | `Paused`, 8 pods ; `taskflow` répond 1.0.0, `taskflow-preview` répond 1.1.0 |
| pas de PR | `promote` sur le Rollout (action sur le cluster) | ~12:41 | bascule, puis ancienne révision à 0 pod après ~30 s ; 4 pods en 1.1.0 |

### Preuves

- Le `Deployment` devient un `Rollout` (diff Git) : ![diff](docs/preuve/11-bluegreen-diff-rollout.png)
- PR #13 mergée : ![pr13](docs/preuve/12-bluegreen-pr13.png)
- La 1.1.0 démarre à côté : `Paused`, 8 pods : ![paused](docs/preuve/13-bluegreen-paused-8-pods.png)
- `taskflow` en 1.0.0, `taskflow-preview` en 1.1.0 : ![observe](docs/preuve/14-bluegreen-observe-active-preview.png)
- Juste avant la promotion : ![avant](docs/preuve/15-bluegreen-avant-promote.png)
- Après `promote` : une seule révision active, l'ancienne `ScaledDown` : ![apres](docs/preuve/16-bluegreen-apres-promote.png)
- Après `promote`, `observe.sh` en 1.1.0 : ![observe apres](docs/preuve/17-bluegreen-observe-1.1.0.png)

### Ce qu'on a observé

- **Aucun utilisateur exposé avant la bascule** : la nouvelle version a pu être testée sur `taskflow-preview` pendant que la production restait en 1.0.0.
- **Coût en ressources** : jusqu'à 8 pods au lieu de 4 pendant la transition.
- **Bascule d'un coup** : à la promotion, 100 % du trafic passe en 1.1.0 en une fois, pas progressivement.
- **Retour arrière** : instantané pendant les ~30 secondes de `scaleDownDelaySeconds`, puisque les anciens pods sont encore là. Une fois la révision 1.0.0 à 0 pod, un retour demande de recréer des pods : ce n'est plus instantané.
- **Git et cluster** : `promote` n'est pas tracé dans Git. Git disait déjà « 1.1.0 » depuis la PR #14, et c'est le cluster qui a choisi le moment de la bascule. Argo CD n'a rien défait, car il n'y a pas d'écart avec Git.

## Lab de l'après-midi, partie B : Canary (14/10/2026)

### Comment ça s'est passé

On a changé de stratégie en gardant la même version : la PR #16 a remplacé le contenu de `rollout.yaml` par celui de `exemples/canary/rollout.yaml` (image toujours en 1.1.0), puis la PR #17 a supprimé `service-preview.yaml`, devenu inutile (on l'avait d'abord oublié dans la #16, la capture le montre). Argo CD a déployé en moins d'une minute à chaque fois. Le Rollout est devenu `Strategy: Canary`, `Healthy`, 4 pods en 1.1.0.

Ensuite, la PR #18 a passé l'image en 2.0.0. Le Rollout est monté à **25 %**, soit 1 pod sur 4 en 2.0.0, puis s'est mis en pause : il attend notre `promote`. Avec `observe.sh` on a compté 8 réponses sur 40 en 2.0.0 (20 %), ce qui colle avec 1 pod sur 4. Sans ingress ni service mesh, le Canary ne peut pas viser un pourcentage précis, il suit juste le nombre de pods. Un `promote` (vers 13:43) a ensuite fait défiler les paliers 50 %, 75 % puis 100 %, avec les pauses prévues de 60 s et 30 s, et a fini en `Healthy`, 4 pods en 2.0.0, `40 version=2.0.0 http=200`. Nous étions revenus à 4 pods à tout moment : pas de pods en plus comme en Blue-Green.

Puis la PR #19 a passé l'image en **2.1.0**, la version qui plante. Au palier de 25 %, le pod canary était `Running` et `ready 1/1` : les probes étaient vertes. Pourtant, `observe.sh` a compté, sur 40 requêtes, 31 en 2.0.0 sans souci, 5 en 2.1.0 correctes, et **4 en erreur** (`version=aucune http=500`). Sur les 9 requêtes tombées sur le canary, 4 ont échoué. Seuls les utilisateurs touchés par ce pod ont vu l'erreur, soit 4 requêtes sur 40.

On a fait un `abort` (vers 14:02). Le Rollout est passé `Degraded` (`RolloutAborted`), le canary est revenu à 0 pod, les 4 pods en 2.0.0 ont repris tout le trafic, et `observe.sh` est revenu à 40 réponses en 2.0.0. Mais `rollout.yaml` de `main` disait toujours 2.1.0, et Argo CD affichait `Synced`, car pour lui rien ne s'écartait de Git. On a donc corrigé Git par une PR : un revert de la #19 (PR #21, mergée vers 14:06, la #20 avait été fermée sans merge). Après la synchronisation, le Rollout est repassé `Healthy`, Argo CD `Synced` / `Healthy`, tout en 2.0.0.

| Merge (UTC) | Ce qu'on a fait | Déployé | Constat |
| --- | --- | --- | --- |
| ~13:05 | PR #16 : `Rollout` Blue-Green → Canary (image 1.1.0) | < 1 min | `Canary`, `Healthy`, 4 pods 1.1.0 |
| ~13:15 | PR #17 : suppression de `service-preview.yaml` | < 1 min | service retiré du cluster (`prune`) |
| ~13:37 | PR #18 : image 1.1.0 → 2.0.0 | < 1 min | 25 %, `Paused`, 8/40 réponses en 2.0.0 |
| pas de PR | `promote` (~13:43) | n/a | paliers 50 %, 75 %, 100 % ; `Healthy`, 40/40 en 2.0.0 |
| ~13:53 | PR #19 : image 2.0.0 → 2.1.0 (défectueuse) | < 1 min | 25 %, pod `Ready`, mais 4 réponses `http=500` sur 40 |
| pas de PR | `abort` (~14:02) | n/a | Rollout `Degraded`, retour 40/40 en 2.0.0 ; Git toujours en 2.1.0 |
| ~14:06 | PR #21 : revert de la PR #19 | ~1 min 30 | Rollout `Healthy`, Argo CD `Synced` / `Healthy`, Git = cluster = 2.0.0 |

### Preuves

- Canary après la PR #16, et services : ![canary](docs/preuve/18-canary-rollout-et-services.png)
- PR #16 mergée : ![pr16](docs/preuve/19-canary-pr16.png)
- État de départ du Canary, 40/40 en 1.1.0 : ![etat initial](docs/preuve/20-canary-etat-initial-1.1.0.png)
- 25 %, `Paused`, 1 pod sur 4 en 2.0.0 : ![25](docs/preuve/21-canary-25pct-paused.png)
- Après `promote`, en cours de palier : ![promote](docs/preuve/22-canary-promote-palier.png)
- Palier à 75 % : ![75](docs/preuve/23-canary-75pct.png)
- 100 %, `Healthy`, 2.0.0 stable : ![100](docs/preuve/24-canary-100pct-2.0.0.png)
- La 2.1.0 : pod `Ready` mais 4 réponses en `http=500` : ![erreurs](docs/preuve/25-canary-2.1.0-erreurs-http.png)
- Après `abort` : Rollout `Degraded`, Argo CD `Synced` : ![abort](docs/preuve/26-canary-abort-degraded.png)
- Argo CD `Synced` / `Healthy` juste avant la synchro du revert : ![argocd](docs/preuve/27-canary-abort-argocd-healthy.png)
- Après la PR de revert : tout est `Healthy` en 2.0.0 : ![revert](docs/preuve/28-canary-revert-healthy.png)

### Question de vérification : un `abort` pendant un canary, que montrent le Rollout, Argo CD et Git, et que faut-il faire ensuite ?

- **Le Rollout** passe `Degraded` (`RolloutAborted`) : le canary est ramené à 0 pod et la version stable reprend tout le trafic.
- **Argo CD** reste `Synced`, car l'`abort` ne change pas ce que Git décrit : le cluster correspond toujours à Git. Sa santé a d'abord été `Degraded` (reprise de celle du Rollout) puis `Healthy` quand nous avons relancé la commande.
- **Git** dit toujours la version défectueuse (2.1.0). C'est le point à retenir : l'`abort` est une action sur le cluster, pas une décision de Git.
- **Ensuite**, il faut corriger Git par une PR : un revert de la PR qui a introduit la 2.1.0. Sans cela, Git continue de réclamer une version qu'on a rejetée, et le Rollout reste `Degraded`.

### Blue-Green ou Canary pour TaskFlow ?

Notre choix serait le **Canary**, pour ces raisons.

**Le risque.** Le défaut de la 2.1.0 était invisible pour les probes : le pod était `Ready`, et seules de vraies requêtes ont montré les erreurs 500. En Blue-Green, on aurait pu tester sur `taskflow-preview`, mais cela suppose de penser à tester ce cas précis. Si ce test est oublié, la bascule envoie 100 % des utilisateurs sur le bug d'un coup. En Canary, le même bug n'a touché que 4 requêtes sur 40 avant qu'on arrête.

**Le coût.** Le Blue-Green a demandé 8 pods pour une application qui en veut 4, soit le double de ressources pendant toute la transition. Le Canary est resté à 4 pods. Pour une petite application comme TaskFlow, doubler les ressources à chaque déploiement est difficile à justifier.

**Le retour arrière.** Il est instantané en Blue-Green, mais seulement pendant les 30 secondes de `scaleDownDelaySeconds` : ensuite les anciens pods ont disparu. En Canary, l'`abort` a rétabli la situation en quelques secondes, avec peu de dégâts.

**Les limites du Canary** : ici, sans ingress ni service mesh, le pourcentage dépend du nombre de pods (25 % = 1 pod sur 4), il n'est pas précis. Et c'est nous qui avons dû repérer les erreurs et faire l'`abort` à la main : un système qui détecte et annule tout seul serait préférable. Le Blue-Green resterait un bon choix si on voulait une bascule nette et testée d'avance, par exemple quand deux versions ne peuvent pas cohabiter.

### Ce qu'on retient du lab

Un déploiement progressif limite les dégâts d'un bug mais ne les empêche pas, et les probes ne remplacent pas une mesure côté utilisateurs. Dans les deux cas, les actions faites sur le cluster (`promote`, `abort`) ne sont pas tracées dans Git : c'est la PR qui remet Git et la réalité d'accord.

