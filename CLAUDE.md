# CLAUDE.md — Projet ALIMA DHIS2

Contexte projet pour Claude Code. Ce fichier décrit le périmètre, l'architecture, les conventions et les commandes du dépôt `alima-dhis2`.

## 1. Vue d'ensemble

Migration de l'instance DHIS2 d'ALIMA (The Alliance for International Medical Action) de la version **2.35.0** vers la version **2.41**, avec modernisation complète de l'infrastructure sur Google Cloud Platform et mise en place d'une chaîne CI/CD.

- **Client** : ALIMA — contact SI : Nicolas DIEME
- **Consultant** : Mamadou Tafsir DIALLO (diallotafsir52@gmail.com)
- **Projet GCP** : `alima-dhis2-prod` (région `europe-west1`)
- **Dépôt GitHub** : `alima-dhis2` (connecté à Cloud Build)

### Existant (source de la migration)
| Composant | Version actuelle | Cible |
|---|---|---|
| DHIS2 | 2.35.0 | 2.41 |
| OS | Ubuntu 18.04.5 LTS | Ubuntu 22.04 LTS |
| PostgreSQL | 10.22 (co-localisé) | 16 (Cloud SQL managé) |
| Java | 11 | 17 |
| Volume base | ≈ 50 GB | — |
| Intégration | Power BI | maintenue et validée post-migration |

## 2. Architecture cible

```
Utilisateurs ──HTTPS──▶ Nginx (TLS) ──▶ Conteneur Docker DHIS2 2.41 (Tomcat/Java 17)
                        [VM Compute Engine e2-standard-2, Ubuntu 22.04]
                                              │ IP privée (VPC, Private Service Access)
                                              ▼
                                   Cloud SQL PostgreSQL 16
                                   (db-custom-2-8192, 100 GB SSD,
                                    sauvegardes auto + PITR, zone unique)
```

Ressources GCP :
- **VPC** `vpc-dhis2` (sous-réseau `10.10.0.0/24`), peering Private Service Access vers Cloud SQL — la base n'a **aucune IP publique**
- **Pare-feu** : SSH uniquement via IAP (`35.235.240.0/20`) ; HTTP/HTTPS entrants sur la VM taguée `http-server`
- **Artifact Registry** : dépôt Docker `dhis2-images` (europe-west1), politique de nettoyage : 10 versions conservées, purge > 30 jours (les versions conservées priment sur la purge — un tag encore utile au retour arrière n'est jamais supprimé)
- **Secret Manager** : mot de passe BDD et secrets de configuration (jamais dans le Git)
- **Cloud Storage** : exports logiques hebdomadaires de la base (rétention 30 jours) + snapshots quotidiens de la VM

## 3. CI/CD (Cloud Build)

Chaîne : `push GitHub → trigger Cloud Build → build image → push Artifact Registry → APPROBATION MANUELLE → déploiement VM (docker compose pull && up -d)`

- Le trigger de production a l'**approbation manuelle activée** : aucun déploiement sans validation humaine (approbateur : référent ALIMA ou consultant selon la phase)
- Rollback : redéploiement du tag d'image précédent depuis Artifact Registry
- Image de base : `dhis2/core:<version>` — le Dockerfile ajoute la configuration ALIMA
- Nommage des tags d'image : `<version-dhis2>-<build-id>` (ex. `2.41.1-abc123`) + `latest`

## 4. Structure du dépôt

```
.
├── CLAUDE.md              ← ce fichier
├── cloudbuild.yaml        ← pipeline Cloud Build (build + deploy)
├── docker/
│   ├── Dockerfile         ← image DHIS2 personnalisée (FROM dhis2/core)
│   ├── docker-compose.yml ← DHIS2 + Nginx sur la VM
│   ├── nginx.conf         ← reverse proxy (TLS en production)
│   └── dhis.conf.template ← template de config DHIS2 (les valeurs réelles via Secret Manager)
├── scripts/
│   ├── 01-setup-gcp.sh    ← provisionnement infrastructure (gcloud)
│   ├── install-vm.sh      ← installation Docker sur la VM
│   └── 99-cleanup-gcp.sh  ← nettoyage
└── docs/                  ← documentation d'exploitation et de migration
```

## 5. Plan de migration (4 semaines)

1. **S1 — Audit & infrastructure** : audit de l'instance 2.35, test de restauration des sauvegardes existantes, provisionnement complet (VPC, Cloud SQL, VM, registre, CI/CD)
2. **S2 — Migration par paliers** : restauration du dump sur PostgreSQL 16, montée de version **2.35 → 2.36 → 2.38 → 2.40 → 2.41** (chaque palier exécute ses migrations de schéma Flyway et est validé avant le suivant)
3. **S3 — Dry-run & UAT** : répétition générale, tests fonctionnels avec les référents ALIMA, validation Power BI, tests de performance et de restauration
4. **S4 — Go-Live & transfert** : bascule en production (fenêtre convenue, gel des saisies limité), documentation, transfert de compétences

**Règle absolue** : la base de production 2.35 n'est **jamais modifiée** — migration en parallèle, retour arrière immédiat possible jusqu'à la bascule finale.

## 6. Commandes utiles

```bash
# SSH sur la VM (via IAP, pas d'IP publique exposée pour SSH)
gcloud compute ssh vm-dhis2-app --zone=europe-west1-b --tunnel-through-iap --project=alima-dhis2-prod

# IP privée de l'instance Cloud SQL
gcloud sql instances describe pg16-dhis2-prod --format="value(ipAddresses[0].ipAddress)"

# État de l'application sur la VM
docker compose -f ~/dhis2/docker-compose.yml ps
docker compose -f ~/dhis2/docker-compose.yml logs -f dhis2

# Lancer un build manuellement
gcloud builds submit --config=cloudbuild.yaml --project=alima-dhis2-prod

# Lister les images du registre
gcloud artifacts docker images list europe-west1-docker.pkg.dev/alima-dhis2-prod/dhis2-images/dhis2-core

# Lire un secret (ex. mot de passe BDD)
gcloud secrets versions access latest --secret=dhis2-db-password --project=alima-dhis2-prod
```

## 7. Conventions et règles

- **Aucun secret dans le Git** : mots de passe, clés et identifiants passent exclusivement par Secret Manager ; `dhis.conf` n'est versionné que sous forme de template
- **Langue** : documentation et messages de commit en français ; code et noms de ressources en anglais
- **Commits** : préfixes `infra:`, `ci:`, `docker:`, `docs:`, `migration:`
- **Branche principale** : `main` — tout push déclenche le build ; le déploiement reste soumis à approbation
- **Confidentialité** : données de santé ALIMA — aucun dump de production ne transite par ce dépôt ni par un poste non autorisé (CGA ALIMA, art. 13)
- **Toute modification d'infrastructure** doit être reflétée dans `scripts/01-setup-gcp.sh` (source de vérité du provisionnement)

## 8. Environnements

| Environnement | Usage | Déploiement |
|---|---|---|
| Test (VM ou instance temporaire) | dry-run, validation des paliers de migration | automatique après build |
| Production (`vm-dhis2-app`) | instance DHIS2 ALIMA | **approbation manuelle obligatoire** |

## 9. Support post-migration

Forfait annuel de 12 heures : assistance technique, application des correctifs de sécurité DHIS2, test de restauration semestriel. Au-delà : 65 000 FCFA/heure sur devis.