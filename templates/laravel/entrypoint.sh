#!/bin/sh
# {{SITE}} — app 容器 entrypoint:先以 daemon 模式啟動 php-fpm,
# 再讓 nginx 以前景模式接手(exec 使 nginx 成為主行程,收容器訊號)
set -e

# 收到參數時直接執行該指令(與 templates/php 行為一致;
# 雖然本模板用 CMD 啟動、run --rm 會整個覆蓋,仍保留此保護以防 Dockerfile 改回 ENTRYPOINT)
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

php-fpm -D
exec nginx -g 'daemon off;'
