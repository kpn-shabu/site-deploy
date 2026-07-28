# php 系共用 image(純手寫 PHP 與 CodeIgniter 4 同用):php-fpm + nginx 同一容器。
# 主程式不進 image,由 compose 掛載 /srv/{{SITE}}(見 compose.override.yml / compose.prod.yml)。
FROM php:8.3-fpm-alpine

# nginx(與 php-fpm 同容器)與 curl(healthcheck 用)
RUN apk add --no-cache nginx curl

# PHP 擴充:pdo_pgsql(PostgreSQL)必裝。
# libpq 為執行期依賴須保留;build 工具鏈以 virtual package 裝完即拆。
RUN apk add --no-cache libpq \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS libpq-dev \
    && docker-php-ext-install -j"$(nproc)" pdo_pgsql pgsql opcache \
    && apk del .build-deps

# 常用擴充(視專案需要取消註解,放進上方同一個 build-deps 區塊亦可):
# RUN apk add --no-cache freetype libjpeg-turbo libpng \
#     && apk add --no-cache --virtual .gd-deps $PHPIZE_DEPS freetype-dev libjpeg-turbo-dev libpng-dev \
#     && docker-php-ext-configure gd --with-freetype --with-jpeg \
#     && docker-php-ext-install -j"$(nproc)" gd \
#     && apk del .gd-deps
# RUN apk add --no-cache libzip \
#     && apk add --no-cache --virtual .zip-deps $PHPIZE_DEPS libzip-dev \
#     && docker-php-ext-install -j"$(nproc)" zip \
#     && apk del .zip-deps

# composer:部署流程以一次性容器執行 composer install(見 SOP Phase 4),
# 故 image 內建 composer;git 與 unzip 為 composer 取套件所需。
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
RUN apk add --no-cache git unzip

# 生產 php.ini(opcache.validate_timestamps=0);
# 本機開發由 compose.override 掛 php.dev.ini 進 conf.d 覆蓋。
COPY php.ini /usr/local/etc/php/php.ini
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY reload-php /usr/local/bin/reload-php
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/reload-php

# healthcheck 打 nginx 的 /healthz(compose 亦定義同款 healthcheck)
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -fsS http://localhost/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
