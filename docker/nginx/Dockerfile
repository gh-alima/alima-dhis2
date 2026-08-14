# =============================================================================
# Image dhis2-nginx — reverse proxy devant DHIS2
#
# Conteneur distinct de DHIS2 : un correctif de sécurité Nginx s'applique sans
# reconstruire ni redémarrer l'application.
#
# Écoute sur 8080/8443 et non 80/443 : le conteneur tourne en non-root et sans
# capacités, il ne peut donc pas se lier aux ports privilégiés. La publication
# sur 80/443 est faite par Docker côté hôte.
# =============================================================================
FROM nginx:1.27-alpine

ARG BUILD_DATE=unspecified
ARG VCS_REF=unspecified
ARG VERSION=unspecified
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.title="DHIS2 Nginx ALIMA" \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.vendor="ALIMA" \
      org.opencontainers.image.version=$VERSION

# La configuration par défaut est retirée : la nôtre la remplace intégralement.
RUN rm -f /etc/nginx/conf.d/default.conf \
    && mkdir -p /var/cache/nginx /var/run \
    && chown -R nginx:nginx /var/cache/nginx /var/run \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log

COPY nginx.conf /etc/nginx/nginx.conf

USER nginx

EXPOSE 8080 8443

CMD ["nginx", "-g", "daemon off;"]
