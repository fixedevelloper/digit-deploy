#!/bin/sh
# Point d'entrée commun à app (php-fpm), queue, scheduler, reverb et migrate.
# La configuration vient des variables d'environnement (api.env + docker-compose),
# il n'y a pas de fichier .env dans l'image.
set -e

cd /var/www

# Le volume storage est vide au premier démarrage : recrée l'arborescence attendue.
mkdir -p storage/app/public storage/framework/cache/data storage/framework/sessions \
         storage/framework/views storage/logs bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache

# Cache de config/événements/vues, généré au démarrage car il dépend des variables d'env.
su-exec www-data php artisan config:cache
su-exec www-data php artisan event:cache
su-exec www-data php artisan view:cache

# php-fpm démarre en root puis bascule ses workers en www-data ;
# toutes les autres commandes (artisan) tournent directement en www-data.
if [ "$1" = "php-fpm" ]; then
  exec "$@"
fi

exec su-exec www-data "$@"
