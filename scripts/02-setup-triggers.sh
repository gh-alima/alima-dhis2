#!/usr/bin/env bash
# =============================================================================
# 02-setup-triggers.sh — création des déclencheurs Cloud Build
#
# Crée les deux déclencheurs de la chaîne :
#   - dhis2-build       : construction automatique à chaque push sur main
#   - dhis2-deploy-prod : déploiement manuel, AVEC APPROBATION OBLIGATOIRE
#
# PRÉREQUIS — à faire UNE FOIS, dans la console, avant d'exécuter ce script :
#
#   1. Le dépôt doit être poussé sur GitHub :
#        git push origin main
#
#   2. Le dépôt GitHub doit être connecté à Cloud Build. Cette étape passe par
#      une autorisation OAuth et ne peut pas être automatisée :
#        https://console.cloud.google.com/cloud-build/triggers/connect
#      Choisir « GitHub (Cloud Build GitHub App) », autoriser, sélectionner
#      gh-alima/alima-dhis2.
#
# Le script est IDEMPOTENT : un déclencheur existant est laissé en l'état.
#
# Usage :
#   ./scripts/02-setup-triggers.sh
#   DRY_RUN=1 ./scripts/02-setup-triggers.sh
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-alima-dhis2-prod}"
REPO_OWNER="${REPO_OWNER:-gh-alima}"
REPO_NAME="${REPO_NAME:-alima-dhis2}"
BRANCH="${BRANCH:-main}"

BUILD_SA="sa-dhis2-build@${PROJECT_ID}.iam.gserviceaccount.com"
SA_PATH="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA}"

TRIGGER_BUILD="dhis2-build"
TRIGGER_DEPLOY="dhis2-deploy-prod"

DRY_RUN="${DRY_RUN:-0}"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[0;33m•\033[0m %s (existe déjà)\n' "$*"; }

run() {
  if [ "${DRY_RUN}" = "1" ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

trigger_exists() {
  gcloud builds triggers describe "$1" --region=global >/dev/null 2>&1
}

command -v gcloud >/dev/null || { echo "gcloud est requis." >&2; exit 1; }

log "Projet ${PROJECT_ID} — dépôt ${REPO_OWNER}/${REPO_NAME}"
gcloud config set project "${PROJECT_ID}" >/dev/null
[ "${DRY_RUN}" = "1" ] && echo "  MODE DRY-RUN — aucun déclencheur ne sera créé."

# ── 1. Construction ──────────────────────────────────────────────────────────
# Se déclenche à chaque push sur main. Les modifications purement
# documentaires n'entraînent pas de reconstruction : une image identique sous
# un nouveau tag n'apporte rien et brouille l'historique du registre.
log "Déclencheur de construction"

if trigger_exists "${TRIGGER_BUILD}"; then
  skip "${TRIGGER_BUILD}"
else
  run gcloud builds triggers create github \
    --name="${TRIGGER_BUILD}" \
    --description="Construit dhis2-core et dhis2-nginx à chaque push sur ${BRANCH}" \
    --repo-owner="${REPO_OWNER}" \
    --repo-name="${REPO_NAME}" \
    --branch-pattern="^${BRANCH}$" \
    --build-config=cloudbuild.yaml \
    --ignored-files="**/*.md" \
    --service-account="${SA_PATH}" \
    --region=global
  ok "${TRIGGER_BUILD} — push sur ${BRANCH}, hors **/*.md"
fi

# ── 2. Déploiement ───────────────────────────────────────────────────────────
# Manuel et soumis à approbation. C'est LE point de contrôle de la chaîne :
# il vit dans le déclencheur, pas dans le dépôt, et ne peut donc pas être
# contourné par un commit.
log "Déclencheur de déploiement"

if trigger_exists "${TRIGGER_DEPLOY}"; then
  skip "${TRIGGER_DEPLOY}"
else
  run gcloud builds triggers create manual \
    --name="${TRIGGER_DEPLOY}" \
    --description="Déploie un tag existant en PRODUCTION — approbation obligatoire" \
    --repo="https://github.com/${REPO_OWNER}/${REPO_NAME}" \
    --repo-type=GITHUB \
    --branch="${BRANCH}" \
    --build-config=cloudbuild-deploy.yaml \
    --require-approval \
    --service-account="${SA_PATH}" \
    --region=global
  ok "${TRIGGER_DEPLOY} — manuel, APPROBATION OBLIGATOIRE"
fi

# ── 3. Contrôle ──────────────────────────────────────────────────────────────
log "Déclencheurs en place"
if [ "${DRY_RUN}" != "1" ]; then
  gcloud builds triggers list --region=global \
    --format="table(name,disabled,approvalConfig.approvalRequired:label=APPROBATION)"

  # L'approbation est le garde-fou de la production : on vérifie qu'elle est
  # bien active plutôt que de la supposer.
  APPROVAL=$(gcloud builds triggers describe "${TRIGGER_DEPLOY}" --region=global \
    --format='value(approvalConfig.approvalRequired)' 2>/dev/null || echo "")
  if [ "${APPROVAL}" != "True" ] && [ "${APPROVAL}" != "true" ]; then
    echo ""
    echo "  ⚠ ATTENTION : l'approbation n'est PAS active sur ${TRIGGER_DEPLOY}." >&2
    echo "    Un déploiement en production pourrait être lancé sans validation." >&2
    echo "    L'activer : Cloud Build → Déclencheurs → ${TRIGGER_DEPLOY}" >&2
    echo "               → Approbation → Exiger une approbation" >&2
  fi
fi

cat <<EOF

  Chaîne en place
  ---------------
  push sur ${BRANCH}
     └─▶ ${TRIGGER_BUILD}  (automatique)
            └─▶ images dans Artifact Registry, tag <version>.<date>.<commit>

  validation locale du tag
     └─▶ ${TRIGGER_DEPLOY}  (manuel + APPROBATION)
            └─▶ VM de production

  Lancer un déploiement :
    gcloud builds triggers run ${TRIGGER_DEPLOY} --region=global \\
      --branch=${BRANCH} --substitutions=_IMAGE_TAG=<tag>

  ou, sans passer par le déclencheur (pas d'approbation dans ce cas) :
    gcloud builds submit --config=cloudbuild-deploy.yaml \\
      --substitutions=_IMAGE_TAG=<tag>

EOF
