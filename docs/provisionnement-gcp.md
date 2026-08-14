# Provisionnement GCP — mode opératoire

Procédure pas à pas pour créer l'infrastructure DHIS2 ALIMA sur Google Cloud, depuis un
poste Windows. À suivre dans l'ordre : chaque étape suppose la précédente réussie.

Conception sous-jacente : [`architecture-et-cicd.md`](architecture-et-cicd.md).

---

## 0. Avant de commencer

### Ce qu'il faut avoir

| | |
|---|---|
| Un projet GCP | `alima-dhis2-prod` (le nom est paramétrable) |
| Un compte de facturation actif | rattaché à ce projet — **sans lui, rien ne se crée** |
| Le rôle IAM `Owner` sur le projet | ou, à défaut, `Editor` + `Project IAM Admin` + `Secret Manager Admin` |
| Un shell POSIX | **Git Bash** ou **WSL** — voir l'avertissement ci-dessous |

### ⚠ Les scripts ne s'exécutent pas depuis PowerShell

`scripts/01-setup-gcp.sh` est un script bash (`set -euo pipefail`, tableaux, heredocs).
Il faut l'exécuter depuis **Git Bash** (livré avec Git pour Windows) ou depuis **WSL**.
Depuis PowerShell ou `cmd`, il échouera dès la première ligne.

### ⚠ Coût

Le provisionnement crée des ressources **facturées à l'heure**, dont une instance Cloud SQL
et une VM qui tournent en continu. Ordre de grandeur pour la configuration décrite
(Cloud SQL `db-custom-2-8192` + 100 Go SSD + sauvegardes, VM `e2-standard-2` + 100 Go SSD,
région `europe-west1`) : **quelques centaines d'euros par mois**.

Ce chiffre est une estimation grossière, pas un devis. Avant de lancer le
provisionnement réel, chiffrer la configuration exacte avec le
[simulateur de coût GCP](https://cloud.google.com/products/calculator).

Le script `99-cleanup-gcp.sh` permet de tout supprimer si l'exécution n'était qu'un test.

---

## 1. Installer gcloud

Télécharger et exécuter l'installateur officiel :

<https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe>

Laisser les options par défaut, en veillant à conserver **« Add gcloud to PATH »**.

Puis, dans un **nouveau** terminal Git Bash (le PATH n'est rafraîchi qu'au démarrage) :

```bash
gcloud --version
```

Résultat attendu : `Google Cloud SDK 5xx.x.x` et la liste des composants.

> Si `gcloud: command not found` dans Git Bash alors que PowerShell le trouve, ajouter
> le SDK au PATH de Git Bash :
> `export PATH="$PATH:/c/Users/$USER/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin"`

---

## 2. S'authentifier

Deux authentifications distinctes sont nécessaires — c'est une source classique de
confusion :

```bash
# 1. Identité pour les commandes gcloud (ouvre un navigateur)
gcloud auth login

# 2. Identifiants par défaut, utilisés par certaines API et outils
gcloud auth application-default login
```

Vérification :

```bash
gcloud auth list
```

Le compte utilisé doit apparaître avec un `*`.

---

## 3. Projet et facturation

### Si le projet n'existe pas encore

```bash
gcloud projects create alima-dhis2-prod --name="ALIMA DHIS2"
```

### Rattacher la facturation

```bash
# Lister les comptes de facturation accessibles
gcloud billing accounts list

# Rattacher (remplacer par l'identifiant obtenu ci-dessus)
gcloud billing projects link alima-dhis2-prod \
  --billing-account=XXXXXX-XXXXXX-XXXXXX
```

### Vérifier avant d'aller plus loin

```bash
gcloud config set project alima-dhis2-prod
gcloud billing projects describe alima-dhis2-prod
```

Le champ `billingEnabled` doit valoir **`true`**. S'il vaut `false`, inutile de
continuer : l'activation des API échouera.

---

## 4. Paramétrer

Le script lit des variables d'environnement, avec des valeurs par défaut. À ajuster
**avant** l'exécution si nécessaire :

```bash
cd /c/Users/lenovo/source/repos/alima-dhis2

export PROJECT_ID=alima-dhis2-prod
export REGION=europe-west1
export ZONE=europe-west1-b

# URL publique définitive de l'instance — stockée en secret, lue au déploiement
export DHIS2_FQDN=https://dhis2.alima.ngo
```

Les autres valeurs (noms des ressources, dimensionnement) sont en tête de
`scripts/01-setup-gcp.sh`. Toute modification doit y être faite **dans le fichier**, pas
en ligne de commande : ce script est la source de vérité du provisionnement.

---

## 5. Répétition à blanc

**Toujours commencer par là.** Le mode `DRY_RUN` affiche chaque commande sans rien créer :

```bash
DRY_RUN=1 ./scripts/01-setup-gcp.sh
```

Lire la sortie en entier. Vérifier notamment :

- le projet ciblé est le bon ;
- la région et la zone correspondent ;
- le dimensionnement Cloud SQL et VM est celui attendu ;
- aucune ressource existante ne va être écrasée (les lignes `existe déjà` sont normales
  et signifient que le script laissera la ressource en l'état).

---

## 6. Provisionnement réel

```bash
./scripts/01-setup-gcp.sh
```

Durée : **15 à 25 minutes**, dominées par la création de l'instance Cloud SQL.

Le script est **idempotent** : en cas d'interruption, il suffit de le relancer. Les
ressources déjà créées sont détectées et laissées telles quelles.

### Ce qu'il crée, dans l'ordre

| Étape | Ressource |
|---|---|
| 1 | Activation des API (compute, sqladmin, artifactregistry, cloudbuild, secretmanager, iap…) |
| 2 | VPC `vpc-dhis2`, sous-réseau `subnet-dhis2` (10.10.0.0/24), peering Private Service Access |
| 3 | Règles de pare-feu : SSH via IAP uniquement, HTTP/HTTPS sur la VM taguée `http-server` |
| 4 | Cloud SQL PostgreSQL 16, **sans IP publique**, PITR activé, sauvegardes à 02:00 |
| 5 | Secrets : `dhis2-db-password`, `dhis2-db-user`, `dhis2-encryption-password`, `dhis2-db-host`, `dhis2-fqdn` |
| 6 | Artifact Registry `dhis2-images` + politique de nettoyage |
| 7 | Comptes de service `sa-dhis2-vm` et `sa-dhis2-build`, avec leurs rôles |
| 8 | Bucket de sauvegardes, rétention 30 jours, accès public interdit |
| 9 | VM `vm-dhis2-app` (sans IP publique) + snapshots quotidiens |

Le mot de passe de la base est **généré aléatoirement et jamais affiché** : il part
directement dans Secret Manager.

---

## 7. Vérifier

```bash
# Instance Cloud SQL : doit être RUNNABLE, sans IP publique
gcloud sql instances describe pg16-dhis2-prod \
  --format="table(name,state,databaseVersion,ipAddresses[].type)"

# IP privée de la base (stockée aussi dans le secret dhis2-db-host)
gcloud sql instances describe pg16-dhis2-prod \
  --format="value(ipAddresses[0].ipAddress)"

# Secrets créés
gcloud secrets list --format="table(name,createTime)"

# VM : doit être RUNNING, sans EXTERNAL_IP
gcloud compute instances list

# Registre d'images (vide à ce stade, c'est normal)
gcloud artifacts repositories list --location=europe-west1
```

Points de contrôle :

- Cloud SQL n'expose **que** `PRIVATE` dans `ipAddresses[].type` ;
- la VM n'a **pas** d'IP externe ;
- les cinq secrets sont présents.

---

## 8. Préparer la VM

Se connecter — l'accès passe obligatoirement par IAP, il n'y a pas d'IP publique :

```bash
gcloud compute ssh vm-dhis2-app \
  --zone=europe-west1-b --tunnel-through-iap --project=alima-dhis2-prod
```

Puis, **sur la VM** :

```bash
# Récupérer le script depuis le dépôt (ou le copier via gcloud compute scp)
sudo DOMAIN=dhis2.alima.ngo ACME_EMAIL=si@alima.ngo ./install-vm.sh
```

`install-vm.sh` installe Docker, crée les trois volumes de persistance, obtient le
certificat TLS et configure l'agent Ops.

> ⚠ **Le certificat TLS exige que le DNS pointe déjà vers l'IP de la VM** et que le port
> 80 soit joignable depuis Internet. Si ce n'est pas encore le cas, le script le signale
> et continue : il faudra relancer `certbot certonly --standalone --cert-name dhis2 -d
> <domaine>` une fois le DNS en place. Nginx refusera de démarrer tant que le certificat
> est absent.

---

## 9. Déclencheurs Cloud Build

À créer dans la console GCP (Cloud Build → Déclencheurs), après avoir connecté le dépôt
GitHub `gh-alima/alima-dhis2` :

| Déclencheur | Événement | Configuration | Approbation |
|---|---|---|---|
| `dhis2-build` | Push sur `main` | `cloudbuild.yaml`, filtre d'exclusion `**/*.md` | non |
| `dhis2-deploy-prod` | Manuel | `cloudbuild-deploy.yaml` | **OUI — obligatoire** |

L'approbation manuelle de production se règle dans les paramètres du déclencheur
(« Exiger une approbation avant l'exécution »). **Ce contrôle vit dans le déclencheur, pas
dans le dépôt** : personne ne peut le contourner par un commit.

Le compte de service utilisé par les déclencheurs doit être `sa-dhis2-build`.

---

## 10. Première construction et premier déploiement

```bash
# Construire et publier les images
gcloud builds submit --config=cloudbuild.yaml --project=alima-dhis2-prod
```

La fin du journal affiche le tag produit, par exemple
`dev.2.41.9.1.20260814.a1b2c3d`. Le déploiement se fait ensuite avec ce tag :

```bash
gcloud builds submit --config=cloudbuild-deploy.yaml \
  --substitutions=_IMAGE_TAG=<tag> \
  --project=alima-dhis2-prod
```

Le pipeline vérifie que les images existent, pousse la configuration sur la VM, régénère
`.env` depuis Secret Manager, déploie, puis **attend la réponse de l'application** avant
d'annoncer un succès.

---

## 11. Écarts connus à traiter

Ces points ne sont pas couverts par `01-setup-gcp.sh` en l'état :

| # | Écart | Quand le traiter |
|---|---|---|
| 1 | **IP externe de la VM.** La VM est créée sans IP publique : elle n'est joignable que par IAP. Il faut lui attacher une adresse statique, ou la placer derrière un équilibreur de charge, pour servir le trafic web entrant. | Avant l'étape 8 |
| 2 | **Enregistrement DNS.** Le domaine doit pointer vers cette adresse avant l'obtention du certificat TLS. | Avant l'étape 8, après le n°1 |

Ces deux points s'enchaînent : sans adresse publique, pas de DNS ; sans DNS, pas de
certificat ; sans certificat, Nginx ne démarre pas. Ils se traitent donc **dans cet
ordre**, une fois l'infrastructure créée et l'exposition souhaitée arbitrée avec ALIMA
(adresse statique directe ou équilibreur de charge).

> **Pas d'environnement de test hébergé.** C'est une décision assumée pour contenir le
> coût : la validation se fait en local (`docker compose --profile local`). Le pipeline de
> déploiement ne cible donc que la production, et aucun tag ne doit y partir sans avoir
> été démarré en local au préalable.

---

## 12. En cas de problème

```bash
# Journaux d'une construction
gcloud builds list --limit=5
gcloud builds log <BUILD_ID>

# État de l'application sur la VM
gcloud compute ssh vm-dhis2-app --zone=europe-west1-b --tunnel-through-iap \
  --command "sudo docker compose -f /opt/alima/dhis2/docker-compose.yml ps"

# Journaux applicatifs
gcloud compute ssh vm-dhis2-app --zone=europe-west1-b --tunnel-through-iap \
  --command "sudo docker logs --tail=100 dhis2"

# Connectivité base depuis la VM
gcloud compute ssh vm-dhis2-app --zone=europe-west1-b --tunnel-through-iap \
  --command "nc -zv \$(gcloud secrets versions access latest --secret=dhis2-db-host) 5432"
```

### Tout supprimer

```bash
DRY_RUN=1 ./scripts/99-cleanup-gcp.sh    # voir ce qui serait supprimé
./scripts/99-cleanup-gcp.sh              # demande confirmation par saisie du projet
./scripts/99-cleanup-gcp.sh --keep-data  # préserve la base Cloud SQL
```

Le bucket de sauvegardes et les secrets ne sont **jamais** supprimés automatiquement.

> ⚠ Ne supprimer `dhis2-encryption-password` qu'une fois certain qu'aucune sauvegarde ne
> devra plus jamais être restaurée : sans cette clé, les données chiffrées d'un dump
> restauré sont définitivement illisibles.
