# Déploiement Docker — Digit Gateway

Ce dossier contient tout le nécessaire pour déployer l'API Laravel, ses workers
et le dashboard Next.js sur un serveur avec Docker, en HTTPS.

> Le `docker-compose.yml` à la racine du projet reste l'environnement de
> **développement**. Celui de ce dossier est celui de **production**.

> ⚠️ **Avant de faire passer de l'argent réel**, corriger les points critiques
> 1 à 3 de `../audit.txt` (versements en double, clés sandbox qui touchent la
> production, PIN sans limite de tentatives).

---

## 1. Architecture

```
                     Internet (80 / 443)
                            │
                        ┌───▼───┐   HTTPS automatique (Let's Encrypt)
                        │ caddy │
                        └───┬───┘
        API_DOMAIN          │            DASHBOARD_DOMAIN
   ┌────────────────────────┼─────────────────────┐
   │ /app/*  (WebSocket)    │ tout le reste       │
┌──▼─────┐            ┌─────▼─┐             ┌─────▼─────┐
│ reverb │            │  web  │ nginx       │ dashboard │ Next.js
└────────┘            └───┬───┘             └───────────┘
                          │ FastCGI
                      ┌───▼───┐   ┌───────┐  ┌───────────┐
                      │  app  │   │ queue │  │ scheduler │   (même image PHP)
                      └───┬───┘   └───┬───┘  └─────┬─────┘
                          └───────────┼────────────┘
                                  ┌───▼───┐
                                  │  db   │ MySQL 8.4
                                  └───────┘
```

| Service     | Rôle |
|-------------|------|
| `caddy`     | Seul service exposé. Reverse proxy + certificats HTTPS. |
| `web`       | nginx : sert `public/` et `/storage/*` (logos, drapeaux), transmet le PHP à `app`. |
| `app`       | PHP-FPM, exécute l'API Laravel. |
| `queue`     | `queue:work` : traite les transferts, retraits et dépôts (jobs Digitwave). |
| `scheduler` | `schedule:work` : `transaction:status` (15 s), `transaction:reconcile` (5 min), `monitor:check` (1 min). |
| `reverb`    | Serveur WebSocket des notifications temps réel (app Flutter). |
| `migrate`   | Lance `migrate --force` à chaque démarrage puis s'arrête. |
| `db`        | MySQL, données dans le volume `db-data`. |
| `dashboard` | Console admin + espace marchand (Next.js). |
| `backup`    | Sauvegarde quotidienne de la base et des fichiers (chiffrée, copie hors serveur), test de restauration hebdomadaire. |

Volumes persistants : `db-data` (base), `api-storage` (logs, fichiers uploadés),
`caddy-data` (certificats).

---

## 2. Prérequis

- Un serveur Linux (2 vCPU / 4 Go RAM conseillés) avec **Docker Engine** et
  **Docker Compose v2** : https://docs.docker.com/engine/install/
- Deux noms de domaine (ou sous-domaines) pointant (enregistrement **A**) vers
  l'IP du serveur :
  - `API_DOMAIN` (ex. `digitapp.guens.org`) — c'est celui que l'app Flutter appelle
    (`digit_app/lib/config/app_config.dart`) ;
  - `DASHBOARD_DOMAIN` (ex. `admin.digitapp.guens.org`).
- Pare-feu : n'ouvrir que les ports **22, 80, 443** (TCP) et **443/UDP**.

```bash
sudo ufw allow 22/tcp && sudo ufw allow 80/tcp && sudo ufw allow 443 && sudo ufw enable
```

---

## 3. Premier déploiement

### 3.1 Récupérer le code

Le code est réparti sur trois dépôts, à cloner les uns dans les autres :

```bash
git clone <url-du-depot-digit-service> digit-service
cd digit-service
git clone https://github.com/fixedevelloper/digit.gateway.git digit-api
git clone https://github.com/fixedevelloper/digitweb.git digit-dashboard
cd deploy
```

Les noms de dossiers `digit-api/` et `digit-dashboard/` sont obligatoires :
`docker-compose.yml` les référence. L'app Flutter (`digit_app`) n'est pas
nécessaire sur le serveur.

### 3.2 Variables du compose (domaines, base de données)

```bash
cp .env.example .env
nano .env
```

Renseigner `API_DOMAIN`, `DASHBOARD_DOMAIN`, `ACME_EMAIL`, et générer les mots de passe :

```bash
openssl rand -base64 24   # pour DB_PASSWORD
openssl rand -base64 24   # pour DB_ROOT_PASSWORD
```

### 3.3 Configuration Laravel

```bash
cp api.env.example api.env
nano api.env
```

À renseigner obligatoirement :

| Variable | Valeur |
|----------|--------|
| `APP_URL` | `https://<API_DOMAIN>` |
| `FRONTEND_URL` | `https://<DASHBOARD_DOMAIN>` (CORS) |
| `APP_KEY` | voir ci-dessous |
| `REVERB_APP_ID` | n'importe quel identifiant, ex. `digit` |
| `REVERB_APP_KEY` | **la même valeur que `AppConfig.reverbKey` dans l'app Flutter** |
| `REVERB_APP_SECRET` | `openssl rand -hex 32` |
| `DIGITWAVE_API_KEY` | clé API Digitwave de production |
| `DIGITWAVE_WEBHOOK_SECRET` | secret HMAC (`agswhsec_...`) du dashboard Digitwave |

Générer `APP_KEY` (construit l'image au passage) :

```bash
docker compose build
docker compose run --rm --no-deps app php artisan key:generate --show
```

Copier la valeur affichée (`base64:...`) dans `APP_KEY` de `api.env`.

> Ne jamais changer `APP_KEY` une fois en production : les données chiffrées
> deviendraient illisibles.

Sécuriser les fichiers de secrets :

```bash
chmod 600 .env api.env
```

### 3.4 Démarrer

```bash
docker compose up -d
docker compose ps
```

Au premier démarrage, `migrate` crée les tables puis passe en `exited (0)` —
c'est normal. Caddy obtient les certificats HTTPS en quelques secondes (les DNS
doivent déjà pointer vers le serveur).

Vérifier :

```bash
curl https://api.digitagateway.com/up          # doit répondre 200
docker compose logs -f caddy          # en cas de problème de certificat
```

### 3.5 Données initiales

**Pays et opérateurs** :

```bash
docker compose exec app php artisan db:seed --class=CountrySeeder --force
```

**Providers** (permet à l'admin de désactiver Digitwave globalement ; idempotent) :

```bash
docker compose exec app php artisan db:seed --class=ProviderSeeder --force
```

> ⚠️ Ne **pas** lancer `db:seed` sans `--class` : `UserSeeder` crée un
> superadmin avec un mot de passe connu (`admin1234`) et un client de test.

**Compte administrateur** (remplacer téléphone, nom et mots de passe) :

```bash
docker compose exec app php artisan tinker --execute="
\App\Models\User::create([
    'name' => 'Administrateur',
    'phone' => '242064449019',
    'password' => 'MOT_DE_PASSE_FORT',
    'transaction_pin' => '1234',
    'role' => 'superadmin',
    'status' => true,
]);"
```

(Les champs `password` et `transaction_pin` sont hachés automatiquement par le modèle.)

**Agences de retrait** :

```bash
docker compose exec app php artisan agency:create --help
```

### 3.6 Configurer Digitwave

Dans le dashboard Digitwave, déclarer l'URL de webhook :

```
https://<API_DOMAIN>/api/webhooks/digitwave
```

### 3.7 Applications clientes

- **Dashboard** : `https://<DASHBOARD_DOMAIN>` — l'URL de l'API
  (`https://<API_DOMAIN>/api`) est intégrée **au build** ; changer de domaine
  impose `docker compose up -d --build dashboard`.
  **Sessions** : les jetons (admin, marchand, agent) ne sont plus dans `localStorage` mais
  dans des **cookies HttpOnly** posés par le serveur Next.js, qui relaie les appels du
  navigateur vers l'API (`/bff/*`) par le réseau Docker interne (`API_INTERNAL_URL=http://web/api`,
  déjà défini dans `docker-compose.yml`). Conséquences : HTTPS obligatoire (cookie `Secure`
  préfixé `__Host-`), et les utilisateurs devront **se reconnecter une fois** après la mise à
  jour. Durée de session : 8 h (admin), 12 h (agent), 7 j (marchand).
- **App Flutter** : `digit_app/lib/config/app_config.dart` doit avoir
  `baseUrl = https://<API_DOMAIN>/api`, `reverbWHost = <API_DOMAIN>`,
  `reverbPort = 443` et `reverbKey = <REVERB_APP_KEY>`.
- **Doc API marchande** : `https://<DOCS_DOMAIN>/` — `DOCS_DOMAIN` doit être
  renseigné à l'identique dans `.env` (certificat HTTPS Caddy) **et** dans
  `api.env` (routes Scramble), avec un enregistrement DNS A vers le serveur.
  ⚠️ En production, Scramble répond **403** tant qu'aucune règle d'accès
  n'est définie. Pour la rendre publique aux marchands, ajouter dans
  `AppServiceProvider::boot()` :
  `Gate::define('viewApiDocs', fn ($user = null) => true);`

---

## 4. Mettre à jour

```bash
cd digit-service
git pull
git -C digit-api pull
git -C digit-dashboard pull
cd deploy
docker compose up -d --build
```

Les migrations s'exécutent automatiquement (service `migrate`) avant le
redémarrage de l'API et des workers. Faire une sauvegarde avant : `docker compose run --rm backup once` (section 6).

Nettoyer les anciennes images de temps en temps : `docker image prune -f`.

---

## 5. Exploitation courante

```bash
docker compose ps                          # état des services
docker compose logs -f queue               # logs d'un service (stdout)
docker compose exec app ls storage/logs    # logs Laravel (fichier par jour)
docker compose exec app tail -f storage/logs/laravel-$(date +%F).log
docker compose exec app php artisan tinker # console
docker compose restart queue               # redémarrer un service
docker compose exec app php artisan queue:failed   # jobs en échec
```

Après toute modification de `api.env` : `docker compose up -d` (recrée les
conteneurs concernés ; la config est remise en cache au démarrage).

---

## 6. Sauvegardes

Le service **`backup`** (déjà dans `docker-compose.yml`) sauvegarde **chaque jour à
`BACKUP_TIME` (UTC, 02:30 par défaut)** :

| Quoi | Fichier dans `deploy/backups/` |
|------|-------------------------------|
| Base MySQL (cohérente, `--single-transaction`) | `digit-db-AAAAMMJJ-HHMMSS.sql.gz` |
| Fichiers uploadés : logos, preuves de transfert, **pièces KYC** (`storage/app`) | `digit-files-AAAAMMJJ-HHMMSS.tar.gz` |
| Empreintes SHA-256 | `digit-AAAAMMJJ-HHMMSS.sha256` |
| État (dernier succès, dernier test de restauration) | `status.json` |

Garanties du script (`backup/backup.sh`, testé de bout en bout) :

- un dump **tronqué ou anormalement petit est refusé** (gzip valide + ligne finale de `mysqldump`) ;
- **test de restauration automatique chaque dimanche** (`BACKUP_VERIFY_WEEKDAY`) : le dump est
  rechargé dans une base jetable et on compte tables / utilisateurs / transactions. Une
  sauvegarde jamais restaurée n'est pas une sauvegarde ;
- l'empreinte est vérifiée avant restauration (détecte un fichier corrompu) ;
- espace disque contrôlé avant chaque sauvegarde ; conservation locale `BACKUP_RETENTION_DAYS` (14 j).

### À configurer avant la mise en production

Dans `deploy/.env` :

1. **`BACKUP_PASSPHRASE`** — chiffre les sauvegardes (AES-256) : elles contiennent des données
   personnelles et des pièces d'identité. `openssl rand -base64 32`, puis **conservez cette
   phrase hors du serveur** (gestionnaire de mots de passe) : sans elle, les sauvegardes sont
   définitivement illisibles.
2. **Copie hors serveur** (`BACKUP_RCLONE_REMOTE` + `RCLONE_CONFIG_OFFSITE_*`) — sans elle, la perte
   du serveur emporte aussi les sauvegardes. Exemple S3 / MinIO / Backblaze B2 / Wasabi :

   ```env
   BACKUP_RCLONE_REMOTE=offsite:nom-du-bucket/digit
   RCLONE_CONFIG_OFFSITE_TYPE=s3
   RCLONE_CONFIG_OFFSITE_PROVIDER=Other        # AWS, Minio, Wasabi, Other…
   RCLONE_CONFIG_OFFSITE_ENDPOINT=https://s3.exemple.com
   RCLONE_CONFIG_OFFSITE_ACCESS_KEY_ID=...
   RCLONE_CONFIG_OFFSITE_SECRET_ACCESS_KEY=...
   ```

   Créez une clé d'accès limitée à ce bucket (écriture + lecture, **pas de suppression de
   masse**) et activez le versionnage / la protection d'objets côté fournisseur.
3. **Alertes** — `BACKUP_ALERT_WEBHOOK_URL` (Slack/Discord/Mattermost) prévient d'un échec.
   `BACKUP_HEARTBEAT_URL` (healthchecks.io, Uptime Kuma « push ») est appelée après chaque
   succès : l'outil externe alerte si **aucun** ping n'arrive (conteneur arrêté, serveur HS).

Le démarrage du service affiche un avertissement tant que le chiffrement ou la copie hors
serveur ne sont pas configurés : `docker compose logs backup`.

### Commandes

```bash
docker compose up -d --build backup            # (re)démarrer le service
docker compose run --rm backup once            # sauvegarde immédiate (avant une mise à jour !)
docker compose run --rm backup verify          # test de restauration du dernier dump
cat backups/status.json                        # dernier succès / dernier test
docker compose logs backup                     # journal
```

### Restaurer

**Base** — ⚠️ écrase les données actuelles ; arrêter l'API avant :

```bash
docker compose stop app queue scheduler reverb web
docker compose run --rm backup restore /backups/digit-db-AAAAMMJJ-HHMMSS.sql.gz --yes
docker compose up -d
```

Un fichier `.enc` est déchiffré automatiquement si `BACKUP_PASSPHRASE` est défini dans `.env`.
Si le fichier vient de la copie hors serveur, le déposer d'abord dans `deploy/backups/`
(`rclone copy offsite:bucket/digit/<fichier> backups/`).

**Fichiers uploadés** (logos, preuves, pièces KYC) :

```bash
# archive chiffrée : openssl enc -d -aes-256-cbc -pbkdf2 -in digit-files-….tar.gz.enc -out digit-files.tar.gz
docker run --rm -v digit_api-storage:/data -v "$PWD/backups":/backups alpine \
  tar xzf /backups/digit-files-AAAAMMJJ-HHMMSS.tar.gz -C /data
```

> Faites **un exercice de restauration complet** sur une machine de test avant la mise en
> production, et notez le temps nécessaire.

---

## 7. Supervision

Trois niveaux complémentaires :

### 7.1 Contrôles métier (intégrés à l'API)

Le scheduler exécute `php artisan monitor:check` **chaque minute**. Chaque contrôle est
indépendant ; un changement d'état envoie **une alerte** (puis la **résolution**, et un rappel
toutes les heures si le problème persiste).

| Contrôle | Alerte quand… | Gravité |
|----------|---------------|---------|
| File d'attente | un job attend ou est bloqué depuis > 5 / 15 min (le worker `queue` ne consomme plus) | critique |
| Transactions non envoyées | une transaction automatique débitée n'est jamais soumise à Digitwave après 10 min | critique |
| Taux d'échec | ≥ 50 % d'échecs sur 30 min (≥ 5 transactions) : Digitwave ou un opérateur en panne | critique |
| Espace disque | < 2 Go libres | critique |
| Jobs en échec | des jobs échouent (≥ 5 en 1 h : critique) | attention |
| À rapprocher | des transactions attendent un rapprochement manuel | attention |
| File manuelle | un transfert manuel n'est pas pris en charge depuis > 4 h | attention |
| Webhooks marchands | ≥ 10 livraisons abandonnées en 1 h | attention |

De plus, **tout job qui échoue définitivement** alerte immédiatement (dédoublonné).

Configuration (`deploy/api.env`) : `MONITOR_ALERT_WEBHOOK_URL` (Slack/Discord/Mattermost/ntfy),
`MONITOR_ALERT_EMAIL` (nécessite un vrai `MAIL_MAILER`), seuils `MONITOR_*`. Sans canal
configuré, les alertes restent dans les logs (`[MONITORING]`, niveau critical/warning).

L'état en direct est visible dans le dashboard : **Supervision** (menu), et via
`GET /api/admin/monitoring`. Il signale aussi un **scheduler arrêté** (aucun passage depuis 5 min).

```bash
docker compose exec app php artisan monitor:check     # lancer les contrôles à la main
```

### 7.2 Signal de vie (alerte si TOUT est arrêté)

Une alerte envoyée *par* le serveur ne peut pas signaler que le serveur est tombé. Créez un
moniteur « heartbeat » gratuit (healthchecks.io ou Uptime Kuma, période 1 min, tolérance 5 min)
et placez son URL dans `MONITOR_HEARTBEAT_URL` (api.env) : l'API la pingue à chaque contrôle.
Faites de même pour les sauvegardes avec `BACKUP_HEARTBEAT_URL` (période 24 h, tolérance 2 h).

### 7.3 Disponibilité externe

Surveillez depuis l'extérieur (UptimeRobot, Uptime Kuma, Better Stack…) :

- `https://<API_DOMAIN>/up` — l'API répond 200 ;
- `https://<DASHBOARD_DOMAIN>/` — le dashboard ;
- l'expiration du certificat HTTPS (la plupart des outils le font).

### Ce qui n'est PAS surveillé

- **Le solde Digitwave** : l'API Digitwave utilisée ici n'expose pas de solde (seulement
  envoi, retrait et statut). Demandez-leur un endpoint de solde ; en attendant, suivez-le dans
  leur dashboard ou fixez une alerte de leur côté.
- **L'état du serveur** (CPU, RAM, disque hôte) : installez un agent (Netdata, node_exporter…)
  ou utilisez la supervision de votre hébergeur.

---

## 8. Dépannage

| Symptôme | Piste |
|----------|-------|
| `migrate` en erreur | `docker compose logs migrate` — souvent un mot de passe DB différent entre `.env` et un volume `db-data` déjà initialisé. |
| 500 sur toutes les routes | `APP_KEY` vide ou invalide dans `api.env`. |
| Certificat HTTPS non obtenu | DNS pas encore propagé, ou ports 80/443 fermés. `docker compose logs caddy`. |
| Dashboard : « serveur injoignable » (502) à la connexion | `docker compose logs dashboard` ; vérifier `API_INTERNAL_URL` (`http://web/api`) et que `web`/`app` sont démarrés. |
| Dashboard : déconnecté en boucle | HTTPS requis pour le cookie de session ; vérifier que Caddy transmet `X-Forwarded-Proto` (par défaut oui) et l'horloge du serveur. |
| Trop de « 429 » à la connexion pour tout le monde | L'IP du visiteur n'arrive pas à l'API : `X-Forwarded-For` doit traverser Caddy → dashboard → web. |
| Pas de notifications temps réel | `REVERB_APP_KEY` ≠ `reverbKey` de l'app Flutter, ou `docker compose logs reverb`. |
| Webhooks Digitwave rejetés (401/500) | `DIGITWAVE_WEBHOOK_SECRET` absent ou incorrect. |
| Transactions bloquées en `pending` | `docker compose logs queue scheduler` ; voir aussi le dashboard **Supervision**. |
| Pas de sauvegarde / alerte `backup` | `docker compose logs backup`, `cat backups/status.json`. |

---

## 9. Fichiers de ce dossier

| Fichier | Rôle |
|---------|------|
| `docker-compose.yml` | Définition des services de production. |
| `.env.example` → `.env` | Domaines, email ACME, identifiants MySQL. |
| `api.env.example` → `api.env` | Configuration Laravel (secrets applicatifs). |
| `Caddyfile` | Routage HTTPS public. |
| `api/Dockerfile` | Images PHP-FPM (`app`) et nginx (`web`). |
| `api/nginx.conf`, `api/php.ini`, `api/entrypoint.sh` | Configuration de l'image API. |
| `dashboard/Dockerfile` | Image Next.js de production. |
| `backup/Dockerfile`, `backup/backup.sh` | Service de sauvegarde / restauration (base + fichiers, chiffrement, copie hors serveur). |

`.env`, `api.env` et `backups/` sont ignorés par git (`deploy/.gitignore`).

cd deploy && docker compose up -d --build
