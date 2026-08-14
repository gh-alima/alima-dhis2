#!/bin/bash
# =============================================================================
# wait-for-it.sh — attend qu'un hôte:port accepte les connexions TCP
#
# Usage : wait-for-it.sh <hôte> <port> [timeout_secondes]
#
# Utilisé au démarrage du conteneur pour attendre Cloud SQL. Sans cette
# attente, DHIS2 échoue au premier démarrage si la base n'est pas encore
# joignable — ce qui arrive régulièrement après un redémarrage de VM.
#
# Implémentation volontairement minimale, sans dépendance externe : elle
# s'appuie sur /dev/tcp de bash.
# =============================================================================
set -uo pipefail

HOST="${1:-}"
PORT="${2:-5432}"
TIMEOUT="${3:-90}"

if [ -z "${HOST}" ]; then
  echo "wait-for-it.sh : hôte manquant" >&2
  exit 1
fi

# Tentative d'ouverture d'une socket TCP. Renvoie 0 si le port accepte la
# connexion, non-zéro sinon.
_probe() {
  (exec 3<>"/dev/tcp/${HOST}/${PORT}") 2>/dev/null
}

echo "Attente de la base de données ${HOST}:${PORT} (délai maximal ${TIMEOUT}s)..."

_elapsed=0
until _probe; do
  if [ "${_elapsed}" -ge "${TIMEOUT}" ]; then
    echo "ERREUR : ${HOST}:${PORT} injoignable après ${TIMEOUT}s." >&2
    echo "         Vérifier l'IP privée Cloud SQL, le peering VPC et les règles de pare-feu." >&2
    exit 1
  fi
  sleep 2
  _elapsed=$((_elapsed + 2))
done

echo "Base de données joignable après ${_elapsed}s."
