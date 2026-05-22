# deploy.ps1 — Build Flutter web + déploie sur Firebase Hosting
#
# Usage : .\deploy.ps1
#
# Prérequis :
#   - Flutter dans le PATH
#   - Firebase CLI installé (npm install -g firebase-tools)
#   - firebase login déjà effectué
#   - .firebaserc pointe sur le bon projet Firebase (fortress-pos)

# Force la console à interpréter la sortie en UTF-8 pour les accents français.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$startTime = Get-Date

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Fortress POS - Deploy Web" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── Étape 1/2 : build Flutter web ─────────────────────────────────────
# --no-tree-shake-icons : embarque la police MaterialIcons COMPLÈTE.
#   Sans ça, Flutter sous-ensemble la police et casse certaines icônes
#   (carré vide), notamment celles du plan Unicode supplémentaire (> U+FFFF)
#   comme `handshake` (0xf06a4), et le subset diffère selon la cible
#   (web/desktop/mobile) → icônes incohérentes d'une plateforme à l'autre.
Write-Host "[1/2] Build Flutter web (release)..." -ForegroundColor Yellow
flutter build web --release --no-tree-shake-icons
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[ECHEC] flutter build web a échoué (code $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}

# ── Étape 2/2 : déploiement Firebase Hosting ──────────────────────────
Write-Host ""
Write-Host "[2/2] Déploiement Firebase Hosting..." -ForegroundColor Yellow
firebase deploy --only hosting
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[ECHEC] firebase deploy a échoué (code $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}

# ── Message de succès ─────────────────────────────────────────────────
$duration = (Get-Date) - $startTime
$mins = [math]::Floor($duration.TotalMinutes)
$secs = $duration.Seconds

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  [OK] Déploiement réussi en ${mins}m ${secs}s" -ForegroundColor Green
Write-Host "  URL : https://fortress-pos.web.app" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
