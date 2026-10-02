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
| `scheduler` | `schedule:work` : lance `transaction:status` toutes les 15 s. |
| `reverb`    | Serveur WebSocket des notifications temps réel (app Flutter). |
| `migrate`   | Lance `migrate --force` à chaque démarrage puis s'arrête. |
| `db`        | MySQL, données dans le volume `db-data`. |
| `dashboard` | Console admin + espace marchand (Next.js). |

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
curl https://<API_DOMAIN>/up          # doit répondre 200
docker compose logs -f caddy          # en cas de problème de certificat
```

### 3.5 Données initiales

**Pays et opérateurs** :

```bash
docker compose exec app php artisan db:seed --class=CountrySeeder --force
```

> ⚠️ Ne **pas** lancer `db:seed` sans `--class` : `UserSeeder` crée un
> superadmin avec un mot de passe connu (`admin1234`) et un client de test.

**Compte administrateur** (remplacer téléphone, nom et mots de passe) :

```bash
docker compose exec app php artisan tinker --execute="
\App\Models\User::create([
    'name' => 'Administrateur',
    'phone' => '2420XXXXXXXX',
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
- **App Flutter** : `digit_app/lib/config/app_config.dart` doit avoir
  `baseUrl = https://<API_DOMAIN>/api`, `reverbWHost = <API_DOMAIN>`,
  `reverbPort = 443` et `reverbKey = <REVERB_APP_KEY>`.
- **Doc API marchande** : `https://<API_DOMAIN>/docs/api` (ou sous-domaine
  dédié : décommenter le bloc `DOCS_DOMAIN` du `Caddyfile` et renseigner
  `DOCS_DOMAIN` dans `.env` et `api.env`).
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
redémarrage de l'API et des workers. Faire une sauvegarde avant (section 6).

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

**Base de données** (à planifier quotidiennement via cron, et à copier hors du serveur) :

```bash
mkdir -p backups
docker compose exec -T db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines "$MYSQL_DATABASE"' \
  | gzip > backups/digit-$(date +%F-%H%M).sql.gz
```

Exemple de crontab (`crontab -e`), tous les jours à 2 h, conservation 14 jours :

```cron
0 2 * * * cd /chemin/digit-service/deploy && docker compose exec -T db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction "$MYSQL_DATABASE"' | gzip > backups/digit-$(date +\%F).sql.gz && find backups -name '*.sql.gz' -mtime +14 -delete
```

**Restauration** :

```bash
gunzip -c backups/digit-AAAA-MM-JJ.sql.gz | docker compose exec -T db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'
```

**Fichiers uploadés** (logos, drapeaux) :

```bash
docker run --rm -v digit_api-storage:/data -v "$PWD/backups":/backup alpine \
  tar czf /backup/storage-$(date +%F).tar.gz -C /data app/public
```

---

## 7. Dépannage

| Symptôme | Piste |
|----------|-------|
| `migrate` en erreur | `docker compose logs migrate` — souvent un mot de passe DB différent entre `.env` et un volume `db-data` déjà initialisé. |
| 500 sur toutes les routes | `APP_KEY` vide ou invalide dans `api.env`. |
| Certificat HTTPS non obtenu | DNS pas encore propagé, ou ports 80/443 fermés. `docker compose logs caddy`. |
| Dashboard : erreurs CORS | `FRONTEND_URL` doit être exactement `https://<DASHBOARD_DOMAIN>` (sans `/` final). |
| Pas de notifications temps réel | `REVERB_APP_KEY` ≠ `reverbKey` de l'app Flutter, ou `docker compose logs reverb`. |
| Webhooks Digitwave rejetés (401/500) | `DIGITWAVE_WEBHOOK_SECRET` absent ou incorrect. |
| Transactions bloquées en `pending` | `docker compose logs queue scheduler`. |

---

## 8. Fichiers de ce dossier

| Fichier | Rôle |
|---------|------|
| `docker-compose.yml` | Définition des services de production. |
| `.env.example` → `.env` | Domaines, email ACME, identifiants MySQL. |
| `api.env.example` → `api.env` | Configuration Laravel (secrets applicatifs). |
| `Caddyfile` | Routage HTTPS public. |
| `api/Dockerfile` | Images PHP-FPM (`app`) et nginx (`web`). |
| `api/nginx.conf`, `api/php.ini`, `api/entrypoint.sh` | Configuration de l'image API. |
| `dashboard/Dockerfile` | Image Next.js de production. |

`.env`, `api.env` et `backups/` sont ignorés par git (`deploy/.gitignore`).
