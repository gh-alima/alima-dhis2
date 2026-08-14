#!/usr/bin/env bash
# =============================================================================
# wait-healthy.sh — attend qu'un conteneur passe à l'état « healthy »
#
# Exécuté SUR LA VM par l'étape de vérification du pipeline de déploiement.
#
# Pourquoi un script plutôt qu'une commande en ligne : la vérification était
# auparavant écrite directement dans cloudbuild-deploy.yaml, ce qui imposait
# trois niveaux d'échappement imbriqués — YAML, shell local, shell distant.
# Chaque apostrophe, chaque $ et chaque guillemet devenait un piège, et deux
# défauts s'y étaient glissés. Un fichier exécuté tel quel supprime le problème
# à la racine.
#
# Usage : wait-healthy.sh [conteneur] [timeout_secondes] [fichier_compose]
# =============================================================================
set -uo pipefail

CONTAINER="${1:-dhis2}"
TIMEOUT="${2:-600}"
COMPOSE_FILE="${3:-/opt/alima/dhis2/docker-compose.yml}"

INTERVAL=10
ELAPSED=0

echo "Attente du démarrage de ${CONTAINER} (jusqu'à $((TIMEOUT / 60)) minutes)..."

# Les migrations Flyway d'un palier de version peuvent durer plusieurs minutes :
# l'absence de réponse immédiate n'est pas un échec.
while [ "${ELAPSED}" -lt "${TIMEOUT}" ]; do
  STATE=$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo absent)

  case "${STATE}" in
    healthy)
      echo "${CONTAINER} opérationnel après ${ELAPSED}s."
      echo ""
      echo "--- /api/system/info ---"
      docker exec "${CONTAINER}" \
        curl -sf http://127.0.0.1:8080/api/system/info 2>/dev/null | head -c 500 || \
        echo "(non lisible sans authentification — normal)"
      echo ""
      exit 0
      ;;
    unhealthy)
      echo "ERREUR : ${CONTAINER} signalé en échec après ${ELAPSED}s." >&2
      echo "" >&2
      echo "--- 100 dernières lignes du journal ---" >&2
      docker compose -f "${COMPOSE_FILE}" logs --tail=100 "${CONTAINER}" >&2 2>/dev/null || \
        docker logs --tail=100 "${CONTAINER}" >&2
      exit 1
      ;;
    absent)
      echo "ERREUR : conteneur ${CONTAINER} introuvable." >&2
      docker ps -a >&2
      exit 1
      ;;
  esac

  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "ERREUR : ${CONTAINER} n'a pas démarré dans le délai de ${TIMEOUT}s." >&2
echo "" >&2
echo "--- 100 dernières lignes du journal ---" >&2
docker compose -f "${COMPOSE_FILE}" logs --tail=100 "${CONTAINER}" >&2 2>/dev/null || \
  docker logs --tail=100 "${CONTAINER}" >&2
exit 1
