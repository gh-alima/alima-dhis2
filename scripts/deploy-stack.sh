#!/usr/bin/env bash
# =============================================================================
# deploy-stack.sh — met à jour la pile applicative sur la VM
#
# Exécuté SUR LA VM par l'étape de déploiement du pipeline, en root :
#   sudo bash /opt/alima/dhis2/scripts/deploy-stack.sh /opt/alima/dhis2
#
# Doit tourner en root : le répertoire applicatif est en 750, propriété de
# root, parce qu'il contient le .env — mot de passe de la base et clé de
# chiffrement comprises. Ce n'est pas une contrainte à contourner en relâchant
# les permissions, mais la raison pour laquelle le déploiement passe par sudo.
#
# Usage : deploy-stack.sh [répertoire_applicatif]
# =============================================================================
set -euo pipefail

APP_DIR="${1:-/opt/alima/dhis2}"
AR_HOST="${2:-europe-west1-docker.pkg.dev}"

[ "$(id -u)" -eq 0 ] || { echo "Ce script doit être exécuté en root." >&2; exit 1; }

cd "${APP_DIR}"

echo "=== Configuration attendue ==="
# On n'affiche jamais le contenu de .env : il porte des secrets. Seuls le tag
# déployé et le nom d'hôte sont utiles au journal de déploiement.
grep -E '^(IMAGE_TAG|REGISTRY|DHIS2_FQDN)=' .env || {
  echo "ERREUR : .env absent ou incomplet dans ${APP_DIR}." >&2
  exit 1
}

# L'assistant d'identification Docker est reconfiguré à chaque déploiement.
# Il est écrit dans le HOME de l'utilisateur qui le configure : selon la façon
# dont install-vm.sh a été lancé, il a pu atterrir ailleurs que dans celui de
# root. Le rejouer ici, en root, garantit que le « pull » qui suit dispose bien
# des identifiants — l'opération est idempotente et coûte une seconde.
echo ""
echo "=== Authentification au registre ==="
gcloud auth configure-docker "${AR_HOST}" --quiet

echo ""
echo "=== Récupération des images ==="
docker compose pull

echo ""
echo "=== Démarrage ==="
docker compose up -d --remove-orphans

# Les images des déploiements précédents sont conservées un mois : c'est ce qui
# rend un retour arrière immédiat, sans nouveau téléchargement.
echo ""
echo "=== Nettoyage des images de plus de 30 jours ==="
docker image prune -f --filter 'until=720h'

echo ""
echo "=== État des conteneurs ==="
docker compose ps
