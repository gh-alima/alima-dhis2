# =============================================================================
# Distribution DHIS2 ALIMA
#
# Surcouche mince sur l'image officielle DHIS2. Aucun code applicatif n'est
# modifié : on ajoute une configuration Tomcat/JVM et un entrypoint capable de
# générer dhis.conf à partir de variables d'environnement.
#
# Contexte de construction : la RACINE du dépôt (pas le répertoire docker/).
#   docker build -f docker/Dockerfile .
# =============================================================================

# Version DHIS2 — déclarée ICI et nulle part ailleurs.
# La chaîne CI la lit dans ce fichier pour composer le tag d'image.
ARG DHIS2_VERSION=2.38.7.0
FROM dhis2/core:${DHIS2_VERSION}

# --- Métadonnées OCI : permettent de remonter d'une image en production au
#     commit exact qui l'a produite --------------------------------------------
ARG BUILD_DATE=unspecified
ARG VCS_REF=unspecified
ARG VCS_URL=unspecified
ARG VERSION=unspecified
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.title="DHIS2 Distribution ALIMA" \
      org.opencontainers.image.description="DHIS2 pour ALIMA — configuration générée au démarrage" \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.source=$VCS_URL \
      org.opencontainers.image.vendor="ALIMA" \
      org.opencontainers.image.version=$VERSION

USER root

# --- Surcouche Tomcat / JVM --------------------------------------------------
# Note : log4j2.xml n'est PAS surchargé. La journalisation se pilote par les
# propriétés logging.* de dhis.conf (cf. docs/architecture-et-cicd.md §5.3).
# Remplacer la configuration log4j2 de DHIS2 risquerait de casser l'écriture
# des journaux sous DHIS2_HOME.
#
# ⚠ PALIERS DE MIGRATION : server.xml vise Tomcat 9/10 (Java 17, cible 2.41).
#   Les images 2.35.14 et 2.36.x reposent sur Tomcat 8.5 / JDK 8-11 — commenter
#   la ligne ci-dessous pour ces paliers. Ils ne servent qu'à faire migrer le
#   schéma et n'ont pas besoin du réglage fin du connecteur.
#   Cf. docs/architecture-et-cicd.md §9.0
# Palier de migration : surcouche Tomcat neutralisée (cf. create-migration-branch.sh)
# COPY docker/server.xml      /usr/local/tomcat/conf/server.xml
COPY docker/setenv.sh       /usr/local/tomcat/bin/setenv.sh

# --- Entrypoint : génère dhis.conf puis démarre Tomcat -----------------------
COPY docker/init.sh         /usr/local/bin/init.sh
COPY docker/wait-for-it.sh  /usr/local/bin/wait-for-it.sh

# --- Métadonnées DHIS2 ALIMA -------------------------------------------------
COPY configuration/         /opt/dhis2/configuration_dhis2

# --- Marque ALIMA ------------------------------------------------------------
# Déposer le logo dans docker/branding/logo_front.png puis décommenter :
# COPY docker/branding/logo_front.png /usr/local/tomcat/logo_front.png

# --- Droits et bascule vers l'utilisateur non-root de l'image de base --------
# IMPORTANT : ce chown conditionne le bon fonctionnement des volumes nommés.
# Un volume nommé hérite, à sa création, du propriétaire du répertoire
# correspondant dans l'image. Si ce chown disparaît, DHIS2 échoue au démarrage
# sur un volume neuf, avec une erreur d'écriture peu explicite.
RUN chmod +x /usr/local/bin/init.sh /usr/local/bin/wait-for-it.sh \
    && mkdir -p /opt/dhis2/files /opt/dhis2/logs \
    && chown -R 1000:1000 \
        /opt/dhis2 \
        /usr/local/tomcat/conf \
        /usr/local/tomcat/logs \
        /usr/local/tomcat/work \
        /usr/local/tomcat/temp \
        /usr/local/tomcat/webapps

# Palier de migration : retablir la decompression du WAR.
# L'image officielle declare unpackWARs="false" ; Tomcat sert alors
# l'application depuis l'archive et DHIS2 ne resout plus ses JAR.
# Le grep fait echouer la construction si le sed ne mord pas.
RUN sed -i 's/unpackWARs="false"/unpackWARs="true"/'       /usr/local/tomcat/conf/server.xml  && grep -q 'unpackWARs="true"' /usr/local/tomcat/conf/server.xml

USER 1000

ENV DHIS2_HOME=/opt/dhis2

EXPOSE 8080

CMD ["sh", "-c", "/usr/local/bin/init.sh"]
