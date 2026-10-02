# syntax=docker/dockerfile:1
#
# Image de production de l'API Laravel. Deux cibles :
#   - app : PHP-FPM (+ réutilisée pour queue, scheduler, reverb, migrate)
#   - web : nginx, sert public/ et transmet les requêtes PHP à app:9000
#
# Contexte de build : ../digit-api
# Contexte additionnel "deploy" : ./api (ce dossier), pour nginx.conf, php.ini, entrypoint.sh

FROM composer:2 AS composer

# ---------------------------------------------------------------------------
FROM php:8.3-fpm-alpine AS app

# Extensions requises par composer.lock : pdo_mysql, intl, bcmath, zip/gd (phpspreadsheet),
# pcntl (arrêt propre de queue:work / reverb), opcache. mbstring, dom, xml, curl,
# fileinfo, iconv... sont déjà compilées dans l'image officielle.
RUN apk add --no-cache icu-libs libzip libpng libjpeg-turbo freetype su-exec \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS icu-dev libzip-dev libpng-dev libjpeg-turbo-dev freetype-dev linux-headers \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql intl bcmath zip gd pcntl opcache \
    && apk del .build-deps

RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY --from=deploy php.ini "$PHP_INI_DIR/conf.d/zz-digit.ini"

COPY --from=composer /usr/bin/composer /usr/bin/composer

WORKDIR /var/www

COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --no-scripts --no-autoloader --prefer-dist

COPY . .
RUN composer dump-autoload --optimize --no-dev \
    && rm -f /usr/bin/composer \
    && chown -R www-data:www-data storage bootstrap/cache

COPY --from=deploy entrypoint.sh /usr/local/bin/digit-entrypoint
RUN chmod +x /usr/local/bin/digit-entrypoint

ENTRYPOINT ["digit-entrypoint"]
CMD ["php-fpm"]

# ---------------------------------------------------------------------------
FROM nginx:1.27-alpine AS web

COPY --from=deploy nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=app /var/www/public /var/www/public
