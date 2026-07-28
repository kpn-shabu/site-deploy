#!/bin/sh
# 容器 entrypoint:先以 daemon 模式啟動 php-fpm,
# 再以 exec 讓 nginx 佔住前景(接手 PID 1,容器生命週期跟隨 nginx)。
set -e

# 收到參數時直接執行該指令——deploy 的一次性容器(run --rm app <cmd>)依賴此行為,
# 否則指令會被當成 entrypoint 參數丟棄、容器卡在 nginx 前景
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

php-fpm -D
exec nginx -g 'daemon off;'
