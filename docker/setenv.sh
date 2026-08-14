#!/bin/bash
# =============================================================================
# setenv.sh — options JVM / CATALINA pour DHIS2
# Lu automatiquement par Tomcat au démarrage.
#
# Aucun -Xmx figé : la JVM détecte la mémoire allouée au conteneur et
# dimensionne son tas en proportion. Redimensionner la VM ou la limite mémoire
# du conteneur suffit — aucune reconstruction d'image, et pas de -Xmx devenu
# incohérent avec la machine.
# =============================================================================

JAVA_OPTS="-XX:MaxRAMPercentage=${DHIS2_MAX_RAM_PERCENTAGE:-80.0}"
JAVA_OPTS="${JAVA_OPTS} -XX:+UseG1GC"
JAVA_OPTS="${JAVA_OPTS} -XX:+UseStringDeduplication"
JAVA_OPTS="${JAVA_OPTS} -XX:+ExitOnOutOfMemoryError"
JAVA_OPTS="${JAVA_OPTS} -Dfile.encoding=UTF-8"
JAVA_OPTS="${JAVA_OPTS} -Duser.timezone=${TZ:-UTC}"
JAVA_OPTS="${JAVA_OPTS} -Djava.security.egd=file:/dev/./urandom"
JAVA_OPTS="${JAVA_OPTS} -Ddhis2.home=${DHIS2_HOME:-/opt/dhis2}"

# Chemin de contexte (racine par défaut)
if [ -n "${DHIS2_CONTEXT_PATH:-}" ] && [ "${DHIS2_CONTEXT_PATH}" != "/" ]; then
  CATALINA_OPTS="${CATALINA_OPTS:-} -Dserver.servlet.context-path=${DHIS2_CONTEXT_PATH}"
  export CATALINA_OPTS
fi

# Échappatoire : options JVM additionnelles sans modifier l'image
if [ -n "${DHIS2_EXTRA_JAVA_OPTS:-}" ]; then
  JAVA_OPTS="${JAVA_OPTS} ${DHIS2_EXTRA_JAVA_OPTS}"
fi

export JAVA_OPTS
