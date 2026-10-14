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

<!-- Noms du binôme -->
Naoile et Doria

## LAB : "Déployer par PR, provoquer une dérive, revenir en arrière"

3) L'application apparaît dans ui Argo cd avec les status Synced et Healthy
 ![Déploiement Taskflow v2.0.0](images/sync-health.png)

4) Sur la branch feat/taskflow-v2, nous avons modifier la version de l'image Docker dasn apps/taskflow/deployment.yaml
   ![Déploiement Taskflow v2.0.0](images/v-2.png)

   Journal de déploiement : 

   Déploiment PR de l'image v2.0.0, temps : environ 1min

   Déploiement de la dérive, temps : environ 1 min

   Déploiement du retrour a la v1.0.0, temps : environ 1 min

5) Après avoir fait un replicat de 10 pods, nous observons que ARGO CD à pris connaisance de l'état sur git et a comparer les ecarts puis annulé la commande.
   
   Questions : 

   PUSH ou PULL : C'est appriche PULL car cest argo CD qui récupère automatiquement les modif depuis la branch main de git pour les appliquer au cluster

   Qui a corrigé quoi ? : C'est argo cd qui a détécter que l'état du cluster ne correspondait plus a celui indiqué sur GIT, argo a automatiquement réappliqué la config définie dans git
   
   Pourquoi Git reverte ? : Ici ona utilisé Git reverte pour revenir a la version 1.0.0 après le déploiement de version 2.0.0. Cette action nous permet de revenir a une version precedente sasn supprimer l'hitorique de modification. Donc Argo cd recupere la nouvelle config et redeploye automatiquement la version 1.0.0 

