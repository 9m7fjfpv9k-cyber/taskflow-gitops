# Postmortem — TaskFlow 2.1.0 : erreurs 500 et latence sur l'API

> Sans reproche : on cherche ce qui a permis l'erreur, pas qui l'a faite.

| Champ | Valeur |
| --- | --- |
| Date et heure | 15 octobre 2026, de 10:50 à 10:59 (heure de Paris) |
| Version en cause | `ghcr.io/9m7fjfpv9k-cyber/taskflow:2.1.0` |
| PR à l'origine | PR #22 (passage de l'image de 2.0.0 à 2.1.0 dans `apps/taskflow/rollout.yaml`) |
| Durée d'exposition | Environ 1 minute, de 10:50:41 (passage à 25 %) à 10:51:40 (abort automatique) |
| Part du trafic touché | Environ 25 % (1 pod sur 4), dont environ 1 requête sur 3 en erreur 500, soit de l'ordre de 7 % du trafic total |
| Détecté par | Test de charge k6 lancé automatiquement par Argo Rollouts (AnalysisRun `taskflow-df976ccb5-7-2`) |
| Résolu par | Abort automatique du Rollout, puis `git revert` de la PR #22 (PR #23) |

## Résumé

La version 2.1.0 a été déployée en Canary par une PR. Au palier de 25 %, l'analyse automatique a lancé un test de charge k6 sur le seul pod 2.1.0 : 27 % des requêtes ont échoué et le p95 est monté à 313 ms, au-delà des deux seuils (moins de 2 % d'erreurs, p95 sous 250 ms). Argo Rollouts a donc annulé le déploiement tout seul, et la production est restée en 2.0.0. Le repo a ensuite été remis en accord avec le cluster par un revert de la PR.

## Chronologie

| Heure | Événement |
| --- | --- |
| 10:50:34 | Fusion de la PR #22 (image 2.1.0) |
| 10:50:41 | Argo CD synchronise : passage à 25 %, 1 pod en 2.1.0 et 3 pods en 2.0.0 |
| 10:50:43 | Le service `taskflow-canary` bascule sur le pod 2.1.0 |
| 10:51:03 | Fin de la pause de 20 s : lancement de l'AnalysisRun (Job k6 sur `taskflow-canary`) |
| 10:51:40 | Seuils dépassés : AnalysisRun en échec, abort automatique, retour à 4 pods en 2.0.0 |
| 10:51:40 | Le Rollout et l'application Argo CD passent en Degraded (le repo demande toujours la 2.1.0) |
| 10:58:55 | Fusion de la PR #23 (revert de la PR #22) |
| 10:59:26 | Argo CD synchronise : le Rollout reconnaît la version stable et repasse en Healthy, sans redéploiement |
| 11:05:38 | La 2.2.0 (PR #24) passe l'analyse et termine son déploiement à 100 % |

## Composant défaillant et cause racine

**Quel composant a échoué ?**

L'API TaskFlow elle-même, dans l'image 2.1.0. Toutes les routes, sauf `/health`, répondent environ 1 fois sur 3 en erreur 500, avec 300 ms de latence ajoutée.

Preuve 1, l'AnalysisRun en échec :

```console
$ kubectl get analysisrun -n taskflow
NAME                     STATUS   AGE
taskflow-df976ccb5-7-2   Failed   86s

$ kubectl describe analysisrun taskflow-df976ccb5-7-2 -n taskflow
  Message:  Metric "test-de-charge-k6" assessed Failed due to failed (1) > failureLimit (0)
```

Preuve 2, les mesures de k6 sur le pod 2.1.0 :

```console
$ kubectl logs -n taskflow job/23fb84b8-9a34-48ce-809b-94cca62c024f.test-de-charge-k6.1
    ✗ 'p(95)<250' p(95)=313.27ms
    ✗ 'rate<0.02' rate=27.02%
    http_req_failed................: 27.02% 80 out of 296
```

Preuve 3, l'abort automatique dans les événements du Rollout :

```console
$ kubectl describe rollout taskflow -n taskflow
  Warning  AnalysisRunFailed  Step Analysis Run 'taskflow-df976ccb5-7-2' Status New: 'Failed' Previous: 'Running'
  Warning  RolloutAborted     Rollout aborted update to revision 7: Step-based analysis phase error/failed: Metric "test-de-charge-k6" assessed Failed due to failed (1) > failureLimit (0)
  Normal   ScalingReplicaSet  Scaled up ReplicaSet taskflow-c6cf57bd6 (revision 6) from 3 to 4
  Normal   ScalingReplicaSet  Scaled down ReplicaSet taskflow-df976ccb5 (revision 7) from 1 to 0
```

Preuve 4, l'image 2.1.0 lancée en local, hors du cluster :

```console
$ docker run -d --rm --name t210 -p 8001:8000 ghcr.io/9m7fjfpv9k-cyber/taskflow:2.1.0
$ curl -s localhost:8001/health
{"status":"ok","version":"2.1.0","pod":"866cbb37be90"}      # HTTP 200 en 4 ms
$ for i in $(seq 1 15); do curl -s -o /dev/null -w '%{http_code}\n' localhost:8001/tasks; done | sort | uniq -c
     10 200
      5 500                                                  # environ 300 ms par requête

$ docker image inspect ghcr.io/9m7fjfpv9k-cyber/taskflow:2.1.0 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'FAILURE|LATENCY'
FAILURE_RATE=0.3
LATENCY_MS=300
```

**Pourquoi les probes Kubernetes ne l'ont-elles pas vu ?**

Nos deux probes (`readinessProbe` et `livenessProbe`) ne testent que `/health`. Or le middleware de l'application qui applique `FAILURE_RATE` et `LATENCY_MS` épargne justement cette route :

```python
@app.middleware("http")
async def inject_faults(request: Request, call_next):
    """Simule une version défaillante : /health reste sain, les utilisateurs souffrent."""
    if request.url.path != "/health":
        ...
```

Pour Kubernetes, le pod 2.1.0 était donc `ready:1/1` et parfaitement sain, alors que les utilisateurs recevaient des erreurs. Les probes vérifient que le pod est vivant, pas qu'il rend un bon service.

**Cause racine :**

L'image 2.1.0 est construite avec une configuration qui dégrade le service (`FAILURE_RATE=0.3`, `LATENCY_MS=300`), et rien dans notre chaîne ne testait les vraies routes de l'application avant qu'elle reçoive du trafic de production. La seule vérification avant la mise en service était la probe sur `/health`, qui ne voit pas ce type de panne. C'est l'analyse k6, ajoutée juste avant, qui a rattrapé l'erreur au premier palier du Canary.

## Ce qui a bien fonctionné

- **Détection automatique :** le test de charge k6 a repéré la panne en 37 secondes, sans intervention humaine.
- **Exposition limitée :** grâce au Canary, la 2.1.0 n'a reçu qu'environ 25 % du trafic, pendant environ une minute.
- **Retour arrière automatique :** l'abort a remis les 4 pods en 2.0.0 immédiatement, sans attendre une PR.
- **Test ciblé :** le service `taskflow-canary` a permis de tester uniquement les pods de la nouvelle version, ce qui rend le résultat net (27 % d'erreurs sur la 2.1.0, au lieu d'une moyenne diluée avec la 2.0.0).
- **Revert sans redéploiement :** le `git revert` a remis le repo en accord avec le cluster, et Argo Rollouts a reconnu la version stable déjà en place.
- **Validation de la correction :** la 2.2.0 a passé la même analyse (0 % d'erreurs, p95 de 10,85 ms) et s'est déployée seule jusqu'à 100 %.

## Actions correctives

| Action | Responsable | Échéance |
| --- | --- | --- |
| Faire tester une vraie route (par exemple `/tasks`) à la `readinessProbe`, ou faire vérifier le service réel par `/health` | Matteo MENCUCCINI | 16/10/2026 |
| Lancer le test de charge k6 dans la CI sur l'image, avant la fusion de la PR, pour bloquer une version défaillante avant même le cluster | Sabri ABID | 23/10/2026 |
| Ajouter une règle conftest qui refuse les variables d'injection de pannes (`FAILURE_RATE`, `LATENCY_MS`) dans les manifests et images de production | Sabri ABID | 23/10/2026 |
| Ajouter des scénarios k6 sur les autres routes (création, recherche, suppression), pour ne pas tester que `/tasks` en lecture | Matteo MENCUCCINI | 30/10/2026 |
