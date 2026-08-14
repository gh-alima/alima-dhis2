# DHIS2 ALIMA

Distribution Docker de [DHIS2](https://dhis2.org/) pour ALIMA — The Alliance for
International Medical Action. Ce dépôt contient l'image applicative, la configuration
d'exécution, la chaîne CI/CD et les scripts de provisionnement GCP.

Migration de l'instance existante **2.35 → 2.41**, avec passage de PostgreSQL 10
co-localisé à Cloud SQL PostgreSQL 16 managé.

---

## Structure

```text
.
├── cloudbuild.yaml            construction : image → Artifact Registry
├── cloudbuild-deploy.yaml     déploiement : tag → environnement (approbation en prod)
├── docker/
│   ├── Dockerfile             image dhis2-core ALIMA (FROM dhis2/core)
│   ├── docker-compose.yml     pile applicative sur la VM
│   ├── .env.example           modèle de configuration — toutes les variables
│   ├── dhis.conf.template     référence des propriétés DHIS2 générées
│   ├── init.sh                entrypoint : génère dhis.conf puis démarre Tomcat
│   ├── setenv.sh              options JVM
│   ├── server.xml             configuration Tomcat
│   ├── wait-for-it.sh         attente de disponibilité de la base
│   └── nginx/                 image dhis2-nginx (TLS, gzip, en-têtes de sécurité)
├── configuration/             métadonnées DHIS2 à charger dans l'image
├── scripts/                   provisionnement GCP, installation VM, sauvegardes
└── docs/                      documentation d'architecture et d'exploitation
```

---

## Principe

**Une image, plusieurs environnements.** L'image ne contient aucune valeur propre à un
environnement : toute la configuration est injectée au démarrage par variables
`DHIS2_*`, et `init.sh` en produit `dhis.conf`. Une image est construite une fois puis
promue de test vers production **par son tag, sans reconstruction**.

Conception détaillée : [`docs/architecture-et-cicd.md`](docs/architecture-et-cicd.md).

---

## Démarrage local

```bash
cd docker
cp .env.example .env        # renseigner les valeurs locales
docker compose up --build
```

DHIS2 répond sur `http://localhost` (via Nginx) ou `http://localhost:8080` (Tomcat
direct). La pile locale démarre également un PostgreSQL 16 + PostGIS.

En local, positionner `INSECURE=true` dans `.env` pour désactiver `server.https`.

---

## Construction

```bash
# Version DHIS2 : déclarée une seule fois, dans docker/Dockerfile (ARG DHIS2_VERSION)
docker build -f docker/Dockerfile -t dhis2-core:local \
  --build-arg VCS_REF=$(git rev-parse --short HEAD) \
  --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) .

docker build -f docker/nginx/Dockerfile -t dhis2-nginx:local docker/nginx
```

En CI, `cloudbuild.yaml` fait la même chose et pousse dans Artifact Registry avec le tag
`<version-dhis2>.<date>.<sha>` — par exemple `2.41.9.1.20260814.556073b`.

---

## Déploiement

Construction et déploiement sont **deux opérations distinctes**. On déploie un tag déjà
construit, jamais `latest` :

```bash
gcloud builds submit \
  --config=cloudbuild-deploy.yaml \
  --substitutions=_IMAGE_TAG=2.41.9.1.20260814.556073b \
  --project=alima-dhis2-prod
```

Le pipeline vérifie d'abord que les deux images existent dans le registre, pousse
`docker-compose.yml` et les scripts sur la VM, régénère `.env` depuis Secret Manager,
déploie, puis **attend la réponse de l'application** avant d'annoncer un succès.

Le déclencheur de production porte une **approbation manuelle obligatoire**. Le retour
arrière consiste à relancer ce même déploiement avec le tag précédent.

---

## Provisionnement

> **État au 14 août 2026 — infrastructure créée.** VM `vm-dhis2-app` en service, adresse
> publique **`34.38.89.219`**, Cloud SQL PostgreSQL 16 en IP privée. En attente de
> l'enregistrement DNS côté ALIMA, préalable au certificat TLS et au premier déploiement.
> État détaillé : [`docs/provisionnement-gcp.md`](docs/provisionnement-gcp.md).

📖 **Mode opératoire complet, pas à pas :
[`docs/provisionnement-gcp.md`](docs/provisionnement-gcp.md)** — installation de gcloud,
authentification, facturation, exécution, vérifications et écarts connus.

En résumé :

```bash
# Depuis Git Bash ou WSL — PAS depuis PowerShell (scripts bash)
export PROJECT_ID=alima-dhis2-prod
export DHIS2_FQDN=https://dhis2.alima.ngo

DRY_RUN=1 ./scripts/01-setup-gcp.sh   # répétition à blanc — toujours commencer par là
./scripts/01-setup-gcp.sh             # provisionnement réel (~20 min, ressources facturées)
```

Puis, sur la VM : `sudo ./scripts/install-vm.sh` (Docker, volumes, TLS, agent Ops).

`scripts/01-setup-gcp.sh` est la **source de vérité** du provisionnement : toute
modification d'infrastructure doit y être répercutée. Il est idempotent — en cas
d'interruption, il suffit de le relancer.

---

## Sauvegardes

| Élément | Mécanisme | Fréquence |
|---|---|---|
| Base de données | sauvegardes automatiques Cloud SQL + PITR | continu |
| Base — export logique | `pg_dump` vers Cloud Storage | hebdomadaire |
| Magasin de fichiers | `scripts/backup-filestore.sh` vers Cloud Storage | hebdomadaire |
| Volumes (bloc) | snapshot du disque persistant | quotidien |

Le magasin de fichiers **n'est pas** dans le dump PostgreSQL : une base restaurée sans
lui référence des documents introuvables. Les deux se sauvegardent et se testent
ensemble.

---

## Conventions

- **Aucun secret dans le dépôt** — tout passe par Secret Manager ; `dhis.conf` et `.env`
  ne sont versionnés que sous forme de modèle.
- **Aucun dump de production** ne transite par ce dépôt (données de santé, CGA art. 13).
- Documentation et messages de commit en **français** ; code et noms de ressources en
  anglais.
- Préfixes de commit : `infra:`, `ci:`, `docker:`, `docs:`, `migration:`.
- Branche principale `main` : tout push déclenche la construction ; le déploiement en
  production reste soumis à approbation.

---

## Contacts

| Rôle | Personne |
|---|---|
| Référent SI ALIMA | Nicolas DIEME |
| Consultant | Mamadou Tafsir DIALLO — <diallotafsir52@gmail.com> |
