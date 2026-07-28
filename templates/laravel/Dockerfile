# {{SITE}} — app image(Laravel:php-fpm + nginx 同一容器)
# 只燒核心 runtime;主程式不進 image,由 compose 掛載 /srv/{{SITE}}。
FROM php:8.3-fpm-alpine

# nginx 與必要套件:
# - libpq:pdo_pgsql 的 runtime 依賴
# - git / unzip:composer 安裝依賴(create-project、install --no-dev)所需
RUN apk add --no-cache nginx libpq git unzip \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS libpq-dev \
    && docker-php-ext-install -j"$(nproc)" pdo_pgsql opcache \
    && apk del .build-deps \
    && mkdir -p /run/nginx

# composer(deploy 以一次性容器執行 composer install --no-dev)
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# nginx 主設定與 PHP 生產設定(本機開發由 compose.override.yml
# 另掛 php.dev.ini 進 conf.d 覆蓋 opcache 驗證)
COPY nginx.conf /etc/nginx/nginx.conf
COPY php.ini /usr/local/etc/php/conf.d/site.ini

# entrypoint:php-fpm -D 後由 nginx 佔前景;reload-php:換版後平滑 reload php-fpm
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY reload-php /usr/local/bin/reload-php
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/reload-php

# 預設工作目錄:讓 exec/run 的 artisan 指令(如 schedule:run)不需另指定 -w
WORKDIR /srv/{{SITE}}/current/src

EXPOSE 80

# 用 CMD 而非 ENTRYPOINT:deploy 的 `run --rm app composer ...` 才能直接覆蓋指令
CMD ["/usr/local/bin/entrypoint.sh"]
