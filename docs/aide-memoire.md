# Aide-mémoire — DHIS2 ALIMA

Les commandes du quotidien, depuis un poste jusqu'à la VM. Pensé pour être ouvert
pendant l'intervention, pas lu à l'avance.

| | |
|---|---|
| Projet GCP | `alima-dhis2-prod` — `europe-west1` / `europe-west1-b` |
| Application | <https://dhis2-test.alima.ngo> |
| VM | `vm-dhis2-app` — publique `34.38.89.219`, interne `10.10.0.2` |
| Base | `pg16-dhis2-prod` — PostgreSQL 16, IP privée `10.235.0.3` |
| Registre | `europe-west1-docker.pkg.dev/alima-dhis2-prod/dhis2-images` |
| Répertoire sur la VM | `/opt/alima/dhis2` |

---

## 0. Deux règles qui évitent les trois quarts des erreurs

**Les scripts sont du bash.** Les exécuter depuis **Git Bash** ou **WSL**, jamais depuis
PowerShell.

**Chaque commande a son bon endroit.**

| Depuis | Quoi |
|---|---|
| **Ton poste** | tout ce qui touche à GCP : `gcloud`, secrets, constructions, déploiements |
| **La VM** | Docker, journaux, diagnostic local — via `dhis2ctl` |

Sur la VM, `gcloud` s'authentifie avec `sa-dhis2-vm`, qui n'a que la lecture des secrets
et du registre. Toute commande d'administration GCP y échouera — c'est voulu.

---

## 1. Se connecter

```bash
# Vérifier sous quelle identité on est
gcloud config get-value account          # doit afficher dhis2@alima.ngo
gcloud config set project alima-dhis2-prod

# Ouvrir une session sur la VM (SSH via IAP — pas d'accès direct au port 22)
gcloud compute ssh vm-dhis2-app \
  --zone=europe-west1-b --tunnel-through-iap --project=alima-dhis2-prod
```

> **`ERROR: [4033: 'not authorized']`** — le compte n'a pas le droit d'ouvrir un tunnel
> IAP. `roles/owner` ne l'inclut pas :
>
> ```bash
> gcloud projects add-iam-policy-binding alima-dhis2-prod \
>   --member="user:<email>" --role="roles/iap.tunnelResourceAccessor" --condition=None
> gcloud projects add-iam-policy-binding alima-dhis2-prod \
>   --member="user:<email>" --role="roles/compute.osAdminLogin" --condition=None
> ```
>
> Compter quelques minutes de propagation.

---

## 2. Exploiter la VM — `dhis2ctl`

Une fois connecté :

```bash
sudo /opt/alima/dhis2/scripts/dhis2ctl.sh <commande>

# Plus court, à poser une fois dans ~/.bashrc :
alias dhis2ctl='sudo /opt/alima/dhis2/scripts/dhis2ctl.sh'
```

| Commande | Effet |
|---|---|
| `status` | conteneurs, santé, version déployée |
| `health` | attend et vérifie que DHIS2 répond |
| `info` | `/api/system/info`, consommation CPU et mémoire |
| `cert` | certificat TLS et jours restants |
| `disk` | espace disque, taille des volumes et des images |
| `logs [service]` | sortie du conteneur, en continu |
| `applog [fichier]` | journaux applicatifs DHIS2 — `dhis.log` par défaut |
| `db` | session `psql` sur Cloud SQL |
| `backup` | sauvegarde du magasin de fichiers |
| `start` / `stop` / `restart` | ⚠ **interrompent le service** |

**`logs` et `applog` ne montrent pas la même chose.** `logs` donne la sortie du conteneur
— démarrage de Tomcat, erreurs fatales. `applog` donne ce que DHIS2 écrit réellement dans
`dhis.log`, `dhis-audit.log` et les autres. Pour un problème fonctionnel, c'est `applog`.

### Mettre à jour les scripts sans déployer

Le pipeline dépose les scripts sur la VM à chaque déploiement. Pour les rafraîchir seuls —
mise au point, opération ponctuelle — depuis la racine du dépôt :

```bash
gcloud compute scp --recurse scripts vm-dhis2-app:~ \
  --zone=europe-west1-b --tunnel-through-iap --project=alima-dhis2-prod \
&& gcloud compute ssh vm-dhis2-app --zone=europe-west1-b --tunnel-through-iap \
  --project=alima-dhis2-prod \
  --command "sudo rm -rf /opt/alima/dhis2/scripts \
    && sudo cp -r ~/scripts /opt/alima/dhis2/scripts \
    && sudo chmod +x /opt/alima/dhis2/scripts/*.sh \
    && ls -l /opt/alima/dhis2/scripts"
```

Le répertoire est **remplacé**, pas fusionné : un script retiré du dépôt disparaît de la
VM, sans quoi une version obsolète y survivrait.

> Ce raccourci ne remplace pas un déploiement. Le prochain déploiement réécrira ces
> fichiers depuis la branche construite — toute correction doit donc aussi être commitée,
> sans quoi elle sera perdue.

---

## 3. Déployer une version

Le déploiement **ne se fait pas sur la VM**. Il passe par Cloud Build, avec approbation.

```bash
# 1. Construire (ou laisser le push sur main s'en charger)
git push origin main

gcloud builds submit --config=cloudbuild.yaml \
  --substitutions=_VCS_REF=$(git rev-parse --short HEAD) \
  --project=alima-dhis2-prod

# 2. Relever le tag produit, affiché en fin de construction
gcloud artifacts docker images list \
  europe-west1-docker.pkg.dev/alima-dhis2-prod/dhis2-images/dhis2-core \
  --include-tags --project=alima-dhis2-prod

# 3. Déployer ce tag
gcloud builds triggers run dhis2-deploy-prod --region=europe-west1 \
  --branch=main --substitutions=_IMAGE_TAG=<tag>
```

Puis **approuver** dans la console : Cloud Build → Historique → le build en attente.

Format des tags : `<version-dhis2>.<date>.<n° du jour>.<commit>`, par exemple
`2.41.9.1.20260814.05.1486613`. Le numéro du jour indique quelle image est la plus
récente — deux empreintes de commit ne s'ordonnent pas entre elles.

### Retour arrière

Relancer le même déploiement avec le **tag précédent**. Aucune reconstruction, quelques
minutes. Les tags restent disponibles 30 jours, les 10 plus récents étant conservés quoi
qu'il arrive.

---

## 4. Diagnostiquer

### L'application ne répond pas

```bash
# Sur la VM
dhis2ctl status        # un conteneur en « Restarting » désigne le coupable
dhis2ctl logs nginx    # ou dhis2, selon ce qu'indique status
dhis2ctl cert          # un certificat absent empêche Nginx de démarrer
```

Depuis le navigateur, le message oriente déjà :

| Symptôme | Signification |
|---|---|
| `ERR_CONNECTION_REFUSED` | le paquet atteint la VM, **rien n'écoute** — Nginx est arrêté |
| Délai d'attente | blocage réseau en amont — pare-feu, DNS, routage |
| `502 Bad Gateway` | Nginx tourne, mais DHIS2 derrière ne répond pas |

### Vérifier le DNS et le certificat depuis n'importe où

```bash
dig +short dhis2-test.alima.ngo          # doit renvoyer 34.38.89.219, et rien d'autre
curl -sI https://dhis2-test.alima.ngo/dhis-web-login/ | head -3
echo | openssl s_client -connect dhis2-test.alima.ngo:443 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

> **Plusieurs adresses en réponse à `dig`** est un problème : le trafic serait réparti
> entre elles. `dhis2.alima.ngo` est dans ce cas — un enregistrement résiduel vers
> `34.79.172.183`, sans lien avec ALIMA, à supprimer avant la bascule.

### Consulter les journaux depuis GCP

```bash
gcloud logging read \
  'resource.type="gce_instance" AND logName=~"dhis2_app"' \
  --limit=50 --project=alima-dhis2-prod --format='value(textPayload)'
```

### État de l'infrastructure

```bash
gcloud compute instances list --project=alima-dhis2-prod
gcloud sql instances describe pg16-dhis2-prod \
  --format="table(name,state,settings.edition,settings.tier)"
gcloud builds list --region=europe-west1 --limit=5 \
  --format="table(id,status,createTime.date('%d/%m %H:%M'))"
```

---

## 5. Secrets

Tous se lisent et s'écrivent **depuis ton poste**, jamais depuis la VM.

```bash
gcloud secrets list --project=alima-dhis2-prod

gcloud secrets versions access latest --secret=dhis2-fqdn --project=alima-dhis2-prod

# Modifier : on ajoute une version, on ne remplace jamais
printf '%s' 'nouvelle-valeur' \
  | gcloud secrets versions add dhis2-fqdn --data-file=- --project=alima-dhis2-prod
```

Un changement de secret ne prend effet qu'au **prochain déploiement** : c'est lui qui
régénère le `.env` de la VM.

> ⛔ **`dhis2-encryption-password` ne doit jamais changer.** Les données déjà chiffrées
> par DHIS2 deviendraient définitivement illisibles.

---

## 6. Sauvegardes

| Élément | Mécanisme | Fréquence |
|---|---|---|
| Base de données | sauvegardes automatiques Cloud SQL + PITR | continu |
| Magasin de fichiers | `dhis2ctl backup` vers Cloud Storage | hebdomadaire |
| Disque entier | snapshots | quotidien |

```bash
# Sur la VM
dhis2ctl backup

# Depuis le poste — sauvegardes présentes
gcloud storage ls gs://alima-dhis2-prod-dhis2-backups/filestore/
gcloud sql backups list --instance=pg16-dhis2-prod --limit=5
```

**Le magasin de fichiers n'est pas dans le dump PostgreSQL.** Restaurer la base sans lui
laisse des références vers des documents introuvables. Les deux se sauvegardent et se
restaurent ensemble.

---

## 7. Que faire si…

| Situation | Geste |
|---|---|
| L'application est lente | `dhis2ctl info` puis `dhis2ctl applog` — chercher les requêtes lentes |
| Le disque se remplit | `dhis2ctl disk` — les journaux sont bornés, suspecter les images |
| Le certificat approche de l'échéance | `dhis2ctl cert` — le renouvellement est automatique et vérifiable |
| Une version pose problème | redéployer le tag précédent (§3) |
| DHIS2 ne démarre plus après migration | `dhis2ctl applog` — chercher les lignes Flyway |
| Il faut couper le service | `dhis2ctl stop` — les volumes restent intacts |

---

## 8. Ne jamais faire

- **`docker compose down -v`** sur la VM — l'option `-v` détruit les volumes, donc le
  magasin de fichiers. Irrécupérable, et non couvert par les sauvegardes PostgreSQL.
- **Modifier un fichier sous `/opt/alima/dhis2`** — tout y est écrasé au déploiement
  suivant. Les corrections passent par le dépôt.
- **Déployer `latest`** — le pipeline le refuse : un tag mobile rend le retour arrière et
  l'audit impossibles.
- **Changer `dhis2-encryption-password`** — voir §5.
- **Exécuter `99-cleanup-gcp.sh`** sans avoir vérifié qu'une sauvegarde récente existe.

---

## Pour aller plus loin

| Document | Contenu |
|---|---|
| [`architecture-et-cicd.md`](architecture-et-cicd.md) | conception, décisions et leurs raisons |
| [`provisionnement-gcp.md`](provisionnement-gcp.md) | création de l'infrastructure, pas à pas |
