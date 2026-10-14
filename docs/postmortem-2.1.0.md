# Postmortem — la 2.1.0 est passée en production malgré l'analyse automatique

> Sans reproche : on cherche ce qui a permis l'erreur, pas qui l'a faite.

| Champ | Valeur |
| --- | --- |
| Date et heure | 8 octobre, de 11:35 à 12:19 (heure de Paris) |
| Version en cause | TaskFlow 2.1.0 |
| PR à l'origine | PR #14 « Image 2.1.0 » |
| Durée d'exposition | environ 44 minutes : premier pod en 2.1.0 vers 11:35, retour complet en 2.0.0 à 12:19:09 |
| Part du trafic touché | 1 pod sur 4 pendant 2 minutes, puis 100 % des pods à partir de 11:38 environ |
| Ce que voyaient les utilisateurs | 25 à 33 % de réponses `http=500`, et environ 300 ms de plus sur chaque réponse |
| Détecté par | un humain, avec `observe.sh` à 11:54. Le test de charge automatique n'a rien signalé |
| Résolu par | `git revert` de la PR #14, puis `kubectl argo rollouts promote --full`, parce que l'analyse bloquait le retour |

## Résumé

J'ai déployé la 2.1.0 par PR. Le test de charge automatique devait la refuser. Il l'a acceptée, et elle est partie
en production. Quand j'ai fait le revert, le même test a refusé le retour à la version saine.

La cause : le test ne parlait pas aux pods de la nouvelle version, mais à ceux de la version déjà en place.
Après correction, la 2.1.0 a été refusée automatiquement en 48 secondes, et la 2.2.0 a été acceptée.

## Chronologie

| Heure | Événement |
| --- | --- |
| 11:17:54 | Étalon sur la 2.0.0 avec `charge.sh` : 735 requêtes, 0,00 % d'erreurs, p95 = 5,43 ms |
| vers 11:24 | Merge de la PR #13 : Canary avec analyse automatique k6. En place dans le cluster à 11:26:34 |
| vers 11:33 | Merge de la PR #14 « Image 2.1.0 » |
| vers 11:35 | Premier pod en 2.1.0 (palier 25 %). L'analyse k6 se lance aussitôt |
| vers 11:36 | AnalysisRun `taskflow-df976ccb5-6-1` : **Successful**. Rapport : 731 requêtes, 0,00 % d'erreurs, p95 = 7,75 ms |
| vers 11:38 | Les 4 pods sont en 2.1.0 : production à 100 % sur la version boguée |
| 11:54:51 | Je constate `2.1.0 (stable)`. `observe.sh` : 12 puis 11 erreurs `http=500` sur 40 |
| 11:58:45 | Trois autres mesures : 10, 9 et 8 erreurs sur 40. Total : 50 sur 200, soit 25 % |
| 12:00:04 | `charge.sh` sur la production : 25,66 % d'erreurs, p95 = 307 ms. Les deux seuils sont dépassés |
| vers 12:06 | Merge du revert de la PR #14 |
| 12:07:24 | Le Service `taskflow-canary` bascule vers le pod en 2.0.0. L'analyse démarre |
| 12:07:25 | k6 démarre, une seconde après la bascule |
| 12:07:55 | k6 échoue : 33,33 % d'erreurs, réponse la plus rapide à 301 ms |
| 12:08:05 | AnalysisRun `taskflow-c6cf57bd6-7-1` : **Failed**. Le retour en 2.0.0 est abandonné. Production toujours en 2.1.0 |
| 12:18:52 | `kubectl argo rollouts promote taskflow --full` |
| 12:19:09 | Rollout Healthy en 2.0.0. **Fin de l'incident** |
| 12:21:03 | Contrôle : 2 fois 40 réponses `version=2.0.0 http=200` |
| vers 12:27 | Merge de la correction de l'analyse (pause de 10 s et `noConnectionReuse`). En place à 12:28:19 |
| vers 12:29 | Merge de la PR #17 : nouvelle tentative en 2.1.0 |
| 12:30:30 | Un pod en 2.1.0 (palier 25 %), puis pause de 10 s |
| 12:30:41 | L'analyse k6 démarre |
| 12:31:12 | k6 échoue : 30,33 % d'erreurs, p95 = 312 ms |
| 12:31:18 | AnalysisRun `taskflow-df976ccb5-8-2` : **Failed**. Abandon automatique. Production restée en 2.0.0, 40 réponses sur 40 en `http=200` |
| 13:55 | Test d'un pod 2.1.0 isolé, hors production : `/health` répond 200, les autres routes mettent 300 ms, une réponse 500 sur 6 |
| 14:00:10 | Revert de la PR #17 appliqué : Rollout Healthy, application Synced |
| 14:03:51 | PR « Image 2.2.0 » : l'analyse k6 démarre |
| 14:04:29 | AnalysisRun `taskflow-7ddd57d788-10-2` : **Successful**. Rapport : 725 requêtes, 0,00 % d'erreurs, p95 = 10,03 ms |
| 14:05:42 | Rollout Healthy en 2.2.0 à 100 %. `observe.sh` : 40 réponses `version=2.2.0 http=200` |

Les heures précédées de « vers » ne sont pas chronométrées. Les heures exactes des merges sont sur les PR.

## Composant défaillant et cause racine

### Quel composant a échoué ?

Il y en a deux : l'application, et le test qui devait l'arrêter.

**1. L'application TaskFlow en version 2.1.0.** Preuve, sur un pod lancé à part (13:55) :

```
/      -> {"app":"TaskFlow","version":"2.1.0","pod":"debug-210"} | http=200 temps=0.305925s
/tasks -> []                                                      | http=200 temps=0.303467s
/tasks -> {"detail":"Erreur interne"}                             | http=500 temps=0.305774s
```

Chaque réponse prend environ 300 ms, contre 1 à 5 ms en 2.0.0, et une partie des requêtes renvoie une erreur 500.
Le défaut est présent dès la première requête d'un pod neuf.

**2. L'analyse automatique, qui testait les mauvais pods.** Preuve, dans le journal d'Argo Rollouts pendant le revert :

```
10:07:18Z  delaying service switch from df976ccb5 to c6cf57bd6: ReplicaSet has zero availability
10:07:24Z  Switched selector for service 'taskflow-canary' from 'df976ccb5' to 'c6cf57bd6'
10:07:55Z  (k6) thresholds on metrics 'http_req_duration, http_req_failed' have been crossed
```

Le Service a basculé vers le nouveau pod à 12:07:24. k6 a démarré à 12:07:25. Pourtant, sa réponse la plus rapide
est à 301 ms : c'est la signature de la 2.1.0, alors que le nouveau pod était en 2.0.0.
Toutes ses requêtes sont donc allées vers les anciens pods.

Les deux analyses de la matinée ont donné un verdict inversé :

| Déploiement | Version à tester | Résultat de k6 | Version réellement testée |
| --- | --- | --- | --- |
| Vers la 2.1.0 | 2.1.0 (boguée) | Successful | la 2.0.0 en place |
| Retour vers la 2.0.0 | 2.0.0 (saine) | Failed | la 2.1.0 en place |

### Pourquoi les probes Kubernetes ne l'ont-elles pas vu ?

Les probes appellent seulement `/health`, et cette route répond `200 OK` en 2.1.0.
Les pods étaient donc `Running` et `ready:1/1`. Kubernetes vérifie que l'application est vivante,
pas qu'elle répond correctement ni rapidement.

### Cause racine

- **Du défaut** : une régression dans le code de la version 2.1.0. Je ne peux pas dire laquelle :
  le journal de l'application indique seulement « 500 Internal Server Error », sans détail.
- **De la mise en production** : l'analyse démarrait une seconde après la bascule du Service `taskflow-canary`.
  Mon explication : k6 ouvre ses 5 connexions dans la première seconde et les garde ouvertes pendant tout le test.
  À ce moment, la bascule n'était pas encore prise en compte par le réseau du cluster, donc les connexions
  sont restées branchées sur les anciens pods. Les horaires et les mesures sont des faits. Le détail
  des connexions est une explication cohérente avec ces faits, confirmée par la correction.

### Hypothèses écartées pendant l'enquête

| Hypothèse | Pourquoi je l'ai écartée |
| --- | --- |
| k6 ne teste pas la route qui casse (`/tasks` au lieu de `/`) | `charge.sh` à 12:00 : 25,66 % d'erreurs sur `/tasks` aussi |
| Il suffit d'ajouter `abortOnFail` aux seuils | Le test voyait 0 erreur sur 731 requêtes : il n'y avait rien à interrompre |
| La 2.1.0 est saine au démarrage et se dégrade ensuite | Pod neuf à 13:55 : 300 ms et une erreur 500 dès les premières requêtes |
| Mes fichiers sont mal configurés | `diff -r exemples/robustesse apps/taskflow` : identiques, sauf la ligne de l'image |

## Ce qui a bien fonctionné

- L'étalon de 11:17. Sans la référence (0 % et 5,43 ms), je n'aurais pas reconnu que le test « réussi » montrait en fait une 2.0.0.
- Mesurer avant de modifier la configuration. Deux corrections envisagées auraient été inutiles.
- Ne pas désactiver l'analyse k6 pour débloquer le revert. Elle a été réparée, et elle a ensuite refusé la 2.1.0.
- Le revert dans Git, puis `promote --full` pour finir le retour : 17 secondes entre la commande et le Rollout Healthy.
- Le journal d'Argo Rollouts, qui donne l'heure exacte de chaque bascule de Service.
- Après correction, le filet de sécurité fait son travail : la 2.1.0 a été refusée sans intervention,
  avec un seul pod exposé pendant 48 secondes, contre 44 minutes le matin.

## Ce qui n'a pas fonctionné

- L'analyse automatique a validé une version boguée, puis a bloqué le retour à la version saine.
- La détection a reposé sur un humain, environ 19 minutes après la mise en production.
- Rien n'alerte quand le taux d'erreurs monte en production.

## Actions correctives

| Action | Responsable | Échéance |
| --- | --- | --- |
| Pause de 10 s avant l'analyse et `noConnectionReuse: true` dans le scénario k6 | arosfa | fait le 8 octobre (commit `b003c5b`) |
| Vérifier dans le scénario k6 que la réponse vient bien de la version testée (champ `version` de la route `/`) | arosfa | à planifier |
| Ajouter `abortOnFail: true` aux seuils, pour arrêter le test dès qu'il échoue et réduire l'exposition | arosfa | à planifier |
| Faire vérifier par la readiness probe une route qui utilise vraiment l'application, pas seulement `/health` | arosfa | à planifier |
| Mettre une alerte sur le taux de réponses 5xx en production | arosfa | à planifier |
| Documenter la procédure de retour quand l'analyse bloque un revert (`promote --full`) | arosfa | à planifier |
| Signaler au formateur que l'analyse fournie peut tester les mauvais pods | arosfa | à faire |

Une limite de la correction : j'ai appliqué la pause et `noConnectionReuse` en même temps.
Je sais que les deux ensemble règlent le problème, pas laquelle des deux suffit.
