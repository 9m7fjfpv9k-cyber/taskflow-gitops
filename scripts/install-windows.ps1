# Installe l'environnement du cours CI/CD M2 sous Windows (sans WSL) :
# cluster kind, Argo CD et Argo Rollouts.
# Equivalent PowerShell de scripts/install.sh.
# Prerequis : Docker Desktop demarre, kind et kubectl installes (winget).
# Usage : powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1

# "Continue" : les messages des outils sur stderr ne doivent pas arreter le script.
# Les erreurs sont detectees via $LASTEXITCODE.
$ErrorActionPreference = "Continue"

$ARGOCD_VERSION   = "v3.5.3"
$ROLLOUTS_VERSION = "v1.10.0"
$CLUSTER          = "cicd"
$IMAGE_REPO       = "ghcr.io/9m7fjfpv9k-cyber/taskflow"
$LAB_IMAGES = @(
  "${IMAGE_REPO}:1.0.0", "${IMAGE_REPO}:1.1.0", "${IMAGE_REPO}:2.0.0",
  "${IMAGE_REPO}:2.1.0", "${IMAGE_REPO}:2.2.0",
  "curlimages/curl:latest", "grafana/k6:latest"
)

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "`nERREUR : $msg" -ForegroundColor Red; exit 1 }

Step "Verification des outils"
foreach ($tool in "docker", "kind", "kubectl") {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "$tool introuvable" }
}
cmd /c "docker info >nul 2>nul"
if ($LASTEXITCODE -ne 0) { Fail "Docker ne repond pas. Demarrez Docker Desktop, puis relancez." }
kubectl version --client
kind version

Step "Plugin kubectl-argo-rollouts (Windows)"
$binDir = Join-Path $env:USERPROFILE ".local\bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$rolloutsExe = Join-Path $binDir "kubectl-argo-rollouts.exe"
if (-not (Test-Path $rolloutsExe)) {
  $url = "https://github.com/argoproj/argo-rollouts/releases/download/$ROLLOUTS_VERSION/kubectl-argo-rollouts-windows-amd64"
  try {
    Invoke-WebRequest -Uri $url -OutFile $rolloutsExe -ErrorAction Stop
    Write-Host "  installe dans $rolloutsExe"
  } catch {
    Write-Host "  ECHEC du telechargement du plugin (pas bloquant pour le lab du jour)" -ForegroundColor Yellow
  }
} else {
  Write-Host "  deja present : $rolloutsExe"
}
if (-not ($env:PATH -split ";" | Where-Object { $_ -eq $binDir })) {
  $env:PATH = "$binDir;$env:PATH"
  $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
  if (-not ($userPath -split ";" | Where-Object { $_ -eq $binDir })) {
    [Environment]::SetEnvironmentVariable("PATH", "$binDir;$userPath", "User")
  }
}

Step "Cluster kind '$CLUSTER'"
$clusters = cmd /c "kind get clusters 2>nul"
if ($clusters -contains $CLUSTER) {
  Write-Host "Le cluster existe deja, on le reutilise."
} else {
  kind create cluster --name $CLUSTER --wait 180s
  if ($LASTEXITCODE -ne 0) { Fail "Creation du cluster kind impossible" }
}
kubectl config use-context "kind-$CLUSTER" | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Contexte kind-$CLUSTER introuvable" }

Step "Argo CD $ARGOCD_VERSION"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - | Out-Null
kubectl apply -n argocd --server-side --force-conflicts `
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml" | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Installation d'Argo CD impossible" }

# Argo CD relit Git toutes les 60 s au lieu de 180 s.
$patchFile = Join-Path $env:TEMP "argocd-cm-patch.json"
'{"data":{"timeout.reconciliation":"60s"}}' | Set-Content -Path $patchFile -Encoding ascii
kubectl -n argocd patch configmap argocd-cm --type merge --patch-file $patchFile | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Patch de argocd-cm impossible" }

Step "Argo Rollouts $ROLLOUTS_VERSION"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f - | Out-Null
kubectl apply -n argo-rollouts --server-side --force-conflicts `
  -f "https://github.com/argoproj/argo-rollouts/releases/download/$ROLLOUTS_VERSION/install.yaml" | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Installation d'Argo Rollouts impossible" }
kubectl wait --for=condition=Established --timeout=120s `
  crd/rollouts.argoproj.io crd/analysistemplates.argoproj.io crd/analysisruns.argoproj.io | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "CRD Argo Rollouts non disponibles" }

Step "Attente du demarrage (quelques minutes la premiere fois)"
kubectl -n argocd rollout restart statefulset/argocd-application-controller | Out-Null
kubectl -n argocd rollout status deployment/argocd-server --timeout=600s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=600s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s
kubectl -n argo-rollouts rollout status deployment/argo-rollouts --timeout=600s

Step "Telechargement des images des labs dans le cluster"
foreach ($image in $LAB_IMAGES) {
  cmd /c "docker exec $CLUSTER-control-plane crictl pull $image >nul 2>nul"
  if ($LASTEXITCODE -eq 0) {
    Write-Host "  ok      $image"
  } else {
    Write-Host "  ECHEC   $image (pas bloquant : elle sera telechargee en cours)" -ForegroundColor Yellow
  }
}

$b64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'
$ARGOCD_PASSWORD = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))

Step "Installation terminee"
Write-Host "  Cluster  : kind-$CLUSTER"
Write-Host "  Argo CD  : kubectl port-forward svc/argocd-server -n argocd 8080:443"
Write-Host "             puis https://localhost:8080 (admin / $ARGOCD_PASSWORD)"
Write-Host "  Rollouts : kubectl argo rollouts version"